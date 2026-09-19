#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (plan 2026-09-18 §6, E7) — an offline snapshot of the module catalog, for air-gapped
# installs. Writes <out>/catalog.json and <out>/manifests/, and prints each module image reference
# (one per line, pinned by digest) on stdout for the caller's images.txt.
#
#   catalog.json   cg-module-catalog-v1 with the NEWEST version of each module only (no nested
#                  "versions"), every manifestUrl rewritten to the relative "manifests/<id>-<version>.json"
#   manifests/     each module's manifest, downloaded over https from the catalog's manifestUrl
#
# The platform API reads such a snapshot from its modules volume when the updater Job has loaded the
# images (images/platform-updater/entrypoint.sh publish_bundle_modules), and offers those modules
# with no internet. Used by New-PlatformRelease.sh --modules-catalog (inside the Platform bundle) and
# New-ModuleBundle.sh (a module-only bundle).
#
# Usage: Get-ModuleCatalogSnapshot.sh <catalog https URL or file> <out dir> [--module <id>]...
set -euo pipefail
SRC=${1:?usage: Get-ModuleCatalogSnapshot.sh <catalog url|file> <out dir> [--module <id>]...}
OUT=${2:?usage: Get-ModuleCatalogSnapshot.sh <catalog url|file> <out dir> [--module <id>]...}
shift 2
ONLY=()
while [ $# -gt 0 ]; do
    case "$1" in
        --module) ONLY+=("$2"); shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
UA='cloudgrange-release/1.0'
fetch() { curl -fsSL --proto '=https' --proto-redir '=https' -A "$UA" --retry 3 --max-time 120 -o "$2" "$1"; }

mkdir -p "$OUT/manifests"
if [[ "$SRC" == https://* ]]; then
    fetch "$SRC" "$OUT/catalog.src.json" || { echo "cannot download the module catalog $SRC" >&2; exit 1; }
else
    cp "$SRC" "$OUT/catalog.src.json"
fi

python3 - "$OUT/catalog.src.json" "$OUT" "${ONLY[@]}" > "$OUT/plan.tsv" <<'PY'
import json, re, sys
src, out, only = sys.argv[1], sys.argv[2], set(sys.argv[3:])
cat = json.load(open(src))
if cat.get("schema") != "cg-module-catalog-v1":
    sys.exit("%s is not a cg-module-catalog-v1 catalog" % src)

def key(v):  # SemVer precedence, enough for YYMM.MINOR.PATCH[-preview.N|-rc.N]
    core, _, pre = v.partition("-")
    nums = [int(x) for x in core.split(".")]
    if not pre:
        return (nums, 1, [])
    return (nums, 0, [(0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split(".")])

best = {}
for top in cat.get("modules", []):
    cands = [top] + [dict(top, **v) for v in top.get("versions", [])]
    for c in cands:
        mid, ver, img, murl = c.get("id"), c.get("version"), c.get("image", ""), c.get("manifestUrl", "")
        if not (mid and ver and murl.startswith("https://") and re.search(r"@sha256:[0-9a-f]{64}$", img)):
            continue
        if only and mid not in only:
            continue
        if mid not in best or key(ver) > key(best[mid]["version"]):
            best[mid] = c
missing = only - set(best)
if missing:
    sys.exit("modules not in the catalog: %s" % ", ".join(sorted(missing)))
if not best:
    sys.exit("the catalog has no installable module")
mods = []
for mid in sorted(best):
    c = {k: v for k, v in best[mid].items() if k != "versions"}
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", "%s-%s" % (mid, c["version"]))
    print("%s\t%s\t%s" % (c["manifestUrl"], "manifests/%s.json" % safe, c["image"]))
    c["manifestUrl"] = "manifests/%s.json" % safe
    mods.append(c)
json.dump({"schema": "cg-module-catalog-v1", "updatedAt": cat.get("updatedAt"), "modules": mods},
          open(out + "/catalog.json", "w"), indent=2, sort_keys=True)
PY
rm -f "$OUT/catalog.src.json"

while IFS=$'\t' read -r url rel image; do
    fetch "$url" "$OUT/$rel" || { echo "cannot download the module manifest $url" >&2; exit 1; }
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OUT/$rel" 2>/dev/null \
        || { echo "$url is not JSON" >&2; exit 1; }
    echo "$image"
done < "$OUT/plan.tsv"
rm -f "$OUT/plan.tsv"
