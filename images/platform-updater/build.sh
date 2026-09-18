#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — build the Platform updater image with every version taken from release/pins.conf.
# Usage: images/platform-updater/build.sh <tag> [extra docker build args...]
# The tag must be a platform version (YYMM.MINOR.PATCH[-preview.N|-rc.N]) or a local test tag
# ending in -local; never latest. Nothing is pushed.
set -euo pipefail
TAG=${1:?usage: build.sh <tag> [docker build args...]}; shift
[[ "$TAG" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(-(preview|rc)\.[0-9]+)?$ || "$TAG" =~ -local$ ]] \
    || { echo "tag must be YYMM.MINOR.PATCH[-preview.N|-rc.N] or end in -local, got: $TAG" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
PINS="$HERE/../../release/pins.conf"
args=()
for key in PLATFORM_UPDATER_BASE_IMAGE HELM_VERSION HELM_LINUX_AMD64_SHA256 KUBECTL_VERSION \
           KUBECTL_LINUX_AMD64_SHA256 COSIGN_VERSION COSIGN_LINUX_AMD64_SHA256; do
    val=$(sed -n "s/^$key=//p" "$PINS")
    [ -n "$val" ] || { echo "$key missing from $PINS" >&2; exit 1; }
    args+=(--build-arg "$key=$val")
done
exec docker build "${args[@]}" -t "ghcr.io/cloudgrange/cloudgrange-platform-updater:$TAG" "$@" "$HERE"
