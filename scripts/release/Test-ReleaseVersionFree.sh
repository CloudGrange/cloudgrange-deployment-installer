#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — a release version must be unique across EVERY published package: the first-party
# images, the module images and the OCI chart. Found 2026-09-18: 2609.0.0-preview.7 and .8 were
# already taken by the chart package (ghcr.io/cloudgrange/charts/cloudgrange) from an earlier
# session while the images had only reached preview.6, so "check the image tag is free" was not
# enough to keep one number per release.
#
# Usage:
#   Test-ReleaseVersionFree.sh --check 2609.0.0-preview.9   exit 0 if free everywhere, 1 if taken (lists where)
#   Test-ReleaseVersionFree.sh --next 2609.0.0-preview      print the lowest free 2609.0.0-preview.N
#
# Needs `gh` authenticated with read:packages for the CloudGrange org (GH_TOKEN).
set -euo pipefail

ORG=${CLOUDGRANGE_PACKAGE_ORG:-CloudGrange}
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
        printf '%s\n' "$out" | sed "s|^|$pkg\t|"
    done
}

case "${1:-}" in
    --check)
        version=${2:?--check needs a version}
        taken=$(all_tags | awk -F'\t' -v v="$version" '$2 == v { print $1 }')
        if [ -n "$taken" ]; then
            echo "version $version is already published in:" >&2
            printf '  %s\n' $taken >&2
            exit 1
        fi
        echo "version $version is free in all ${#PACKAGES[@]} packages"
        ;;
    --next)
        base=${2:?--next needs a base such as 2609.0.0-preview}
        max=$(all_tags | awk -F'\t' -v b="$base." 'index($2, b) == 1 { n = substr($2, length(b) + 1); if (n ~ /^[0-9]+$/ && n + 0 > m) m = n + 0 } END { print m + 0 }')
        echo "$base.$((max + 1))"
        ;;
    *)
        echo "usage: $0 --check <version> | --next <base>" >&2
        exit 2
        ;;
esac
