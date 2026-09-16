#!/usr/bin/env bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9182 — produces a plain SHA-256 digest manifest for the bundled chart artifacts:
# what to check before trusting a bundle, without the key-management cost of actual
# signing (owner-approved 2026-09-16: "inexpensive and robust"). Verifies bit-for-bit
# integrity of what shipped, which is the actual question an install needs answered —
# it does not attest to WHO built it (that needs real signing, not requested here).
set -euo pipefail

CHARTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/charts"
OUT="${1:-$CHARTS_DIR/manifest.json}"

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# When called from a reproducible-build pipeline (scripts/New-ReleaseBundleK3s.sh),
# SOURCE_DATE_EPOCH makes "generated" deterministic too — a live wall-clock timestamp
# here would otherwise make the bundle it's part of non-reproducible even though every
# other input is pinned. Found by actually diffing two consecutive bundle builds: same
# source, same version, different SHA-256, because this field differed by seconds.
GENERATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
    GENERATED="$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
fi

{
    echo "{"
    echo "  \"generated\": \"$GENERATED\","
    echo "  \"components\": {"
    first=true
    for f in "$CHARTS_DIR"/vendor/*.tgz; do
        [ -f "$f" ] || continue
        [ "$first" = true ] && first=false || echo ","
        printf '    "%s": "%s"' "$(basename "$f")" "$(sha256_of "$f")"
    done
    # The umbrella chart itself isn't a single file — hash a reproducible tar of its
    # tracked contents so any change to any template/values file changes the digest.
    chart_tar="$(mktemp)"
    tar -C "$CHARTS_DIR" --sort=name --mtime='UTC 2026-01-01' \
        --exclude='cloudgrange/charts/*.tgz' --exclude='cloudgrange/Chart.lock' \
        -cf "$chart_tar" cloudgrange
    echo ","
    printf '    "cloudgrange-chart": "%s"' "$(sha256_of "$chart_tar")"
    rm -f "$chart_tar"
    echo ""
    echo "  }"
    echo "}"
} > "$OUT"

echo "Manifest written to $OUT"
cat "$OUT"
