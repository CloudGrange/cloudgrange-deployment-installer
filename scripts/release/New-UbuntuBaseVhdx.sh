#!/usr/bin/env bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (plan 2026-09-18-foundation-platform-separation C3) — build the pre-converted Ubuntu base
# disk the Windows script (Install-CloudGrange.ps1 -> New-CloudGrangeVm.ps1) downloads, so a
# customer's Windows host no longer needs qemu-img to turn Canonical's cloud image into a Hyper-V
# Gen2 disk. The conversion moves here, into the release pipeline, and runs once per release.
#
# What it does (nothing is uploaded; publishing is a separate, deliberate release step):
#   1. takes the Ubuntu cloud image pinned in release/pins.conf (UBUNTU_CLOUDIMG_SERIAL, by serial,
#      never noble/current) -- downloaded, or --image FILE -- and verifies UBUNTU_CLOUDIMG_SHA256;
#   2. resizes a scratch copy to 30 GB and converts it to a dynamic VHDX (exactly what the Windows
#      script used to do on the customer's host: qemu-img resize, then convert -o subformat=dynamic);
#   3. zips it (Expand-Archive on Windows PowerShell 5.1 can open it; dynamic VHDX compresses well);
#   4. writes <name>.vhdx.sha256, <name>.vhdx.zip.sha256 and ubuntu-base-vhdx-record.json;
#   5. with --update-pins, writes UBUNTU_BASE_VHDX_ZIP_URL / _ZIP_SHA256 / _SHA256 into
#      release/pins.conf for the URL given by --url-base. Only do that for the artifact you then
#      actually publish there: a VHDX is not bit-reproducible (qemu-img puts fresh GUIDs in the
#      header), so a rebuild has different hashes.
#
# Usage:
#   scripts/release/New-UbuntuBaseVhdx.sh --out DIR [--image noble-server-cloudimg-amd64.img]
#       [--url-base https://<bucket>/foundation/base-images] [--update-pins]
# Needs: qemu-img, curl (unless --image), zip, sha256sum.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PINS="$REPO/release/pins.conf"
OUT='' IMAGE='' URL_BASE='' UPDATE_PINS=false
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT=$2; shift 2 ;;
        --image) IMAGE=$2; shift 2 ;;
        --url-base) URL_BASE=${2%/}; shift 2 ;;
        --update-pins) UPDATE_PINS=true; shift ;;
        *) sed -n '22,26p' "$0" >&2; exit 2 ;;
    esac
done
[ -n "$OUT" ] || { echo "--out is required" >&2; exit 2; }
if [ "$UPDATE_PINS" = true ] && [ -z "$URL_BASE" ]; then echo "--update-pins needs --url-base" >&2; exit 2; fi
for tool in qemu-img zip sha256sum; do command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }; done
log() { echo "[ubuntu-base-vhdx] $*"; }

pin() { sed -n "s/^$1=//p" "$PINS" | tr -d '[:space:]'; }
SERIAL=$(pin UBUNTU_CLOUDIMG_SERIAL)
IMG_SHA=$(pin UBUNTU_CLOUDIMG_SHA256)
[[ "$SERIAL" =~ ^[0-9]{8}(\.[0-9]+)?$ && "$IMG_SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "UBUNTU_CLOUDIMG_SERIAL/SHA256 missing or malformed in $PINS" >&2; exit 1; }

NAME="ubuntu-noble-${SERIAL}-hyperv-gen2-30g"
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ -z "$IMAGE" ]; then
    IMAGE="$WORK/noble-server-cloudimg-amd64.img"
    log "downloading the pinned cloud image (serial $SERIAL)"
    curl -sfL "https://cloud-images.ubuntu.com/noble/$SERIAL/noble-server-cloudimg-amd64.img" -o "$IMAGE"
fi
actual=$(sha256sum "$IMAGE" | cut -d' ' -f1)
[ "$actual" = "$IMG_SHA" ] || { echo "cloud image SHA-256 $actual does not match the pinned $IMG_SHA" >&2; exit 1; }
log "cloud image verified against the pin ($IMG_SHA)"

cp "$IMAGE" "$WORK/source.img"
log "resize to 30G and convert to a dynamic VHDX"
qemu-img resize -f qcow2 "$WORK/source.img" 30G >/dev/null
qemu-img convert -f qcow2 -O vhdx -o subformat=dynamic "$WORK/source.img" "$WORK/$NAME.vhdx"
qemu-img check -f vhdx "$WORK/$NAME.vhdx" >/dev/null
virtual=$(qemu-img info --output=json "$WORK/$NAME.vhdx" | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])')
[ "$virtual" = $((30 * 1024 * 1024 * 1024)) ] || { echo "unexpected virtual size $virtual" >&2; exit 1; }

log "zip"
rm -f "$OUT/$NAME.vhdx.zip"
(cd "$WORK" && zip -X -q -9 "$OUT/$NAME.vhdx.zip" "$NAME.vhdx")
vhdx_sha=$(sha256sum "$WORK/$NAME.vhdx" | cut -d' ' -f1)
zip_sha=$(sha256sum "$OUT/$NAME.vhdx.zip" | cut -d' ' -f1)
printf '%s  %s\n' "$vhdx_sha" "$NAME.vhdx" > "$OUT/$NAME.vhdx.sha256"
printf '%s  %s\n' "$zip_sha" "$NAME.vhdx.zip" > "$OUT/$NAME.vhdx.zip.sha256"
url=''
[ -n "$URL_BASE" ] && url="$URL_BASE/$NAME.vhdx.zip"
python3 - "$OUT/ubuntu-base-vhdx-record.json" <<PY
import json, sys
json.dump({
    "artifact": "$NAME.vhdx.zip",
    "url": "$url" or None,
    "zipSha256": "$zip_sha",
    "vhdxSha256": "$vhdx_sha",
    "virtualSizeBytes": int("$virtual"),
    "source": {"ubuntuCloudImageSerial": "$SERIAL", "sha256": "$IMG_SHA"},
    "qemuImg": "$(qemu-img --version | head -1)",
}, open(sys.argv[1], "w"), indent=2, sort_keys=True)
open(sys.argv[1], "a").write("\n")
PY

if [ "$UPDATE_PINS" = true ]; then
    log "writing the base VHDX pins into $PINS"
    sed -i \
        -e "s|^UBUNTU_BASE_VHDX_ZIP_URL=.*|UBUNTU_BASE_VHDX_ZIP_URL=$url|" \
        -e "s|^UBUNTU_BASE_VHDX_ZIP_SHA256=.*|UBUNTU_BASE_VHDX_ZIP_SHA256=$zip_sha|" \
        -e "s|^UBUNTU_BASE_VHDX_SHA256=.*|UBUNTU_BASE_VHDX_SHA256=$vhdx_sha|" "$PINS"
fi
log "$NAME.vhdx.zip  zip sha256 $zip_sha  vhdx sha256 $vhdx_sha  ($(du -m "$OUT/$NAME.vhdx.zip" | cut -f1) MiB)"
log "not published: upload $OUT/$NAME.vhdx.zip to ${url:-<url-base>/$NAME.vhdx.zip} as a separate release step"
