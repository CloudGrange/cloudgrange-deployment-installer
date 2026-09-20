#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — build every first-party platform image for a release, reproducibly.
#
# This replaces the ad-hoc `build-images.sh` that release runs used to carry around. That script
# lived in no repository, built all four components in PARALLEL against ONE shared BuildKit NuGet
# cache mount (`id=cg-nuget`), and treated `--no-cache` as "clean". It is why a release build
# failed with `NETSDK1064: Package Microsoft.AspNetCore.OpenApi ... was not found` and could not be
# cleared by retrying.
#
# What "clean" actually means, and the two traps this script closes:
#
#   * `--no-cache` skips the LAYER cache. It does NOT touch cache MOUNTS. The only thing that
#     clears those is `docker builder prune --filter type=exec.cachemount`, which `--clean` runs
#     here. Without it, "I rebuilt from scratch and it still fails" is simply not true.
#   * A cache mount is reclaimable, so BuildKit's GC can drop it BETWEEN the restore layer and the
#     publish layer of the same build. The api and relay Dockerfiles no longer depend on the mount
#     surviving across layers (publish does an implicit locked restore instead of `--no-restore`),
#     and they use per-component mount ids with `sharing=locked` so a parallel build can never have
#     two writers. `assert_dockerfile_cache_contract` below refuses to build a source tree that has
#     regressed on either point — a release build is exactly where that regression would hurt.
#
# Every image is stamped and read back through scripts/release/image-provenance.sh, so the
# `--source-sha` values New-PlatformRelease.sh demands are produced here and printed at the end.
#
# Usage (Linux/WSL, docker with buildx):
#   Build-PlatformImages.sh --version 2609.0.0-preview.28 \
#       --api-source <cloudgrange-platform-api checkout> \
#       --relay-source <cloudgrange-runtime-relay checkout> \
#       --portal-source <cloudgrange-portal checkout> --cli-dir <New-CliRelease.sh --out DIR> \
#       [--nuget-token-file FILE] [--registry ghcr.io/cloudgrange] [--log-dir DIR]
#       [--only api,relay,portal,platform-updater] [--clean] [--serial] [--push]
#
#   --clean    prune the BuildKit cache mounts first and build with --no-cache. This is what a
#              release build should use; it is the only way to prove a build works from nothing.
#   --serial   build one component at a time (parallel is the default).
#   --push     push each image as it is built. Without it images are only loaded locally.
#
# --nuget-token-file defaults to a temporary file holding $GH_TOKEN, which is what the private
# CloudGrange.* feed needs. Without a token AND without a populated cache mount, restore cannot
# succeed — that failure looks like the cache bug but is not, so it is called out explicitly.
set -euo pipefail

VERSION='' API_SRC='' RELAY_SRC='' PORTAL_SRC='' CLI_DIR='' TOKEN_FILE='' LOG_DIR=''
REGISTRY='ghcr.io/cloudgrange' ONLY='' CLEAN=0 SERIAL=0 PUSH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION=$2; shift 2 ;;
        --api-source) API_SRC=$2; shift 2 ;;
        --relay-source) RELAY_SRC=$2; shift 2 ;;
        --portal-source) PORTAL_SRC=$2; shift 2 ;;
        --cli-dir) CLI_DIR=$2; shift 2 ;;
        --nuget-token-file) TOKEN_FILE=$2; shift 2 ;;
        --registry) REGISTRY=$2; shift 2 ;;
        --log-dir) LOG_DIR=$2; shift 2 ;;
        --only) ONLY=$2; shift 2 ;;
        --clean) CLEAN=1; shift ;;
        --serial) SERIAL=1; shift ;;
        --push) PUSH=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ "$VERSION" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(-(preview|rc)\.[0-9]+)?$ ]] \
    || { echo "--version must be YYMM.MINOR.PATCH[-preview.N|-rc.N]" >&2; exit 2; }
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=scripts/release/image-provenance.sh
. "$HERE/image-provenance.sh"

ALL='api relay portal platform-updater'
COMPONENTS=${ONLY:-$ALL}
COMPONENTS=${COMPONENTS//,/ }
for c in $COMPONENTS; do
    case " $ALL " in *" $c "*) ;; *) echo "--only: unknown component '$c' (choose from: $ALL)" >&2; exit 2 ;; esac
done
want() { case " $COMPONENTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

want api      && { [ -n "$API_SRC" ]   || { echo "--api-source is required to build api" >&2; exit 2; }; }
want relay    && { [ -n "$RELAY_SRC" ] || { echo "--relay-source is required to build relay" >&2; exit 2; }; }
want portal   && { [ -n "$PORTAL_SRC" ] && [ -n "$CLI_DIR" ] \
                    || { echo "--portal-source and --cli-dir are required to build portal" >&2; exit 2; }; }
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

LOG_DIR=${LOG_DIR:-$(mktemp -d)}
mkdir -p "$LOG_DIR"
LOG_DIR=$(cd "$LOG_DIR" && pwd)
log() { echo "[build-images] $*"; }

CLEANUP_TOKEN=''
if [ -z "$TOKEN_FILE" ]; then
    if [ -n "${GH_TOKEN:-}" ]; then
        CLEANUP_TOKEN=$(mktemp); chmod 600 "$CLEANUP_TOKEN"
        printf '%s' "$GH_TOKEN" > "$CLEANUP_TOKEN"
        TOKEN_FILE=$CLEANUP_TOKEN
    else
        echo "WARNING: no --nuget-token-file and no \$GH_TOKEN. The private CloudGrange.* feed is" >&2
        echo "         unreachable, so a restore can only succeed from an already-populated cache" >&2
        echo "         mount. With --clean that is guaranteed to fail, and the failure will LOOK" >&2
        echo "         like the cache-mount bug this script exists to rule out." >&2
        [ "$CLEAN" = 0 ] || { echo "refusing --clean without a NuGet token" >&2; exit 2; }
    fi
fi
trap '[ -z "$CLEANUP_TOKEN" ] || rm -f "$CLEANUP_TOKEN"' EXIT

# A .NET source tree must not reintroduce either cache-mount trap. Checked before anything is
# built, because a release build is the worst place to discover it.
assert_dockerfile_cache_contract() {
    local comp=$1 src=$2 df="$2/Dockerfile" ids
    [ -f "$df" ] || { echo "$comp: no Dockerfile at $df" >&2; return 1; }
    grep -q 'type=cache' "$df" || return 0   # no cache mount, nothing to get wrong
    ids=$(grep -o 'id=cg-nuget[A-Za-z0-9_-]*' "$df" | sort -u)
    if printf '%s\n' "$ids" | grep -qx 'id=cg-nuget'; then
        echo "$comp ($df): uses the SHARED NuGet cache mount id 'cg-nuget'. Two components building" >&2
        echo "  in parallel then write one mount. Use a per-component id, e.g. id=cg-nuget-$comp." >&2
        return 1
    fi
    if grep -E 'type=cache,id=cg-nuget' "$df" | grep -qv 'sharing=locked'; then
        echo "$comp ($df): a cg-nuget cache mount is missing sharing=locked, so concurrent builds" >&2
        echo "  can write it at the same time." >&2
        return 1
    fi
    if grep -q -- '--no-restore' "$df"; then
        echo "$comp ($df): 'dotnet publish --no-restore' with a cache mount fails with NETSDK1064" >&2
        echo "  if BuildKit's GC reclaims the mount between the restore layer and the publish" >&2
        echo "  layer. Drop --no-restore and pass -p:RestoreLockedMode=true instead." >&2
        return 1
    fi
    return 0
}

for comp in $COMPONENTS; do
    case "$comp" in
        api) assert_dockerfile_cache_contract api "$API_SRC" || exit 1 ;;
        relay) assert_dockerfile_cache_contract relay "$RELAY_SRC" || exit 1 ;;
    esac
done
log "Dockerfile cache-mount contract: OK"

if [ "$CLEAN" = 1 ]; then
    # THE point of this script. `docker buildx build --no-cache` alone leaves the NuGet cache
    # mounts exactly as they were, so a "clean" build was never clean.
    log "clean: pruning BuildKit cache mounts (--no-cache does NOT do this)"
    docker builder prune -f --filter type=exec.cachemount >/dev/null
fi
NOCACHE=(); [ "$CLEAN" = 0 ] || NOCACHE=(--no-cache)
OUTFLAG=(--load); [ "$PUSH" = 0 ] || OUTFLAG=(--push)
PROV_MODE=local; [ "$PUSH" = 0 ] || PROV_MODE=remote

build_dotnet() {  # <component> <source dir> <image repo>
    local comp=$1 src=$2 repo=$3 image="$REGISTRY/$3:$VERSION" secret=()
    cg_provenance_labels "$src" "$VERSION" || return 1
    echo "$comp $CG_PROVENANCE_REVISION" >> "$LOG_DIR/revisions.txt"
    [ -z "$TOKEN_FILE" ] || secret=(--secret "id=nuget_token,src=$TOKEN_FILE")
    docker buildx build "${NOCACHE[@]}" "${secret[@]}" \
        --build-arg "GIT_SHA=$CG_PROVENANCE_REVISION" --build-arg "VERSION=$VERSION" \
        "${CG_PROVENANCE_LABELS[@]}" -t "$image" "${OUTFLAG[@]}" "$src"
    cg_assert_image_provenance "$image" "$CG_PROVENANCE_REVISION" "$VERSION" "$PROV_MODE"
}

build_portal() {
    local args=(--version "$VERSION" --portal-source "$PORTAL_SRC" --cli-dir "$CLI_DIR" --registry "$REGISTRY")
    [ "$PUSH" = 0 ] || args+=(--push)
    cg_provenance_labels "$PORTAL_SRC" "$VERSION" || return 1
    echo "portal $CG_PROVENANCE_REVISION" >> "$LOG_DIR/revisions.txt"
    bash "$HERE/Build-PortalImage.sh" "${args[@]}"
}

build_updater() {
    cg_provenance_labels "$REPO_ROOT" "$VERSION" || return 1
    echo "platform-updater $CG_PROVENANCE_REVISION" >> "$LOG_DIR/revisions.txt"
    bash "$REPO_ROOT/images/platform-updater/build.sh" "$VERSION" "${NOCACHE[@]}"
    [ "$PUSH" = 0 ] || docker push -q "$REGISTRY/cloudgrange-platform-updater:$VERSION"
}

run_component() {  # <component> — writes its own log, never interleaves with a sibling
    local comp=$1 rc=0
    {
        case "$comp" in
            api)   build_dotnet api "$API_SRC" cloudgrange-api ;;
            relay) build_dotnet relay "$RELAY_SRC" cloudgrange-relay ;;
            portal) build_portal ;;
            platform-updater) build_updater ;;
        esac
    } > "$LOG_DIR/$comp.log" 2>&1 || rc=$?
    echo "$rc" > "$LOG_DIR/$comp.rc"
    if [ "$rc" = 0 ]; then log "$comp: OK"; else log "$comp: FAILED (rc=$rc) — see $LOG_DIR/$comp.log"; fi
    return "$rc"
}

rm -f "$LOG_DIR/revisions.txt"
log "version $VERSION, registry $REGISTRY, components: $COMPONENTS"
log "logs: $LOG_DIR"
failed=()
if [ "$SERIAL" = 1 ]; then
    for comp in $COMPONENTS; do run_component "$comp" || failed+=("$comp"); done
else
    pids=()
    for comp in $COMPONENTS; do run_component "$comp" & pids+=("$!:$comp"); done
    for entry in "${pids[@]}"; do
        wait "${entry%%:*}" || failed+=("${entry#*:}")
    done
fi

if [ ${#failed[@]} -ne 0 ]; then
    echo >&2
    echo "BUILD FAILED: ${failed[*]}" >&2
    for comp in "${failed[@]}"; do
        echo "--- last 30 lines of $LOG_DIR/$comp.log ---" >&2
        tail -30 "$LOG_DIR/$comp.log" >&2
    done
    exit 1
fi

echo
log "all components built as $VERSION"
log "pass these to New-PlatformRelease.sh:"
while read -r comp sha; do
    [ -n "$comp" ] || continue
    printf '    --source-sha %s=%s\n' "$comp" "$sha"
done < <(sort -u "$LOG_DIR/revisions.txt")
