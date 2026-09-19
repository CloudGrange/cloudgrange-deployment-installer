#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — Build Install-CloudGrange-Windows.zip, the Windows-script (Hyper-V) installer for one
# release. Install-CloudGrange.ps1 is not in the K3s bundle (that bundle is the Linux installer),
# and no per-release Windows artifact existed, so the Windows install page had nothing it could
# download. This zip is the installer tree of the release commit (Install-CloudGrange.ps1, its
# scripts/, the chart, release/pins.conf, cloudgrange-installer.sha256), with the release version
# stamped into the chart exactly as New-ReleaseBundleK3s.sh stamps it, plus a SHA256SUMS that
# verify-bundle.ps1 checks. The install itself pulls images from ghcr.io (Online mode); the
# offline payload is the K3s bundle's airgap/ directory (-Mode Bundled -BundlePath).
#
# Usage:
#   New-WindowsInstallerZip.sh --source DIR --version V --out DIR
#     --source   an exported tree of the release commit (git archive), not a working copy
set -euo pipefail

SOURCE='' VERSION='' OUT=''
while [ $# -gt 0 ]; do
    case "$1" in
        --source) SOURCE=$2; shift 2 ;;
        --version) VERSION=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$SOURCE" ] && [ -n "$VERSION" ] && [ -n "$OUT" ] || { echo "--source, --version and --out are required" >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(-(preview|rc)\.[0-9]+)?$ ]] || { echo "invalid version: $VERSION" >&2; exit 2; }
SOURCE=$(cd "$SOURCE" && pwd)
EPOCH=${SOURCE_DATE_EPOCH:-$(tr -d '[:space:]' < "$SOURCE/release/SOURCE_DATE_EPOCH")}
export LC_ALL=C TZ=UTC
umask 022
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
B="$WORK/Install-CloudGrange-Windows"
mkdir -p "$B"
# Everything the installer can reach, minus history and experiments that no install path loads.
(cd "$SOURCE" && tar -cf - --exclude=./archive --exclude=./experiments --exclude=./.github --exclude=./test .) | tar -xf - -C "$B"
for f in Install-CloudGrange.ps1 cloudgrange-installer.sha256 scripts/Deploy-K3sHelm.ps1 scripts/Install-CloudGrangeK3s.sh \
         scripts/release/Set-ChartVersion.sh release/pins.conf charts/cloudgrange/Chart.yaml; do
    [ -f "$B/$f" ] || { echo "$f missing from $SOURCE" >&2; exit 1; }
done
# The installer refuses to run when its own SHA-256 does not match cloudgrange-installer.sha256.
[ "$(sha256sum "$B/Install-CloudGrange.ps1" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$B/cloudgrange-installer.sha256" | tr 'A-F' 'a-f')" ] \
    || { echo "cloudgrange-installer.sha256 does not match Install-CloudGrange.ps1 in $SOURCE" >&2; exit 1; }
rm -f "$B/charts/cloudgrange/Chart.lock"
bash "$SOURCE/scripts/release/Set-ChartVersion.sh" "$B/charts/cloudgrange" "$VERSION" >/dev/null
printf '%s\n' "$VERSION" > "$B/VERSION"
(cd "$B" && find . -type f ! -name SHA256SUMS | sort | while IFS= read -r f; do sha256sum "$f" | sed 's|  \./|  |'; done) > "$WORK/SHA256SUMS"
mv "$WORK/SHA256SUMS" "$B/SHA256SUMS"
chmod -R u=rwX,go=rX "$B"
find "$B" -exec touch -h -d "@$EPOCH" {} +
mkdir -p "$OUT"
ZIP="$(cd "$OUT" && pwd)/Install-CloudGrange-Windows.zip"
rm -f "$ZIP" "$ZIP.sha256"
(cd "$B" && find . -type f | sort | sed 's|^\./||' | zip -X -D -q -@ "$ZIP")
(cd "$OUT" && sha256sum Install-CloudGrange-Windows.zip > Install-CloudGrange-Windows.zip.sha256)
echo "[windows-installer] $ZIP $(stat -c %s "$ZIP") bytes sha256 $(cut -d' ' -f1 "$ZIP.sha256")"
