#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — publish the `cg` CLI built by New-CliRelease.sh to the download host (Cloudflare R2)
# under cli/<version>/:
#   cli/<version>/<rid>/cg[.exe]   cli/<version>/SHA256SUMS   cli/<version>/manifest.json
# These are the same files the platform itself serves at /downloads/cli/. Every binary is read back
# from the public URL and checked against SHA256SUMS.
#
# Required environment (never committed), the same as Publish-Release.sh:
#   CF_ACCOUNT_ID, CF_TOKEN (R2 write; the S3 secret is sha256(token)), CF_TOKEN_ID (the S3 access
#   key id), R2_BUCKET, R2_PUBLIC_BASE
#
# Usage:
#   Publish-CliRelease.sh --version 2609.0.0-preview.11 --cli-dir <New-CliRelease.sh --out DIR>
set -euo pipefail

VERSION='' DIR=''
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION=$2; shift 2 ;;
        --cli-dir) DIR=$2; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ "$VERSION" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(-(preview|rc)\.[0-9]+)?$ ]] \
    || { echo "--version must be YYMM.MINOR.PATCH[-preview.N|-rc.N]" >&2; exit 2; }
[ -n "$DIR" ] || { echo "--cli-dir is required" >&2; exit 2; }
: "${CF_ACCOUNT_ID:?}" "${CF_TOKEN:?}" "${CF_TOKEN_ID:?}" "${R2_BUCKET:?}" "${R2_PUBLIC_BASE:?}"
python3 - "$DIR/manifest.json" "$VERSION" <<'PY' || exit 2
import json, sys
m = json.load(open(sys.argv[1]))
assert m.get("schema") == "cg-cli-manifest-v1" and m["version"] == sys.argv[2], "CLI dir is not version %s" % sys.argv[2]
PY
(cd "$DIR" && sha256sum -c --quiet SHA256SUMS)

SECRET=$(printf '%s' "$CF_TOKEN" | sha256sum | cut -d' ' -f1)
S3="https://$CF_ACCOUNT_ID.r2.cloudflarestorage.com/$R2_BUCKET"
PUBLIC="${R2_PUBLIC_BASE%/}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

put() { # <file> <key> <content-type>
  local code
  code=$(curl -sS -o "$WORK/put.out" -w '%{http_code}' --aws-sigv4 "aws:amz:auto:s3" --user "$CF_TOKEN_ID:$SECRET" \
    -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" -H "Content-Type: $3" -T "$1" "$S3/$2")
  echo "PUT $2 -> HTTP $code"
  [ "$code" = 200 ] || { head -c 400 "$WORK/put.out" >&2; echo >&2; exit 1; }
}

while read -r sha path; do
  put "$DIR/$path" "cli/$VERSION/$path" application/octet-stream
  got=$(curl -sSfL "$PUBLIC/cli/$VERSION/$path" | sha256sum | cut -d' ' -f1)
  [ "$got" = "$sha" ] || { echo "public cli/$VERSION/$path has SHA-256 $got, expected $sha" >&2; exit 1; }
done < "$DIR/SHA256SUMS"
put "$DIR/SHA256SUMS" "cli/$VERSION/SHA256SUMS" text/plain
put "$DIR/manifest.json" "cli/$VERSION/manifest.json" application/json
curl -sSf "$PUBLIC/cli/$VERSION/SHA256SUMS"
echo "CLI URL: $PUBLIC/cli/$VERSION/"
