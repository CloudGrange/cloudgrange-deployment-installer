#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — Publish a release's customer installers as a GitHub Release on the installer repo, and
# make it the repo's LATEST release. Customers download from GitHub Releases (owner decision
# 2026-09-18), and the install docs use the version-free URLs
#     https://github.com/<repo>/releases/latest/download/<asset>
# so they never go stale. GitHub's /releases/latest skips pre-releases and drafts, so the release
# is published as a full release marked latest; "preview" is carried by the version and the title.
#
# Assets (stable names; the tag carries the version):
#   Install-CloudGrange-K3s-Bundled.zip(.sha256)   Linux installer + offline payload (New-ReleaseBundleK3s.sh)
#   Install-CloudGrange-Windows.zip(.sha256)       Windows/Hyper-V installer (New-WindowsInstallerZip.sh)
#   cloudgrange-chart.tgz(.sha256)                 the Helm chart, for Helm on your own cluster
#   manifest.json                                  the Platform release manifest (chart SHA-256, image digests)
# Every .sha256 names its asset, so `sha256sum --check` works on the downloaded files as-is.
#
# Idempotent: an existing release (for example one created by hand) is edited to be the latest
# full release, and only missing or different-size assets are uploaded. Uses the gh CLI with
# GH_TOKEN (contents:write on the repo). Never GitHub Actions.
#
# Usage:
#   Publish-GitHubRelease.sh --version V --target COMMIT --bundle-dir DIR
#       [--windows-dir DIR] [--platform-release-dir DIR] [--repo OWNER/NAME] [--notes TEXT]
set -euo pipefail

VERSION='' TARGET='' BUNDLE_DIR='' WINDOWS_DIR='' PLATFORM_DIR='' NOTES=''
REPO=${CLOUDGRANGE_INSTALLER_REPO:-CloudGrange/cloudgrange-deployment-installer}
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION=$2; shift 2 ;;
        --target) TARGET=$2; shift 2 ;;
        --bundle-dir) BUNDLE_DIR=$2; shift 2 ;;
        --windows-dir) WINDOWS_DIR=$2; shift 2 ;;
        --platform-release-dir) PLATFORM_DIR=$2; shift 2 ;;
        --repo) REPO=$2; shift 2 ;;
        --notes) NOTES=$2; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ "$VERSION" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(-(preview|rc)\.[0-9]+)?$ ]] || { echo "--version must be YYMM.MINOR.PATCH[-preview.N|-rc.N]" >&2; exit 2; }
[[ "$TARGET" =~ ^[0-9a-f]{7,40}$ ]] || { echo "--target must be the release commit SHA" >&2; exit 2; }
[ -n "$BUNDLE_DIR" ] || { echo "--bundle-dir is required" >&2; exit 2; }
command -v gh >/dev/null || { echo "gh CLI is required" >&2; exit 2; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/up"
log() { echo "[github-release] $*"; }
MAX=$((2 * 1024 * 1024 * 1024 - 1))   # GitHub's per-asset limit is 2 GiB

# Every asset is staged (hard link, else symlink) under its asset name, because gh names an
# asset after the path it is given.
NAMES=()
add() { # <file> <asset-name>
    [ -f "$1" ] || { echo "$1 missing" >&2; exit 2; }
    [ "$(stat -c %s "$1")" -le "$MAX" ] || { echo "$1 is over GitHub's 2 GiB asset limit" >&2; exit 1; }
    [ "$1" = "$WORK/up/$2" ] || ln "$1" "$WORK/up/$2" 2>/dev/null || ln -s "$(realpath "$1")" "$WORK/up/$2"
    NAMES+=("$2")
}
with_sha() { # <file> <asset-name>: the asset plus a .sha256 that names it, checked against any build record
    local sha
    sha=$(sha256sum "$1" | cut -d' ' -f1)
    if [ -f "$1.sha256" ]; then
        [ "$sha" = "$(cut -d' ' -f1 "$1.sha256")" ] || { echo "$1 does not match $1.sha256" >&2; exit 1; }
    fi
    printf '%s  %s\n' "$sha" "$2" > "$WORK/up/$2.sha256"
    add "$1" "$2"
    add "$WORK/up/$2.sha256" "$2.sha256"
}
with_sha "$BUNDLE_DIR/Install-CloudGrange-K3s-Bundled.zip" Install-CloudGrange-K3s-Bundled.zip
[ -z "$WINDOWS_DIR" ] || with_sha "$WINDOWS_DIR/Install-CloudGrange-Windows.zip" Install-CloudGrange-Windows.zip
if [ -n "$PLATFORM_DIR" ]; then
    python3 - "$PLATFORM_DIR/manifest.json" "$VERSION" "$PLATFORM_DIR/cloudgrange-$VERSION.tgz" <<'PY' || exit 2
import hashlib, json, sys
m = json.load(open(sys.argv[1]))
assert m["platform"] == sys.argv[2] and not m.get("dryRun"), "manifest is a dry run or for another version"
assert m["chart"]["sha256"] == hashlib.sha256(open(sys.argv[3], "rb").read()).hexdigest(), "chart does not match the manifest"
PY
    with_sha "$PLATFORM_DIR/cloudgrange-$VERSION.tgz" cloudgrange-chart.tgz
    add "$PLATFORM_DIR/manifest.json" manifest.json
fi

[ -n "$NOTES" ] || NOTES="CloudGrange $VERSION (preview, not GA).

Install guide: https://cloudgrange.dev/docs/getting-started/

- Linux server: Install-CloudGrange-K3s-Bundled.zip (includes K3s, Helm and every container image, so it also installs offline)
- Windows + Hyper-V: Install-CloudGrange-Windows.zip
- Helm on your own Kubernetes: cloudgrange-chart.tgz

Every download has a .sha256; verify it before you install. Installed platforms update in the portal under Platform > Updates."

if gh release view "$VERSION" -R "$REPO" >/dev/null 2>&1; then
    log "release $VERSION exists: making it the latest full release"
    gh release edit "$VERSION" -R "$REPO" --prerelease=false --draft=false --latest >/dev/null
else
    log "creating release $VERSION at $TARGET"
    gh release create "$VERSION" -R "$REPO" --target "$TARGET" --title "CloudGrange $VERSION" \
        --notes "$NOTES" --latest >/dev/null
fi
# The tag must point at the release commit, whoever created the release.
tag_sha=$(gh api "repos/$REPO/commits/$VERSION" --jq .sha)
[[ "$tag_sha" == "$TARGET"* ]] || { echo "tag $VERSION is $tag_sha, not the release commit $TARGET" >&2; exit 1; }

existing=$(gh release view "$VERSION" -R "$REPO" --json assets --jq '.assets[] | "\(.name)\t\(.size)"')
for name in "${NAMES[@]}"; do
    size=$(stat -L -c %s "$WORK/up/$name")
    have=$(printf '%s\n' "$existing" | awk -F'\t' -v n="$name" '$1 == n { print $2 }')
    # Checksums are tiny and always re-sent; a large asset of the right size is not re-uploaded.
    if [ "$have" = "$size" ] && [[ "$name" != *.sha256 ]]; then
        log "$name already uploaded ($size bytes)"
        continue
    fi
    log "uploading $name ($size bytes)"
    gh release upload "$VERSION" -R "$REPO" --clobber "$WORK/up/$name" >/dev/null
done

# Prove what a customer gets: the version-free URLs resolve to THIS release's bytes.
BASE="https://github.com/$REPO/releases/latest/download"
latest=$(gh api "repos/$REPO/releases/latest" --jq .tag_name)
[ "$latest" = "$VERSION" ] || { echo "GitHub reports $latest as the latest release, not $VERSION" >&2; exit 1; }
for name in "${NAMES[@]}"; do
    [[ "$name" == *.sha256 ]] || continue
    asset=${name%.sha256}
    curl -fsSL "$BASE/$name" -o "$WORK/check" || { echo "$BASE/$name did not download" >&2; exit 1; }
    cmp -s "$WORK/check" "$WORK/up/$name" || { echo "$BASE/$name is not this release's checksum" >&2; exit 1; }
    remote=$(curl -fsSLI "$BASE/$asset" | tr -d '\r' | awk 'tolower($1) == "content-length:" { v = $2 } END { print v }')
    [ "$remote" = "$(stat -L -c %s "$WORK/up/$asset")" ] || { echo "$BASE/$asset serves $remote bytes, expected $(stat -L -c %s "$WORK/up/$asset")" >&2; exit 1; }
    log "OK $BASE/$asset"
done
log "release $VERSION is GitHub's latest; the version-free install URLs resolve to it"
