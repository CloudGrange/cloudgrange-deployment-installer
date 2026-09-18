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
#   2. adds or replaces the <id, version> entry in modules/catalog.json, keeping every other entry.
#
# Required environment (never committed) — the same as Publish-Release.sh:
#   CF_ACCOUNT_ID, CF_TOKEN, CF_TOKEN_ID, R2_BUCKET, R2_PUBLIC_BASE
#
# Usage:
#   Publish-ModuleCatalog.sh --module-json <path/to/module.json> --version 2609.0.0-preview.9 \
#       --image ghcr.io/cloudgrange/cloudgrange-module-hello:2609.0.0-preview.9@sha256:<digest> [--dry-run]
set -euo pipefail

MODULE_JSON='' VERSION='' IMAGE='' DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --module-json) MODULE_JSON=$2; shift 2 ;;
    --version) VERSION=$2; shift 2 ;;
    --image) IMAGE=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -f "$MODULE_JSON" ] || { echo "--module-json must name a module.json" >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "--version must be a SemVer version" >&2; exit 2; }
[[ "$IMAGE" =~ ^[^@]+:[^@:]+@sha256:[0-9a-f]{64}$ ]] || { echo "--image must be repo:tag@sha256:<digest>" >&2; exit 2; }
[[ "$IMAGE" != *:latest@* ]] || { echo "--image with tag latest is refused" >&2; exit 2; }
: "${R2_PUBLIC_BASE:?}"
[ "$DRY" = 1 ] || : "${CF_ACCOUNT_ID:?}" "${CF_TOKEN:?}" "${CF_TOKEN_ID:?}" "${R2_BUCKET:?}"

PUBLIC="${R2_PUBLIC_BASE%/}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["metadata"]["id"])' "$MODULE_JSON")
[[ "$ID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "module id '$ID' is not a valid package id" >&2; exit 2; }
MANIFEST_KEY="modules/$ID/$VERSION/module.json"
MANIFEST_URL="$PUBLIC/$MANIFEST_KEY"

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
code=$(curl -sS -o "$WORK/existing.json" -w '%{http_code}' "$MANIFEST_URL")
if [ "$code" = 200 ] && ! cmp -s "$WORK/existing.json" "$WORK/module.json"; then
  echo "$MANIFEST_URL already exists with different content; publish a new version instead" >&2
  exit 1
fi

code=$(curl -sS -o "$WORK/catalog.in.json" -w '%{http_code}' "$PUBLIC/modules/catalog.json")
case "$code" in
  200) ;;
  404) echo '{"schema":"cg-module-catalog-v1","modules":[]}' > "$WORK/catalog.in.json" ;;
  *) echo "reading the current catalog returned HTTP $code" >&2; exit 1 ;;
esac

python3 - "$WORK/catalog.in.json" "$WORK/module.json" "$MANIFEST_URL" > "$WORK/catalog.json" <<'PY'
import json, sys, time
catalog_path, manifest_path, manifest_url = sys.argv[1:4]
catalog = json.load(open(catalog_path))
if catalog.get("schema") != "cg-module-catalog-v1":
    sys.exit("the current catalog is not cg-module-catalog-v1")
m = json.load(open(manifest_path))
md, spec = m["metadata"], m["spec"]
entry = {
    "id": md["id"],
    "name": md.get("name") or md["id"],
    "version": md["version"],
    "description": md.get("description", ""),
    "publisher": md.get("publisher", "CloudGrange"),
    "image": spec["image"],
    "manifestUrl": manifest_url,
    "sdkVersion": spec.get("sdkVersion", ""),
}
modules = [x for x in catalog.get("modules", []) if not (x.get("id") == entry["id"] and x.get("version") == entry["version"])]
modules.append(entry)
modules.sort(key=lambda x: (x["id"], x["version"]))
json.dump({"schema": "cg-module-catalog-v1", "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "modules": modules},
          sys.stdout, indent=2)
sys.stdout.write("\n")
PY

if [ "$DRY" = 1 ]; then
  echo "DRY RUN — would upload $MANIFEST_KEY and modules/catalog.json:"
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
put "$WORK/module.json" "$MANIFEST_KEY" application/json
put "$WORK/catalog.json" modules/catalog.json application/json

# Verify what a customer install will actually read.
curl -sSf "$MANIFEST_URL" | cmp -s - "$WORK/module.json" || { echo "public manifest does not match the upload" >&2; exit 1; }
curl -sSf "$PUBLIC/modules/catalog.json" | python3 -c '
import json, sys
c = json.load(sys.stdin)
assert any(m["id"] == sys.argv[1] and m["version"] == sys.argv[2] for m in c["modules"]), "entry missing from public catalog"
print("public catalog lists", sys.argv[1], sys.argv[2])' "$ID" "$VERSION"
