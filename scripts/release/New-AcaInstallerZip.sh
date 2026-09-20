#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (E9) — build Install-CloudGrange-Aca.zip, the Azure Container Apps installer asset
# published with every release.
#
# Why this exists at all: the public install guide tells an operator to download a named asset
# from GitHub Releases. The Linux guide once named an asset nothing produced, and the owner hit
# a 404 following his own published documentation. An install page must never name an artifact
# that no release step creates, so the asset is built here and uploaded by
# Publish-GitHubRelease.sh in the same run.
#
# Contents: the wrapper and the Bicep it deploys, and nothing else — no container images. On
# this path Azure pulls the images itself, so the archive stays a few tens of kilobytes.
#
# Usage: New-AcaInstallerZip.sh --out DIR
set -euo pipefail

OUT=''
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT=$2; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$OUT" ] || { echo "--out is required" >&2; exit 2; }
command -v zip >/dev/null || { echo "zip is required" >&2; exit 2; }

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/stage/scripts" "$WORK/stage/iac"
cp "$REPO_ROOT/scripts/Install-CloudGrange-Aca.sh" "$WORK/stage/scripts/"
chmod +x "$WORK/stage/scripts/Install-CloudGrange-Aca.sh"
# The template's realm import reads the chart's realm file with loadTextContent, so the archive
# has to carry it too, at the same relative path the template expects.
mkdir -p "$WORK/stage/charts/cloudgrange/charts/keycloak/files"
cp "$REPO_ROOT/charts/cloudgrange/charts/keycloak/files/cloudgrange-realm.json" \
   "$WORK/stage/charts/cloudgrange/charts/keycloak/files/"
cp "$REPO_ROOT"/iac/*.bicep "$REPO_ROOT"/iac/*.json "$WORK/stage/iac/" 2>/dev/null || true

( cd "$WORK/stage" && zip -qr "$WORK/Install-CloudGrange-Aca.zip" . )
mv "$WORK/Install-CloudGrange-Aca.zip" "$OUT/"
sha256sum "$OUT/Install-CloudGrange-Aca.zip" | sed "s#$(printf '%s' "$OUT/" | sed 's#[/&]#\\&#g')##" > "$OUT/Install-CloudGrange-Aca.zip.sha256"
echo "[aca-zip] $OUT/Install-CloudGrange-Aca.zip ($(stat -c %s "$OUT/Install-CloudGrange-Aca.zip") bytes)"
