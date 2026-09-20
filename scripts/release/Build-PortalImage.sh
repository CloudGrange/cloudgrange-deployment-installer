#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — build the portal image for a platform release WITH the `cg` CLI binaries baked in, so
# the platform serves them at /downloads/cli/ (air-gapped installs included). The portal's
# Dockerfile has an empty `cli` stage; this overrides it with the New-CliRelease.sh output through a
# BuildKit named build context, then checks that the image really carries the CLI for this version.
#
# Usage (Linux/WSL, docker with buildx):
#   Build-PortalImage.sh --version 2609.0.0-preview.11 --portal-source <cloudgrange-portal checkout> \
#       --cli-dir <New-CliRelease.sh --out DIR> [--registry ghcr.io/cloudgrange] [--tag TAG] [--push]
# --tag defaults to the version. Without --push the image is only loaded into the local docker store.
set -euo pipefail

VERSION='' SRC='' CLI_DIR='' REGISTRY='ghcr.io/cloudgrange' TAG='' PUSH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION=$2; shift 2 ;;
        --portal-source) SRC=$2; shift 2 ;;
        --cli-dir) CLI_DIR=$2; shift 2 ;;
        --registry) REGISTRY=$2; shift 2 ;;
        --tag) TAG=$2; shift 2 ;;
        --push) PUSH=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ "$VERSION" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(-(preview|rc)\.[0-9]+)?$ ]] \
    || { echo "--version must be YYMM.MINOR.PATCH[-preview.N|-rc.N]" >&2; exit 2; }
[ -n "$SRC" ] && [ -n "$CLI_DIR" ] || { echo "--portal-source and --cli-dir are required" >&2; exit 2; }
TAG=${TAG:-$VERSION}
[ "$TAG" != latest ] || { echo "--tag latest is refused" >&2; exit 2; }
grep -q '^FROM scratch AS cli' "$SRC/Dockerfile" \
    || { echo "$SRC/Dockerfile has no 'cli' stage: that portal predates CLI downloads" >&2; exit 1; }
python3 - "$CLI_DIR/manifest.json" "$VERSION" <<'PY' || exit 1
import json, sys
m = json.load(open(sys.argv[1]))
assert m.get("schema") == "cg-cli-manifest-v1", "not a cg CLI manifest"
assert m["version"] == sys.argv[2], "CLI dir is version %s, not %s" % (m["version"], sys.argv[2])
PY
(cd "$CLI_DIR" && sha256sum -c --quiet SHA256SUMS)

IMAGE="$REGISTRY/cloudgrange-portal:$TAG"
out=(--load)
[ "$PUSH" = 0 ] || out=(--push)
# AB#9171 — stamp the source commit of the PORTAL checkout into the image, so the release can prove
# later which source this image came from (scripts/release/image-provenance.sh).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/image-provenance.sh"
cg_provenance_labels "$SRC" "$TAG" || exit 1
echo "[portal-image] building $IMAGE with the CLI from $CLI_DIR (source revision $CG_PROVENANCE_REVISION)"
docker buildx build --build-context "cli=$CLI_DIR" "${CG_PROVENANCE_LABELS[@]}" -t "$IMAGE" "${out[@]}" "$SRC"
# Read back what was actually produced: with --push buildx does not --load, so the registry is the
# only truthful source (a leftover local image of the same tag would otherwise answer instead).
[ "$PUSH" = 0 ] && prov_mode=local || prov_mode=remote
cg_assert_image_provenance "$IMAGE" "$CG_PROVENANCE_REVISION" "$TAG" "$prov_mode" || exit 1

# Prove the image serves the CLI for this version (with --push this pulls what was pushed).
got=$(docker run --rm --entrypoint cat "$IMAGE" /usr/share/nginx/html/downloads/cli/manifest.json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
[ "$got" = "$VERSION" ] || { echo "$IMAGE carries CLI $got, expected $VERSION" >&2; exit 1; }
docker run --rm --entrypoint sh "$IMAGE" -c 'cd /usr/share/nginx/html/downloads/cli && sha256sum -c -s SHA256SUMS' \
    || { echo "$IMAGE: CLI files do not match their SHA256SUMS" >&2; exit 1; }
echo "[portal-image] $IMAGE serves cg $got at /downloads/cli/"
