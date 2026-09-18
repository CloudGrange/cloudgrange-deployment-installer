#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (plan 2026-09-18-foundation-platform-separation B5) — the pinning gate. Fails when a
# shipped artifact uses `latest` or an unpinned version:
#   1. release/pins.conf       every required pin present, well-formed, never "latest";
#   2. chart sources           no `latest` anywhere in values or templates, and no image
#                              hardcoded in a template (images come from values, where they are
#                              pinned and overridable);
#   3. rendered manifests      every profile (and every optional component switched on): each image
#                              has a real tag or a digest — no `latest`, no bare/floating major tag;
#                              first-party images carry the chart's appVersion;
#   4. Dockerfiles             every FROM pinned by digest (or a build-arg with no default);
#   5. chart metadata          version/appVersion in the platform scheme, kubeVersion present, the
#                              pinned K3s inside it, api/portal/relay appVersion in step;
#   6. drift                   copies of pins that live outside pins.conf still match it;
#   7. wrappers                no `latest` default / unpinned download in the delivery-path
#                              scripts, except entries listed in test/lint-pins.allow (each with a
#                              reason). An allowlist entry that no longer matches also FAILS, so the
#                              list can only shrink;
#   8. update trust            HTTPS + digest pinning, no signing key (owner decision 2026-09-18):
#                              every profile renders an https:// update channel for the updater;
#                              the updater downloads https-only and refuses unpinned images; the
#                              release tooling publishes manifestSha256 and needs no key.
# Needs: bash, grep, sed, awk, helm. Exit 0 = clean; 1 = at least one failure (all are listed).
#
# Env overrides (used to prove the gate catches a planted regression):
#   LINT_PINS_ROOT   repo root (default: this script's parent)
set -uo pipefail
ROOT=${LINT_PINS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
cd "$ROOT" || exit 2
CHART=charts/cloudgrange
PINS=release/pins.conf
ALLOW=test/lint-pins.allow
command -v helm >/dev/null || { echo "PIN-LINT: helm is required" >&2; exit 2; }
FAILS=0
fail() { echo "PIN-LINT FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pin() { sed -n "s/^$1=//p" "$PINS" | head -1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
SEMVER_PLATFORM='^[0-9]{4}\.[0-9]+\.[0-9]+(-(preview|rc)\.[0-9]+)?$'

# ---- 1. pins file --------------------------------------------------------------------------------
[ -f "$PINS" ] || { fail "$PINS is missing"; echo "PIN-LINT: $FAILS failure(s)" >&2; exit 1; }
check_pin() { # <key> <regex>
    local v; v=$(pin "$1")
    if [ -z "$v" ]; then fail "$PINS: $1 is missing or empty"
    elif [[ "$v" == *latest* ]]; then fail "$PINS: $1 is '$v' (latest is never a pin)"
    elif ! [[ "$v" =~ $2 ]]; then fail "$PINS: $1='$v' is not of the form $2"
    fi
}
SHA='^[0-9a-f]{64}$'
IMG_DIGEST='^[^ @]+:[^ @:]+@sha256:[0-9a-f]{64}$'
check_pin K3S_VERSION '^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$'
check_pin K3S_INSTALL_SH_SHA256 "$SHA"
check_pin UBUNTU_CLOUDIMG_SERIAL '^[0-9]{8}(\.[0-9]+)?$'
check_pin UBUNTU_CLOUDIMG_SHA256 "$SHA"
check_pin QEMU_WINDOWS_BUILD '^[0-9]{8}$'
check_pin HELM_VERSION '^v[0-9]+\.[0-9]+\.[0-9]+$'
check_pin HELM_LINUX_AMD64_SHA256 "$SHA"
check_pin KUBECTL_VERSION '^v[0-9]+\.[0-9]+\.[0-9]+$'
check_pin KUBECTL_LINUX_AMD64_SHA256 "$SHA"
check_pin COSIGN_VERSION '^v[0-9]+\.[0-9]+\.[0-9]+$'
check_pin COSIGN_LINUX_AMD64_SHA256 "$SHA"
check_pin PLATFORM_UPDATER_BASE_IMAGE "$IMG_DIGEST"
check_pin CHART_SECRETS_BOOTSTRAP_IMAGE "$IMG_DIGEST"
check_pin CHART_BUSYBOX_IMAGE "$IMG_DIGEST"
check_pin CHART_PROMTAIL_IMAGE "$IMG_DIGEST"
# Every other KEY= line, including pins other changes add (FOUNDATION_*, UBUNTU_BASE_VHDX_*): never
# "latest"; EMPTY only when explicitly marked as not yet published — the word "unpublished" in a
# trailing comment on that line or in the comment line directly above it, e.g.
#     # unpublished: set when the base VHDX is first published
#     UBUNTU_BASE_VHDX_SHA256=
prev=''
while IFS= read -r line; do
    if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=([^#]*)(#.*)?$ ]]; then
        key=${BASH_REMATCH[1]}; val=$(sed -E 's/[[:space:]]+$//' <<< "${BASH_REMATCH[2]}"); trailing=${BASH_REMATCH[3]:-}
        if [ -z "$val" ]; then
            shopt -s nocasematch
            [[ "$trailing" == *unpublished* || "$prev" == \#*unpublished* ]] \
                || fail "$PINS: $key is empty and not marked unpublished (a pin must have a value)"
            shopt -u nocasematch
        elif [[ "$val" == *latest* ]]; then
            fail "$PINS: $key is '$val' (latest is never a pin)"
        fi
    fi
    prev=$line
done < "$PINS"
k3s_minor=$(pin K3S_VERSION | sed -E 's/^v([0-9]+\.[0-9]+)\..*/\1/')
kubectl_minor=$(pin KUBECTL_VERSION | sed -E 's/^v([0-9]+\.[0-9]+)\..*/\1/')
[ "$k3s_minor" = "$kubectl_minor" ] || fail "$PINS: KUBECTL_VERSION minor $kubectl_minor != K3S_VERSION minor $k3s_minor"

# ---- 2. chart sources ----------------------------------------------------------------------------
while IFS= read -r hit; do
    fail "chart source uses latest: $hit"
done < <(grep -rnE '(:latest([@"'"'"' ]|$)|tag:[[:space:]]*"?latest"?[[:space:]]*$)' "$CHART" --include='*.yaml' --include='*.tpl' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
while IFS= read -r hit; do
    fail "image hardcoded in a template (move it to values, pinned): $hit"
done < <(grep -rnE '^[[:space:]]*(-[[:space:]]*)?image:[[:space:]]*"?[a-zA-Z0-9]' "$CHART" --include='*.yaml' --include='*.tpl' | grep '/templates/')

# ---- 3. rendered manifests -----------------------------------------------------------------------
app_version=$(sed -n 's/^appVersion:[[:space:]]*//p' "$CHART/Chart.yaml" | tr -d "\"'")
check_ref() { # <profile> <image ref>
    local p=$1 ref=$2 name tag digest=''
    [[ "$ref" == *@* ]] && { digest=${ref#*@}; ref=${ref%@*}; }
    [ -z "$digest" ] || [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { fail "[$p] malformed digest: $2"; return; }
    name=${ref##*/}
    if [[ "$name" == *:* ]]; then tag=${name##*:}; else tag=''; fi
    if [ -z "$tag" ] && [ -z "$digest" ]; then fail "[$p] image has no tag and no digest: $2"; return; fi
    [ "$tag" != latest ] || { fail "[$p] image uses latest: $2"; return; }
    # A tag with no dot (redis:7, nginx:alpine) floats across releases unless a digest pins it.
    if [ -z "$digest" ] && [ -n "$tag" ] && [[ "$tag" != *.* ]]; then fail "[$p] floating tag without a digest: $2"; fi
    if [[ "$ref" == ghcr.io/cloudgrange/* ]] && [ "$p" != first-party-override ] && [ "$tag" != "$app_version" ]; then
        fail "[$p] first-party image not at the chart appVersion $app_version: $2"
    fi
}
ALL_ON=(--set observability.promtail.enabled=true --set observability.promtail.raiseInotifyLimits=true
        --set metallb.enabled=true --set 'metallb.addressPool[0]=192.0.2.10/32' --set backup.enabled=true
        --set certManager.installOperator=true --set platformUpdater.enabled=true --api-versions cert-manager.io/v1)
render_check() { # <profile label> <helm args...>
    local label=$1; shift
    if ! helm template cg "$CHART" -n cloudgrange "$@" > "$WORK/render.yaml" 2> "$WORK/render.err"; then
        fail "[$label] helm template failed: $(head -3 "$WORK/render.err" | tr '\n' ' ')"; return
    fi
    local refs
    refs=$( { grep -hoE '^[[:space:]]*(-[[:space:]]*)?(image|imageName):[[:space:]]*"?[^"'"'"' ]+' "$WORK/render.yaml" \
                | sed -E 's/^[[:space:]]*(-[[:space:]]*)?(image|imageName):[[:space:]]*"?//';
              sed -n 's/^[[:space:]]*CLOUDGRANGE_PLATFORM_UPDATER_IMAGE:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$WORK/render.yaml"; } | sort -u)
    [ -n "$refs" ] || { fail "[$label] rendered no images"; return; }
    while IFS= read -r ref; do check_ref "$label" "$ref"; done <<< "$refs"
    grep -nE ':latest([@"'"'"' ]|$)' "$WORK/render.yaml" | while IFS= read -r l; do echo "PIN-LINT FAIL: [$label] rendered latest: $l" >&2; done
    grep -qE ':latest([@"'"'"' ]|$)' "$WORK/render.yaml" && FAILS=$((FAILS + 1))
    echo "  ok-render: $label ($(wc -l <<< "$refs") images)"
}
echo "PIN-LINT: rendering every profile"
render_check "chart defaults"
for f in "$CHART"/values-*.yaml; do
    render_check "$(basename "$f")" -f "$f"
    render_check "$(basename "$f") + all optional components" -f "$f" "${ALL_ON[@]}"
done
render_check "chart defaults + all optional components" "${ALL_ON[@]}"

# ---- 4. Dockerfiles ------------------------------------------------------------------------------
while IFS= read -r df; do
    while IFS= read -r line; do
        img=$(awk '{for (i = 2; i <= NF; i++) if ($i !~ /^--/) { print $i; exit }}' <<< "$line")
        if [[ "$img" =~ ^\$\{?([A-Za-z_]+)\}?$ ]]; then
            arg=${BASH_REMATCH[1]}
            default=$(sed -nE "s/^ARG[[:space:]]+$arg=(.*)$/\1/p" "$df" | head -1)
            [ -z "$default" ] || [[ "$default" =~ @sha256:[0-9a-f]{64}$ ]] || fail "$df: ARG $arg default is not digest-pinned: $default"
        elif ! [[ "$img" =~ @sha256:[0-9a-f]{64}$ ]]; then
            fail "$df: FROM $img is not pinned by digest"
        fi
    done < <(grep -E '^FROM[[:space:]]' "$df")
done < <(find images -name Dockerfile 2>/dev/null)

# ---- 5. chart metadata ---------------------------------------------------------------------------
chart_version=$(sed -n 's/^version:[[:space:]]*//p' "$CHART/Chart.yaml" | tr -d "\"'")
[[ "$chart_version" =~ $SEMVER_PLATFORM ]] || fail "$CHART/Chart.yaml version '$chart_version' is not YYMM.MINOR.PATCH[-preview.N|-rc.N]"
[[ "$app_version" =~ $SEMVER_PLATFORM ]] || fail "$CHART/Chart.yaml appVersion '$app_version' is not YYMM.MINOR.PATCH[-preview.N|-rc.N]"
[ "$chart_version" = "$app_version" ] || fail "$CHART/Chart.yaml version $chart_version != appVersion $app_version (the chart is the platform)"
for sub in api portal relay; do
    v=$(sed -n 's/^appVersion:[[:space:]]*//p' "$CHART/charts/$sub/Chart.yaml" | tr -d "\"'")
    [ "$v" = "$app_version" ] || fail "$CHART/charts/$sub appVersion $v != umbrella appVersion $app_version (image tag fallback)"
done
grep -qE '^kubeVersion:[[:space:]]*"?[^"[:space:]]' "$CHART/Chart.yaml" || fail "$CHART/Chart.yaml has no kubeVersion"
helm template cg "$CHART" --kube-version "$(pin K3S_VERSION)" >/dev/null 2>"$WORK/kv.err" \
    || fail "the pinned K3s $(pin K3S_VERSION) is outside the chart's kubeVersion: $(head -1 "$WORK/kv.err")"

# ---- 6. drift of pin copies ----------------------------------------------------------------------
drift() { # <file> <extracted value> <pin key>
    local want; want=$(pin "$3")
    [ "$2" = "$want" ] || fail "$1 has ${2:-nothing} where $PINS $3 is $want"
}
drift scripts/Install-CloudGrangeK3s.sh "$(sed -nE 's/^K3S_VERSION="\$\{CLOUDGRANGE_K3S_VERSION:-([^}]*)\}".*/\1/p' scripts/Install-CloudGrangeK3s.sh)" K3S_VERSION
drift scripts/Install-CloudGrangeK3s.sh "$(sed -nE 's/^[[:space:]]*local helm_version="([^"]*)".*/\1/p' scripts/Install-CloudGrangeK3s.sh)" HELM_VERSION
drift scripts/Install-CloudGrangeK3s.sh "$(sed -nE 's/^K3S_INSTALL_SH_SHA256="\$\{CLOUDGRANGE_K3S_INSTALL_SH_SHA256:-([^}]*)\}".*/\1/p' scripts/Install-CloudGrangeK3s.sh)" K3S_INSTALL_SH_SHA256
drift scripts/Install-CloudGrangeK3s.sh "$(sed -nE 's/^FOUNDATION_VERSION="\$\{CLOUDGRANGE_FOUNDATION_VERSION:-([^}]*)\}".*/\1/p' scripts/Install-CloudGrangeK3s.sh)" FOUNDATION_VERSION
drift scripts/Install-CloudGrangeK3s.sh "$(sed -nE 's/^FOUNDATION_CHANNEL_URL="\$\{CLOUDGRANGE_FOUNDATION_CHANNEL_URL:-([^}]*)\}".*/\1/p' scripts/Install-CloudGrangeK3s.sh)" FOUNDATION_CHANNEL_URL
drift scripts/CloudGrange-Prereqs.ps1 "$(sed -nE "s/^\\\$script:CloudGrangeQemuVersion[[:space:]]*=[[:space:]]*'([^']*)'.*/\\1/p" scripts/CloudGrange-Prereqs.ps1)" QEMU_WINDOWS_BUILD
drift "$CHART/values.yaml secretsBootstrap.image" "$(awk '/^secretsBootstrap:/{s=1;next} s&&/^[^ #]/{s=0} s&&/^  image:/{print $2; exit}' "$CHART/values.yaml")" CHART_SECRETS_BOOTSTRAP_IMAGE
drift "$CHART/charts/observability/values.yaml busybox.image" "$(awk '/^busybox:/{s=1;next} s&&/^[^ #]/{s=0} s&&/^  image:/{print $2; exit}' "$CHART/charts/observability/values.yaml")" CHART_BUSYBOX_IMAGE
drift "$CHART/charts/api/values.yaml waitForPostgres.image" "$(awk '/^waitForPostgres:/{s=1;next} s&&/^[^ #]/{s=0} s&&/^  image:/{print $2; exit}' "$CHART/charts/api/values.yaml")" CHART_BUSYBOX_IMAGE
drift "$CHART/charts/observability/values.yaml promtail.image" "$(awk '/^promtail:/{s=1;next} s&&/^[^ #]/{s=0} s&&/^  image:/{print $2; exit}' "$CHART/charts/observability/values.yaml")" CHART_PROMTAIL_IMAGE

# ---- 7. delivery-path wrappers -------------------------------------------------------------------
WRAPPERS=(Install-CloudGrange.ps1 Install-CloudGrange-Linux.sh Build-CloudGrangeApplianceK3s.ps1
          scripts/Install-CloudGrangeK3s.sh scripts/Deploy-K3sHelm.ps1 scripts/New-CloudGrangeVm.ps1
          scripts/New-ReleaseBundleK3s.sh appliance/cloudgrange-generalize-k3s.sh images/platform-updater/entrypoint.sh)
PATTERN=":-latest\}|= *'latest'|= *\"latest\"|get\.k3s\.io|/current/|releases/latest"
touch "$WORK/allow-used"
while IFS= read -r hit; do
    file=${hit%%:*}; rest=${hit#*:}; text=${rest#*:}
    allowed=''
    if [ -f "$ALLOW" ]; then
        while IFS='|' read -r afile asub _reason; do
            [[ -z "$afile" || "$afile" == \#* ]] && continue
            if [ "$afile" = "$file" ] && [[ "$text" == *"$asub"* ]]; then allowed="$afile|$asub"; break; fi
        done < "$ALLOW"
    fi
    if [ -n "$allowed" ]; then echo "$allowed" >> "$WORK/allow-used"; echo "  allowed (tracked in $ALLOW): $file: $(sed -E 's/^[[:space:]]+//' <<< "$text")"
    else fail "unpinned in a delivery-path wrapper: $hit"; fi
done < <(for w in "${WRAPPERS[@]}"; do [ -f "$w" ] && grep -nE "$PATTERN" "$w" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|$w:|"; done)
if [ -f "$ALLOW" ]; then
    while IFS='|' read -r afile asub _reason; do
        [[ -z "$afile" || "$afile" == \#* ]] && continue
        grep -qxF "$afile|$asub" "$WORK/allow-used" || fail "$ALLOW entry no longer matches anything — remove it: $afile|$asub"
    done < "$ALLOW"
fi

# ---- 8. update trust: HTTPS + digest pinning, no signing key --------------------------------------
for vf in "" values-single-node.yaml values-azure.yaml values-multi-node.yaml; do
    args=(); [ -n "$vf" ] && args=(-f "$CHART/$vf")
    ch=$(helm template cg "$CHART" "${args[@]}" 2>/dev/null | sed -n 's/^  channelUrl: "\(.*\)"$/\1/p' | head -1)
    [[ "$ch" == https://* ]] || fail "${vf:-chart defaults}: the platform updater's trust ConfigMap has no https:// channelUrl (${ch:-none})"
done
EP=images/platform-updater/entrypoint.sh
grep -q -- "--proto '=https' --proto-redir '=https'" "$EP" || fail "$EP: downloads are not restricted to https (curl --proto =https --proto-redir =https)"
grep -q 'not pinned by @sha256 digest' "$EP" || fail "$EP: no refusal of images not pinned by digest"
grep -q 'latest.manifestSha256' "$EP" || fail "$EP: the release manifest is not pinned to the channel's manifestSha256"
grep -qi 'refusing an unverifiable' "$EP" scripts/cloudgrange-updater-k3s.py \
    && fail "an updater still refuses updates for lack of a signing key (owner decision 2026-09-18: signatures are optional)"
grep -q '"manifestSha256"' scripts/release/Publish-Release.sh || fail "Publish-Release.sh does not publish latest.manifestSha256"
grep -q '"manifestSha256"' scripts/release/Publish-ModuleCatalog.sh || fail "Publish-ModuleCatalog.sh does not publish manifestSha256"
grep -q 'manifest.json.sig" \]' scripts/release/Publish-Release.sh || fail "Publish-Release.sh must treat manifest.json.sig as optional"

if [ "$FAILS" -gt 0 ]; then echo "PIN-LINT: $FAILS failure(s)" >&2; exit 1; fi
echo "PIN-LINT: OK — no latest and no unpinned versions in shipped artifacts"
