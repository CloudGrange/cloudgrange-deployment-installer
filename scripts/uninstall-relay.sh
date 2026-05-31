#!/usr/bin/env bash
# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0
#
# uninstall-relay.sh — Stop and remove the CloudSmith relay agent container.
#
# Usage:
#   bash uninstall-relay.sh
#
# One-liner:
#   curl -sSL https://raw.githubusercontent.com/cloudsmith-cloud/cloudsmith-installer/main/scripts/uninstall-relay.sh | bash

set -euo pipefail

CONTAINER_NAME="cloudsmith-relay"

if ! command -v docker &>/dev/null; then
    echo "Error: Docker is not installed or not on PATH."
    exit 1
fi

if ! docker inspect "${CONTAINER_NAME}" &>/dev/null; then
    echo "Container '${CONTAINER_NAME}' not found — nothing to remove."
    exit 0
fi

echo "Stopping container '${CONTAINER_NAME}' ..."
docker stop "${CONTAINER_NAME}" 2>/dev/null || true

echo "Removing container '${CONTAINER_NAME}' ..."
docker rm "${CONTAINER_NAME}"

echo ""
echo "Relay agent removed. The container image is still cached locally."
echo "To also remove the image, run:  docker rmi ghcr.io/cloudsmith-cloud/cloudsmith-relay"
