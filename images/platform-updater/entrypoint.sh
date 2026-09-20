#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (plan 2026-09-18-foundation-platform-separation §3/§4, E1) — the in-cluster Platform
# updater. Runs as a Kubernetes Job, created by the API, under ServiceAccount
# <release>-platform-updater. Works the same on K3s, BYO Kubernetes and AKS: it only talks to the
# Kubernetes API, Helm and Postgres, never to the host.
#
#   apply --version <v> [--manifest-url <url>]
#       1. refuse if another update is running or the release is not in a deployed state;
#       2. TRUST (owner decision 2026-09-18: HTTPS + digest pinning, no signing key required):
#          read the update channel (cg-onprem-channel-v1) over https from the configured channel
#          URL; download the release manifest (cg-release-manifest-v1) it lists for <v>, over https
#          from the channel host (or a host listed in platformUpdater.trust.allowedHosts); refuse
#          unless the manifest's SHA-256 equals the channel's latest.manifestSha256. A cosign
#          signature (<manifest url>.sig) is OPTIONAL: verified when a public key is configured
#          (platformUpdater.signing.publicKey), not required when none is;
#       3. check the manifest: platform == <v>, not a dry run, the installed version is inside
#          upgradeFrom, every first-party image pinned by @sha256 digest (an unpinned image is
#          refused);
#       4. download the chart, check its SHA-256 against the manifest, and refuse if the running
#          cluster is outside the chart's kubeVersion;
#       5. pg_dump the database to the backup volume;
#       4c. permission pre-check: refuse (changing nothing) when the new chart needs cluster-scoped
#          rights the namespace-scoped updater does not have, naming the one-time admin command;
#       6. helm upgrade --reset-then-reuse-values with the pinned tag and digests;
#       7. health gate: rollout status of every Deployment/StatefulSet/DaemonSet in the release,
#          then the API's readiness endpoint;
#       8. on any failure after step 5: stop the API, restore the database, helm rollback.
#   apply --version <v> --bundle <cloudgrange-platform-<v>.zip> --bundle-sha256 <hex>  (AB#9171 E7)
#       The same steps from an uploaded offline Platform bundle instead of the network (air-gapped).
#       TRUST: the zip's SHA-256 must equal --bundle-sha256, the value the administrator saw in the
#       portal and confirmed against the published cloudgrange-platform-<v>.zip.sha256 (owner
#       decision 2026-09-18: no signing key; an uploaded bundle is trusted by that SHA-256). Inside,
#       the manifest, the chart and the images all come from the bundle and are pinned exactly as
#       online (chart SHA-256, first-party image digests, images.txt SHA-256, every image by digest);
#       a signature is checked only when a key is configured. After step 4 the updater also checks
#       that every image the target chart renders is in the bundle and, when CLOUDGRANGE_AIRGAP_REGISTRY
#       is set (the chart's in-cluster registry, airgap.registry.enabled), pushes every image there
#       with crane and checks each pushed digest against its pin. Nothing is pushed or changed if any
#       check fails. Without CLOUDGRANGE_AIRGAP_REGISTRY (bring-your-own Kubernetes) the images must
#       already be in the customer's mirror (global.imageRegistry). A bundle that carries modules
#       (modules/catalog.json) has its catalog published to the modules volume once the update succeeded.
#   load-images --bundle <cloudgrange-modules-*.zip> --bundle-sha256 <hex>                    (E7)
#       An offline MODULE bundle: the same SHA-256 trust, its images pushed into the in-cluster
#       registry, then its module catalog published so the API offers those modules offline.
#   rollback
#       Roll back to the release revision recorded by the last successful apply and restore the
#       database backup it took.
#
# Progress goes to ConfigMap cloudgrange-platform-update-status with keys state
# (idle|running|succeeded|failed|rolled-back), fromVersion, toVersion, message, updatedAt.
#
# Environment (all optional; the API may pass the first two, see job.example.yaml):
#   CLOUDGRANGE_RELEASE_NAME   Helm release (default: the one cloudgrange release in the namespace)
#   CLOUDGRANGE_NAMESPACE      namespace (default: this pod's namespace)
#   CLOUDGRANGE_BACKUP_DIR     backup volume mount (default /backups)
#   CLOUDGRANGE_HEALTH_TIMEOUT rollout timeout (default 10m)
#   CLOUDGRANGE_SIGNING_KEY_FILE  optional cosign public key file (default: ConfigMap
#                              <release>-platform-updater-signing; neither = signatures not checked)
#   CLOUDGRANGE_UPDATE_CHANNEL_URL   the update channel (default: ConfigMap
#                              <release>-platform-updater-trust, key channelUrl, rendered by the chart
#                              from api.updateChannel — the same URL the API reads)
#   CLOUDGRANGE_UPDATE_ALLOWED_HOSTS extra hosts (space/comma separated) the manifest and chart may
#                              come from besides the channel host (default: ConfigMap key allowedHosts)
#   CLOUDGRANGE_UPDATE_CA_FILE       extra PEM CA bundle for a private https mirror (default:
#                              ConfigMap key caBundle); added to the system CAs, never replacing them
#   CLOUDGRANGE_AIRGAP_REGISTRY      host:port of the in-cluster registry's push side (bundle and
#                              load-images modes; AB#9171 E7)
set -uo pipefail

STATUS_CM=cloudgrange-platform-update-status
NS=${CLOUDGRANGE_NAMESPACE:-}
RELEASE=${CLOUDGRANGE_RELEASE_NAME:-}
BACKUP_DIR=${CLOUDGRANGE_BACKUP_DIR:-/backups}
HEALTH_TIMEOUT=${CLOUDGRANGE_HEALTH_TIMEOUT:-10m}
KEEP_BACKUPS=${CLOUDGRANGE_KEEP_BACKUPS:-3}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FROM_VERSION='' TO_VERSION=''

log() { echo "[platform-updater $(date -u +%H:%M:%S)] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
    cat >&2 <<'EOF'
usage: cloudgrange-platform-updater apply --version <YYMM.MINOR.PATCH[-pre]> [--manifest-url <url>]
       cloudgrange-platform-updater apply --version <v> --bundle <file.zip> --bundle-sha256 <hex>
       cloudgrange-platform-updater verify --version <v> [--manifest-url <url>]
       cloudgrange-platform-updater load-images --bundle <file.zip> --bundle-sha256 <hex>
       cloudgrange-platform-updater rollback
       cloudgrange-platform-updater check-kube-range <range> [<kube-version>]
EOF
    exit 2
}

# ---- SemVer ------------------------------------------------------------------------------------
# semver_cmp A B -> prints -1, 0 or 1. SemVer 2.0 precedence; build metadata (+...) is ignored.
semver_cmp() {
    local a=${1#v} b=${2#v}
    a=${a%%+*}; b=${b%%+*}
    local ac=${a%%-*} bc=${b%%-*} ap='' bp=''
    [[ "$a" == *-* ]] && ap=${a#*-}
    [[ "$b" == *-* ]] && bp=${b#*-}
    local IFS=.
    local -a an=($ac) bn=($bc)
    local i
    for i in 0 1 2; do
        local x=${an[$i]:-0} y=${bn[$i]:-0}
        ((10#$x > 10#$y)) && { echo 1; return; }
        ((10#$x < 10#$y)) && { echo -1; return; }
    done
    [ -z "$ap" ] && [ -z "$bp" ] && { echo 0; return; }
    [ -z "$ap" ] && { echo 1; return; }
    [ -z "$bp" ] && { echo -1; return; }
    local -a ai=($ap) bi=($bp)
    local n=${#ai[@]}; ((${#bi[@]} > n)) && n=${#bi[@]}
    for ((i = 0; i < n; i++)); do
        local x=${ai[$i]:-} y=${bi[$i]:-}
        [ -z "$x" ] && { echo -1; return; }
        [ -z "$y" ] && { echo 1; return; }
        if [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]]; then
            ((10#$x > 10#$y)) && { echo 1; return; }
            ((10#$x < 10#$y)) && { echo -1; return; }
        elif [[ "$x" =~ ^[0-9]+$ ]]; then echo -1; return
        elif [[ "$y" =~ ^[0-9]+$ ]]; then echo 1; return
        else
            [[ "$x" > "$y" ]] && { echo 1; return; }
            [[ "$x" < "$y" ]] && { echo -1; return; }
        fi
    done
    echo 0
}

# in_range VERSION "RANGE": RANGE is space-separated comparators (>=, >, <=, <, =), all of which
# must hold — the form Chart.yaml kubeVersion and the manifest's upgradeFrom use. The build
# metadata of VERSION is dropped and, as Helm does for kubeVersion, a pre-release suffix of the
# version under test is ignored ("v1.36.4+k3s1" and "v1.36.4-eks-1" both test as 1.36.4).
in_range() {
    local v=${1#v} range=$2 c op want r
    v=${v%%+*}; v=${v%%-*}
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [ -n "$range" ] || return 1
    for c in $range; do
        [[ "$c" =~ ^(>=|<=|>|<|=)?v?([0-9][0-9A-Za-z.+-]*)$ ]] || return 1
        op=${BASH_REMATCH[1]:-=}; want=${BASH_REMATCH[2]}
        r=$(semver_cmp "$v" "$want")
        case "$op" in
            '>=') [ "$r" -ge 0 ] || return 1 ;;
            '>')  [ "$r" -gt 0 ] || return 1 ;;
            '<=') [ "$r" -le 0 ] || return 1 ;;
            '<')  [ "$r" -lt 0 ] || return 1 ;;
            '=')  [ "$r" -eq 0 ] || return 1 ;;
        esac
    done
    return 0
}

# ---- Kubernetes helpers ------------------------------------------------------------------------
resolve_target() {
    if [ -z "$NS" ]; then
        NS=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null) \
            || die "CLOUDGRANGE_NAMESPACE is not set and this is not running in a pod"
    fi
    if [ -z "$RELEASE" ]; then
        local names
        names=$(helm list -n "$NS" -a -o json | jq -r '.[] | select(.chart | startswith("cloudgrange-")) | .name')
        [ "$(printf '%s\n' "$names" | grep -c .)" = 1 ] \
            || die "set CLOUDGRANGE_RELEASE_NAME: expected exactly one cloudgrange release in $NS, found: ${names:-none}"
        RELEASE=$names
    fi
}

release_json() { helm list -n "$NS" -a -o json | jq -c --arg r "$RELEASE" '.[] | select(.name == $r)'; }

set_status() { # <state> <message>
    local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log "status: $1 — $2"
    kubectl create configmap "$STATUS_CM" -n "$NS" \
        --from-literal=state="$1" --from-literal=fromVersion="$FROM_VERSION" \
        --from-literal=toVersion="$TO_VERSION" --from-literal=message="$2" \
        --from-literal=updatedAt="$now" --dry-run=client -o yaml \
        | kubectl label --local -f - app.kubernetes.io/part-of=cloudgrange app.kubernetes.io/component=platform-updater -o yaml \
        | kubectl apply -n "$NS" -f - >/dev/null \
        || log "WARNING: could not write $STATUS_CM"
}

refuse_if_running() {
    local state updated age
    state=$(kubectl get configmap "$STATUS_CM" -n "$NS" -o jsonpath='{.data.state}' 2>/dev/null || true)
    [ "$state" = running ] || return 0
    updated=$(kubectl get configmap "$STATUS_CM" -n "$NS" -o jsonpath='{.data.updatedAt}' 2>/dev/null || true)
    age=$(( $(date -u +%s) - $(date -u -d "${updated:-1970-01-01T00:00:00Z}" +%s 2>/dev/null || echo 0) ))
    # A status left "running" for 2h+ is a crashed Job, not a live one.
    [ "$age" -gt 7200 ] || { log "ERROR: another Platform update is running (since $updated)"; exit 3; }
    log "WARNING: ignoring a stale 'running' status from $updated"
}

cluster_version() { kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty'; }

# ---- Database ----------------------------------------------------------------------------------
db_env() {
    export PGHOST="$RELEASE-postgres" PGPORT=5432 PGUSER=cloudgrange PGDATABASE=cloudgrange
    PGPASSWORD=$(kubectl get secret "$RELEASE-secrets" -n "$NS" -o jsonpath='{.data.postgres-password}' | base64 -d) \
        || die "cannot read the database password from secret $RELEASE-secrets"
    export PGPASSWORD
}

backup_db() { # <dir>
    mkdir -p "$1" || return 1
    pg_dump --format=custom --no-owner --file="$1/cloudgrange.dump" || return 1
    pg_restore --list "$1/cloudgrange.dump" >/dev/null || return 1
    sha256sum "$1/cloudgrange.dump" > "$1/cloudgrange.dump.sha256"
}

# Restore into an EMPTY database, in one transaction. `pg_restore --clean` only drops the objects
# that are IN the dump, so anything the newer release's migrations added (tables, and foreign keys
# onto tables the dump does contain) survived and blocked the drops: a real 2609.0.0-preview.12 ->
# preview.10 rollback failed with "cannot drop constraint secret_refs_pkey ... constraint
# cluster_credentials_credential_ref_id_fkey depends on it" and left the old release on the new
# schema. So every non-system schema (ours and Keycloak's `public`) is dropped, `public` is
# re-created (pg_dump does not emit it), and the dump is replayed; any error rolls it all back.
restore_db() { # <dir>
    (cd "$1" && sha256sum -c cloudgrange.dump.sha256 >/dev/null) || { log "backup checksum mismatch in $1"; return 1; }
    pg_restore --list "$1/cloudgrange.dump" >/dev/null || { log "backup archive in $1 is unreadable"; return 1; }
    {
        echo 'BEGIN;'
        echo 'SET client_min_messages = warning;'
        echo "DO \$\$DECLARE s text; BEGIN FOR s IN SELECT nspname FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname <> 'information_schema' LOOP EXECUTE format('DROP SCHEMA %I CASCADE', s); END LOOP; END\$\$;"
        echo 'CREATE SCHEMA public;'
        # A failed render must never reach COMMIT: the division error aborts the transaction.
        pg_restore --no-owner --file=- "$1/cloudgrange.dump" || echo 'SELECT 1/0 AS pg_restore_failed;'
        echo 'COMMIT;'
    } | psql --no-psqlrc -q -v ON_ERROR_STOP=1 --dbname="$PGDATABASE" >/dev/null
}

# Stop everything that writes to the database before a restore. The replica counts are saved
# first and put back after `helm rollback`: Helm's three-way merge sees the same replicas in both
# revisions and leaves the live 0 alone, so the rollback on its own would leave them stopped.
declare -A SAVED_REPLICAS=()
WRITERS=(api keycloak)
quiesce_writers() {
    local c d n rc=0
    for c in "${WRITERS[@]}"; do
        d="$RELEASE-$c"
        n=$(kubectl get deployment "$d" -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null) || continue
        SAVED_REPLICAS[$d]=${n:-1}
        kubectl scale deployment "$d" -n "$NS" --replicas=0 >&2 || { log "cannot scale $d to 0"; rc=1; }
    done
    for c in "${WRITERS[@]}"; do
        kubectl wait --for=delete pod -n "$NS" -l "app.kubernetes.io/name=cloudgrange-$c" --timeout=180s >/dev/null 2>&1 \
            || log "WARNING: $RELEASE-$c pods still present after 180s"
    done
    # Anything still connected (a pod that outlived the wait, a module) would hold locks the
    # restore needs or keep writing mid-restore.
    psql -qAt -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()" >/dev/null \
        || log "WARNING: could not terminate other database sessions"
    return $rc
}

resume_writers() {
    local d rc=0
    for d in "${!SAVED_REPLICAS[@]}"; do
        kubectl scale deployment "$d" -n "$NS" --replicas="${SAVED_REPLICAS[$d]}" >&2 || { log "cannot scale $d back to ${SAVED_REPLICAS[$d]}"; rc=1; }
    done
    return $rc
}

# ---- Health gate -------------------------------------------------------------------------------
health_gate() {
    local kind name failed=0
    while read -r kind name; do
        [ -n "$name" ] || continue
        log "health gate: rollout status $kind/$name"
        kubectl rollout status "$kind/$name" -n "$NS" --timeout="$HEALTH_TIMEOUT" >&2 || failed=1
    done < <(helm get manifest "$RELEASE" -n "$NS" | awk '
        /^---/ { kind=""; name=""; next }
        /^kind: / { kind=$2 }
        /^metadata:/ { inmeta=1; next }
        inmeta && /^  name: / { name=$2; gsub(/["\047]/, "", name); inmeta=0 }
        /^[^ ]/ && !/^metadata:/ { inmeta=0 }
        kind != "" && name != "" && (kind=="Deployment" || kind=="StatefulSet" || kind=="DaemonSet") {
            print tolower(kind), name; kind=""; name="" }')
    [ "$failed" = 0 ] || return 1
    local i
    for i in $(seq 1 30); do
        curl -fsS -o /dev/null --max-time 5 "http://$RELEASE-api:8080/health/ready" && return 0
        sleep 5
    done
    log "health gate: $RELEASE-api /health/ready did not answer"
    return 1
}

# ---- Permission pre-check (AB#9171) ------------------------------------------------------------
# The updater is NAMESPACE-SCOPED by design (plan §4): inside $NS it is effectively namespace-admin,
# outside it it holds nothing but `get`/`delete` on a handful of this release's own objects by name.
# So a new chart version that adds, changes or removes a CLUSTER-SCOPED object cannot be applied
# in-app, and — because granting RBAC requires already holding what you grant — the updater can
# never fix that itself. It happened for real (reproduced on kind v1.34): a release installed with
# certManager.installOperator=true before cert-manager was in the cluster had no ClusterIssuer, the
# next chart rendered one, and `helm upgrade` died with
#     clusterissuers.cert-manager.io is forbidden: User
#     "system:serviceaccount:<ns>:<release>-platform-updater" cannot create resource
#     "clusterissuers" in API group "cert-manager.io" at the cluster scope
# AFTER the database backup and mid-apply, so the update auto-rolled back and the administrator was
# shown a raw RBAC error with no remedy. (templates/certmanager.yaml no longer renders a
# ClusterIssuer at all, which removes that particular case; this gate is for the class.)
#
# The gate runs BEFORE the backup and before anything is touched, renders the NEW chart against the
# live release with the SAME flags the real upgrade uses, and asks the API server — as this
# ServiceAccount — whether every cluster-scoped (or other-namespace) object it would create, change
# or delete is allowed. When it is not, the update is refused with the exact one-time `helm upgrade`
# a cluster administrator must run. A check that cannot be performed (no api-resources, no render)
# warns and lets the update proceed: it must never block an update that would have worked.
#
# The values flag both the pre-check and the real upgrade use. NOT --reuse-values: that keeps the
# OLD chart's values verbatim and so drops every default the new chart adds, which is what broke the
# 2609.0.0-preview.18/.19 in-app updates (a nil-pointer on .Values.airgap). --reset-then-reuse-values
# (Helm >= 3.14; release/pins.conf pins v3.22.0) resets to the NEW chart's defaults and then
# re-applies only the values the administrator actually supplied.
HELM_VALUES_FLAG=--reset-then-reuse-values

# Prints "Kind|resource" for every cluster-scoped API resource the cluster serves. NAMESPACED is the
# only column whose value is always literally "false" here, so KIND is the field after it and the
# resource name is field 1 — stable whether or not a row has SHORTNAMES or CATEGORIES.
cluster_scoped_kinds() {
    kubectl api-resources --namespaced=false --no-headers -o wide 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) if ($i == "false") { print $(i + 1) "|" $1; break } }'
}

# Splits a rendered multi-document manifest (stdin) into one file per object under <dir>, named
# "<Kind>__<namespace-or-_>__<name>", and prints "Kind|name|namespace" for each. The file contents
# are what Helm would send, so two identical files mean Helm's three-way merge has nothing to patch
# and the API is never written to — the difference between "rendered" and "actually changed".
split_manifest() { # <dir>
    mkdir -p "$1"
    awk -v out="$1" '
        function flush(  key, f) {
            if (kind != "" && name != "") {
                f = out "/" kind "__" (ns == "" ? "_" : ns) "__" name
                printf "%s", body > f
                close(f)
                print kind "|" name "|" ns
            }
            kind = ""; name = ""; ns = ""; body = ""; inmeta = 0
        }
        /^---/ { flush(); next }
        # Comments and blank lines are not part of what Helm sends, so they must not count as a
        # change: a chart whose only edit inside an object is a YAML comment produces an empty
        # patch and no API write, and demanding `update` rights for it would refuse updates that
        # succeed (the managed profiles, whose ClusterRole carries a long explanatory comment).
        { if ($0 !~ /^[ \t]*#/ && $0 !~ /^[ \t]*$/) body = body $0 "\n" }
        /^kind: / { kind = $2; gsub(/["\047]/, "", kind) }
        /^metadata:/ { inmeta = 1; next }
        inmeta && /^  name: / { name = $2; gsub(/["\047]/, "", name) }
        inmeta && /^  namespace: / { ns = $2; gsub(/["\047]/, "", ns) }
        /^[^ #]/ { if ($0 !~ /^metadata:/) inmeta = 0 }
        END { flush() }
    '
}

# check_cluster_rights <chart> <helm --set args...>
# Prints a refusal reason and returns 1 when a right is missing; returns 0 otherwise.
check_cluster_rights() {
    local chart=$1; shift
    local new="$WORK/precheck-new.yaml" old="$WORK/precheck-old.yaml"
    local kinds="$WORK/precheck-kinds" ndir="$WORK/precheck-new.d" odir="$WORK/precheck-old.d"
    local nkeys="$WORK/precheck-new.keys" okeys="$WORK/precheck-old.keys"
    cluster_scoped_kinds > "$kinds"
    if [ ! -s "$kinds" ]; then
        log "WARNING: could not list the cluster-scoped API resources; skipping the permission pre-check"
        return 0
    fi
    # --dry-run=server renders exactly as the real upgrade will (live Capabilities and `lookup`) and
    # writes nothing. -o json puts the rendered release manifest in .manifest.
    helm upgrade "$RELEASE" "$chart" -n "$NS" "$HELM_VALUES_FLAG" "$@" --dry-run=server -o json \
        2>"$WORK/precheck.err" | jq -r '.manifest // empty' > "$new" || : > "$new"
    if [ ! -s "$new" ]; then
        # Helm reads every object of the new manifest before it applies any, so a cluster-scoped
        # object the updater may not even GET fails the render itself. That is the same refusal,
        # so it gets the same remedy rather than the raw RBAC error.
        if grep -qi 'is forbidden' "$WORK/precheck.err"; then
            local denied
            denied=$(sed -n 's/.*cannot \([a-z]*\) resource "\([^"]*\)".*/\1 \2/p' "$WORK/precheck.err" | head -1)
            refusal "${denied:-$(grep -o 'is forbidden.*' "$WORK/precheck.err" | head -1 | cut -c1-200)}"
            return 1
        fi
        echo "Platform $TO_VERSION cannot be rendered against this release: $(grep -v '^[[:space:]]*$' "$WORK/precheck.err" | tail -2 | tr '\n' ' ')"
        return 1
    fi
    split_manifest "$ndir" < "$new" | sort -u > "$nkeys"
    helm get manifest "$RELEASE" -n "$NS" 2>/dev/null | split_manifest "$odir" | sort -u > "$okeys" || : > "$okeys"

    local -a missing=()
    local kind name ns res file
    # Objects the new chart renders: created when absent, updated when their content changes.
    while IFS='|' read -r kind name ns; do
        [ -n "$kind" ] && [ -n "$name" ] || continue
        res=$(awk -F'|' -v k="$kind" '$1 == k { print $2; exit }' "$kinds")
        if [ -n "$res" ]; then
            if ! kubectl get "$res" "$name" >/dev/null 2>&1; then
                # RBAC ignores resourceNames for `create`, so this asks for the resource, not the name.
                kubectl auth can-i create "$res" >/dev/null 2>&1 \
                    || missing+=("create $kind/$name (cluster-scoped)")
            else
                file="$kind"__"${ns:-_}"__"$name"
                # Identical rendering = an empty patch = no write, so no `update` right is needed.
                cmp -s "$ndir/$file" "$odir/$file" 2>/dev/null && continue
                kubectl auth can-i update "$res/$name" >/dev/null 2>&1 \
                    || missing+=("update $kind/$name (cluster-scoped)")
            fi
        elif [ -n "$ns" ] && [ "$ns" != "$NS" ]; then
            # A namespaced object the chart puts in ANOTHER namespace (metallb-system, velero).
            res=$(printf '%ss' "$kind" | tr 'A-Z' 'a-z')
            if kubectl get "$res" "$name" -n "$ns" >/dev/null 2>&1; then
                file="$kind"__"$ns"__"$name"
                cmp -s "$ndir/$file" "$odir/$file" 2>/dev/null && continue
                kubectl auth can-i update "$res" -n "$ns" >/dev/null 2>&1 \
                    || missing+=("update $kind/$name in namespace $ns")
            else
                kubectl auth can-i create "$res" -n "$ns" >/dev/null 2>&1 \
                    || missing+=("create $kind/$name in namespace $ns")
            fi
        fi
    done < "$nkeys"

    # Cluster-scoped objects the old release has and the new chart drops. Helm deletes these, but a
    # deletion it is not allowed to perform is a WARNING, not a failed upgrade (verified on kind
    # v1.34 as this ServiceAccount) — the object is simply left behind. So this is reported, never
    # a refusal: refusing here would block updates that demonstrably succeed.
    while IFS='|' read -r kind name ns; do
        [ -n "$kind" ] && [ -n "$name" ] || continue
        res=$(awk -F'|' -v k="$kind" '$1 == k { print $2; exit }' "$kinds")
        [ -n "$res" ] || continue
        grep -qxF "$kind|$name|$ns" "$nkeys" && continue
        kubectl get "$res" "$name" >/dev/null 2>&1 || continue
        kubectl auth can-i delete "$res/$name" >/dev/null 2>&1 \
            || log "NOTE: Platform $TO_VERSION no longer includes $kind/$name and this updater may not delete a cluster-scoped object, so it will be left behind. It grants nothing new; a cluster administrator can remove it."
    done < "$okeys"

    [ ${#missing[@]} -eq 0 ] && return 0
    local what; what=$(printf '%s; ' "${missing[@]}"); what=${what%; }
    refusal "$what"
    return 1
}

# The one message an administrator sees when an update needs rights the updater does not have. It
# names the remedy, because a bare RBAC error tells nobody what to run.
refusal() { # <what is missing>
    cat <<EOF
Platform $TO_VERSION changes cluster-scoped objects the in-cluster updater is not allowed to change: $1. The updater's rights deliberately stop at namespace $NS and it cannot grant itself more, so this one update has to be applied once by a cluster administrator, from a machine whose kubeconfig is cluster-admin:

  helm upgrade $RELEASE ${PRECHECK_CHART_REF:-<chart>} -n $NS --reset-then-reuse-values --set global.image.tag=$TO_VERSION --wait --timeout $HEALTH_TIMEOUT

Use --reset-then-reuse-values, NEVER --reuse-values: --reuse-values keeps the old chart's values verbatim, drops every default the new chart adds, and the upgrade then fails on values the new templates expect. After that one command, in-app updates from Platform -> Updates work again.

Nothing on this cluster has been changed and no database backup was taken.
EOF
}

# ---- Trust: HTTPS + digest pinning (owner decision 2026-09-18) ---------------------------------
# No signing key is required. What is applied is trusted because:
#   - every download is https:// (curl --proto =https, redirects included) with normal TLS
#     verification, from the configured channel host or an explicitly allowed host;
#   - the release manifest's SHA-256 equals the one the channel publishes for that version;
#   - the manifest pins the chart by SHA-256 and every first-party image by @sha256 digest, and
#     helm upgrade deploys exactly those digests.
# A signature is an optional extra: verified when a public key is configured, skipped when none is.
CHANNEL_URL='' ALLOWED_HOSTS='' CA_FILE=''
trust_value() { # <configmap key>
    kubectl get configmap "$RELEASE-platform-updater-trust" -n "$NS" -o "jsonpath={.data.$1}" 2>/dev/null || true
}
load_trust() {
    CHANNEL_URL=${CLOUDGRANGE_UPDATE_CHANNEL_URL:-$(trust_value channelUrl)}
    ALLOWED_HOSTS=${CLOUDGRANGE_UPDATE_ALLOWED_HOSTS:-$(trust_value allowedHosts)}
    ALLOWED_HOSTS=${ALLOWED_HOSTS//,/ }
    local extra="$WORK/extra-ca.pem"
    if [ -n "${CLOUDGRANGE_UPDATE_CA_FILE:-}" ]; then cp "$CLOUDGRANGE_UPDATE_CA_FILE" "$extra" 2>/dev/null || true
    else trust_value caBundle > "$extra"; fi
    if grep -q 'BEGIN CERTIFICATE' "$extra" 2>/dev/null; then
        # Added to the system CAs, never instead of them.
        CA_FILE="$WORK/ca-bundle.pem"
        cat /etc/ssl/certs/ca-certificates.crt "$extra" > "$CA_FILE" 2>/dev/null || cat "$extra" > "$CA_FILE"
    fi
}

url_host() { # <https url> -> lower-case host[:port], with a default :443 dropped
    local h=${1#*://}
    h=${h%%[/?#]*}; h=${h##*@}; h=${h,,}; h=${h%:443}
    echo "$h"
}

# check_source <what> <url> <channel host>: https only, from the channel host or an allowed host.
check_source() {
    local what=$1 url=$2 chost=$3 h a
    [[ "$url" == https://* ]] || { echo "$what must be downloaded over https:// (got ${url:-nothing}); refusing"; return 1; }
    h=$(url_host "$url")
    [ -n "$h" ] || { echo "$what URL has no host: $url"; return 1; }
    [ "$h" = "$chost" ] && return 0
    for a in $ALLOWED_HOSTS; do [ "$h" = "$(url_host "https://$a")" ] && return 0; done
    echo "$what comes from $h, which is neither the update channel host ($chost) nor in platformUpdater.trust.allowedHosts; refusing"
    return 1
}

signing_key() { # prints the path of a usable public key; fails when none is configured
    local key="$WORK/cosign.pub"
    if [ -n "${CLOUDGRANGE_SIGNING_KEY_FILE:-}" ]; then
        cp "$CLOUDGRANGE_SIGNING_KEY_FILE" "$key" 2>/dev/null || return 1
    else
        kubectl get configmap "$RELEASE-platform-updater-signing" -n "$NS" -o jsonpath='{.data.cosign\.pub}' > "$key" 2>/dev/null || return 1
    fi
    # An empty or placeholder key is "no key configured", not an error.
    grep -q 'BEGIN PUBLIC KEY' "$key" && ! grep -qi placeholder "$key" || return 1
    echo "$key"
}

# verify_signature_if_configured <manifest> <manifest url>: optional. With a configured key the
# signature must exist and verify; without one it is not fetched at all.
verify_signature_if_configured() {
    local key
    key=$(signing_key) || { log "no release signing key configured: trust is HTTPS + SHA-256/digest pinning"; return 0; }
    fetch "$2.sig" "$WORK/manifest.json.sig" \
        || { echo "a release signing key is configured but the manifest has no signature ($2.sig); refusing"; return 1; }
    # Offline key-pair verification: no transparency log the cluster may not reach.
    cosign verify-blob --key "$key" --signature "$WORK/manifest.json.sig" --insecure-ignore-tlog=true "$1" >&2 2>"$WORK/cosign.err" \
        || { echo "release manifest signature is invalid: $(tail -1 "$WORK/cosign.err")"; return 1; }
    log "release manifest signature verified"
}

# https only, redirects included; the extra CA bundle (if any) is added to the system CAs.
fetch() {
    local -a ca=()
    [ -n "$CA_FILE" ] && ca=(--cacert "$CA_FILE")
    curl -fsSL --proto '=https' --proto-redir '=https' "${ca[@]}" --retry 3 --max-time 600 -o "$2" "$1"
}

# resolve_release <version> <manifest url or ''> -> downloads and verifies $WORK/manifest.json;
# on refusal prints the reason and fails. Sets MANIFEST_URL and CHANNEL_HOST.
MANIFEST_URL='' CHANNEL_HOST=''
resolve_release() {
    local version=$1 given=$2 m="$WORK/manifest.json" ch="$WORK/channel.json" channel_url ch_version want got reason
    channel_url=$CHANNEL_URL
    # No configured channel: an API that passes the channel document itself as --manifest-url.
    [ -n "$channel_url" ] || channel_url=$given
    [ -n "$channel_url" ] || { echo "no update channel is configured (api.updateChannel); nothing to verify the release against"; return 1; }
    [[ "$channel_url" == https://* ]] || { echo "the update channel must be https:// (got $channel_url); refusing"; return 1; }
    CHANNEL_HOST=$(url_host "$channel_url")
    fetch "$channel_url" "$ch" || { echo "could not download the update channel from $channel_url"; return 1; }
    [ "$(jq -r '.schema // empty' "$ch" 2>/dev/null)" = cg-onprem-channel-v1 ] \
        || { echo "$channel_url is not an update channel (cg-onprem-channel-v1)"; return 1; }
    ch_version=$(jq -r '.latest.version // empty' "$ch")
    [ "$ch_version" = "$version" ] || { echo "the channel offers ${ch_version:-nothing}, not $version"; return 1; }
    MANIFEST_URL=$(jq -r '.latest.manifestUrl // empty' "$ch")
    want=$(jq -r '.latest.manifestSha256 // empty' "$ch" | tr 'A-F' 'a-f')
    [ -n "$MANIFEST_URL" ] || { echo "the channel publishes no release manifest for $version (latest.manifestUrl); refusing"; return 1; }
    [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { echo "the channel publishes no SHA-256 for the $version release manifest (latest.manifestSha256); refusing"; return 1; }
    # The API passes the manifest URL it read from the same channel; a different one is refused.
    if [ -n "$given" ] && [ "$given" != "$MANIFEST_URL" ] && [ "$given" != "$channel_url" ]; then
        echo "the requested manifest $given is not the one the channel lists ($MANIFEST_URL); refusing"; return 1
    fi
    reason=$(check_source "the release manifest" "$MANIFEST_URL" "$CHANNEL_HOST") || { echo "$reason"; return 1; }
    fetch "$MANIFEST_URL" "$m" || { echo "could not download the release manifest from $MANIFEST_URL"; return 1; }
    got=$(sha256sum "$m" | cut -d' ' -f1)
    [ "$got" = "$want" ] || { echo "release manifest SHA-256 $got does not match the channel ($want); refusing"; return 1; }
    verify_signature_if_configured "$m" "$MANIFEST_URL" || return 1
}

# check_manifest <version> <manifest file>: the content rules; prints the reason and fails on refusal.
check_manifest() {
    local version=$1 m=$2 unpinned comp image chart_url chart_sha
    jq -e . "$m" >/dev/null 2>&1 || { echo "the release manifest is not valid JSON"; return 1; }
    [ "$(jq -r .schema "$m")" = cg-release-manifest-v1 ] || { echo "unknown manifest schema"; return 1; }
    [ "$(jq -r .platform "$m")" = "$version" ] || { echo "manifest is for $(jq -r .platform "$m"), not $version"; return 1; }
    [ "$(jq -r '.dryRun // false' "$m")" = false ] || { echo "manifest is a dry run and cannot be applied"; return 1; }
    # Every image the manifest names must be pinned by digest: a tag alone can be moved.
    unpinned=$(jq -r '(.components // {}) | to_entries[] | select((.value.image // "") | test("@sha256:[0-9a-f]{64}$") | not) | .key' "$m")
    [ -z "$unpinned" ] || { echo "the release manifest has images not pinned by @sha256 digest: $(echo $unpinned); refusing"; return 1; }
    for comp in api portal relay platform-updater; do
        image=$(jq -r --arg c "cloudgrange-$comp" '.components[$c].image // empty' "$m")
        if [ -z "$image" ]; then
            [ "$comp" = platform-updater ] && continue
            echo "manifest does not pin cloudgrange-$comp"; return 1
        fi
        [[ "$image" =~ :$version@sha256:[0-9a-f]{64}$ ]] || { echo "cloudgrange-$comp is not pinned as :$version@sha256:<digest> ($image)"; return 1; }
    done
    chart_url=$(jq -r '.chart.url // empty' "$m"); chart_sha=$(jq -r '.chart.sha256 // empty' "$m")
    [ -n "$chart_url" ] && [[ "$chart_sha" =~ ^[0-9a-f]{64}$ ]] || { echo "manifest does not pin the chart"; return 1; }
    # An offline bundle carries the chart itself (checked against the same SHA-256 pin); chart.url is
    # only where it is published online, so where it points does not matter here.
    [ "$BUNDLE_MODE" = 1 ] && return 0
    check_source "the chart" "$chart_url" "$CHANNEL_HOST"
}

# ---- Offline bundle (E7) -----------------------------------------------------------------------
# Trust for an uploaded bundle (owner decision 2026-09-18, update-architecture.md): the SHA-256 of the
# whole zip, which the API computed while it streamed the upload, showed to the administrator, and
# the administrator confirmed against the .sha256 published beside the download. The API passes that
# confirmed value as --bundle-sha256; it is checked again here, before anything is unpacked, so a zip
# replaced on the volume after the confirmation is refused. Everything inside is then pinned from
# that root exactly as online: the manifest pins the chart (SHA-256), every first-party image
# (@sha256) and images.txt (SHA-256), and images.txt pins every other image by digest.
BUNDLE_MODE=0

# unpack_bundle <zip> <expected sha256> <dir>: prints the reason and fails on refusal.
unpack_bundle() {
    local zip=$1 want=$2 dir=$3 got
    [ -f "$zip" ] || { echo "the offline bundle $zip is not there (was it removed after the upload?)"; return 1; }
    [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { echo "no confirmed SHA-256 for the offline bundle; refusing"; return 1; }
    got=$(sha256sum "$zip" | cut -d' ' -f1)
    [ "$got" = "$want" ] || { echo "the offline bundle's SHA-256 is $got, not the $want the administrator confirmed; refusing"; return 1; }
    mkdir -p "$dir"
    unzip -q "$zip" -d "$dir" 2> "$WORK/unzip.err" || { echo "the offline bundle is not a readable zip: $(tail -1 "$WORK/unzip.err")"; return 1; }
    # SHA256SUMS (written by the release tooling) names every file: a broken build is caught early and
    # by name. It adds no trust; the confirmed SHA-256 of the zip already covers every byte.
    if [ -f "$dir/SHA256SUMS" ]; then
        (cd "$dir" && sha256sum --quiet -c SHA256SUMS) > "$WORK/sums.err" 2>&1 \
            || { echo "the offline bundle is inconsistent with its SHA256SUMS: $(head -1 "$WORK/sums.err")"; return 1; }
    fi
    log "offline bundle $zip: SHA-256 $got matches the confirmed value"
}

# A Platform bundle's manifest signature is optional, as online: checked only when a key is configured.
verify_bundle_signature_if_configured() { # <manifest> <signature file, may be missing>
    local key
    key=$(signing_key) || { log "no release signing key configured: the bundle is trusted by its confirmed SHA-256 and the pins inside it"; return 0; }
    [ -f "$2" ] || { echo "a release signing key is configured but the bundle's manifest has no signature (manifest.json.sig); refusing"; return 1; }
    cosign verify-blob --key "$key" --signature "$2" --insecure-ignore-tlog=true "$1" >&2 2>"$WORK/cosign.err" \
        || { echo "the bundle's release manifest signature is invalid: $(tail -1 "$WORK/cosign.err")"; return 1; }
    log "bundle release manifest signature verified"
}

# check_image_list <bundle dir>: every images.txt line is pinned by digest and carried in the bundle.
check_image_list() {
    local dir=$1 repo tag digest n=0
    [ -f "$dir/images.txt" ] || { echo "the bundle has no images.txt"; return 1; }
    while read -r repo tag digest _; do
        [[ -z "$repo" || "$repo" == \#* ]] && continue
        [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "images.txt: $repo:$tag is not pinned by digest"; return 1; }
        [ -d "$dir/images/${digest#sha256:}/oci" ] || { echo "the bundle is missing the image $repo:$tag@$digest"; return 1; }
        n=$((n + 1))
    done < "$dir/images.txt"
    [ "$n" -gt 0 ] || { echo "the bundle's images.txt lists no images"; return 1; }
}

# ---- Offline modules (E7) ----------------------------------------------------------------------
# A bundle may carry modules: modules/catalog.json (cg-module-catalog-v1, each manifestUrl a relative
# "manifests/<file>") and modules/manifests/, with every module image in images.txt. Once the images
# are in the in-cluster registry, the catalog is published to the modules volume
# (CLOUDGRANGE_MODULES_DIR); the API reads it and offers those modules with no internet. Published
# only after the images are loaded, so a module offered offline can always start.
MODULES_DIR=${CLOUDGRANGE_MODULES_DIR:-/modules}

# check_bundle_modules <bundle dir>: prints the reason and fails when the modules part is unusable.
check_bundle_modules() {
    local dir=$1 cat="$1/modules/catalog.json" image murl d bad=''
    [ -f "$cat" ] || return 0
    [ "$(jq -r '.schema // empty' "$cat" 2>/dev/null)" = cg-module-catalog-v1 ] \
        || { echo "modules/catalog.json is not a module catalog (cg-module-catalog-v1)"; return 1; }
    while IFS=$'\t' read -r image murl; do
        if [[ "$image" =~ @(sha256:[0-9a-f]{64})$ ]]; then
            d=${BASH_REMATCH[1]}
            awk -v d="$d" '$3 == d { f = 1 } END { exit !f }' "$dir/images.txt" || bad+=" image $image is not in images.txt;"
        else
            bad+=" image ${image:-<none>} is not pinned by digest;"
        fi
        [[ "$murl" == manifests/* && "$murl" != *..* && -f "$dir/modules/$murl" ]] || bad+=" manifest ${murl:-<none>} is not in the bundle;"
    done < <(jq -r '[.modules[]? | ., (.versions[]?)] | .[] | [(.image // ""), (.manifestUrl // "")] | @tsv' "$cat")
    [ -z "$bad" ] || { echo "modules/catalog.json:${bad:0:400}"; return 1; }
    log "modules: $(jq '[.modules[]?] | length' "$cat") module(s) in the bundle, every image and manifest present"
}

# publish_bundle_modules <bundle dir> <bundle sha256>: the catalog and manifests go to
# $MODULES_DIR/catalogs/<sha256>/, written aside and then renamed so the API never reads half of one.
publish_bundle_modules() {
    local dir=$1 sha=$2 dest tmp
    [ -f "$dir/modules/catalog.json" ] || return 0
    [ -d "$MODULES_DIR" ] || { log "WARNING: no modules volume at $MODULES_DIR; the bundle's modules are not offered offline"; return 0; }
    dest="$MODULES_DIR/catalogs/$sha"; tmp="$MODULES_DIR/catalogs/.tmp-$sha-$$"
    { mkdir -p "$MODULES_DIR/catalogs" && rm -rf "$tmp" && mkdir -p "$tmp"; } || { echo "cannot write to $MODULES_DIR"; return 1; }
    if ! { cp "$dir/modules/catalog.json" "$tmp/catalog.json" && cp -r "$dir/modules/manifests" "$tmp/manifests" \
            && jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$sha" '{importedAt: $at, bundleSha256: $sha}' > "$tmp/import.json" \
            && chmod -R a+rX "$tmp"; }; then
        rm -rf "$tmp"; echo "cannot write the module catalog to $MODULES_DIR"; return 1
    fi
    rm -rf "$dest" && mv "$tmp" "$dest" || { rm -rf "$tmp"; echo "cannot publish the module catalog in $MODULES_DIR"; return 1; }
    log "modules: published $(jq '[.modules[]?] | length' "$dest/catalog.json") module(s) to $dest"
}

# ---- load-images (E7): an offline MODULE bundle ------------------------------------------------
# load-images --bundle <zip> --bundle-sha256 <hex>: verify (confirmed SHA-256, every image pinned and
# present, the module catalog consistent), push the images into the in-cluster registry, then
# publish the bundle's module catalog. Changes nothing that runs. Status goes to ConfigMap
# cloudgrange-module-import-status (state idle|running|succeeded|failed, bundleSha256, message).
IMPORT_CM=cloudgrange-module-import-status
set_import_status() { # <state> <message> <sha>
    local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log "import status: $1 — $2"
    kubectl create configmap "$IMPORT_CM" -n "$NS" \
        --from-literal=state="$1" --from-literal=bundleSha256="$3" --from-literal=message="$2" \
        --from-literal=updatedAt="$now" --dry-run=client -o yaml \
        | kubectl label --local -f - app.kubernetes.io/part-of=cloudgrange app.kubernetes.io/component=platform-updater -o yaml \
        | kubectl apply -n "$NS" -f - >/dev/null \
        || log "WARNING: could not write $IMPORT_CM"
}

cmd_load_images() {
    local bundle='' sha='' reason dir="$WORK/bundle"
    while [ $# -gt 0 ]; do
        case "$1" in
            --bundle) bundle=$2; shift 2 ;;
            --bundle-sha256) sha=${2,,}; shift 2 ;;
            *) usage ;;
        esac
    done
    [ -n "$bundle" ] && [ -n "$sha" ] || usage
    resolve_target
    ifail() { set_import_status failed "$1" "$sha"; exit 1; }
    set_import_status running "verifying the module bundle" "$sha"
    reason=$(unpack_bundle "$bundle" "$sha" "$dir") || ifail "$reason"
    [ -f "$dir/modules/catalog.json" ] || ifail "the bundle carries no modules (modules/catalog.json)"
    reason=$(check_image_list "$dir") || ifail "$reason"
    reason=$(check_bundle_modules "$dir") || ifail "$reason"
    if [ -n "${CLOUDGRANGE_AIRGAP_REGISTRY:-}" ]; then
        set_import_status running "loading module images into the in-cluster registry" "$sha"
        reason=$(push_bundle_images "$dir" "$CLOUDGRANGE_AIRGAP_REGISTRY") || ifail "$reason"
    else
        log "no in-cluster registry (CLOUDGRANGE_AIRGAP_REGISTRY): the module images must already be in this cluster's mirror (global.imageRegistry)"
    fi
    reason=$(publish_bundle_modules "$dir" "$sha") || ifail "$reason"
    set_import_status succeeded "imported $(jq '[.modules[]?] | length' "$dir/modules/catalog.json") module(s)" "$sha"
}

# mirror_path REF -> the repository path without its registry host, Docker Hub's "library/" explicit.
# The one naming rule shared by the chart (templates/_helpers.tpl cloudgrange.image), the release's
# images.txt (scripts/release/Get-PlatformImages.sh) and containerd's registry mirrors.
mirror_path() {
    local name=${1%%@*} host rest
    # drop a tag (a ':' after the last '/')
    [[ "${name##*/}" == *:* ]] && name=${name%:*}
    if [[ "$name" != */* ]]; then echo "library/$name"; return; fi
    host=${name%%/*}; rest=${name#*/}
    if [[ "$host" == *.* || "$host" == *:* || "$host" == localhost ]]; then
        [[ "$host" == docker.io && "$rest" != */* ]] && rest="library/$rest"
        echo "$rest"
    else
        echo "$name"
    fi
}

# image_key REF -> "<mirror path>@<digest>" when pinned by digest, else "<mirror path>:<tag>". An
# untagged, undigested reference gets an empty tag, which matches nothing in a bundle (the chart
# never renders one; test/lint-pins.sh refuses it).
image_key() {
    local ref=$1 name tag=''
    if [[ "$ref" == *@sha256:* ]]; then echo "$(mirror_path "$ref")@${ref##*@}"; return; fi
    name=${ref##*/}; [[ "$name" == *:* ]] && tag=${name##*:}
    echo "$(mirror_path "$ref"):$tag"
}

# The images the target chart renders with this release's values; every one must be in the bundle.
chart_images() { # <chart> <values file> <sets...>
    local chart=$1 values=$2; shift 2
    # --kube-version: helm template otherwise assumes an old default and the chart's kubeVersion refuses it.
    helm template "$RELEASE" "$chart" -n "$NS" -f "$values" ${TARGET_KUBE:+--kube-version "$TARGET_KUBE"} "$@" 2>"$WORK/target-render.err" > "$WORK/target-render.yaml" || return 1
    {
        grep -hoE '^[[:space:]]*(-[[:space:]]*)?(image|imageName):[[:space:]]*"?[^"'"'"' ]+' "$WORK/target-render.yaml" \
            | sed -E 's/^[[:space:]]*(-[[:space:]]*)?(image|imageName):[[:space:]]*"?//'
        sed -n 's/^[[:space:]]*CLOUDGRANGE_PLATFORM_UPDATER_IMAGE:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$WORK/target-render.yaml"
    } | sort -u
}

# Verify an unpacked bundle's images against the manifest and the target chart. Prints the
# reason and fails on the first problem; changes nothing.
check_bundle_images() { # <bundle dir> <manifest> <chart> <sets...>
    local dir=$1 m=$2 chart=$3; shift 3
    local list="$dir/images.txt" want have repo tag digest ref key n=0
    [ -f "$list" ] || { echo "the bundle has no images.txt"; return 1; }
    want=$(jq -r '.images.sha256 // empty' "$m")
    [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { echo "the manifest does not pin the bundle's image list (images.sha256)"; return 1; }
    have=$(sha256sum "$list" | cut -d' ' -f1)
    [ "$have" = "$want" ] || { echo "images.txt does not match the manifest (sha256 $have, pinned $want)"; return 1; }
    : > "$WORK/bundle-keys"
    while read -r repo tag digest _; do
        [[ -z "$repo" || "$repo" == \#* ]] && continue
        [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "images.txt: $repo:$tag is not pinned by digest"; return 1; }
        [ -d "$dir/images/${digest#sha256:}/oci" ] || { echo "the bundle is missing the image $repo:$tag@$digest"; return 1; }
        printf '%s@%s\n%s:%s\n' "$(mirror_path "$repo")" "$digest" "$(mirror_path "$repo")" "$tag" >> "$WORK/bundle-keys"
    done < "$list"
    # Every first-party image the manifest pins must be in the bundle under that exact digest.
    while read -r ref; do
        [ -n "$ref" ] || continue
        grep -qxF "$(image_key "$ref")" "$WORK/bundle-keys" || { echo "the bundle does not carry $ref, which the manifest pins"; return 1; }
    done < <(jq -r '.components[].image // empty' "$m")
    # Every image the target chart renders with this release's values must be in the bundle, or the
    # upgrade would sit in ImagePullBackOff on an air-gapped node and then roll back.
    helm get values "$RELEASE" -n "$NS" -o yaml > "$WORK/current-values.yaml" 2>/dev/null || { echo "cannot read the release's values"; return 1; }
    chart_images "$chart" "$WORK/current-values.yaml" "$@" > "$WORK/target-images.txt" || { echo "could not render the target chart to list its images: $(head -2 "$WORK/target-render.err" | tr '\n' ' ')"; return 1; }
    while read -r ref; do
        [ -n "$ref" ] || continue
        n=$((n + 1))
        key=$(image_key "$ref")
        grep -qxF "$key" "$WORK/bundle-keys" || { echo "the target chart uses $ref, which is not in the bundle"; return 1; }
    done < "$WORK/target-images.txt"
    [ "$n" -gt 0 ] || { echo "the target chart rendered no images"; return 1; }
    log "bundle: images.txt matches the manifest; all $n images the target chart uses are in the bundle"
}

# Push every bundle image into the in-cluster registry and check each digest against its pin.
push_bundle_images() { # <bundle dir> <registry host:port>
    local dir=$1 reg=$2 repo tag digest path d top got mt n=0
    while read -r repo tag digest _; do
        [[ -z "$repo" || "$repo" == \#* ]] && continue
        path=$(mirror_path "$repo"); d="$dir/images/${digest#sha256:}"
        # The linux/amd64 image: pushed from its OCI layout as-is, so its manifest keeps its digest.
        crane push --insecure "$d/oci" "$reg/$path:$tag" > "$WORK/crane.log" 2>&1 \
            || { echo "pushing $repo:$tag failed: $(tail -1 "$WORK/crane.log")"; return 1; }
        top="$d/index-manifest.json"
        if [ -f "$top" ]; then
            # A multi-platform pin: put the exact index bytes back under the tag, so the tag resolves
            # to the pinned digest. The registry recomputes the digest; it is checked below as well.
            [ "sha256:$(sha256sum "$top" | cut -d' ' -f1)" = "$digest" ] || { echo "$repo: index bytes do not match $digest"; return 1; }
            mt=$(jq -r '.mediaType // "application/vnd.oci.image.index.v1+json"' "$top")
            curl -fsS -o /dev/null -X PUT -H "Content-Type: $mt" --data-binary "@$top" "http://$reg/v2/$path/manifests/$tag" \
                || { echo "pushing the index of $repo:$tag failed"; return 1; }
        fi
        got=$(crane digest --insecure "$reg/$path:$tag" 2>/dev/null)
        [ "$got" = "$digest" ] || { echo "$repo:$tag is ${got:-missing} in the registry, not the pinned $digest"; return 1; }
        n=$((n + 1))
    done < "$dir/images.txt"
    log "bundle: pushed $n images to $reg, every digest matches its pin"
}

# ---- apply -------------------------------------------------------------------------------------
cmd_apply() {
    local version='' manifest_url='' bundle='' bundle_sha=''
    while [ $# -gt 0 ]; do
        case "$1" in
            --version) version=$2; shift 2 ;;
            --manifest-url) manifest_url=$2; shift 2 ;;
            --bundle) bundle=$2; shift 2 ;;
            --bundle-sha256) bundle_sha=${2,,}; shift 2 ;;
            *) usage ;;
        esac
    done
    [ -n "$version" ] || usage
    # Exactly one source: the network (channel/manifest URL) or an uploaded offline bundle (E7).
    [ -z "$bundle" ] || [ -z "$manifest_url" ] || usage
    [ -z "$bundle" ] || [[ "$bundle_sha" =~ ^[0-9a-f]{64}$ ]] || die "--bundle needs --bundle-sha256 <the SHA-256 the administrator confirmed>"
    [[ "$version" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(-(preview|rc)\.[0-9]+)?$ ]] || die "invalid platform version: $version"
    resolve_target
    load_trust
    TO_VERSION=$version
    refuse_if_running

    local rel status revision
    rel=$(release_json)
    [ -n "$rel" ] || die "release $RELEASE not found in $NS"
    status=$(jq -r .status <<<"$rel"); revision=$(jq -r .revision <<<"$rel")
    FROM_VERSION=$(jq -r .app_version <<<"$rel")
    fail() { set_status failed "$1"; exit 1; }
    [ "$status" = deployed ] || fail "release $RELEASE is '$status', not deployed; resolve that before updating"
    set_status running "verifying release manifest"

    # 2-3. trust, then content.
    local m="$WORK/manifest.json" reason bsrc=''
    if [ -n "$bundle" ]; then
        # E7, offline: TRUST is the SHA-256 of the whole bundle, which the administrator saw in the
        # portal after the upload and confirmed against the one published beside the download
        # (cloudgrange-platform-<v>.zip.sha256). The Job re-checks it here, so a file changed on
        # the volume after that confirmation is refused. Inside the bundle, the manifest pins the
        # chart by SHA-256, every first-party image by digest and images.txt by SHA-256, exactly as
        # online. A signature is checked only when a signing key is configured.
        set_status running "verifying the offline bundle"
        bsrc="$WORK/bundle"
        reason=$(unpack_bundle "$bundle" "$bundle_sha" "$bsrc") || fail "$reason"
        cp "$bsrc/manifest.json" "$m"
        if [ -f "$bsrc/manifest.json.sig" ]; then cp "$bsrc/manifest.json.sig" "$WORK/bundle-manifest.sig"; fi
        reason=$(verify_bundle_signature_if_configured "$m" "$WORK/bundle-manifest.sig") || fail "$reason"
        BUNDLE_MODE=1
    else
        reason=$(resolve_release "$version" "$manifest_url") || fail "${reason:-the release could not be verified}"
        # resolve_release ran in a subshell; recompute what it established (it already passed).
        CHANNEL_HOST=$(url_host "${CHANNEL_URL:-$manifest_url}")
    fi
    reason=$(check_manifest "$version" "$m") || fail "$reason"
    local upgrade_from; upgrade_from=$(jq -r '.upgradeFrom // empty' "$m")
    if [ -n "$upgrade_from" ] && ! in_range "$FROM_VERSION" "$upgrade_from"; then
        fail "installed $FROM_VERSION cannot update directly to $version (supported from: $upgrade_from)"
    fi
    local -a sets=(--set "global.image.tag=$version")
    local comp image digest
    for comp in api portal relay platform-updater; do
        image=$(jq -r --arg c "cloudgrange-$comp" '.components[$c].image // empty' "$m")
        [ -n "$image" ] || continue
        digest=${image##*@}
        case "$comp" in
            platform-updater) sets+=(--set "platformUpdater.image.tag=$version" --set "platformUpdater.image.digest=$digest") ;;
            *) sets+=(--set "$comp.image.digest=$digest") ;;
        esac
    done

    # 4. chart + compatibility gate.
    local chart="$WORK/cloudgrange-$version.tgz" chart_url chart_sha kube_range kube
    chart_url=$(jq -r '.chart.url' "$m"); chart_sha=$(jq -r '.chart.sha256' "$m")
    if [ -n "$bundle" ]; then
        # chart.url is where the chart is published online; offline, the bundle carries the same file,
        # checked against the same SHA-256 pin below.
        cp "$bsrc/cloudgrange-$version.tgz" "$chart" 2>/dev/null || fail "the offline bundle has no chart cloudgrange-$version.tgz"
    else
        set_status running "downloading chart $version"
        fetch "$chart_url" "$chart" || fail "could not download the chart from $chart_url"
    fi
    echo "$chart_sha  $chart" | sha256sum -c - >/dev/null 2>&1 || fail "chart SHA-256 does not match the manifest"
    [ "$(helm show chart "$chart" | sed -n 's/^version: *//p' | tr -d '"')" = "$version" ] || fail "chart is not version $version"
    kube_range=$(helm show chart "$chart" | sed -n 's/^kubeVersion: *//p' | tr -d "\"'")
    kube=$(cluster_version)
    [ -n "$kube_range" ] || fail "chart $version declares no kubeVersion; refusing"
    [ -n "$kube" ] || fail "could not read the cluster's Kubernetes version"
    in_range "$kube" "$kube_range" \
        || fail "this cluster runs Kubernetes $kube; Platform $version supports $kube_range. Update the Foundation (Kubernetes) first."

    # 4c. permission pre-check (AB#9171). Last gate before anything is touched: the updater is
    # namespace-scoped, so a chart that changes a cluster-scoped object has to be applied once by a
    # cluster administrator. Refusing here — rather than failing mid-apply and rolling back — costs
    # nothing and gives the administrator the exact command instead of a raw RBAC error.
    set_status running "checking permissions for $version"
    # What a cluster admin would pass to `helm upgrade`: the chart the release manifest pins. Offline,
    # that same file is the one inside the uploaded bundle.
    if [ -n "$bundle" ]; then
        PRECHECK_CHART_REF="./cloudgrange-$version.tgz   # from the uploaded Platform bundle"
    else
        PRECHECK_CHART_REF=${chart_url:-oci://ghcr.io/cloudgrange/charts/cloudgrange --version $version}
    fi
    reason=$(check_cluster_rights "$chart" "${sets[@]}") || fail "$reason"

    # 4b. offline bundle (E7): its images, checked against the pins, then pushed. Pushing only
    # adds images to the registry and changes nothing that runs, so it happens before the backup.
    if [ -n "$bundle" ]; then
        set_status running "checking the bundle's images"
        TARGET_KUBE=$kube
        reason=$(check_bundle_images "$bsrc" "$m" "$chart" "${sets[@]}") || fail "$reason"
        reason=$(check_bundle_modules "$bsrc") || fail "$reason"
        if [ -n "${CLOUDGRANGE_AIRGAP_REGISTRY:-}" ]; then
            set_status running "loading images into the in-cluster registry"
            reason=$(push_bundle_images "$bsrc" "$CLOUDGRANGE_AIRGAP_REGISTRY") || fail "$reason"
        else
            log "no in-cluster registry (CLOUDGRANGE_AIRGAP_REGISTRY): the images must already be in this cluster's mirror (global.imageRegistry)"
        fi
        rm -rf "$bsrc/images"
    fi

    # 5. backup.
    local stamp bdir
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    bdir="$BACKUP_DIR/$stamp-$FROM_VERSION-to-$version"
    mountpoint -q "$BACKUP_DIR" 2>/dev/null \
        || log "WARNING: $BACKUP_DIR is not a mounted volume; the backup will not survive this Job (a later 'rollback' cannot restore it)"
    set_status running "backing up the database"
    db_env
    backup_db "$bdir" || fail "database backup failed; nothing was changed"
    jq -n --arg from "$FROM_VERSION" --arg to "$version" --argjson rev "$revision" --arg at "$stamp" \
        '{fromVersion:$from, toVersion:$to, fromRevision:$rev, takenAt:$at, applied:false}' > "$bdir/backup.json"

    # 6-7. upgrade + health gate; 8. undo on any failure.
    set_status running "upgrading $FROM_VERSION to $version"
    if helm upgrade "$RELEASE" "$chart" -n "$NS" "$HELM_VALUES_FLAG" "${sets[@]}" \
            --wait --timeout "$HEALTH_TIMEOUT" >&2 \
        && { set_status running "health gate"; health_gate; }; then
        jq '.applied = true' "$bdir/backup.json" > "$bdir/backup.json.tmp" && mv "$bdir/backup.json.tmp" "$bdir/backup.json"
        echo "$bdir" > "$BACKUP_DIR/LAST_APPLIED"
        prune_backups
        if [ -n "$bundle" ]; then
            # The Platform update succeeded; a module catalog that cannot be published is reported, not undone.
            reason=$(publish_bundle_modules "$bsrc" "$bundle_sha") || log "WARNING: $reason"
        fi
        set_status succeeded "Platform updated to $version"
        return 0
    fi
    log "update failed; restoring the database and rolling back to revision $revision"
    set_status running "update failed; rolling back to $FROM_VERSION"
    if undo "$bdir" "$revision"; then
        set_status rolled-back "update to $version failed; restored $FROM_VERSION and its database"
    else
        set_status failed "update to $version failed AND the automatic rollback failed; manual recovery needed (backup: $bdir)"
    fi
    exit 1
}

undo() { # <backup dir> <revision>
    local ok=0
    quiesce_writers || { log "could not stop the database writers; restoring anyway after terminating their sessions"; }
    restore_db "$1" || { log "database restore failed"; ok=1; }
    helm rollback "$RELEASE" "$2" -n "$NS" --wait --timeout "$HEALTH_TIMEOUT" >&2 || { log "helm rollback failed"; ok=1; }
    resume_writers || ok=1
    [ "$ok" = 0 ] && health_gate && return 0
    return 1
}

prune_backups() {
    local d
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '2*' | sort -r | tail -n +$((KEEP_BACKUPS + 1)) \
        | while read -r d; do [ "$d" = "$(cat "$BACKUP_DIR/LAST_APPLIED" 2>/dev/null)" ] || rm -rf "$d"; done
}

# ---- rollback ----------------------------------------------------------------------------------
cmd_rollback() {
    [ $# -eq 0 ] || usage
    resolve_target
    refuse_if_running
    local rel bdir revision
    rel=$(release_json); [ -n "$rel" ] || die "release $RELEASE not found in $NS"
    FROM_VERSION=$(jq -r .app_version <<<"$rel")
    bdir=$(cat "$BACKUP_DIR/LAST_APPLIED" 2>/dev/null || true)
    if [ -z "$bdir" ] || [ ! -f "$bdir/backup.json" ]; then
        TO_VERSION=''
        set_status failed "no backup of a previous update was found on $BACKUP_DIR; nothing to roll back to"
        exit 1
    fi
    TO_VERSION=$(jq -r .fromVersion "$bdir/backup.json")
    revision=$(jq -r .fromRevision "$bdir/backup.json")
    [ "$(jq -r .toVersion "$bdir/backup.json")" = "$FROM_VERSION" ] \
        || { set_status failed "installed $FROM_VERSION is not the version the last update installed; refusing to roll back"; exit 1; }
    set_status running "rolling back $FROM_VERSION to $TO_VERSION"
    db_env
    if undo "$bdir" "$revision"; then
        rm -f "$BACKUP_DIR/LAST_APPLIED"
        set_status rolled-back "rolled back to $TO_VERSION and restored its database"
    else
        set_status failed "rollback to $TO_VERSION failed; manual recovery needed (backup: $bdir)"
        exit 1
    fi
}

# ---- verify (no cluster needed) ----------------------------------------------------------------
# verify --version <v> [--manifest-url <url>]: the trust and content checks of `apply` and the chart
# download, and nothing else. Changes nothing; used by the tests and to diagnose a refusal.
cmd_verify() {
    local version='' manifest_url='' reason chart
    while [ $# -gt 0 ]; do
        case "$1" in
            --version) version=$2; shift 2 ;;
            --manifest-url) manifest_url=$2; shift 2 ;;
            *) usage ;;
        esac
    done
    [ -n "$version" ] || usage
    RELEASE=${RELEASE:-cloudgrange} NS=${NS:-cloudgrange}
    load_trust
    reason=$(resolve_release "$version" "$manifest_url") || { echo "REFUSED: $reason"; exit 1; }
    CHANNEL_HOST=$(url_host "${CHANNEL_URL:-$manifest_url}")
    reason=$(check_manifest "$version" "$WORK/manifest.json") || { echo "REFUSED: $reason"; exit 1; }
    chart="$WORK/chart.tgz"
    fetch "$(jq -r .chart.url "$WORK/manifest.json")" "$chart" || { echo "REFUSED: could not download the chart"; exit 1; }
    echo "$(jq -r .chart.sha256 "$WORK/manifest.json")  $chart" | sha256sum -c - >/dev/null 2>&1 \
        || { echo "REFUSED: chart SHA-256 does not match the manifest"; exit 1; }
    echo "VERIFIED: $version"
}

case "${1:-}" in
    apply) shift; cmd_apply "$@" ;;
    verify) shift; cmd_verify "$@" ;;
    load-images) shift; cmd_load_images "$@" ;;
    rollback) shift; cmd_rollback "$@" ;;
    check-kube-range) # diagnostic: check-kube-range <range> [<kube-version>]
        shift; [ $# -ge 1 ] || usage
        v=${2:-$(cluster_version)}
        if in_range "$v" "$1"; then echo "in range: $v satisfies $1"; else echo "OUT OF RANGE: $v does not satisfy $1"; exit 1; fi ;;
    *) usage ;;
esac
