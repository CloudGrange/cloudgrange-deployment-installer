#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9184/AB#9189 — Build Install-CloudGrange-K3s-Bundled.zip, the ONLY customer bundle.
# The Compose bundle and its builder (scripts/New-ReleaseBundle.sh) are retired: the
# parallel-support period the restructure plan called for is over, K3s/Helm is the only
# shipping engine, and this bundle now carries the offline payload that was the last
# remaining reason to keep the Compose one. Determinism: fixed file modes,
# SOURCE_DATE_EPOCH mtimes, C-locale sorted zip contents, so the same source tree and
# version produce a byte-identical zip regardless of build machine or time.
#
# AB#9189 — this bundle now has full offline/air-gapped parity with the Compose bundle:
# --images registry (the default) packages the pinned K3s binary, K3s's own airgap image
# tarball, and every container image the rendered chart actually references, so a host
# with no internet access can complete an --engine k3s install. The image list is derived
# from `helm template` rather than hand-maintained, so it cannot drift from the chart.
# Pass --images none for a smaller network-install-only bundle.
#
# Inputs:
#   --source DIR     an exported tree of one commit (git archive), not a working copy
#   --version X.Y.Z  stamped as global.image.tag in the bundled values
#   --out DIR        receives the zip, its .sha256, and the manifest
#   --images MODE    registry (default): pull+bundle every image for offline install;
#                    none: no images bundled (install pulls from the network)
set -euo pipefail

usage() { sed -n '5,20p' "$0" >&2; exit 2; }
SOURCE='' VERSION='' OUT='' IMAGES='registry'
while [ $# -gt 0 ]; do
    case "$1" in
        --source) SOURCE=$2; shift 2 ;;
        --version) VERSION=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        --images) IMAGES=$2; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$SOURCE" ] && [ -n "$VERSION" ] && [ -n "$OUT" ] || usage
case "$IMAGES" in registry|none) ;; *) echo "--images must be registry or none" >&2; exit 2 ;; esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "invalid version: $VERSION" >&2; exit 1; }
SOURCE=$(cd "$SOURCE" && pwd)
PINS="$SOURCE/release"
EPOCH=${SOURCE_DATE_EPOCH:-$(tr -d '[:space:]' < "$PINS/SOURCE_DATE_EPOCH")}
[[ "$EPOCH" =~ ^[0-9]+$ ]] || { echo "invalid SOURCE_DATE_EPOCH" >&2; exit 1; }
export LC_ALL=C TZ=UTC
umask 022
log() { echo "[release-bundle-k3s] $*"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
B="$WORK/bundle"
mkdir -p "$B/scripts" "$B/charts"

log "installer + charts from $SOURCE"
cp "$SOURCE/Install-CloudGrange-Linux.sh" "$B/Install-CloudGrange-Linux.sh"
cp "$SOURCE/scripts/Install-CloudGrangeK3s.sh" "$SOURCE/scripts/New-ArtifactManifest.sh" "$B/scripts/"
cp -r "$SOURCE/charts/cloudgrange" "$B/charts/cloudgrange"
mkdir -p "$B/charts/vendor"
cp "$SOURCE/charts/vendor/"*.tgz "$B/charts/vendor/"
rm -f "$B/charts/cloudgrange/Chart.lock"
find "$B/charts/cloudgrange/charts" -maxdepth 1 -name '*.tgz' -delete

log "stamping version $VERSION into values-single-node.yaml's default image tag"
python3 - "$B/charts/cloudgrange/values.yaml" "$VERSION" <<'PY'
import sys, re
path, version = sys.argv[1], sys.argv[2]
text = open(path).read()
text = re.sub(r'(\n\s+tag:\s*).*', rf'\g<1>{version}', text, count=1)
open(path, "w").write(text)
PY

if [ "$IMAGES" = registry ]; then
    K3S_VERSION=$(tr -d '[:space:]' < "$PINS/k3s-version.txt")
    log "air-gap payload: k3s $K3S_VERSION + every image the rendered chart references"
    A="$B/airgap"
    mkdir -p "$A"
    k3s_url="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION//+/%2B}"
    curl -sfL "$k3s_url/k3s" -o "$A/k3s"
    curl -sfL "$k3s_url/k3s-airgap-images-amd64.tar" -o "$A/k3s-airgap-images-amd64.tar"
    curl -sfL "$k3s_url/sha256sum-amd64.txt" -o "$WORK/k3s-sha256sum.txt"
    # K3s publishes one checksum file covering every asset; check our two against it
    # rather than trusting the download, then emit per-file .sha256 the installer verifies.
    (cd "$A" && grep -E ' (k3s|k3s-airgap-images-amd64\.tar)$' "$WORK/k3s-sha256sum.txt" | sed 's| .*/| |' | sha256sum -c -)
    (cd "$A" && sha256sum k3s > k3s.sha256 && sha256sum k3s-airgap-images-amd64.tar > k3s-airgap-images-amd64.tar.sha256)
    curl -sfL https://get.k3s.io -o "$A/k3s-install.sh"

    # Derive the image list from the rendered chart -- never a hand-maintained list, which
    # would silently drift the moment a subchart changes an image. cert-manager is rendered
    # separately because Install-CloudGrangeK3s.sh installs it as its own release first.
    helm template cloudgrange "$B/charts/cloudgrange" -f "$B/charts/cloudgrange/values-single-node.yaml" \
        > "$WORK/rendered.yaml"
    helm template cert-manager "$B/charts/vendor/cert-manager-v1.21.2.tgz" --set crds.enabled=true \
        >> "$WORK/rendered.yaml"
    grep -hoE '^\s+image:\s*"?[^"'"'"' ]+' "$WORK/rendered.yaml" \
        | sed -E 's/^\s+image:\s*"?//' | sort -u > "$WORK/images.txt"
    [ -s "$WORK/images.txt" ] || { echo "no images found in rendered chart" >&2; exit 1; }
    log "$(wc -l < "$WORK/images.txt") images to bundle"
    while read -r img; do
        docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null
    done < "$WORK/images.txt"
    xargs -a "$WORK/images.txt" docker save -o "$WORK/images-raw.tar"
    # docker save lists images in map (random) order and stamps live mtimes; repack sorted
    # with fixed owners/modes/mtimes so the same inputs give a byte-identical bundle.
    mkdir -p "$WORK/img" && tar -xf "$WORK/images-raw.tar" -C "$WORK/img"
    # Both files carry a LIST of entries whose order docker save does not fix; sorting the
    # keys alone is not enough -- the list itself has to be sorted or two runs over the same
    # images produce different bytes.
    for j in "$WORK/img/manifest.json" "$WORK/img/index.json"; do
        [ -f "$j" ] || continue
        python3 - "$j" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
if isinstance(data, list):
    data.sort(key=lambda e: json.dumps(e, sort_keys=True))
elif isinstance(data, dict) and isinstance(data.get("manifests"), list):
    data["manifests"].sort(key=lambda e: json.dumps(e, sort_keys=True))
json.dump(data, open(path, "w"), indent=None, sort_keys=True)
PY
    done
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$EPOCH" \
        -cf "$A/cloudgrange-images-amd64.tar" -C "$WORK/img" .
    (cd "$A" && sha256sum cloudgrange-images-amd64.tar > cloudgrange-images-amd64.tar.sha256)
    cp "$WORK/images.txt" "$A/images.txt"
    rm -rf "$WORK/img" "$WORK/images-raw.tar"
fi

log "artifact manifest (AB#9182 — plain SHA-256, not signed)"
SOURCE_DATE_EPOCH="$EPOCH" bash "$SOURCE/scripts/New-ArtifactManifest.sh" "$B/charts/manifest.json" >/dev/null

log "SHA256SUMS"
(cd "$B" && find . -type f ! -path ./SHA256SUMS | sort | while IFS= read -r f; do sha256sum "$f" | sed 's|  \./|  |'; done) > "$WORK/SHA256SUMS"
mv "$WORK/SHA256SUMS" "$B/SHA256SUMS"

log "normalize modes and timestamps (SOURCE_DATE_EPOCH=$EPOCH)"
chmod -R u=rwX,go=rX "$B"
chmod u+x "$B/Install-CloudGrange-Linux.sh" "$B/scripts/"*.sh
find "$B" -exec touch -h -d "@$EPOCH" {} +

mkdir -p "$OUT"
ZIP="$OUT/Install-CloudGrange-K3s-Bundled.zip"
rm -f "$ZIP" "$ZIP.sha256"
(cd "$B" && find . -type f | sort | sed 's|^\./||' | zip -X -D -q -@ "$ZIP")
(cd "$OUT" && sha256sum Install-CloudGrange-K3s-Bundled.zip > Install-CloudGrange-K3s-Bundled.zip.sha256)
bundle_sha=$(awk '{print $1}' "$ZIP.sha256")
bundle_bytes=$(stat -c %s "$ZIP")

python3 - "$OUT/release-record-k3s.json" <<PY
import json, sys
record = {
    "version": "$VERSION",
    "sourceDateEpoch": int("$EPOCH"),
    "artifacts": {"Install-CloudGrange-K3s-Bundled.zip": {"sha256": "$bundle_sha", "bytes": int("$bundle_bytes")}},
    "images": "$IMAGES",
    "offlineCapable": "$IMAGES" == "registry",
}
json.dump(record, open(sys.argv[1], "w"), indent=2, sort_keys=True)
open(sys.argv[1], "a").write("\n")
PY
log "Install-CloudGrange-K3s-Bundled.zip $bundle_bytes bytes sha256 $bundle_sha"
