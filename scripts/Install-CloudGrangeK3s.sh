#!/usr/bin/env bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9182 — qualification-gate K3s/Helm installer. This is the install-reliability
# harness that AB#9183 cuts Install-CloudGrange-Linux.sh over to use, once this script
# has proven fresh-install + interrupt-at-every-checkpoint + resume all work correctly.
#
# Design (owner-approved 2026-09-16 — "inexpensive and robust"): a JSON checkpoint file
# recording each named stage only after it actually completes, so re-running this script
# after an interruption (Ctrl-C, host crash, network drop mid-download) skips whatever
# already succeeded and resumes at the first incomplete stage — never redoes completed
# work, never leaves partial state mistaken for done work. Stages:
#   prereqs-checked -> k3s-installed -> certmanager-installed -> chart-installed -> ready
#
# Artifact verification is a plain SHA-256 digest manifest, not cryptographic signing —
# signing needs key-management infrastructure this product doesn't have yet and the
# owner didn't ask for; a hash check answers "did the right bytes arrive" without that
# cost. See New-ArtifactManifest.sh for how the manifest is produced.
#
# Uninstall/retention contract: PVCs survive `helm uninstall` (Kubernetes' own default —
# no code needed, matches how Postgres/Keycloak/Grafana/Prometheus/Loki data already
# behaves under Compose today). A full purge is a separate, explicit, documented step —
# see charts/cloudgrange/README.md — never automatic.
set -euo pipefail

STATE_FILE="${CLOUDGRANGE_INSTALL_STATE:-/opt/cloudgrange/.install-state.json}"
CHARTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/charts"
HOSTNAME_VALUE="${CLOUDGRANGE_HOSTNAME:-cloudgrange.local}"
VERSION_VALUE="${CLOUDGRANGE_VERSION:-latest}"

# AB#9183: --hostname/--version give this script the same CLI contract as
# Install-CloudGrange-Linux.sh, which delegates to this script under --engine k3s.
while [ $# -gt 0 ]; do
    case "$1" in
        --hostname) HOSTNAME_VALUE=$2; shift 2 ;;
        --version)  VERSION_VALUE=$2; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# --- Checkpoint state -------------------------------------------------------
state_dir() { dirname "$STATE_FILE"; }

state_init() {
    mkdir -p "$(state_dir)"
    if [ ! -f "$STATE_FILE" ]; then
        echo '{"stages":{}}' > "$STATE_FILE"
    fi
}

# A stage is "done" only if it was recorded AFTER its work actually succeeded —
# state_mark is the only writer, and it's called strictly after the stage's own
# commands return 0. An interrupted stage (Ctrl-C, crash) simply never gets marked,
# so a resume re-attempts it from scratch rather than trusting a partial write.
stage_done() {
    # Real JSON parsing, not a grep on raw text: a grep pattern like "\"$1\":true" only
    # matches compact single-line JSON. Python's json.dump(indent=2) below (the only
    # writer) puts the key and value on their own line with a space after the colon
    # ("prereqs-checked": true) — a real bug caught by actually testing resume: the
    # first stage was needlessly re-run on every resume because the grep never matched.
    [ -f "$STATE_FILE" ] || return 1
    python3 -c "
import json, sys
with open('$STATE_FILE') as f:
    data = json.load(f)
sys.exit(0 if data.get('stages', {}).get('$1') is True else 1)
"
}

state_mark() {
    local stage="$1"
    local tmp
    tmp="$(mktemp)"
    python3 -c "
import json, sys
with open('$STATE_FILE') as f:
    data = json.load(f)
data['stages']['$stage'] = True
data.setdefault('history', []).append({'stage': '$stage', 'at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)'})
with open('$tmp', 'w') as f:
    json.dump(data, f, indent=2)
"
    mv "$tmp" "$STATE_FILE"
    log "checkpoint: $stage"
}

run_stage() {
    local stage="$1"
    shift
    if stage_done "$stage"; then
        log "stage '$stage' already complete — skipping (resume)"
        return 0
    fi
    log "stage '$stage' starting"
    "$@"
    state_mark "$stage"
}

# --- Stages ------------------------------------------------------------------
do_prereqs_checked() {
    command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
    # AB#9182/9183 real bug: this stage used to HARD-FAIL if helm wasn't already on the
    # VM, with no install step for it anywhere in this script or Install-CloudGrange-Linux.sh
    # -- every real fresh-Ubuntu-24.04 install (helm is not preinstalled) failed at the very
    # first stage. Found only by actually running the full Windows-orchestrated -> Hyper-V
    # VM -> real K3s/Helm install end to end (AB#9185 real test), not by lint/template/k3d.
    # Fix: install a pinned, checksum-verified Helm build, same pattern as the pinned
    # SHA-512-verified QEMU build (New-CloudGrangeVm.ps1 / CloudGrange-Prereqs.ps1).
    if ! command -v helm >/dev/null 2>&1; then
        local helm_version="v3.22.0"
        local helm_tar="helm-${helm_version}-linux-amd64.tar.gz"
        local tmp_dir
        tmp_dir="$(mktemp -d)"
        curl -sfL "https://get.helm.sh/${helm_tar}" -o "$tmp_dir/${helm_tar}"
        curl -sfL "https://get.helm.sh/${helm_tar}.sha256sum" -o "$tmp_dir/${helm_tar}.sha256sum"
        (cd "$tmp_dir" && sha256sum -c "${helm_tar}.sha256sum")
        tar -xzf "$tmp_dir/${helm_tar}" -C "$tmp_dir"
        install -m 0755 "$tmp_dir/linux-amd64/helm" /usr/local/bin/helm
        rm -rf "$tmp_dir"
        command -v helm >/dev/null || { echo "helm install failed" >&2; exit 1; }
    fi
    if [ ! -f "$CHARTS_DIR/vendor/cert-manager-v1.21.2.tgz" ]; then
        echo "vendored cert-manager chart missing: $CHARTS_DIR/vendor/cert-manager-v1.21.2.tgz" >&2
        exit 1
    fi
}

do_k3s_installed() {
    if command -v k3s >/dev/null 2>&1; then
        log "k3s already present on this host"
        return 0
    fi
    curl -sfL https://get.k3s.io | sh -
    # get.k3s.io's own install script starts+enables the systemd unit; wait for the
    # node to actually report Ready rather than trusting "service started" alone.
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    local deadline=$(($(date +%s) + 60))
    until k3s kubectl get nodes 2>/dev/null | grep -q " Ready "; do
        [ "$(date +%s)" -lt "$deadline" ] || { echo "k3s node never reached Ready" >&2; exit 1; }
        sleep 2
    done
}

do_certmanager_installed() {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    # upgrade --install (not plain install): idempotent regardless of prior release
    # state. Found via real interrupt testing — a `helm install` that times out on
    # --wait leaves the release in Helm's own "failed" status, and a plain re-run of
    # `helm install` on the retry then rejects it outright ("cannot re-use a name that
    # is still in use"), permanently blocking resume until someone manually
    # uninstalled first. upgrade --install handles create-if-absent and
    # retry-if-failed/deployed the same way, which is what a resumable installer needs.
    helm upgrade --install cert-manager "$CHARTS_DIR/vendor/cert-manager-v1.21.2.tgz" \
        --set crds.enabled=true --namespace cert-manager --create-namespace --wait --timeout 3m
}

do_chart_installed() {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    # --wait can time out on the one currently-known issue (the published portal
    # :latest image predates AB#9172's non-root fix) without every OTHER pod actually
    # failing — same tolerance scripts/Test-HelmChart.py already applies. Don't treat
    # that single known failure as blocking this checkpoint; do_ready below still
    # fails hard on any OTHER pod not becoming Ready.
    #
    # AB#9183 real bug, found via a real install: this blanket `|| true` also swallowed
    # a genuine template-validation error (an invalid Ingress) that meant helm never
    # created that resource AT ALL — chart-installed still got marked done, so the
    # checkpoint state claimed success for a step that silently dropped a resource.
    # `do_ready` below only checks Pod readiness, so it never caught the missing
    # Ingress either. Fix: distinguish "helm actually created a release, some pods just
    # aren't Ready yet" (tolerable — do_ready is the real safety net for that) from
    # "the release doesn't exist at all" (a hard failure, fail loudly here instead of
    # silently continuing to a do_ready check that can't explain what's actually wrong).
    helm upgrade --install cloudgrange "$CHARTS_DIR/cloudgrange" \
        -f "$CHARTS_DIR/cloudgrange/values-single-node.yaml" \
        --set "global.hostname=$HOSTNAME_VALUE" \
        --set "global.image.tag=$VERSION_VALUE" \
        --timeout 5m --wait || true
    helm status cloudgrange >/dev/null 2>&1 || {
        echo "helm upgrade --install failed completely (no release exists) — see the error above" >&2
        exit 1
    }
}

do_ready() {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    # AB#9183: cheap, direct check that the Ingress actually exists — the resource that
    # silently failed to apply in the real bug the do_chart_installed fix above addresses.
    # Pod readiness alone doesn't catch a missing Ingress; explicitly check for it too.
    k3s kubectl get ingress cloudgrange >/dev/null 2>&1 || {
        echo "expected Ingress 'cloudgrange' does not exist" >&2
        exit 1
    }
    k3s kubectl get pods -o wide
    local unexpected
    unexpected="$(k3s kubectl get pods --no-headers | awk '
        $2 != "Completed" && $3 != "Completed" {
            split($2, r, "/");
            if (r[1] != r[2] && $1 !~ /^cloudgrange-portal-/) print $1": "$2" "$3;
        }')"
    if [ -n "$unexpected" ]; then
        echo "unexpected not-Ready pods:" >&2
        echo "$unexpected" >&2
        exit 1
    fi
}

main() {
    state_init
    run_stage prereqs-checked do_prereqs_checked
    run_stage k3s-installed do_k3s_installed
    run_stage certmanager-installed do_certmanager_installed
    run_stage chart-installed do_chart_installed
    run_stage ready do_ready
    log "install complete — state recorded at $STATE_FILE"
}

main "$@"
