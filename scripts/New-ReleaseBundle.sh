#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — Build Install-CloudGrange-Bundled.zip reproducibly: the same source tree, version and pinned inputs
# give a byte-identical zip (same SHA-256), independent of the build machine, time, umask or commit metadata.
#
# Inputs (all pinned or verified):
#   --source DIR        an exported tree of one commit (git archive), not a working copy
#   --version X.Y.Z[-pre] first-party image tag; stamped into compose as <repo>:<version>@sha256:<digest>
#   --images registry|local  registry: docker pull the first-party tags and every pinned vendor image;
#                            local: every image must already be present with the pinned digest
#   --ubuntu-image FILE the Ubuntu noble cloud image; must match release/ubuntu-noble-cloudimg-amd64.sha256
#   --debs-dir DIR      the offline .deb set; must match release/docker-debs/SHA256SUMS exactly (no extra files)
#   --out DIR           receives the zip, its .sha256 and release-record.json
#   --source-commit SHA recorded in release-record.json (optional)
#
# Determinism:
#   - file set and content come only from the source tree and the verified inputs;
#   - every file and directory gets mode u=rwX,go=rX and mtime SOURCE_DATE_EPOCH (release/SOURCE_DATE_EPOCH);
#   - the zip is written in C-locale sorted order with no extra attributes (zip -X -D) and TZ=UTC;
#   - `docker save` output is already deterministic (epoch mtimes, content-addressed blobs) for the same images
#     saved in the same (sorted) order; SHA256SUMS and images.txt are sorted.
set -euo pipefail

usage() { sed -n '5,23p' "$0" >&2; exit 2; }
SOURCE='' VERSION='' IMAGES='' UBUNTU='' DEBS='' OUT='' COMMIT=''
while [ $# -gt 0 ]; do
    case "$1" in
        --source) SOURCE=$2; shift 2 ;;
        --version) VERSION=$2; shift 2 ;;
        --images) IMAGES=$2; shift 2 ;;
        --ubuntu-image) UBUNTU=$2; shift 2 ;;
        --debs-dir) DEBS=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        --source-commit) COMMIT=$2; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$SOURCE" ] && [ -n "$VERSION" ] && [ -n "$UBUNTU" ] && [ -n "$DEBS" ] && [ -n "$OUT" ] || usage
[[ "$IMAGES" == registry || "$IMAGES" == local ]] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "invalid version: $VERSION" >&2; exit 1; }
SOURCE=$(cd "$SOURCE" && pwd)
PINS="$SOURCE/release"
EPOCH=${SOURCE_DATE_EPOCH:-$(tr -d '[:space:]' < "$PINS/SOURCE_DATE_EPOCH")}
[[ "$EPOCH" =~ ^[0-9]+$ ]] || { echo "invalid SOURCE_DATE_EPOCH" >&2; exit 1; }
export LC_ALL=C TZ=UTC
umask 022
log() { echo "[release-bundle] $*"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
B="$WORK/bundle"
mkdir -p "$B/docs" "$B/docker-debs/debs" "$OUT"

log "installer files from $SOURCE"
for f in Install-CloudGrange.ps1 verify-bundle.ps1 New-SelfSignedCert.ps1 Uninstall-CloudGrange.ps1 Update-CloudGrange.ps1; do
    cp "$SOURCE/$f" "$B/$f"
done
cp -r "$SOURCE/scripts" "$B/scripts"
cp -r "$SOURCE/compose" "$B/compose"
rm -f "$B/compose/.env"
for d in prerequisites.md product-installer-design.md appliance-operator-access.md; do
    cp "$SOURCE/docs/$d" "$B/docs/$d"
done
sha256sum "$B/Install-CloudGrange.ps1" | awk '{print toupper($1)"  Install-CloudGrange.ps1"}' > "$B/cloudgrange-installer.sha256"

log "first-party images $VERSION (pinned by digest into the bundle compose)"
if [ "$IMAGES" = registry ]; then
    for svc in api portal relay; do docker pull -q "ghcr.io/cloudgrange/cloudgrange-$svc:$VERSION" >/dev/null; done
fi
bash "$SOURCE/scripts/Set-FirstPartyImagePins.sh" "$B/compose/docker-compose.yml" "$VERSION"

log "gates: every image digest-pinned, compose hardening"
bash "$SOURCE/scripts/Test-ComposeImagePins.sh" "$B/compose" | sort -u > "$WORK/images.txt"
python3 "$SOURCE/scripts/Test-ComposeHardening.py" "$B/compose"

log "images"
: > "$WORK/save.txt"
while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    if [ "$IMAGES" = registry ]; then docker pull -q "$ref" >/dev/null; fi
    docker image inspect "$ref" >/dev/null 2>&1 || { echo "image not present with the pinned digest: $ref" >&2; exit 1; }
    named="${ref%@sha256:*}"
    docker tag "$ref" "$named"
    echo "$named" >> "$WORK/save.txt"
done < "$WORK/images.txt"
sort -u -o "$WORK/save.txt" "$WORK/save.txt"
# shellcheck disable=SC2046
docker save -o "$B/cloudgrange-images.tar" $(cat "$WORK/save.txt")
cp "$WORK/images.txt" "$B/images.txt"

log "Ubuntu cloud image (pinned SHA-256)"
expected_img=$(awk '{print $1}' "$PINS/ubuntu-noble-cloudimg-amd64.sha256")
actual_img=$(sha256sum "$UBUNTU" | awk '{print $1}')
[ "$actual_img" = "$expected_img" ] || { echo "Ubuntu image SHA-256 $actual_img does not match the pin $expected_img" >&2; exit 1; }
cp "$UBUNTU" "$B/ubuntu-24.04-cloudimg.img"

log "offline Docker CE packages (pinned set)"
(cd "$DEBS" && ls -1 *.deb | sort) > "$WORK/debs.present"
awk '{print $2}' "$PINS/docker-debs/SHA256SUMS" | sort > "$WORK/debs.pinned"
cmp -s "$WORK/debs.present" "$WORK/debs.pinned" || { echo "the .deb set does not match release/docker-debs/SHA256SUMS:" >&2; diff "$WORK/debs.pinned" "$WORK/debs.present" >&2 || true; exit 1; }
(cd "$DEBS" && sha256sum -c --quiet "$PINS/docker-debs/SHA256SUMS")
cp "$DEBS"/*.deb "$B/docker-debs/debs/"
cp "$PINS/docker-debs/SHA256SUMS" "$PINS/docker-debs/versions.txt" "$B/docker-debs/"

log "SHA256SUMS"
(cd "$B" && find . -type f ! -name SHA256SUMS | sort | while IFS= read -r f; do sha256sum "$f" | sed 's|  \./|  |'; done) > "$WORK/SHA256SUMS"
mv "$WORK/SHA256SUMS" "$B/SHA256SUMS"

log "normalize modes and timestamps (SOURCE_DATE_EPOCH=$EPOCH)"
chmod -R u=rwX,go=rX "$B"
find "$B" -exec touch -h -d "@$EPOCH" {} +

ZIP="$OUT/Install-CloudGrange-Bundled.zip"
rm -f "$ZIP" "$ZIP.sha256"
(cd "$B" && find . -type f | sort | sed 's|^\./||' | zip -X -D -q -@ "$ZIP")
(cd "$OUT" && sha256sum Install-CloudGrange-Bundled.zip > Install-CloudGrange-Bundled.zip.sha256)
bundle_sha=$(awk '{print $1}' "$ZIP.sha256")
bundle_bytes=$(stat -c %s "$ZIP")

python3 - "$OUT/release-record.json" <<PY
import json, sys
images = [l.strip() for l in open("$WORK/images.txt") if l.strip()]
record = {
    "version": "$VERSION",
    "sourceCommit": "$COMMIT",
    "sourceDateEpoch": int("$EPOCH"),
    "artifacts": {"Install-CloudGrange-Bundled.zip": {"sha256": "$bundle_sha", "bytes": int("$bundle_bytes")}},
    "images": images,
    "ubuntuImageSha256": "$expected_img",
    "dockerDebsSha256sums": "$(sha256sum "$PINS/docker-debs/SHA256SUMS" | awk '{print $1}')",
}
json.dump(record, open(sys.argv[1], "w"), indent=2, sort_keys=True)
open(sys.argv[1], "a").write("\n")
PY
log "Install-CloudGrange-Bundled.zip $bundle_bytes bytes sha256 $bundle_sha"
