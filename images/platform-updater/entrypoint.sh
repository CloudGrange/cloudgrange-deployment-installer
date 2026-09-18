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
#   CLOUDGRANGE_SIGNING_KEY_FILE  optional cosign public key file (default: ConfigMap
#                              <release>-platform-updater-signing; neither = signatures not checked)
#   CLOUDGRANGE_UPDATE_CHANNEL_URL   the update channel (default: ConfigMap
#                              <release>-platform-updater-trust, key channelUrl, rendered by the chart
#                              from api.updateChannel — the same URL the API reads)
#   CLOUDGRANGE_UPDATE_ALLOWED_HOSTS extra hosts (space/comma separated) the manifest and chart may
#                              come from besides the channel host (default: ConfigMap key allowedHosts)
#   CLOUDGRANGE_UPDATE_CA_FILE       extra PEM CA bundle for a private https mirror (default:
#                              ConfigMap key caBundle); added to the system CAs, never replacing them
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
       cloudgrange-platform-updater verify --version <v> [--manifest-url <url>]
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
    check_source "the chart" "$chart_url" "$CHANNEL_HOST"
}

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
    [ -n "$version" ] || usage
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

    # 2-3. trust (https + channel SHA-256 + optional signature), then content.
    local m="$WORK/manifest.json" reason
    reason=$(resolve_release "$version" "$manifest_url") || fail "${reason:-the release could not be verified}"
    # resolve_release ran in a subshell; recompute what it established (it already passed).
    CHANNEL_HOST=$(url_host "${CHANNEL_URL:-$manifest_url}")
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
    rollback) shift; cmd_rollback "$@" ;;
    check-kube-range) # diagnostic: check-kube-range <range> [<kube-version>]
        shift; [ $# -ge 1 ] || usage
        v=${2:-$(cluster_version)}
        if in_range "$v" "$1"; then echo "in range: $v satisfies $1"; else echo "OUT OF RANGE: $v does not satisfy $1"; exit 1; fi ;;
    *) usage ;;
esac
