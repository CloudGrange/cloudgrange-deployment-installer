#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — publish a module version to the module catalog on the download host (Cloudflare R2).
#
# The platform's module catalog is a static cg-module-catalog-v1 index at
# <R2_PUBLIC_BASE>/modules/catalog.json (the chart's CLOUDGRANGE_MODULE_CATALOG_URL default). It
# replaced a GitHub packages API listing that needed a token, so the catalog was empty on every
# customer install. This script:
#   1. writes the module's manifest with spec.image pinned to the pushed digest and
#      metadata.version set, and uploads it to modules/<id>/<version>/module.json (immutable: an
#      existing, different manifest for the same id and version is refused);
#   2. REPLACES that module's entry in modules/catalog.json, keeping every other module. The
#      catalog holds exactly ONE top-level entry per module id, whose "version" is the highest
#      SemVer version published; every other published version moves into that entry's nested
#      "versions" array (newest first), so an install can still pin it but it is never a second
#      tile. Found live on preview.10: the old <id, version> keying listed hello preview.10 AND
#      preview.9 and the portal showed two Hello World modules.
#      Each entry carries manifestSha256 (the SHA-256 of module.json): update trust is HTTPS +
#      digest pinning (owner decision 2026-09-18), no signing key.
#
# --dedupe-only rewrites the current catalog into that one-entry-per-id shape without publishing a
# manifest (used once to repair the live catalog; idempotent).
#
#
# AB#9171 — ONE shared image package for every module: ghcr.io/cloudgrange/cloudgrange-modules,
# tagged <short-name>-<version> where <short-name> is metadata.id without "cloudgrange-module-"
# (cloudgrange-module-hello 2609.0.0-preview.12 -> cloudgrange-modules:hello-2609.0.0-preview.12).
# GitHub has no API to make a NEW container package public, so a package per module needed a
# manual visibility click for every module; the shared package is made public once. --image must
# be in that package with exactly that tag. Existing catalog entries that point at the old
# per-module package (cloudgrange-module-hello:2609.0.0-preview.9/.10) are left as they are and
# stay resolvable: they remain in the entry's version history, pinned by their own digests.
#
# Required environment (never committed) — the same as Publish-Release.sh:
#   CF_ACCOUNT_ID, CF_TOKEN, CF_TOKEN_ID, R2_BUCKET, R2_PUBLIC_BASE
#
# Usage (the module repo's scripts/Build-ModuleImage.sh --push prints this exact command):
#   Publish-ModuleCatalog.sh --module-json <path/to/module.json> --version 2609.0.0-preview.12 \
#       --image ghcr.io/cloudgrange/cloudgrange-modules:hello-2609.0.0-preview.12@sha256:<digest> [--dry-run]
#   Publish-ModuleCatalog.sh --dedupe-only [--dry-run]
set -euo pipefail

MODULE_JSON='' VERSION='' IMAGE='' DRY=0 DEDUPE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --module-json) MODULE_JSON=$2; shift 2 ;;
    --version) VERSION=$2; shift 2 ;;
    --image) IMAGE=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --dedupe-only) DEDUPE_ONLY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ "$DEDUPE_ONLY" = 0 ]; then
  [ -f "$MODULE_JSON" ] || { echo "--module-json must name a module.json" >&2; exit 2; }
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "--version must be a SemVer version" >&2; exit 2; }
  [[ "$IMAGE" =~ ^[^@]+:[^@:]+@sha256:[0-9a-f]{64}$ ]] || { echo "--image must be repo:tag@sha256:<digest>" >&2; exit 2; }
  [[ "$IMAGE" != *:latest@* ]] || { echo "--image with tag latest is refused" >&2; exit 2; }
fi
: "${R2_PUBLIC_BASE:?}"
[ "$DRY" = 1 ] || : "${CF_ACCOUNT_ID:?}" "${CF_TOKEN:?}" "${CF_TOKEN_ID:?}" "${R2_BUCKET:?}"

PUBLIC="${R2_PUBLIC_BASE%/}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# r2.dev answers 403 to some default user agents.
UA='cloudgrange-release/1.0'

if [ "$DEDUPE_ONLY" = 0 ]; then
  ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["metadata"]["id"])' "$MODULE_JSON")
  [[ "$ID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "module id '$ID' is not a valid package id" >&2; exit 2; }
  MANIFEST_KEY="modules/$ID/$VERSION/module.json"
  MANIFEST_URL="$PUBLIC/$MANIFEST_KEY"
  MODULE_REPO=${CLOUDGRANGE_MODULE_REPOSITORY:-ghcr.io/cloudgrange/cloudgrange-modules}
  EXPECTED_TAG="$MODULE_REPO:${ID#cloudgrange-module-}-$VERSION"
  [ "${IMAGE%@*}" = "$EXPECTED_TAG" ] || {
    echo "--image must be $EXPECTED_TAG@sha256:<digest> (all modules publish to the shared package $MODULE_REPO); got ${IMAGE%@*}" >&2
    exit 2
  }

  python3 - "$MODULE_JSON" "$VERSION" "$IMAGE" > "$WORK/module.json" <<'PY'
import json, sys
src, version, image = sys.argv[1:4]
m = json.load(open(src))
m["metadata"]["version"] = version
m["spec"]["image"] = image
json.dump(m, sys.stdout, indent=2)
sys.stdout.write("\n")
PY

  # Immutable per version: the same bytes may be re-published, different ones may not.
  code=$(curl -sS -A "$UA" -o "$WORK/existing.json" -w '%{http_code}' "$MANIFEST_URL")
  if [ "$code" = 200 ] && ! cmp -s "$WORK/existing.json" "$WORK/module.json"; then
    echo "$MANIFEST_URL already exists with different content; publish a new version instead" >&2
    exit 1
  fi
else
  : > "$WORK/module.json"
  MANIFEST_URL=''
fi

code=$(curl -sS -A "$UA" -o "$WORK/catalog.in.json" -w '%{http_code}' "$PUBLIC/modules/catalog.json")
case "$code" in
  200) ;;
  404) echo '{"schema":"cg-module-catalog-v1","modules":[]}' > "$WORK/catalog.in.json" ;;
  *) echo "reading the current catalog returned HTTP $code" >&2; exit 1 ;;
esac

python3 - "$WORK/catalog.in.json" "$WORK/module.json" "$MANIFEST_URL" > "$WORK/catalog.json" <<'PY'
import hashlib, json, re, sys, time
catalog_path, manifest_path, manifest_url = sys.argv[1:4]
catalog = json.load(open(catalog_path))
if catalog.get("schema") != "cg-module-catalog-v1":
    sys.exit("the current catalog is not cg-module-catalog-v1")

def semver_key(v):
    """SemVer 2.0 precedence: a release outranks its pre-releases; numeric identifiers numerically."""
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?", v or "")
    if not m:
        return ((-1, -1, -1), (0,), ())
    core = tuple(int(x) for x in m.group(1, 2, 3))
    if m.group(4) is None:
        return (core, (1,), ())
    ids = tuple((0, int(p), "") if p.isdigit() else (1, 0, p) for p in m.group(4).split("."))
    return (core, (0,), ids)

VERSION_FIELDS = ("version", "image", "manifestUrl", "manifestSha256", "signatureRef", "sdkVersion")

# Flatten: every <id, version> the catalog knows, from top-level entries (possibly repeated, the
# old shape) and from nested version history.
known = {}   # id -> {version -> full entry}
for top in catalog.get("modules", []):
    history = top.get("versions") or []
    base = {k: v for k, v in top.items() if k != "versions"}
    for e in [base] + [dict(base, **{k: h[k] for k in h if k in VERSION_FIELDS}) for h in history]:
        if e.get("id") and e.get("version"):
            known.setdefault(e["id"], {}).setdefault(e["version"], e)

if manifest_url:
    m = json.load(open(manifest_path))
    md, spec = m["metadata"], m["spec"]
    known.setdefault(md["id"], {})[md["version"]] = {
        "id": md["id"],
        "name": md.get("name") or md["id"],
        "version": md["version"],
        "description": md.get("description", ""),
        "publisher": md.get("publisher", "CloudGrange"),
        "image": spec["image"],
        "manifestUrl": manifest_url,
        "manifestSha256": hashlib.sha256(open(manifest_path, "rb").read()).hexdigest(),
        "sdkVersion": spec.get("sdkVersion", ""),
    }

modules = []
for mid in sorted(known):
    ordered = sorted(known[mid].values(), key=lambda e: semver_key(e["version"]), reverse=True)
    top = dict(ordered[0])
    top.pop("versions", None)
    older = [{k: e[k] for k in VERSION_FIELDS if e.get(k) not in (None, "")} for e in ordered[1:]]
    if older:
        top["versions"] = older
    modules.append(top)

json.dump({"schema": "cg-module-catalog-v1", "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "modules": modules},
          sys.stdout, indent=2)
sys.stdout.write("\n")
PY

# Invariant the platform relies on: one top-level entry per module id.
python3 - "$WORK/catalog.json" <<'PY'
import collections, json, sys
ids = [m["id"] for m in json.load(open(sys.argv[1]))["modules"]]
dups = [i for i, n in collections.Counter(ids).items() if n > 1]
if dups:
    sys.exit(f"refusing to publish: catalog lists {dups} more than once")
PY

if [ "$DRY" = 1 ]; then
  echo "DRY RUN — would upload ${MANIFEST_KEY:-(no manifest)} and modules/catalog.json:"
  cat "$WORK/catalog.json"
  exit 0
fi

SECRET=$(printf '%s' "$CF_TOKEN" | sha256sum | cut -d' ' -f1)
S3="https://$CF_ACCOUNT_ID.r2.cloudflarestorage.com/$R2_BUCKET"
put() { # <file> <key> <content-type>
  local code
  code=$(curl -sS -o "$WORK/put.out" -w '%{http_code}' --aws-sigv4 "aws:amz:auto:s3" --user "$CF_TOKEN_ID:$SECRET" \
    -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" -H "Content-Type: $3" -H "Cache-Control: max-age=60" -T "$1" "$S3/$2")
  echo "PUT $2 -> HTTP $code"
  [ "$code" = 200 ] || { head -c 400 "$WORK/put.out" >&2; echo >&2; exit 1; }
}

# Manifest first: the catalog must never point at a manifest that is not there yet.
[ "$DEDUPE_ONLY" = 1 ] || put "$WORK/module.json" "$MANIFEST_KEY" application/json
put "$WORK/catalog.json" modules/catalog.json application/json

# Verify what a customer install will actually read. The public URL is cached (max-age=60), so
# compare against the object we uploaded via the S3 API as well.
[ "$DEDUPE_ONLY" = 1 ] || curl -sSf -A "$UA" "$MANIFEST_URL" | cmp -s - "$WORK/module.json" || { echo "public manifest does not match the upload" >&2; exit 1; }
curl -sSf --aws-sigv4 "aws:amz:auto:s3" --user "$CF_TOKEN_ID:$SECRET" -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" \
  "$S3/modules/catalog.json" | cmp -s - "$WORK/catalog.json" || { echo "stored catalog does not match the upload" >&2; exit 1; }
python3 - "$WORK/catalog.json" "${ID:-}" "${VERSION:-}" <<'PY'
import collections, json, sys
c = json.load(open(sys.argv[1]))
mid, ver = sys.argv[2], sys.argv[3]
if mid:
    assert any(m["id"] == mid and (m["version"] == ver or any(v["version"] == ver for v in m.get("versions", []))) for m in c["modules"]), "entry missing from catalog"
print("catalog:", ", ".join(f'{m["id"]} {m["version"]} (+{len(m.get("versions", []))} older)' for m in c["modules"]))
PY
