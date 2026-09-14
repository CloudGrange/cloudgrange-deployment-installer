#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — Release gate: every image the stack runs (compose services, first-party included, plus
# helper-images.txt) must be pinned by an immutable @sha256 digest. There are no exemptions.
# Usage: Test-ComposeImagePins.sh <compose-dir>     (writes the resolved list to stdout)
set -euo pipefail
COMPOSE_DIR=${1:?usage: Test-ComposeImagePins.sh <compose-dir>}
# Placeholder for the one required interpolation (Keycloak hostname); it does not affect image names.
export CLOUDGRANGE_HOSTNAME=${CLOUDGRANGE_HOSTNAME:-pin-gate.invalid}
# Render separately and fail closed: an invalid compose file must not pass with only the helper image checked.
config_err=$(mktemp)
trap 'rm -f "$config_err"' EXIT
if ! compose_images=$(docker compose -f "$COMPOSE_DIR/docker-compose.yml" config --images 2>"$config_err"); then
    echo "PIN-GATE FAIL: docker compose config failed for $COMPOSE_DIR/docker-compose.yml:" >&2
    grep -v 'level=warning' "$config_err" >&2 || true
    exit 1
fi
[ -n "$compose_images" ] || { echo "PIN-GATE FAIL: docker compose config resolved no images" >&2; exit 1; }
images=$( { printf '%s\n' "$compose_images"; grep -vE '^\s*(#|$)' "$COMPOSE_DIR/helper-images.txt"; } | sort -u)
[ -n "$images" ] || { echo "PIN-GATE FAIL: no images resolved" >&2; exit 1; }
bad=0
while IFS= read -r image; do
    if [[ "$image" =~ ^[a-z0-9./_-]+(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$ ]]; then
        echo "$image"
    else
        echo "PIN-GATE FAIL: not digest-pinned: $image" >&2
        bad=1
    fi
done <<< "$images"
exit $bad
