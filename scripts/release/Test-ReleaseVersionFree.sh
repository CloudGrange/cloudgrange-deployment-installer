#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — a release version must be unique across EVERY place a release number is published:
#   - the first-party images, the module images and the OCI chart (GHCR container packages);
#   - GitHub Releases and git tags on the installer repo (the customer download host);
#   - the R2 download host (releases/<version>/ — the in-app updater's source).
# Found 2026-09-18: 2609.0.0-preview.7 and .8 were already taken by the chart package from an
# earlier session while the images had only reached preview.6, and GitHub Releases preview.5/.6/.8
# (2026-09-16) are different builds from the GHCR images later tagged preview.5/.6 (2026-09-18).
# Checking one registry was never enough to keep one number per release.
#
# Usage:
#   Test-ReleaseVersionFree.sh --check 2609.0.0-preview.9   exit 0 if free everywhere, 1 if taken (lists where)
#   Test-ReleaseVersionFree.sh --next 2609.0.0-preview      print the lowest N above every used 2609.0.0-preview.N
#
# Needs `gh` authenticated with read:packages for the CloudGrange org (GH_TOKEN). An unreachable
# source is an error (exit 3), never "free".
set -euo pipefail

ORG=${CLOUDGRANGE_PACKAGE_ORG:-CloudGrange}
REPO=${CLOUDGRANGE_INSTALLER_REPO:-CloudGrange/cloudgrange-deployment-installer}
R2_PUBLIC_BASE=${R2_PUBLIC_BASE:-https://pub-ab113af532ff44ef827c176e42118f17.r2.dev}
# Every container package a release version is stamped on. A package that does not exist yet
# (a new module) simply has no tags.
PACKAGES=(
    cloudgrange-api
    cloudgrange-portal
    cloudgrange-relay
    cloudgrange-platform-updater
    cloudgrange-module-hello
    charts/cloudgrange
)

# Every used version, one "<where>\t<version>" per line.
all_tags() {
    local pkg enc out
    for pkg in "${PACKAGES[@]}"; do
        enc=${pkg//\//%2F}
        if ! out=$(gh api --paginate "orgs/$ORG/packages/container/$enc/versions?per_page=100" \
                --jq '.[].metadata.container.tags[]' 2>/dev/null); then
            # 404 = the package does not exist yet. Anything else must not read as "free".
            gh api "orgs/$ORG/packages/container/$enc" >/dev/null 2>&1 \
                && { echo "cannot list tags of $pkg" >&2; exit 3; }
            continue
        fi
        printf '%s\n' "$out" | sed "s|^|ghcr:$pkg\t|"
    done
    # GitHub Releases (drafts included: a draft still reserves its tag name) and git tags.
    out=$(gh api --paginate "repos/$REPO/releases?per_page=100" --jq '.[].tag_name') \
        || { echo "cannot list GitHub releases of $REPO" >&2; exit 3; }
    printf '%s\n' "$out" | sed '/^$/d' | sed "s|^|github-release:$REPO\t|"
    out=$(gh api --paginate "repos/$REPO/git/matching-refs/tags/" --jq '.[].ref | ltrimstr("refs/tags/")') \
        || { echo "cannot list git tags of $REPO" >&2; exit 3; }
    printf '%s\n' "$out" | sed '/^$/d' | sed "s|^|git-tag:$REPO\t|"
}

# R2 has no public listing, so a specific version is probed directly: its bundle checksum or its
# Platform release manifest. 404 = free; anything but 200/404 = unknown, which is an error.
r2_used() {
    local v=$1 key code
    for key in "releases/$v/Install-CloudGrange-$v.zip.sha256" "releases/$v/manifest.json"; do
        code=$(curl -s -o /dev/null -I -A 'cloudgrange-release-tooling' -w '%{http_code}' "${R2_PUBLIC_BASE%/}/$key")
        case "$code" in
            200) echo "r2:${R2_PUBLIC_BASE%/}/$key"; return 0 ;;
            404) ;;
            *) echo "cannot probe ${R2_PUBLIC_BASE%/}/$key (HTTP $code)" >&2; exit 3 ;;
        esac
    done
    return 1
}

case "${1:-}" in
    --check)
        version=${2:?--check needs a version}
        tags=$(all_tags)
        taken=$(printf '%s\n' "$tags" | awk -F'\t' -v v="$version" '$2 == v { print $1 }')
        r2=$(r2_used "$version") && taken=$(printf '%s\n%s' "$taken" "$r2" | sed '/^$/d')
        if [ -n "$taken" ]; then
            echo "version $version is already published in:" >&2
            printf '  %s\n' $taken >&2
            exit 1
        fi
        echo "version $version is free in all ${#PACKAGES[@]} packages, GitHub Releases, git tags and R2"
        ;;
    --next)
        base=${2:?--next needs a base such as 2609.0.0-preview}
        max=$(all_tags | awk -F'\t' -v b="$base." 'index($2, b) == 1 { n = substr($2, length(b) + 1); if (n ~ /^[0-9]+$/ && n + 0 > m) m = n + 0 } END { print m + 0 }')
        next=$((max + 1))
        # R2-only versions (published to the download host but never tagged anywhere else).
        while r2_used "$base.$next" >/dev/null; do next=$((next + 1)); done
        echo "$base.$next"
        ;;
    *)
        echo "usage: $0 --check <version> | --next <base>" >&2
        exit 2
        ;;
esac
