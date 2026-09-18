#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (plan 2026-09-18-foundation-platform-separation §3/§4, E1) — the in-cluster Platform
# updater. Runs as a Kubernetes Job, created by the API, under ServiceAccount
# <release>-platform-updater. Works the same on K3s, BYO Kubernetes and AKS: it only talks to the
# Kubernetes API, Helm and Postgres, never to the host.
#
#   apply --version <v> --manifest-url <url>
#       1. refuse if another update is running or the release is not in a deployed state;
#       2. download the release manifest (cg-release-manifest-v1) and verify its cosign signature
#          (<url>.sig) — FAIL CLOSED when no signing key is configured;
#       3. check the manifest: platform == <v>, not a dry run, the installed version is inside
#          upgradeFrom, every first-party image pinned by digest;
#       4. download the chart, check its SHA-256 against the manifest, and refuse if the running
#          cluster is outside the chart's kubeVersion;
#       5. pg_dump the database to the backup volume;
#       6. helm upgrade --reuse-values with the pinned tag and digests;
#       7. health gate: rollout status of every Deployment/StatefulSet/DaemonSet in the release,
#          then the API's readiness endpoint;
#       8. on any failure after step 5: stop the API, restore the database, helm rollback.
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
#   CLOUDGRANGE_SIGNING_KEY_FILE  cosign public key file (default: ConfigMap <release>-platform-updater-signing)
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
usage: cloudgrange-platform-updater apply --version <YYMM.MINOR.PATCH[-pre]> --manifest-url <url>
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

restore_db() { # <dir>
    (cd "$1" && sha256sum -c cloudgrange.dump.sha256 >/dev/null) || { log "backup checksum mismatch in $1"; return 1; }
    pg_restore --clean --if-exists --no-owner --single-transaction --exit-on-error \
        --dbname="$PGDATABASE" "$1/cloudgrange.dump"
}

# Stop everything that writes to the database before a restore; helm rollback restores the
# replica counts from the previous revision's manifest.
quiesce_writers() {
    local d
    for d in "$RELEASE-api" "$RELEASE-keycloak"; do
        kubectl scale deployment "$d" -n "$NS" --replicas=0 >/dev/null 2>&1 || true
    done
    for d in "$RELEASE-api" "$RELEASE-keycloak"; do
        kubectl wait --for=delete pod -n "$NS" -l "app.kubernetes.io/name=cloudgrange-${d#"$RELEASE"-}" --timeout=120s >/dev/null 2>&1 || true
    done
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

# ---- Signature ---------------------------------------------------------------------------------
signing_key() { # prints the path of the public key, or fails
    local key="$WORK/cosign.pub"
    if [ -n "${CLOUDGRANGE_SIGNING_KEY_FILE:-}" ]; then
        cp "$CLOUDGRANGE_SIGNING_KEY_FILE" "$key" 2>/dev/null || return 1
    else
        kubectl get configmap "$RELEASE-platform-updater-signing" -n "$NS" -o jsonpath='{.data.cosign\.pub}' > "$key" 2>/dev/null || return 1
    fi
    grep -q 'BEGIN PUBLIC KEY' "$key" && ! grep -qi placeholder "$key" || return 1
    echo "$key"
}

verify_manifest() { # <manifest> <sig>
    local key
    key=$(signing_key) || {
        echo "no release signing key is configured (platformUpdater.signing.publicKey); refusing an unverifiable update"
        return 1
    }
    # Offline key-pair verification (the air-gapped case): trust comes from the pinned public key,
    # not from a transparency log the cluster may not be able to reach.
    cosign verify-blob --key "$key" --signature "$2" --insecure-ignore-tlog=true "$1" >&2 2>"$WORK/cosign.err" \
        || { echo "release manifest signature is invalid: $(tail -1 "$WORK/cosign.err")"; return 1; }
}

fetch() { curl -fsSL --retry 3 --max-time 600 -o "$2" "$1"; }

# ---- apply -------------------------------------------------------------------------------------
cmd_apply() {
    local version='' manifest_url=''
    while [ $# -gt 0 ]; do
        case "$1" in
            --version) version=$2; shift 2 ;;
            --manifest-url) manifest_url=$2; shift 2 ;;
            *) usage ;;
        esac
    done
    [ -n "$version" ] && [ -n "$manifest_url" ] || usage
    [[ "$version" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(-(preview|rc)\.[0-9]+)?$ ]] || die "invalid platform version: $version"
    resolve_target
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

    # 2-3. manifest: signature first, then content.
    local m="$WORK/manifest.json" reason
    fetch "$manifest_url" "$m" || fail "could not download the release manifest from $manifest_url"
    fetch "$manifest_url.sig" "$WORK/manifest.json.sig" || fail "the release manifest has no signature ($manifest_url.sig)"
    reason=$(verify_manifest "$m" "$WORK/manifest.json.sig") || fail "$reason"
    jq -e . "$m" >/dev/null 2>&1 || fail "the release manifest is not valid JSON"
    [ "$(jq -r .schema "$m")" = cg-release-manifest-v1 ] || fail "unknown manifest schema"
    [ "$(jq -r .platform "$m")" = "$version" ] || fail "manifest is for $(jq -r .platform "$m"), not $version"
    [ "$(jq -r '.dryRun // false' "$m")" = false ] || fail "manifest is a dry run and cannot be applied"
    local upgrade_from; upgrade_from=$(jq -r '.upgradeFrom // empty' "$m")
    if [ -n "$upgrade_from" ] && ! in_range "$FROM_VERSION" "$upgrade_from"; then
        fail "installed $FROM_VERSION cannot update directly to $version (supported from: $upgrade_from)"
    fi
    local -a sets=(--set "global.image.tag=$version")
    local comp key image digest
    for comp in api portal relay platform-updater; do
        image=$(jq -r --arg c "cloudgrange-$comp" '.components[$c].image // empty' "$m")
        digest=${image##*@}
        if [ -z "$image" ]; then
            [ "$comp" = platform-updater ] && continue
            fail "manifest does not pin cloudgrange-$comp"
        fi
        [[ "$image" =~ :$version@sha256:[0-9a-f]{64}$ ]] || fail "cloudgrange-$comp is not pinned as :$version@sha256:<digest> ($image)"
        case "$comp" in
            platform-updater) sets+=(--set "platformUpdater.image.tag=$version" --set "platformUpdater.image.digest=$digest") ;;
            *) key=$comp; sets+=(--set "$key.image.digest=$digest") ;;
        esac
    done

    # 4. chart + compatibility gate.
    local chart="$WORK/cloudgrange-$version.tgz" chart_url chart_sha kube_range kube
    chart_url=$(jq -r '.chart.url // empty' "$m"); chart_sha=$(jq -r '.chart.sha256 // empty' "$m")
    [ -n "$chart_url" ] && [[ "$chart_sha" =~ ^[0-9a-f]{64}$ ]] || fail "manifest does not pin the chart"
    set_status running "downloading chart $version"
    fetch "$chart_url" "$chart" || fail "could not download the chart from $chart_url"
    echo "$chart_sha  $chart" | sha256sum -c - >/dev/null 2>&1 || fail "chart SHA-256 does not match the manifest"
    [ "$(helm show chart "$chart" | sed -n 's/^version: *//p' | tr -d '"')" = "$version" ] || fail "chart is not version $version"
    kube_range=$(helm show chart "$chart" | sed -n 's/^kubeVersion: *//p' | tr -d "\"'")
    kube=$(cluster_version)
    [ -n "$kube_range" ] || fail "chart $version declares no kubeVersion; refusing"
    [ -n "$kube" ] || fail "could not read the cluster's Kubernetes version"
    in_range "$kube" "$kube_range" \
        || fail "this cluster runs Kubernetes $kube; Platform $version supports $kube_range. Update the Foundation (Kubernetes) first."

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
    if helm upgrade "$RELEASE" "$chart" -n "$NS" --reuse-values "${sets[@]}" \
            --wait --timeout "$HEALTH_TIMEOUT" >&2 \
        && { set_status running "health gate"; health_gate; }; then
        jq '.applied = true' "$bdir/backup.json" > "$bdir/backup.json.tmp" && mv "$bdir/backup.json.tmp" "$bdir/backup.json"
        echo "$bdir" > "$BACKUP_DIR/LAST_APPLIED"
        prune_backups
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
    quiesce_writers
    restore_db "$1" || { log "database restore failed"; ok=1; }
    helm rollback "$RELEASE" "$2" -n "$NS" --wait --timeout "$HEALTH_TIMEOUT" >&2 || { log "helm rollback failed"; ok=1; }
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

case "${1:-}" in
    apply) shift; cmd_apply "$@" ;;
    rollback) shift; cmd_rollback "$@" ;;
    check-kube-range) # diagnostic: check-kube-range <range> [<kube-version>]
        shift; [ $# -ge 1 ] || usage
        v=${2:-$(cluster_version)}
        if in_range "$v" "$1"; then echo "in range: $v satisfies $1"; else echo "OUT OF RANGE: $v does not satisfy $1"; exit 1; fi ;;
    *) usage ;;
esac
