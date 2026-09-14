#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — Stamp the first-party images into a release copy of docker-compose.yml as
# ghcr.io/cloudgrange/cloudgrange-<svc>:<version>@sha256:<digest>, so a bundle ships exactly the
# images it was built with (never a moving tag). The images must already be present locally
# (pulled from GHCR for a release, or built locally for a test bundle).
# Usage: Set-FirstPartyImagePins.sh <compose-file> <version>
set -euo pipefail
COMPOSE_FILE=${1:?usage: Set-FirstPartyImagePins.sh <compose-file> <version>}
VERSION=${2:?usage: Set-FirstPartyImagePins.sh <compose-file> <version>}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "invalid version: $VERSION" >&2; exit 1; }
for svc in api portal relay; do
    repo="ghcr.io/cloudgrange/cloudgrange-$svc"
    digest=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$repo:$VERSION" | grep -m1 "^$repo@sha256:" | cut -d@ -f2)
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "no digest for $repo:$VERSION" >&2; exit 1; }
    grep -q "image: $repo:\${CLOUDGRANGE_VERSION:-latest}\$" "$COMPOSE_FILE" || { echo "image line for $repo not found" >&2; exit 1; }
    sed -i "s|image: $repo:\${CLOUDGRANGE_VERSION:-latest}\$|image: $repo:$VERSION@$digest|" "$COMPOSE_FILE"
    echo "pinned $repo:$VERSION@$digest"
done
