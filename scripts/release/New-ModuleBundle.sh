#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (plan 2026-09-18 §6, E7) — an offline MODULE bundle for air-gapped installs:
# cloudgrange-modules-<name>.zip and its .sha256. An administrator uploads it on the Module catalog page
# (Upload offline modules); the in-cluster updater Job checks it against the SHA-256 the administrator
# confirmed, pushes the module images into the in-cluster registry and publishes the catalog, and the
# modules then install as usual with no internet.
#   modules/catalog.json, modules/manifests/   the catalog snapshot (Get-ModuleCatalogSnapshot.sh)
#   images.txt                                 "<repository> <tag> <digest>" of every module image
#   images/<digest hex>/...                    the images (Add-BundleImages.sh)
#   SHA256SUMS
# Every Platform bundle built with --modules-catalog carries the same modules/ part; this is for
# adding or updating modules between Platform releases.
#
# Usage: New-ModuleBundle.sh --out DIR [--catalog URL|FILE] [--name NAME] [--module ID]...
#   --catalog   default: the public catalog, $R2_PUBLIC_BASE/modules/catalog.json
#   --name      default: the UTC date and time (cloudgrange-modules-<name>.zip)
#   --module    only these module ids (default: every module, newest version of each)
# Needs crane with read access to the module package (ghcr.io/cloudgrange/cloudgrange-modules), jq, zip.
set -euo pipefail
OUT='' CATALOG='' NAME='' MODS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT=$2; shift 2 ;;
        --catalog) CATALOG=$2; shift 2 ;;
        --name) NAME=$2; shift 2 ;;
        --module) MODS+=(--module "$2"); shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$OUT" ] || { echo "--out is required" >&2; exit 2; }
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PUBLIC=${R2_PUBLIC_BASE:-https://pub-ab113af532ff44ef827c176e42118f17.r2.dev}
CATALOG=${CATALOG:-$PUBLIC/modules/catalog.json}
NAME=${NAME:-$(date -u +%Y%m%dT%H%M%SZ)}
[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "--name may contain only letters, digits, . _ -" >&2; exit 2; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
B="$WORK/bundle"; mkdir -p "$B"

bash "$REPO_ROOT/scripts/release/Get-ModuleCatalogSnapshot.sh" "$CATALOG" "$B/modules" "${MODS[@]}" > "$WORK/refs.txt"
{
    echo "# CloudGrange modules ($NAME): <repository> <tag> <digest>"
    while read -r ref; do
        [ -n "$ref" ] || continue
        name=${ref%%@*}; digest=${ref##*@}
        tag=''; [[ "${name##*/}" == *:* ]] && { tag=${name##*:}; name=${name%:*}; }
        [ -n "$tag" ] || { echo "module image without a tag: $ref" >&2; exit 1; }
        printf '%s %s %s\n' "$name" "$tag" "$digest"
    done < "$WORK/refs.txt" | sort -u
} > "$B/images.txt"
bash "$REPO_ROOT/scripts/release/Add-BundleImages.sh" "$B/images.txt" "$B"
ZIP="$OUT/cloudgrange-modules-$NAME.zip"
bash "$REPO_ROOT/scripts/release/Write-OfflineBundleZip.sh" "$B" "$ZIP"
echo "[module-bundle] $ZIP ($(du -m "$ZIP" | cut -f1) MiB, sha256 $(cut -d' ' -f1 "$ZIP.sha256")): $(jq -r '[.modules[] | "\(.id) \(.version)"] | join(", ")' "$B/modules/catalog.json")"
