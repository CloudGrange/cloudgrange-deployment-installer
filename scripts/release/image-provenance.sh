#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — release-artifact provenance: the ONE place that stamps an image with the source commit
# it was built from, and the ONE place that reads that stamp back and refuses a mismatch.
#
# Why this exists: nothing proved which source commit a released container image came from. A stale
# label cost five rebuilds, and the release tooling has a "retag an unchanged image" path
# (--already-pushed, and retagging a previous release's digest) where an image was once retagged
# from a build that PREDATED the fix it was supposed to carry (the relay, preview.10). The check
# compared the wrong base and nobody noticed.
#
# The contract:
#   - every image the release tooling builds carries org.opencontainers.image.revision (the full
#     40-hex commit of its SOURCE repository), org.opencontainers.image.version (the version it is
#     built AS) and, when the checkout has an origin, org.opencontainers.image.source;
#   - before a release is considered good, every image it publishes is read back and both labels
#     are compared against what the release recorded. A mismatch, or a missing label, is a hard
#     failure naming the image, the expected value and the found value.
#
# A dirty source tree is refused: a revision label naming HEAD while the working tree differs from
# it is exactly the lie this file exists to prevent. CG_ALLOW_DIRTY_PROVENANCE=1 is for a throwaway
# local build only and must never be set by release tooling.
#
# Usage (source it; it defines functions, it does not run anything):
#   . "$(dirname "$0")/image-provenance.sh"
#   cg_provenance_labels <source checkout> <version>   -> CG_PROVENANCE_LABELS[] and CG_PROVENANCE_REVISION
#   docker build "${CG_PROVENANCE_LABELS[@]}" ...
#   cg_assert_image_provenance <ref> <expected 40-hex revision> <expected version> [auto|local|remote]

# cg_provenance_labels <source checkout dir> <version>
# Sets CG_PROVENANCE_LABELS (an array of --label arguments) and CG_PROVENANCE_REVISION.
cg_provenance_labels() {
    local src=${1:?cg_provenance_labels <source dir> <version>} version=${2:?cg_provenance_labels <source dir> <version>}
    local sha remote
    [ -d "$src" ] || { echo "provenance: $src is not a directory" >&2; return 1; }
    git -C "$src" rev-parse --git-dir >/dev/null 2>&1 \
        || { echo "provenance: $src is not a git checkout, so an image built from it cannot be traced to a commit" >&2; return 1; }
    sha=$(git -C "$src" rev-parse HEAD 2>/dev/null) || sha=''
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "provenance: cannot read the HEAD commit of $src" >&2; return 1; }
    if [ -n "$(git -C "$src" status --porcelain 2>/dev/null)" ] && [ "${CG_ALLOW_DIRTY_PROVENANCE:-0}" != 1 ]; then
        echo "provenance: $src has uncommitted changes, so org.opencontainers.image.revision=$sha would name a commit that is not what is being built. Commit them first (CG_ALLOW_DIRTY_PROVENANCE=1 is for a throwaway local build only)." >&2
        return 1
    fi
    CG_PROVENANCE_REVISION=$sha
    CG_PROVENANCE_LABELS=(--label "org.opencontainers.image.revision=$sha"
                          --label "org.opencontainers.image.version=$version")
    # org.opencontainers.image.source, when the checkout has an origin. Normalise the cheap SSH
    # forms to an https URL; anything else is left exactly as the checkout reports it.
    remote=$(git -C "$src" remote get-url origin 2>/dev/null) || remote=''
    if [ -n "$remote" ]; then
        case "$remote" in
            git@*:*) remote="https://$(printf '%s' "${remote#git@}" | sed 's|:|/|')" ;;
            ssh://git@*) remote="https://${remote#ssh://git@}" ;;
        esac
        remote=${remote%.git}
        CG_PROVENANCE_LABELS+=(--label "org.opencontainers.image.source=$remote")
    fi
    return 0
}

# cg_image_labels_json <ref> [auto|local|remote]
# Prints the image's config labels as a JSON object. "local" reads the local docker image store,
# "remote" reads the registry with crane, "auto" (the default) tries local first.
cg_image_labels_json() {
    local ref=${1:?cg_image_labels_json <ref>} mode=${2:-auto} out
    if [ "$mode" != remote ]; then
        if command -v docker >/dev/null 2>&1 && out=$(docker image inspect --format '{{json .Config.Labels}}' "$ref" 2>/dev/null); then
            [ "$out" != null ] || out='{}'
            printf '%s' "$out"
            return 0
        fi
        [ "$mode" != local ] || { echo "provenance: $ref is not in the local image store" >&2; return 1; }
    fi
    command -v crane >/dev/null 2>&1 \
        || { echo "provenance: crane is required to read the labels of $ref (release/pins.conf CRANE_VERSION)" >&2; return 1; }
    out=$(crane config --platform linux/amd64 "$ref" 2>/dev/null) \
        || { echo "provenance: cannot read the image config of $ref from the registry" >&2; return 1; }
    printf '%s' "$out" | python3 -c 'import json,sys; c=json.load(sys.stdin); print(json.dumps((c.get("config") or c.get("Config") or {}).get("Labels") or {}))'
}

# cg_image_label <labels json> <label name>: the value, or empty.
cg_image_label() {
    printf '%s' "$1" | python3 -c 'import json,sys; print((json.load(sys.stdin) or {}).get(sys.argv[1], ""))' "$2"
}

# cg_assert_image_provenance <ref> <expected 40-hex revision> <expected version> [auto|local|remote]
# Hard-fails (returns 1, message on stderr) when the image was not built from the expected source
# commit, was not built as the expected version, or carries no such label at all.
cg_assert_image_provenance() {
    local ref=${1:?cg_assert_image_provenance <ref> <revision> <version>} want_rev=${2:-} want_ver=${3:-} mode=${4:-auto}
    local labels got_rev got_ver
    [[ "$want_rev" =~ ^[0-9a-f]{40}$ ]] \
        || { echo "PROVENANCE FAILURE: $ref: the expected source revision '$want_rev' is not a full 40-hex commit SHA" >&2; return 1; }
    [ -n "$want_ver" ] || { echo "PROVENANCE FAILURE: $ref: no expected version was given" >&2; return 1; }
    labels=$(cg_image_labels_json "$ref" "$mode") || {
        echo "PROVENANCE FAILURE: $ref: cannot read its labels, so its source commit cannot be proved (expected $want_rev)" >&2
        return 1
    }
    got_rev=$(cg_image_label "$labels" org.opencontainers.image.revision)
    got_ver=$(cg_image_label "$labels" org.opencontainers.image.version)
    if [ -z "$got_rev" ]; then
        echo "PROVENANCE FAILURE: $ref carries no org.opencontainers.image.revision label; expected $want_rev. It was not built through the stamped release path (scripts/release/image-provenance.sh), so nothing proves which source commit it came from." >&2
        return 1
    fi
    if [ "$got_rev" != "$want_rev" ]; then
        echo "PROVENANCE FAILURE: $ref was built from source revision $got_rev, expected $want_rev. Refusing to publish an image built from the wrong source commit (this is what a stale retag looks like)." >&2
        return 1
    fi
    if [ -z "$got_ver" ]; then
        echo "PROVENANCE FAILURE: $ref carries no org.opencontainers.image.version label; expected $want_ver." >&2
        return 1
    fi
    if [ "$got_ver" != "$want_ver" ]; then
        echo "PROVENANCE FAILURE: $ref was built as version $got_ver, expected $want_ver. Refusing to publish an image built for a different release." >&2
        return 1
    fi
    echo "[provenance] $ref: revision $got_rev, built as $got_ver"
    return 0
}
