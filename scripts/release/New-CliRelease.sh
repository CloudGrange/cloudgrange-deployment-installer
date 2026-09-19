#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — build the `cg` CLI for a platform release: self-contained single-file binaries for
# win-x64, linux-x64, linux-arm64, osx-x64 and osx-arm64, stamped with the PLATFORM version
# (`cg --version` prints it), plus SHA256SUMS and manifest.json. Every platform release ships the
# CLI built for it, two ways:
#   1. baked into the portal image (Build-PortalImage.sh --cli-dir OUT) and served by the platform
#      at /downloads/cli/<rid>/cg[.exe], so air-gapped installs download it from their own platform;
#   2. published to the download host under cli/<version>/ (Publish-CliRelease.sh --cli-dir OUT).
# New-PlatformRelease.sh refuses a portal image that does not carry the CLI for its version.
#
# Usage (Linux/WSL, from native paths, not /mnt/<drive>):
#   New-CliRelease.sh --version 2609.0.0-preview.11 --cli-source <cloudgrange-cli checkout at the release commit> \
#       --out DIR [--configfile nuget.config]
# Needs the .NET SDK pinned by the CLI's global.json, sha256sum and python3. --configfile is passed to
# the restore (the CLI's packages come from nuget.org today; a config with credentials for the
# private feed is only needed if that changes).
set -euo pipefail

VERSION='' SRC='' OUT='' CONFIGFILE=''
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION=$2; shift 2 ;;
        --cli-source) SRC=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        --configfile) CONFIGFILE=$2; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ "$VERSION" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(-(preview|rc)\.[0-9]+)?$ ]] \
    || { echo "--version must be YYMM.MINOR.PATCH[-preview.N|-rc.N]" >&2; exit 2; }
[ -n "$SRC" ] && [ -n "$OUT" ] || { echo "--cli-source and --out are required" >&2; exit 2; }
[ -f "$SRC/scripts/publish-binaries.sh" ] \
    || { echo "$SRC is not a cloudgrange-cli checkout with scripts/publish-binaries.sh" >&2; exit 2; }
if git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; then
    [ -z "$(git -C "$SRC" status --porcelain)" ] || { echo "$SRC has uncommitted changes: release from a clean commit" >&2; exit 1; }
    echo "[cli-release] source commit $(git -C "$SRC" rev-parse HEAD)"
fi
args=(--version "$VERSION" --out "$OUT")
[ -z "$CONFIGFILE" ] || args+=(--configfile "$CONFIGFILE")
bash "$SRC/scripts/publish-binaries.sh" "${args[@]}"

# The binaries must report the version they are published as.
case "$(uname -m)" in x86_64) host=linux-x64 ;; aarch64) host=linux-arm64 ;; *) host='' ;; esac
if [ -n "$host" ] && [ -x "$OUT/$host/cg" ]; then
    got=$("$OUT/$host/cg" --version | tr -d '\r')
    [ "$got" = "$VERSION" ] || { echo "$host/cg --version printed '$got', expected '$VERSION'" >&2; exit 1; }
    echo "[cli-release] $host/cg --version = $got"
fi
(cd "$OUT" && sha256sum -c --quiet SHA256SUMS)
echo "[cli-release] $OUT ready. Next: Build-PortalImage.sh --cli-dir $OUT, then Publish-CliRelease.sh --cli-dir $OUT"
