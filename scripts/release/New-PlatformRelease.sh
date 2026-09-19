#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (plan 2026-09-18-foundation-platform-separation B1/B2, E1) — cut the Platform release
# artifacts the in-cluster Platform updater consumes:
#   1. tag the first-party images (api, portal, relay, platform-updater) with the platform version
#      YYMM.MINOR.PATCH and resolve each one's registry digest;
#   2. stamp the version into a copy of the chart (Set-ChartVersion.sh) and `helm package` it;
#   3. write the release manifest (cg-release-manifest-v1, release-versioning.md) that pins the
#      chart by SHA-256 and every first-party image by digest;
#   4. write manifest.json.sha256 — the value Publish-Release.sh puts in the channel as
#      latest.manifestSha256, which is what the Platform updater pins the manifest to;
#   5. OPTIONALLY sign the manifest with cosign when a key is given (manifest.json.sig). No key is
#      required: update trust is HTTPS + SHA-256/digest pinning (owner decision 2026-09-18).
#
# DRY RUN BY DEFAULT: without --push nothing is tagged or pushed; the commands are printed and the
# manifest is written with "dryRun": true, which the Platform updater refuses to apply.
#
# Usage:
#   New-PlatformRelease.sh --version 2609.0.0-preview.3 --out DIR --chart-base-url URL
#       [--source-tag TAG]    tag the images were built/pushed under (default: the version itself)
#       [--registry REG]      default ghcr.io/cloudgrange
#       [--channel C]         preview|rc|stable (default preview)
#       [--upgrade-from R]    SemVer range of installed versions this release can update (default ">=2609.0.0-0")
#       [--cosign-key PATH]   optional: also sign manifest.json -> manifest.json.sig (cosign sign-blob --key)
#       [--push]              really tag and push; needs `docker login ghcr.io` with write access
#       [--already-pushed]    the images are ALREADY in the registry as <repo>:<version> (built and pushed,
#                             or retagged by digest, by the release run): push nothing, resolve each
#                             digest from the registry, and write a real (non-dry-run) manifest. The
#                             version-free check is skipped because this step publishes nothing;
#                             a missing tag is an error.
# --chart-base-url is where the chart .tgz will be published, e.g. $R2_PUBLIC_BASE/releases/<version>
set -euo pipefail

VERSION='' OUT='' CHART_BASE_URL='' SOURCE_TAG='' REGISTRY='ghcr.io/cloudgrange' CHANNEL='preview'
UPGRADE_FROM='>=2609.0.0-0' COSIGN_KEY='' PUSH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        --chart-base-url) CHART_BASE_URL=$2; shift 2 ;;
        --source-tag) SOURCE_TAG=$2; shift 2 ;;
        --registry) REGISTRY=$2; shift 2 ;;
        --channel) CHANNEL=$2; shift 2 ;;
        --upgrade-from) UPGRADE_FROM=$2; shift 2 ;;
        --cosign-key) COSIGN_KEY=$2; shift 2 ;;
        --push) PUSH=1; shift ;;
        --already-pushed) PUSH=2; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ "$VERSION" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(-(preview|rc)\.[0-9]+)?$ ]] \
    || { echo "--version must be YYMM.MINOR.PATCH[-preview.N|-rc.N]" >&2; exit 2; }
[ -n "$OUT" ] && [ -n "$CHART_BASE_URL" ] || { echo "--out and --chart-base-url are required" >&2; exit 2; }
case "$CHANNEL" in preview|rc|stable) ;; *) echo "--channel must be preview, rc or stable" >&2; exit 2 ;; esac
SOURCE_TAG=${SOURCE_TAG:-$VERSION}
[ "$SOURCE_TAG" != latest ] || { echo "--source-tag latest is refused: tag from an immutable build tag" >&2; exit 2; }
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
log() { echo "[platform-release] $*"; }
run() { case "$PUSH" in 1) "$@" ;; 2) echo "ALREADY-PUSHED, skipped: $*" ;; *) echo "DRY-RUN: $*" ;; esac; }
[ "$PUSH" != 2 ] || [ "$SOURCE_TAG" = "$VERSION" ] || { echo "--already-pushed cannot retag: drop --source-tag" >&2; exit 2; }

# AB#9171: one version number per release, across every image AND the OCI chart. Refuse before
# anything is pushed rather than overwriting or splitting a number between two builds.
if [ "$PUSH" = 1 ]; then
    bash "$REPO_ROOT/scripts/release/Test-ReleaseVersionFree.sh" --check "$VERSION" \
        || { echo "pick a free version: $(bash "$REPO_ROOT/scripts/release/Test-ReleaseVersionFree.sh" --next "${VERSION%.*}")" >&2; exit 1; }
fi

# component name in the manifest -> image repository
declare -A IMAGES=(
    [cloudgrange-api]=cloudgrange-api
    [cloudgrange-portal]=cloudgrange-portal
    [cloudgrange-relay]=cloudgrange-relay
    [cloudgrange-platform-updater]=cloudgrange-platform-updater
)
: > "$WORK/components.tsv"
for comp in $(printf '%s\n' "${!IMAGES[@]}" | sort); do
    repo="$REGISTRY/${IMAGES[$comp]}"
    src="$repo:$SOURCE_TAG" dst="$repo:$VERSION"
    if [ "$SOURCE_TAG" != "$VERSION" ]; then
        run docker pull -q "$src"
        run docker tag "$src" "$dst"
    fi
    run docker push -q "$dst"
    digest=''
    if [ "$PUSH" = 2 ]; then
        digest=$(docker buildx imagetools inspect "$dst" --format '{{json .Manifest}}' 2>/dev/null \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])' 2>/dev/null) \
            || { echo "$dst is not in the registry (--already-pushed)" >&2; exit 1; }
        [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "no registry digest for $dst" >&2; exit 1; }
    elif [ "$PUSH" = 1 ]; then
        digest=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$dst" | grep -m1 "^$repo@sha256:" | cut -d@ -f2)
        [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "no registry digest for $dst after push" >&2; exit 1; }
    else
        digest="sha256:$(printf '0%.0s' $(seq 64))"
    fi
    printf '%s\t%s\t%s\n' "$comp" "$dst@$digest" "$digest" >> "$WORK/components.tsv"
    log "$comp -> $dst@$digest"
done

log "chart: stamp $VERSION and package"
cp -r "$REPO_ROOT/charts/cloudgrange" "$WORK/cloudgrange"
rm -f "$WORK/cloudgrange/Chart.lock"
bash "$REPO_ROOT/scripts/release/Set-ChartVersion.sh" "$WORK/cloudgrange" "$VERSION" >/dev/null
helm package "$WORK/cloudgrange" -d "$OUT" >/dev/null
CHART_TGZ="$OUT/cloudgrange-$VERSION.tgz"
[ -f "$CHART_TGZ" ] || { echo "helm package did not produce $CHART_TGZ" >&2; exit 1; }
chart_sha=$(sha256sum "$CHART_TGZ" | cut -d' ' -f1)
kube_range=$(sed -n 's/^kubeVersion:[[:space:]]*//p' "$WORK/cloudgrange/Chart.yaml" | tr -d '"')
[ -n "$kube_range" ] || { echo "chart has no kubeVersion" >&2; exit 1; }

python3 - "$OUT/manifest.json" "$VERSION" "$CHANNEL" "$UPGRADE_FROM" "$kube_range" \
    "${CHART_BASE_URL%/}/cloudgrange-$VERSION.tgz" "$chart_sha" "$PUSH" "$WORK/components.tsv" <<'PY'
import json, sys, time
out, version, channel, upgrade_from, kube_range, chart_url, chart_sha, push, tsv = sys.argv[1:10]
components = {}
for line in open(tsv):
    name, image, digest = line.rstrip("\n").split("\t")
    components[name] = {"version": version, "image": image, "digest": digest}
manifest = {
    "schema": "cg-release-manifest-v1",
    "platform": version,
    "channel": channel,
    "released": time.strftime("%Y-%m-%d", time.gmtime()),
    "upgradeFrom": upgrade_from,
    "kubeVersion": kube_range,
    "chart": {"url": chart_url, "sha256": chart_sha},
    "components": components,
}
if push not in ("1", "2"):
    manifest["dryRun"] = True
json.dump(manifest, open(out, "w"), indent=2, sort_keys=True)
open(out, "a").write("\n")
PY

if [ -n "$COSIGN_KEY" ]; then
    log "signing manifest.json with $COSIGN_KEY"
    # Legacy detached signature (manifest.json.sig), key-pair only, no transparency log: the same
    # form the appliance uses, and verifiable offline. cosign v3 needs the explicit opt-outs.
    cosign sign-blob --yes --key "$COSIGN_KEY" --new-bundle-format=false --use-signing-config=false \
        --tlog-upload=false --output-signature "$OUT/manifest.json.sig" "$OUT/manifest.json" >/dev/null
else
    rm -f "$OUT/manifest.json.sig"
    log "no --cosign-key: manifest.json is unsigned (optional); updates trust its SHA-256 in the channel and the image digests"
fi
# Every image in the manifest must be pinned by digest; the updater refuses anything else.
python3 - "$OUT/manifest.json" <<'PY'
import json, re, sys
m = json.load(open(sys.argv[1]))
bad = [k for k, c in m["components"].items() if not re.search(r"@sha256:[0-9a-f]{64}$", c.get("image", ""))]
sys.exit("images not pinned by digest: %s" % ", ".join(bad) if bad else 0)
PY
manifest_sha=$(sha256sum "$OUT/manifest.json" | cut -d' ' -f1)
printf '%s  manifest.json\n' "$manifest_sha" > "$OUT/manifest.json.sha256"
log "wrote $OUT/manifest.json (sha256 $manifest_sha) and $CHART_TGZ (sha256 $chart_sha)$([ "$PUSH" != 0 ] || echo ' — DRY RUN, nothing pushed')"
