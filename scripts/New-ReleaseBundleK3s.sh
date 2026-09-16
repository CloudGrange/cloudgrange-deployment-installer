#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9184 — Build Install-CloudGrange-K3s-Bundled.zip, the K3s/Helm counterpart to
# scripts/New-ReleaseBundle.sh's Install-CloudGrange-Bundled.zip (Compose). Per the
# platform-restructure plan's rollout order, a release produces BOTH bundles during the
# parallel-support period — this script does not replace New-ReleaseBundle.sh, it runs
# alongside it. Same determinism conventions as that script: fixed file modes,
# SOURCE_DATE_EPOCH mtimes, C-locale sorted zip contents, so the same source tree and
# version produce a byte-identical zip regardless of build machine or time.
#
# Scope note (disclosed, not hidden): unlike New-ReleaseBundle.sh, this script does NOT
# yet bundle container images for a fully offline/airgapped K3s install (a K3s airgap
# image tarball + every service's image, matching the Compose bundle's docker-save
# step). That is real, substantial additional work — pinning and packaging the K3s
# binary + airgap images for every chart service — tracked as a known gap, not silently
# skipped. This bundle today gives a customer with internet access at install time
# (pulls images from ghcr.io/cloudgrange and docker.io as normal) everything needed for
# --engine k3s; full offline parity with the Compose bundle is future work.
#
# Inputs:
#   --source DIR     an exported tree of one commit (git archive), not a working copy
#   --version X.Y.Z  stamped as global.image.tag in the bundled values
#   --out DIR        receives the zip, its .sha256, and the manifest
set -euo pipefail

usage() { sed -n '5,20p' "$0" >&2; exit 2; }
SOURCE='' VERSION='' OUT=''
while [ $# -gt 0 ]; do
    case "$1" in
        --source) SOURCE=$2; shift 2 ;;
        --version) VERSION=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$SOURCE" ] && [ -n "$VERSION" ] && [ -n "$OUT" ] || usage
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
    "knownGaps": ["no bundled container images yet -- install pulls from ghcr.io/cloudgrange and docker.io at install time (see script header)"],
}
json.dump(record, open(sys.argv[1], "w"), indent=2, sort_keys=True)
open(sys.argv[1], "a").write("\n")
PY
log "Install-CloudGrange-K3s-Bundled.zip $bundle_bytes bytes sha256 $bundle_sha"
