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
BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHARTS_DIR="$BUNDLE_ROOT/charts"
AIRGAP_DIR="${CLOUDGRANGE_AIRGAP_DIR:-$BUNDLE_ROOT/airgap}"
UPDATES_DIR="${CLOUDGRANGE_UPDATES_SHARED:-/var/lib/cloudgrange/updates}"
HOSTNAME_VALUE="${CLOUDGRANGE_HOSTNAME:-cloudgrange.local}"
# AB#9171 (C1): empty means "the release the chart itself pins" (values.yaml global.image.tag, stamped
# at release time). This used to default to `latest`, so the WRAPPER decided which Platform build ran,
# overriding the chart -- and a bring-your-own-Kubernetes install of the same chart got a different one.
VERSION_VALUE="${CLOUDGRANGE_VERSION:-}"

# AB#9184/AB#9189 — K3s is PINNED, never "whatever get.k3s.io serves today". This script
# previously ran a bare `curl -sfL https://get.k3s.io | sh -`, which installs whatever the
# current stable channel points at: two installs of the same CloudGrange release could get
# different Kubernetes versions, and an air-gapped install was impossible by construction.
# That directly contradicts this repo's own immutable-version rule — the same rule that
# retired New-CloudGrangeBundle.ps1 (see its CG-BUNDLE-ERR-001 notice). This pin is the
# version verified end to end on a real Hyper-V VM install (AB#9185).
K3S_VERSION="${CLOUDGRANGE_K3S_VERSION:-v1.36.4+k3s1}"
# SHA-256 of K3s's install.sh at that tag; the online path checks the download against it.
# Copy kept in sync with release/pins.conf K3S_INSTALL_SH_SHA256 (test/lint-pins.sh checks it).
K3S_INSTALL_SH_SHA256="${CLOUDGRANGE_K3S_INSTALL_SH_SHA256:-46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad}"

# AB#9171 — the Foundation release this installer lays down (plan 2026-09-18 §3: Foundation and
# Platform have separate versions). Recorded in $ETC_DIR/foundation-version for the Foundation
# updater, which reports it as installedVersion and advances it on each admin-applied update.
FOUNDATION_VERSION="${CLOUDGRANGE_FOUNDATION_VERSION:-F2609.0.0}"
# Where a foundation-check looks for newer Foundation releases (the Foundation card's "available"
# version). Separate from the Platform update channel: separate releases, separate cadence.
# Copies kept in sync with release/pins.conf: FOUNDATION_VERSION, FOUNDATION_CHANNEL_URL.
FOUNDATION_CHANNEL_URL="${CLOUDGRANGE_FOUNDATION_CHANNEL_URL:-https://pub-ab113af532ff44ef827c176e42118f17.r2.dev/channels/foundation-preview.json}"

# Host locations, overridable only so the qualification tests can run this script unprivileged
# against a scratch tree. Production never sets these.
ETC_DIR="${CLOUDGRANGE_ETC_DIR:-/etc/cloudgrange}"
APT_CONF_DIR="${CLOUDGRANGE_APT_CONF_DIR:-/etc/apt/apt.conf.d}"
SBIN_DIR="${CLOUDGRANGE_SBIN_DIR:-/usr/local/sbin}"
SYSTEMD_DIR="${CLOUDGRANGE_SYSTEMD_DIR:-/etc/systemd/system}"

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
        # AB#9171: an offline bundle carries the same pinned Helm tarball (New-ReleaseBundleK3s.sh);
        # without this an air-gapped install died here, before K3s was even touched.
        if [ -f "$AIRGAP_DIR/${helm_tar}" ] && [ -f "$AIRGAP_DIR/${helm_tar}.sha256sum" ]; then
            cp "$AIRGAP_DIR/${helm_tar}" "$AIRGAP_DIR/${helm_tar}.sha256sum" "$tmp_dir/"
        else
            curl -sfL "https://get.helm.sh/${helm_tar}" -o "$tmp_dir/${helm_tar}"
            curl -sfL "https://get.helm.sh/${helm_tar}.sha256sum" -o "$tmp_dir/${helm_tar}.sha256sum"
        fi
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
    disable_automatic_updates
    install_updater
}

# AB#9171 — owner decision 2026-09-18: on a managed foundation (every host this script installs:
# the VHDX appliance, the Windows script's VM and the Linux script's server) an administrator
# ALWAYS starts a Foundation update from Platform -> Updates. Nothing patches the host on its own,
# not even security updates, so Ubuntu's own automatic machinery is switched off here: the
# unattended-upgrades service, the apt-daily/apt-daily-upgrade timers that drive it, and snap
# auto-refresh. The Foundation updater (cloudgrange-updater-k3s.service) runs apt itself, and only
# when asked. Idempotent: the appliance's first boot runs this again.
disable_automatic_updates() {
    log "managed foundation: disabling automatic OS updates (an administrator applies them from Platform -> Updates)"
    install -d -m 0755 "$APT_CONF_DIR"
    cat > "$APT_CONF_DIR/99cloudgrange-no-automatic-updates" <<'APTCONF'
// CloudGrange managed foundation (AB#9171): nothing is installed automatically. OS updates are
// applied by an administrator from Platform -> Updates -> Foundation (cloudgrange-updater-k3s).
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
APTCONF
    chmod 0644 "$APT_CONF_DIR/99cloudgrange-no-automatic-updates"
    local unit
    for unit in unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer; do
        # A unit that is not installed is already "off"; that is not an error.
        if systemctl list-unit-files "$unit" >/dev/null 2>&1; then
            systemctl disable --now "$unit" >/dev/null 2>&1 || log "WARNING: could not disable $unit"
            systemctl mask "$unit" >/dev/null 2>&1 || log "WARNING: could not mask $unit"
        fi
    done
    if command -v snap >/dev/null 2>&1; then
        snap refresh --hold >/dev/null 2>&1 || log "WARNING: could not hold snap auto-refresh"
    fi
}

# AB#9189/AB#9171 — the Foundation updater (host service, managed foundations only). The API pod
# mounts $UPDATES_DIR as a hostPath and drops Foundation requests (foundation-check/-apply/-rollback)
# and uploaded Foundation releases there; this root service acts on them and on nothing else.
# Platform updates do not come here any more: they run in the cluster.
install_updater() {
    local src="$BUNDLE_ROOT/scripts/cloudgrange-updater-k3s.py"
    local unit_src="$BUNDLE_ROOT/appliance/cloudgrange-updater-k3s.service"
    local key_src="$BUNDLE_ROOT/cloudgrange-signing-key.pub"
    # requests/ and incoming/ are the only directories the non-root API pod may write to;
    # status/ stays root-owned so the pod can read progress but never forge it.
    install -d -m 0755 "$UPDATES_DIR"
    install -d -m 0733 "$UPDATES_DIR/requests" "$UPDATES_DIR/incoming"
    install -d -m 0755 "$UPDATES_DIR/status"
    # What Foundation this host is on. Written once: a re-run of this installer must not undo a
    # Foundation update the administrator has applied since.
    install -d -m 0755 "$ETC_DIR"
    [ -s "$ETC_DIR/foundation-version" ] || echo "$FOUNDATION_VERSION" > "$ETC_DIR/foundation-version"
    [ -s "$ETC_DIR/foundation-channel-url" ] || echo "$FOUNDATION_CHANNEL_URL" > "$ETC_DIR/foundation-channel-url"
    # The key Foundation releases are verified against. The updater refuses every release while this
    # is missing or still the repository placeholder, so a missing key fails closed, never open.
    if [ -f "$key_src" ]; then
        install -m 0644 "$key_src" "$ETC_DIR/foundation-signing-key.pub"
    fi
    # The updater is part of every managed foundation (owner: no deploy without an updater), so a
    # bundle or upload without it is a packaging error, not something to skip past.
    [ -f "$src" ] || { echo "Foundation updater missing from this installer ($src)" >&2; exit 1; }
    [ -f "$unit_src" ] || { echo "Foundation updater unit missing from this installer ($unit_src)" >&2; exit 1; }
    install -m 0755 "$src" "$SBIN_DIR/cloudgrange-updater-k3s.py"
    install -m 0644 "$unit_src" "$SYSTEMD_DIR/cloudgrange-updater-k3s.service"
    systemctl daemon-reload
    systemctl enable --now cloudgrange-updater-k3s.service
}

# AB#9184 — import the bundle's CloudGrange/vendor service images into containerd.
# Runs in BOTH the fresh-install and the k3s-already-present paths: an air-gapped host
# with a pre-existing k3s still has no way to pull ghcr.io/cloudgrange images, so this
# cannot live behind the fresh-install branch. Idempotent — re-importing an image that
# is already present is a no-op, so a resumed install repeats it harmlessly.
import_bundled_service_images() {
    local tar="$AIRGAP_DIR/cloudgrange-images-amd64.tar"
    [ -f "$tar" ] || return 0
    log "importing bundled service images into containerd"
    (cd "$AIRGAP_DIR" && sha256sum -c cloudgrange-images-amd64.tar.sha256)
    k3s ctr images import "$tar"
}

do_k3s_installed() {
    if command -v k3s >/dev/null 2>&1; then
        log "k3s already present on this host"
        import_bundled_service_images
        return 0
    fi
    # Air-gapped path: when the bundle carries the K3s binary + its airgap image tarball,
    # stage them where K3s's own installer looks for them, so no network access is needed.
    # K3s imports /var/lib/rancher/k3s/agent/images/*.tar into containerd on first start.
    if [ -f "$AIRGAP_DIR/k3s" ] && [ -f "$AIRGAP_DIR/k3s-airgap-images-amd64.tar" ]; then
        log "air-gapped k3s install from bundle ($K3S_VERSION)"
        (cd "$AIRGAP_DIR" && sha256sum -c k3s.sha256 && sha256sum -c k3s-airgap-images-amd64.tar.sha256)
        if [ -f "$AIRGAP_DIR/k3s-install.sh.sha256" ]; then (cd "$AIRGAP_DIR" && sha256sum -c k3s-install.sh.sha256); fi
        install -m 0755 "$AIRGAP_DIR/k3s" /usr/local/bin/k3s
        install -d -m 0755 /var/lib/rancher/k3s/agent/images
        install -m 0644 "$AIRGAP_DIR/k3s-airgap-images-amd64.tar" /var/lib/rancher/k3s/agent/images/
        INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_VERSION="$K3S_VERSION" sh "$AIRGAP_DIR/k3s-install.sh"
    else
        log "online k3s install, pinned to $K3S_VERSION"
        # AB#9171: K3s's install.sh as of the pinned tag, not whatever get.k3s.io serves today, and
        # checked against the pinned SHA-256 before it runs as root.
        local k3s_install_sh
        k3s_install_sh=$(mktemp)
        curl -sfL "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION//+/%2B}/install.sh" -o "$k3s_install_sh"
        echo "$K3S_INSTALL_SH_SHA256  $k3s_install_sh" | sha256sum -c - >/dev/null \
            || { rm -f "$k3s_install_sh"; echo "k3s install.sh for $K3S_VERSION does not match K3S_INSTALL_SH_SHA256" >&2; exit 1; }
        INSTALL_K3S_VERSION="$K3S_VERSION" sh "$k3s_install_sh"
        rm -f "$k3s_install_sh"
    fi
    # K3s's own install script starts+enables the systemd unit; wait for the
    # node to actually report Ready rather than trusting "service started" alone.
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    local deadline=$(($(date +%s) + 60))
    until k3s kubectl get nodes 2>/dev/null | grep -q " Ready "; do
        [ "$(date +%s)" -lt "$deadline" ] || { echo "k3s node never reached Ready" >&2; exit 1; }
        sleep 2
    done
    import_bundled_service_images
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

# AB#9171 real bug, found installing 2609.0.0-preview.5 with the Windows script: --version only
# set global.image.tag, which moves the api/portal/relay images and nothing else. The chart's
# appVersion IS the platform version: it is what the API reports as installed
# (CLOUDGRANGE_PLATFORM_VERSION / CLOUDGRANGE_SOLUTION_VERSION) and the Platform updater image's
# default tag. So `-Version 2609.0.0-preview.5` came up claiming to be 2609.0.0 and pointing its
# updater Job at an image tag that was never published. A release bundle is stamped when it is
# built (New-ReleaseBundleK3s.sh); the Windows script uploads the repo's chart, which is not.
# Stamp the chart this install uses with the requested version, the same way a release does.
stamp_chart_version() {
    [ -n "$VERSION_VALUE" ] || return 0
    local chart="$CHARTS_DIR/cloudgrange" current
    current=$(sed -n -E 's/^appVersion:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/p' "$chart/Chart.yaml")
    [ "$current" != "$VERSION_VALUE" ] || return 0
    local stamper="$BUNDLE_ROOT/scripts/release/Set-ChartVersion.sh"
    [ -f "$stamper" ] || {
        echo "--version $VERSION_VALUE asked for, but the chart is $current and $stamper is missing to stamp it" >&2
        exit 1
    }
    log "stamping platform version $VERSION_VALUE into the chart (was $current)"
    bash "$stamper" "$chart" "$VERSION_VALUE"
}

do_chart_installed() {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    # There is NO tolerated "known failing pod" here any more. This previously carried a
    # deliberate allowance for the portal image predating AB#9172's non-root fix, paired
    # with a portal exemption in do_ready — so a broken portal passed both gates and the
    # installer printed "install complete" over a dead container on a real customer
    # server. The portal image and chart are fixed; the allowance is gone. If a pod fails,
    # the install fails. Never re-add a per-component exemption to make a run go green.
    #
    # AB#9183 real bug, found via a real install: a blanket `|| true` here also swallowed
    # a genuine template-validation error (an invalid Ingress) that meant helm never
    # created that resource AT ALL — chart-installed still got marked done, so the
    # checkpoint state claimed success for a step that silently dropped a resource.
    # `do_ready` below only checks Pod readiness, so it never caught the missing
    # Ingress either. Fix: distinguish "helm actually created a release, some pods just
    # aren't Ready yet" (tolerable — do_ready is the real safety net for that) from
    # "the release doesn't exist at all" (a hard failure, fail loudly here instead of
    # silently continuing to a do_ready check that can't explain what's actually wrong).
    stamp_chart_version
    local tag_args=()
    [ -z "$VERSION_VALUE" ] || tag_args=(--set "global.image.tag=$VERSION_VALUE")
    helm upgrade --install cloudgrange "$CHARTS_DIR/cloudgrange" \
        -f "$CHARTS_DIR/cloudgrange/values-single-node.yaml" \
        --set "global.hostname=$HOSTNAME_VALUE" \
        "${tag_args[@]}" \
        --timeout 5m --wait || log "WARNING: 'helm upgrade --install --wait' did not succeed — continuing only far enough for the checks below to report exactly what is wrong; do_ready fails the install if any pod is not Ready"
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
    # NO per-pod exemptions here, ever. This check previously excluded
    # `cloudgrange-portal-*` from the not-Ready test, which meant a portal stuck in
    # CreateContainerConfigError still passed this gate — the installer printed
    # "install complete" over a broken install, on a real customer server. A readiness
    # gate that is taught to ignore the component that is failing is worse than no gate,
    # because it converts a visible failure into a silent one. If a pod cannot become
    # Ready, fix the pod; do not narrow the check.
    unexpected="$(k3s kubectl get pods --no-headers | awk '
        $2 != "Completed" && $3 != "Completed" {
            split($2, r, "/");
            if (r[1] != r[2]) print $1": "$2" "$3;
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
