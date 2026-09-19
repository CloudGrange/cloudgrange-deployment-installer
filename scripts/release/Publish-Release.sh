#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — Publish a platform release bundle (the in-app update) to the download host (Cloudflare R2) and point an
# update channel at it (cg-onprem-channel-v1). Installed platforms that check that channel announce the release in
# Platform administration -> Updates and install it from bundleUrl.
#
# Update trust is HTTPS + digest pinning (owner decision 2026-09-18), no signing key: the channel
# carries the sha256 of the bundle (latest.sha256) and of the Platform release manifest
# (latest.manifestSha256); the in-cluster updater refuses a manifest whose SHA-256 differs, and the
# manifest pins the chart by SHA-256 and every image by digest. A manifest.json.sig, if present, is
# published too (an optional extra the updater verifies only when a key is configured).
#
# Required environment (never committed):
#   CF_ACCOUNT_ID    Cloudflare account id that owns the bucket
#   CF_TOKEN         Cloudflare user API token with R2 write (the R2 S3 secret is sha256(token))
#   CF_TOKEN_ID      that token's id (the R2 S3 access key id)
#   R2_BUCKET        bucket name
#   R2_PUBLIC_BASE   public base URL of the bucket (e.g. its r2.dev URL or custom download domain)
#
# AB#9171 — customers download installers from GitHub Releases (owner decision 2026-09-18), not
# from R2: after the channel is live this also runs Publish-GitHubRelease.sh, which creates the
# GitHub release at the release commit, uploads the Linux bundle, the Windows installer and the
# chart under stable asset names, and makes it the repo's latest release, so the install docs'
# version-free .../releases/latest/download/<asset> URLs resolve to it. R2 stays the in-app
# updater's source.
#
# Usage:
#   Publish-Release.sh --version 2609.0.0-preview.3 --bundle-dir <dir with Install-CloudGrange-K3s-Bundled.zip(.sha256)> \
#     --channel preview|rc|stable --severity security|recommended|optional --summary "<one line>" \
#     --github-target <release commit sha> [--windows-dir <dir with Install-CloudGrange-Windows.zip>] \
#     [--platform-release-dir <New-PlatformRelease.sh --out dir>] [--no-github-release]
set -euo pipefail

VERSION=""; DIR=""; CHANNEL=""; SEVERITY=""; SUMMARY=""; PLATFORM_DIR=""; GITHUB_TARGET=""; WINDOWS_DIR=""; GITHUB_RELEASE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION=$2; shift 2 ;;
    --bundle-dir) DIR=$2; shift 2 ;;
    --channel) CHANNEL=$2; shift 2 ;;
    --severity) SEVERITY=$2; shift 2 ;;
    --summary) SUMMARY=$2; shift 2 ;;
    # AB#9171: output of New-PlatformRelease.sh (manifest.json, cloudgrange-<v>.tgz, optional
    # manifest.json.sig). Published next to the bundle; the channel then carries latest.manifestUrl
    # and latest.manifestSha256, which the in-cluster Platform updater pins, verifies and applies. Run New-PlatformRelease.sh with
    # --chart-base-url "$R2_PUBLIC_BASE/releases/<version>" so the manifest points at this upload.
    --platform-release-dir) PLATFORM_DIR=$2; shift 2 ;;
    --github-target) GITHUB_TARGET=$2; shift 2 ;;
    --windows-dir) WINDOWS_DIR=$2; shift 2 ;;
    --no-github-release) GITHUB_RELEASE=0; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
# AB#9171: the bundle New-ReleaseBundleK3s.sh builds. The Compose bundle (Install-CloudGrange-Bundled.zip)
# is retired, and this script still looked for it, so it could not publish a K3s release.
BUNDLE=Install-CloudGrange-K3s-Bundled.zip
[[ "$VERSION" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(-(preview|rc)\.[0-9]+)?$ ]] || { echo "--version must be YYMM.MINOR.PATCH[-preview.N|-rc.N]" >&2; exit 2; }
# rc is a real channel: the chart's api.updateChannel follows an …-rc.N install to channels/rc.json.
case "$CHANNEL" in preview|rc|stable) ;; *) echo "--channel must be preview, rc or stable" >&2; exit 2 ;; esac
case "$SEVERITY" in security|recommended|optional) ;; *) echo "--severity must be security, recommended or optional" >&2; exit 2 ;; esac
: "${CF_ACCOUNT_ID:?}" "${CF_TOKEN:?}" "${CF_TOKEN_ID:?}" "${R2_BUCKET:?}" "${R2_PUBLIC_BASE:?}"
[ -f "$DIR/$BUNDLE" ] && [ -f "$DIR/$BUNDLE.sha256" ] || { echo "bundle not found in $DIR" >&2; exit 2; }
# Checked before anything is uploaded, so a release never reaches the channel without its customer download.
[ "$GITHUB_RELEASE" = 0 ] || [[ "$GITHUB_TARGET" =~ ^[0-9a-f]{7,40}$ ]] \
  || { echo "--github-target <release commit sha> is required (or --no-github-release)" >&2; exit 2; }

SECRET=$(printf '%s' "$CF_TOKEN" | sha256sum | cut -d' ' -f1)
S3="https://$CF_ACCOUNT_ID.r2.cloudflarestorage.com/$R2_BUCKET"
PUBLIC="${R2_PUBLIC_BASE%/}"
ZIP="Install-CloudGrange-$VERSION.zip"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

put() { # <file> <key> <content-type>
  local code
  code=$(curl -sS -o "$WORK/put.out" -w '%{http_code}' --aws-sigv4 "aws:amz:auto:s3" --user "$CF_TOKEN_ID:$SECRET" \
    -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" -H "Content-Type: $3" -T "$1" "$S3/$2")
  echo "PUT $2 -> HTTP $code"
  [ "$code" = 200 ] || { head -c 400 "$WORK/put.out" >&2; echo >&2; exit 1; }
}

size=$(stat -c %s "$DIR/$BUNDLE")
[ "$size" -lt $((5 * 1024 * 1024 * 1024)) ] || { echo "bundle is over 5 GiB: multipart upload is not implemented" >&2; exit 1; }
sha=$(sha256sum "$DIR/$BUNDLE" | cut -d' ' -f1)
[ "$sha" = "$(cut -d' ' -f1 "$DIR/$BUNDLE.sha256")" ] || { echo "bundle SHA-256 does not match its build record" >&2; exit 1; }
printf '%s  %s\n' "$sha" "$ZIP" > "$WORK/$ZIP.sha256"

put "$WORK/$ZIP.sha256" "releases/$VERSION/$ZIP.sha256" text/plain
put "$DIR/$BUNDLE" "releases/$VERSION/$ZIP" application/zip
remote=$(curl -sSI "$PUBLIC/releases/$VERSION/$ZIP" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')
[ "$remote" = "$size" ] || { echo "public size $remote does not match $size" >&2; exit 1; }

MANIFEST_URL="" MANIFEST_SHA=""
if [ -n "$PLATFORM_DIR" ]; then
  for f in manifest.json "cloudgrange-$VERSION.tgz"; do
    [ -f "$PLATFORM_DIR/$f" ] || { echo "$PLATFORM_DIR/$f missing (incomplete platform release)" >&2; exit 2; }
  done
  python3 - "$PLATFORM_DIR/manifest.json" "$VERSION" "$PLATFORM_DIR/cloudgrange-$VERSION.tgz" <<'PY' || exit 2
import hashlib, json, re, sys
m = json.load(open(sys.argv[1]))
assert m["platform"] == sys.argv[2] and not m.get("dryRun"), "manifest is a dry run or for another version"
bad = [k for k, c in m["components"].items() if not re.search(r"@sha256:[0-9a-f]{64}$", c.get("image", ""))]
assert not bad, "images not pinned by digest: %s" % ", ".join(bad)
assert m["chart"]["sha256"] == hashlib.sha256(open(sys.argv[3], "rb").read()).hexdigest(), "chart does not match the manifest"
PY
  MANIFEST_SHA=$(sha256sum "$PLATFORM_DIR/manifest.json" | cut -d' ' -f1)
  put "$PLATFORM_DIR/cloudgrange-$VERSION.tgz" "releases/$VERSION/cloudgrange-$VERSION.tgz" application/gzip
  if [ -f "$PLATFORM_DIR/manifest.json.sig" ]; then
    put "$PLATFORM_DIR/manifest.json.sig" "releases/$VERSION/manifest.json.sig" text/plain
  fi
  put "$PLATFORM_DIR/manifest.json" "releases/$VERSION/manifest.json" application/json
  MANIFEST_URL="$PUBLIC/releases/$VERSION/manifest.json"
  # What the updater will download must be byte-identical to what the channel pins.
  [ "$(curl -sSf "$MANIFEST_URL" | sha256sum | cut -d' ' -f1)" = "$MANIFEST_SHA" ] \
    || { echo "public manifest does not match its SHA-256" >&2; exit 1; }
fi

python3 - "$VERSION" "$PUBLIC/releases/$VERSION/$ZIP" "$sha" "$size" "$SEVERITY" "$SUMMARY" "$MANIFEST_URL" "$MANIFEST_SHA" > "$WORK/channel.json" <<'PY'
import json, sys, time
version, url, sha, size, severity, summary, manifest_url, manifest_sha = sys.argv[1:9]
print(json.dumps({
    "schema": "cg-onprem-channel-v1",
    "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "latest": {"version": version, "bundleUrl": url, "sha256": sha, "sizeBytes": int(size),
               "severity": severity, "summary": summary, "releaseNotesUrl": None,
               "manifestUrl": manifest_url or None, "manifestSha256": manifest_sha or None},
}, indent=2))
PY
put "$WORK/channel.json" "channels/$CHANNEL.json" application/json
curl -sSf "$PUBLIC/channels/$CHANNEL.json"
echo
echo "RELEASE URL: $PUBLIC/releases/$VERSION/$ZIP"

if [ "$GITHUB_RELEASE" = 1 ]; then
  bash "$(dirname "$0")/Publish-GitHubRelease.sh" --version "$VERSION" --target "$GITHUB_TARGET" --bundle-dir "$DIR" \
    ${WINDOWS_DIR:+--windows-dir "$WINDOWS_DIR"} ${PLATFORM_DIR:+--platform-release-dir "$PLATFORM_DIR"}
fi
