#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (plan 2026-09-18 §6, E7) — copy every image an images.txt lists into an offline bundle
# directory, in the layout the in-cluster Platform updater pushes from
# (images/platform-updater/entrypoint.sh push_bundle_images):
#   <bundle>/images/<digest hex>/oci/                  OCI layout of the linux/amd64 image
#   <bundle>/images/<digest hex>/index-manifest.json   the exact index bytes, when the pinned digest is a
#                                                      multi-platform index (only amd64 is carried, and
#                                                      the in-cluster registry validates amd64 only)
# Every manifest is checked against its pinned digest as it is read.
#
# Usage: Add-BundleImages.sh <images.txt> <bundle dir> [--rewrite FROM=TO]...
#   --rewrite   read the repository <FROM> from the repository <TO> instead (a first-party staging registry)
# Needs crane (release/pins.conf CRANE_VERSION) with read access to every source registry.
set -euo pipefail
LIST=${1:?usage: Add-BundleImages.sh <images.txt> <bundle dir> [--rewrite FROM=TO]...}
B=${2:?usage: Add-BundleImages.sh <images.txt> <bundle dir> [--rewrite FROM=TO]...}
shift 2
declare -a RW=()
while [ $# -gt 0 ]; do
    case "$1" in
        --rewrite) RW+=("$2"); shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
command -v crane >/dev/null || { echo "crane is required (release/pins.conf CRANE_VERSION)" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
source_repo() {
    local r=$1 m
    for m in "${RW[@]}"; do
        [ "$r" = "${m%%=*}" ] && { echo "${m#*=}"; return; }
    done
    echo "$r"
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$B/images"
n=0
while read -r repo tag digest _; do
    [[ -z "$repo" || "$repo" == \#* ]] && continue
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "$repo:$tag is not pinned by digest" >&2; exit 1; }
    d="$B/images/${digest#sha256:}"; src=$(source_repo "$repo")
    [ -d "$d/oci" ] && continue
    rm -rf "$d"; mkdir -p "$d"
    crane manifest "$src@$digest" > "$T/top.json" || { echo "cannot read $src@$digest" >&2; exit 1; }
    [ "sha256:$(sha256sum "$T/top.json" | cut -d' ' -f1)" = "$digest" ] || { echo "$src@$digest: manifest bytes do not match the digest" >&2; exit 1; }
    if jq -e 'has("manifests")' "$T/top.json" >/dev/null; then
        cp "$T/top.json" "$d/index-manifest.json"
        child=$(jq -r '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64")][0].digest // empty' "$T/top.json")
        [ -n "$child" ] || { echo "$repo@$digest has no linux/amd64 image" >&2; exit 1; }
        crane pull --format=oci "$src@$child" "$d/oci" >/dev/null
    else
        crane pull --format=oci "$src@$digest" "$d/oci" >/dev/null
    fi
    n=$((n + 1))
    echo "[bundle-images] $repo:$tag ($(du -sm "$d" | cut -f1) MiB)" >&2
done < "$LIST"
echo "[bundle-images] $n image(s) added to $B/images" >&2
