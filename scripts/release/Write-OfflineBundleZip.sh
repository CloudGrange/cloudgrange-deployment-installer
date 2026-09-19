#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (plan 2026-09-18 §6, E7) — seal an offline bundle directory into <zip> and <zip>.sha256.
# Writes SHA256SUMS (every file, sorted) first, then a stored (not deflated: image layers are already
# compressed), reproducibly ordered zip; zip switches to zip64 past 4 GiB. The .sha256 is what the
# administrator compares with the SHA-256 the portal shows after the upload: it is the trust root of
# an offline update (owner decision 2026-09-18).
#
# Usage: Write-OfflineBundleZip.sh <bundle dir> <out zip>
set -euo pipefail
B=${1:?usage: Write-OfflineBundleZip.sh <bundle dir> <out zip>}
ZIP=${2:?usage: Write-OfflineBundleZip.sh <bundle dir> <out zip>}
command -v zip >/dev/null || { echo "zip is required" >&2; exit 1; }
mkdir -p "$(dirname "$ZIP")"
ZIP="$(cd "$(dirname "$ZIP")" && pwd)/$(basename "$ZIP")"
rm -f "$ZIP" "$ZIP.sha256" "$B/SHA256SUMS"
# Written outside the bundle first, so SHA256SUMS never lists (or hashes) itself.
SUMS=$(mktemp); trap 'rm -f "$SUMS"' EXIT
(cd "$B" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | xargs -d '\n' sha256sum) > "$SUMS"
mv "$SUMS" "$B/SHA256SUMS"
(cd "$B" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | zip -X -0 -q -@ "$ZIP")
(cd "$(dirname "$ZIP")" && sha256sum "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
