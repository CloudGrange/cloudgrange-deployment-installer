#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (plan 2026-09-18-foundation-platform-separation B1/B2, E1) — cut the Platform release
# artifacts the in-cluster Platform updater consumes:
#   1. tag the first-party images (api, portal, relay, platform-updater) with the platform version
#      YYMM.MINOR.PATCH and resolve each one's registry digest;
#   (the portal image must carry the matching cg CLI: New-CliRelease.sh + Build-PortalImage.sh)
#   2. stamp the version into a copy of the chart (Set-ChartVersion.sh) and `helm package` it;
#   3. write the release manifest (cg-release-manifest-v1, release-versioning.md) that pins the
#      chart by SHA-256 and every first-party image by digest;
#   4. write manifest.json.sha256 — the value Publish-Release.sh puts in the channel as
#      latest.manifestSha256, which is what the Platform updater pins the manifest to;
#   5. OPTIONALLY sign the manifest with cosign when a key is given (manifest.json.sig). No key is
#      required: update trust is HTTPS + SHA-256/digest pinning (owner decision 2026-09-18).
#   6. (AB#9171 E7) write images.txt — every image the release can run (scripts/release/
#      Get-PlatformImages.sh), plus the module images when --modules-catalog is given, one
#      "<repository> <tag> <digest>" line each, pinned by digest — and pin it in the manifest
#      (images.sha256). Customers mirror these images for an air-gapped bring-your-own-Kubernetes
#      or AKS install (global.imageRegistry).
#   7. (E7, --offline-bundle) build cloudgrange-platform-<version>.zip and its .sha256: the offline
#      Platform bundle an administrator uploads on the Platform card of an air-gapped managed install.
#        manifest.json, [manifest.json.sig], cloudgrange-<version>.tgz, images.txt, SHA256SUMS,
#        images/<digest hex>/oci/                  OCI layout of the image (linux/amd64)
#        images/<digest hex>/index-manifest.json   the exact index bytes, when the pin is a
#                                                  multi-platform index (only amd64 is carried)
#        modules/catalog.json, modules/manifests/  (with --modules-catalog) the module catalog
#                                                  snapshot, offered by the API with no internet
#      Trust: the zip's SHA-256, published beside it, which the administrator confirms in the portal;
#      inside, the same pins as online. The in-cluster Platform updater verifies it and pushes the
#      images into the in-cluster registry (images/platform-updater/entrypoint.sh apply --bundle).
#      Needs crane (release/pins.conf CRANE_VERSION) and --push or --already-pushed.
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
#       [--source-sha C=SHA]  AB#9171 provenance, REQUIRED for every component with --push or
#                             --already-pushed (repeatable; C is api|portal|relay|platform-updater
#                             or the full component name, SHA the full 40-hex commit of that
#                             component's SOURCE repository HEAD). Every image this release
#                             publishes is read back and refused unless its
#                             org.opencontainers.image.revision equals the SHA given here and its
#                             org.opencontainers.image.version equals the version it was built as.
#                             This is what catches a retag of an image that predates the fix it is
#                             supposed to carry: the retag path is checked against the CURRENT
#                             source HEAD, so an unchanged component only passes when its published
#                             image really was built from the source being released.
#       [--modules-catalog U] E7: include the module catalog at U (https URL or file,
#                             cg-module-catalog-v1; the newest version of each module) in images.txt
#                             and in the offline bundle (scripts/release/Get-ModuleCatalogSnapshot.sh)
#       [--offline-bundle]    E7: also build the offline Platform bundle (needs --push or --already-pushed)
# --chart-base-url is where the chart .tgz will be published, e.g. $R2_PUBLIC_BASE/releases/<version>
set -euo pipefail

VERSION='' OUT='' CHART_BASE_URL='' SOURCE_TAG='' REGISTRY='ghcr.io/cloudgrange' CHANNEL='preview'
UPGRADE_FROM='>=2609.0.0-0' COSIGN_KEY='' PUSH=0 OFFLINE_BUNDLE=0 MODULES_CATALOG=''
declare -A SOURCE_SHA=()
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
        --offline-bundle) OFFLINE_BUNDLE=1; shift ;;
        --modules-catalog) MODULES_CATALOG=$2; shift 2 ;;
        --source-sha)
            [[ "$2" == *=* ]] || { echo "--source-sha takes <component>=<40-hex commit sha>" >&2; exit 2; }
            _c=${2%%=*}; _s=${2#*=}
            [[ "$_c" == cloudgrange-* ]] || _c="cloudgrange-$_c"
            [[ "$_s" =~ ^[0-9a-f]{40}$ ]] || { echo "--source-sha $_c: '$_s' is not a full 40-hex commit sha" >&2; exit 2; }
            SOURCE_SHA[$_c]=$_s; shift 2 ;;
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

# component name in the manifest -> image repository
declare -A IMAGES=(
    [cloudgrange-api]=cloudgrange-api
    [cloudgrange-portal]=cloudgrange-portal
    [cloudgrange-relay]=cloudgrange-relay
    [cloudgrange-platform-updater]=cloudgrange-platform-updater
)

# AB#9171 provenance: a release must be able to prove which source commit every image it publishes
# came from. Refuse, before anything is pulled, tagged or pushed, unless the caller states the
# source HEAD of every component; each published image is then read back and compared against it.
# shellcheck source=scripts/release/image-provenance.sh
. "$REPO_ROOT/scripts/release/image-provenance.sh"
if [ "$PUSH" != 0 ]; then
    missing=()
    for comp in $(printf '%s\n' "${!IMAGES[@]}" | sort); do
        [ -n "${SOURCE_SHA[$comp]:-}" ] || missing+=("$comp")
    done
    [ ${#missing[@]} -eq 0 ] || {
        echo "provenance: --source-sha <component>=<40-hex commit sha> is required for: ${missing[*]}" >&2
        echo "  Give the CURRENT source HEAD of each component's repository. Every image this release publishes" >&2
        echo "  is read back and refused unless it was built from that commit — including a retagged 'unchanged'" >&2
        echo "  image, which is how a build predating the fix it was supposed to carry reached a release before." >&2
        exit 2
    }
    command -v crane >/dev/null \
        || { echo "crane is required (release/pins.conf CRANE_VERSION) to read published image labels and digests" >&2; exit 1; }
fi

# AB#9171: one version number per release, across every image AND the OCI chart. Refuse before
# anything is pushed rather than overwriting or splitting a number between two builds.
if [ "$PUSH" = 1 ]; then
    bash "$REPO_ROOT/scripts/release/Test-ReleaseVersionFree.sh" --check "$VERSION" \
        || { echo "pick a free version: $(bash "$REPO_ROOT/scripts/release/Test-ReleaseVersionFree.sh" --next "${VERSION%.*}")" >&2; exit 1; }
fi

# AB#9171: every platform release ships the matching `cg` CLI, served by the platform at
# /downloads/cli/. Refuse a portal image built without it (Build-PortalImage.sh bakes it in),
# before anything is tagged or pushed.
portal="$REGISTRY/cloudgrange-portal:$SOURCE_TAG"
if [ "$PUSH" != 0 ]; then
    cli_version=$(docker run --rm --entrypoint cat "$portal" /usr/share/nginx/html/downloads/cli/manifest.json 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null) || cli_version=''
    [ "$cli_version" = "$VERSION" ] || {
        echo "$portal does not carry the cg CLI for $VERSION (found '${cli_version:-none}'): build it with New-CliRelease.sh + Build-PortalImage.sh" >&2
        exit 1
    }
    log "portal serves cg $cli_version at /downloads/cli/"
else
    echo "DRY-RUN: would check that $portal carries the cg CLI for $VERSION"
fi

: > "$WORK/components.tsv"
# AB#9171 provenance: the version an image is LEGITIMATELY stamped with is the version it was built
# as — that is $SOURCE_TAG on the retag path (--push --source-tag), and $VERSION everywhere else.
# With --already-pushed the image must already sit in the registry under :$VERSION, so it must also
# have been BUILT as $VERSION: a hand-retagged older digest is refused here even if its revision
# happens to match, and the operator is told to use --push --source-tag instead.
[ "$PUSH" = 2 ] && want_ver="$VERSION" || want_ver="$SOURCE_TAG"
for comp in $(printf '%s\n' "${!IMAGES[@]}" | sort); do
    repo="$REGISTRY/${IMAGES[$comp]}"
    src="$repo:$SOURCE_TAG" dst="$repo:$VERSION"
    want_sha=${SOURCE_SHA[$comp]:-}
    if [ "$SOURCE_TAG" != "$VERSION" ]; then
        run docker pull -q "$src"
        # Refuse BEFORE the retag: a stale image must never reach the registry under the new tag.
        if [ "$PUSH" = 1 ]; then
            cg_assert_image_provenance "$src" "$want_sha" "$want_ver" local || {
                echo "refusing to retag $src as $dst: it was not built from the source being released" >&2; exit 1; }
        fi
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
    # AB#9171: read the PUBLISHED bytes back and refuse anything whose stamped source commit or
    # version is not what this release recorded. This runs on every path that publishes an image,
    # including --already-pushed and a retag of a previous release's digest.
    if [ "$PUSH" != 0 ]; then
        cg_assert_image_provenance "$repo@$digest" "$want_sha" "$want_ver" remote || {
            echo "refusing the release: $dst ($digest) does not carry the provenance this release claims" >&2
            exit 1
        }
    else
        echo "DRY-RUN: would verify $dst carries org.opencontainers.image.revision=${want_sha:-<--source-sha>} and org.opencontainers.image.version=$want_ver"
    fi
    printf '%s\t%s\t%s\t%s\n' "$comp" "$dst@$digest" "$digest" "$want_sha" >> "$WORK/components.tsv"
    log "$comp -> $dst@$digest${want_sha:+ (source $want_sha)}"
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

# 5. images.txt (E7): every image this release can run, as the stamped chart renders it with the
# first-party digests pinned, each resolved to a digest. "<repository> <tag> <digest>", repository
# fully qualified (docker.io/library/... for Docker Hub short names), sorted.
command -v crane >/dev/null || { echo "crane is required (release/pins.conf CRANE_VERSION) to resolve image digests" >&2; exit 1; }
CHART_REGISTRY=$(awk '/^  image:/{s=1;next} s&&/^    registry:/{print $2; exit}' "$WORK/cloudgrange/values.yaml")
[ -n "$CHART_REGISTRY" ] || { echo "cannot read global.image.registry from the chart" >&2; exit 1; }
fq_repo() { # <ref> -> fully qualified repository, no tag or digest
    local name=${1%%@*} first
    [[ "${name##*/}" == *:* ]] && name=${name%:*}
    first=${name%%/*}
    if [[ "$name" != */* ]]; then echo "docker.io/library/$name"
    elif [[ "$first" == *.* || "$first" == *:* || "$first" == localhost ]]; then echo "$name"
    else echo "docker.io/$name"; fi
}
# Where to read an image from: first-party images from --registry (which may differ from the name
# the chart renders, for example a staging registry), everything else from where the chart pins it.
# Only this release's own images (the IMAGES map above); other images under the same registry, such
# as the module package, are read from where they are pinned.
first_party() { local r=$1 c; for c in "${IMAGES[@]}"; do [ "$r" = "$CHART_REGISTRY/$c" ] && return 0; done; return 1; }
pull_repo() { local r=$1; if [ "$REGISTRY" != "$CHART_REGISTRY" ] && first_party "$r"; then echo "$REGISTRY/${r#"$CHART_REGISTRY/"}"; else echo "$r"; fi; }
pin_sets=()
while IFS=$'\t' read -r comp _image digest _revision; do
    case "$comp" in
        cloudgrange-platform-updater) pin_sets+=(--set "platformUpdater.image.digest=$digest") ;;
        *) pin_sets+=(--set "${comp#cloudgrange-}.image.digest=$digest") ;;
    esac
done < "$WORK/components.tsv"
bash "$REPO_ROOT/scripts/release/Get-PlatformImages.sh" "$WORK/cloudgrange" "${pin_sets[@]}" > "$WORK/refs.txt"
# E7: the module catalog snapshot (newest version of each module). Its images join images.txt, so
# a BYO customer mirrors them too and an offline bundle carries them.
if [ -n "$MODULES_CATALOG" ]; then
    bash "$REPO_ROOT/scripts/release/Get-ModuleCatalogSnapshot.sh" "$MODULES_CATALOG" "$WORK/modules" >> "$WORK/refs.txt"
    log "modules: $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["modules"]))' "$WORK/modules/catalog.json") module(s) from $MODULES_CATALOG"
fi
{
    echo "# CloudGrange Platform $VERSION: every container image this release can run (AB#9171 E7)."
    echo "# <repository> <tag> <digest>. Mirror each as <your registry>/<repository without its host>:<tag>"
    echo "# (keep the digest), then install or upgrade with --set global.imageRegistry=<your registry>."
    while read -r ref; do
        [ -n "$ref" ] || continue
        repo=$(fq_repo "$ref"); name=${ref%%@*}; tag=''
        [[ "${name##*/}" == *:* ]] && tag=${name##*:}
        [ -n "$tag" ] || { echo "image without a tag: $ref" >&2; exit 1; }
        if [[ "$ref" == *@sha256:* ]]; then digest=${ref##*@}
        elif [ "$PUSH" != 1 ] && [[ "$repo" == "$CHART_REGISTRY/"* ]]; then digest="sha256:$(printf '0%.0s' $(seq 64))"
        else digest=$(crane digest "$(pull_repo "$repo"):$tag") || { echo "cannot resolve the digest of $repo:$tag" >&2; exit 1; }
        fi
        printf '%s %s %s\n' "$repo" "$tag" "$digest"
    done < "$WORK/refs.txt" | sort -u
} > "$OUT/images.txt"
# One mirror path per repository: the in-cluster registry and global.imageRegistry drop the host.
dupes=$(grep -v '^#' "$OUT/images.txt" | awk '{r=$1; sub(/^[^\/]*\//, "", r); print r, $1}' | sort -u | awk '{print $1}' | uniq -d)
[ -z "$dupes" ] || { echo "two registries carry the same repository path; they would collide in a mirror: $dupes" >&2; exit 1; }
images_sha=$(sha256sum "$OUT/images.txt" | cut -d' ' -f1)
log "images.txt: $(grep -vc '^#' "$OUT/images.txt") images (sha256 $images_sha)"

python3 - "$OUT/manifest.json" "$VERSION" "$CHANNEL" "$UPGRADE_FROM" "$kube_range" \
    "${CHART_BASE_URL%/}/cloudgrange-$VERSION.tgz" "$chart_sha" "$PUSH" "$WORK/components.tsv" "$images_sha" <<'PY'
import json, sys, time
out, version, channel, upgrade_from, kube_range, chart_url, chart_sha, push, tsv, images_sha = sys.argv[1:11]
components = {}
for line in open(tsv):
    name, image, digest, revision = line.rstrip("\n").split("\t")
    components[name] = {"version": version, "image": image, "digest": digest}
    # AB#9171 provenance: the source commit this component was built from. The published image's
    # org.opencontainers.image.revision was read back and compared against it before this manifest
    # was written, so the manifest records a proved value, not a claimed one.
    if revision:
        components[name]["revision"] = revision
manifest = {
    "schema": "cg-release-manifest-v1",
    "platform": version,
    "channel": channel,
    "released": time.strftime("%Y-%m-%d", time.gmtime()),
    "upgradeFrom": upgrade_from,
    "kubeVersion": kube_range,
    "chart": {"url": chart_url, "sha256": chart_sha},
    "components": components,
    # AB#9171 (E7): pins images.txt, so the manifest signature covers every third-party image too.
    "images": {"file": "images.txt", "sha256": images_sha},
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

# 7. the offline Platform bundle (E7).
if [ "$OFFLINE_BUNDLE" = 1 ]; then
    [ "$PUSH" != 0 ] || { echo "--offline-bundle needs --push or --already-pushed: a dry-run manifest cannot be applied" >&2; exit 2; }
    B="$WORK/bundle"; mkdir -p "$B"
    cp "$OUT/manifest.json" "$CHART_TGZ" "$OUT/images.txt" "$B/"
    [ ! -f "$OUT/manifest.json.sig" ] || cp "$OUT/manifest.json.sig" "$B/"
    [ -z "$MODULES_CATALOG" ] || cp -r "$WORK/modules" "$B/modules"
    # First-party images come from --registry (possibly a staging registry), the rest from where they are pinned.
    rewrite=()
    if [ "$REGISTRY" != "$CHART_REGISTRY" ]; then
        for c in "${IMAGES[@]}"; do rewrite+=(--rewrite "$CHART_REGISTRY/$c=$REGISTRY/$c"); done
    fi
    bash "$REPO_ROOT/scripts/release/Add-BundleImages.sh" "$OUT/images.txt" "$B" "${rewrite[@]}"
    ZIP="$OUT/cloudgrange-platform-$VERSION.zip"
    bash "$REPO_ROOT/scripts/release/Write-OfflineBundleZip.sh" "$B" "$ZIP"
    log "offline Platform bundle: $ZIP ($(du -m "$ZIP" | cut -f1) MiB, sha256 $(cut -d' ' -f1 "$ZIP.sha256"))"
fi
log "wrote $OUT/manifest.json (sha256 $manifest_sha) and $CHART_TGZ (sha256 $chart_sha)$([ "$PUSH" != 0 ] || echo ' — DRY RUN, nothing pushed')"
