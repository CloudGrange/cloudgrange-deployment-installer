#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (plan 2026-09-18-foundation-platform-separation section 3) — publish a signed Foundation
# release built by New-FoundationRelease.sh to the download host (Cloudflare R2) and add it to the
# Foundation channel that managed foundations read (foundation-check; FOUNDATION_CHANNEL_URL in
# release/pins.conf, copied to /etc/cloudgrange/foundation-channel-url on every managed host).
#
# DRY RUN BY DEFAULT: it verifies the bundle, reads the live channel and prints (or writes, with
# --channel-out) the channel document it would upload, and uploads nothing. Only --publish uploads.
#
# What it checks before anything else:
#   - the zip matches its .sha256 build record;
#   - the updater's OWN extract / load_manifest accept it: cg-foundation-release-v1, and every file in
#     the zip pinned by the manifest's per-file sha256 (with the channel's bundle sha256, that is the
#     trust chain: HTTPS + SHA-256, owner decision 2026-09-18);
#   - the version is a Foundation version (F2609.1.0) and matches the file name;
#   - a signature is optional. If the bundle carries foundation-release.json.sig and --pubkey (default:
#     cloudgrange-signing-key.pub, what installers put on every host) is a real key, the signature
#     must verify: a bad signature is refused, never shipped;
#   - immutability: a bundle already published for this version with different content is refused.
#
# Layout on the bucket (public base = FOUNDATION_CHANNEL_URL up to /channels/):
#   foundation/<version>/cloudgrange-foundation-<version>.zip(.sha256)
#   channels/foundation-<channel>.json   {"schema":"cg-foundation-channel-v1","updatedAt":...,
#       "releases":[{version, bundleUrl, sha256, k3sVersion, sizeBytes, supportedPlatformVersions,
#                    requiresReboot, notes, apt{packages,securityUpdates}}]}  — every other entry is
#       kept; this version's is replaced. `apt` is the advisory copy of the manifest's apt intent, so a
#       managed foundation can bucket its upgradable packages without downloading the bundle (AB#9171).
#
# Environment for --publish (never committed; the same R2 credentials as Publish-Release.sh):
#   CF_ACCOUNT_ID   Cloudflare account that owns the bucket
#   CF_TOKEN        Cloudflare API token with R2 write (default: $CLOUDFLARE_API_TOKEN); the R2 S3
#                   secret is sha256(token)
#   CF_TOKEN_ID     that token's id (the R2 S3 access key id)
#   R2_BUCKET       bucket name
#
# Usage:
#   scripts/release/Publish-FoundationRelease.sh --bundle out/cloudgrange-foundation-F2609.1.0.zip
#       [--channel-url URL] [--pubkey FILE] [--channel-out FILE] [--publish]
# Needs: bash, python3, openssl, curl (for --publish).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PINS=${CG_PINS_FILE:-$REPO/release/pins.conf}
BUNDLE='' CHANNEL_URL='' PUBKEY="$REPO/cloudgrange-signing-key.pub" CHANNEL_OUT='' PUBLISH=false
usage() { sed -n '/^# Usage:/,/^# Needs:/p' "$0" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle) BUNDLE=$2; shift 2 ;;
        --channel-url) CHANNEL_URL=$2; shift 2 ;;
        --pubkey) PUBKEY=$2; shift 2 ;;
        --channel-out) CHANNEL_OUT=$2; shift 2 ;;
        --publish) PUBLISH=true; shift ;;
        --dry-run) PUBLISH=false; shift ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done
log() { echo "[foundation-publish] $*"; }
die() { echo "[foundation-publish] ERROR: $*" >&2; exit 1; }
[ -n "$BUNDLE" ] || usage
[ -f "$BUNDLE" ] || die "bundle $BUNDLE not found"
[ -f "$BUNDLE.sha256" ] || die "$BUNDLE.sha256 not found (build with New-FoundationRelease.sh)"
UPDATER="$REPO/scripts/cloudgrange-updater-k3s.py"
[ -f "$UPDATER" ] || die "$UPDATER not found"
for tool in python3 openssl; do command -v "$tool" >/dev/null || die "$tool is required"; done
if [ -z "$CHANNEL_URL" ]; then
    [ -f "$PINS" ] || die "pins file $PINS not found and no --channel-url"
    CHANNEL_URL=$(sed -n 's/^FOUNDATION_CHANNEL_URL=//p' "$PINS" | head -1 | tr -d '[:space:]')
fi
[[ "$CHANNEL_URL" =~ ^(https://[^/]+|file:///.+)/(channels/[A-Za-z0-9._-]+\.json)$ ]] \
    || die "channel URL '$CHANNEL_URL' is not <public base>/channels/<name>.json"
PUBLIC=${BASH_REMATCH[1]}
CHANNEL_KEY=${BASH_REMATCH[2]}
if [ "$PUBLISH" = true ]; then
    [[ "$CHANNEL_URL" == https://* ]] || die "--publish needs an https:// channel URL"
    CF_TOKEN=${CF_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}
    : "${CF_ACCOUNT_ID:?CF_ACCOUNT_ID is required for --publish}" "${CF_TOKEN:?CF_TOKEN or CLOUDFLARE_API_TOKEN is required for --publish}" \
      "${CF_TOKEN_ID:?CF_TOKEN_ID is required for --publish}" "${R2_BUCKET:?R2_BUCKET is required for --publish}"
    command -v curl >/dev/null || die "curl is required"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- the bundle -----------------------------------------------------------------------------------
SHA=$(sha256sum "$BUNDLE" | cut -d' ' -f1)
[ "$SHA" = "$(cut -d' ' -f1 "$BUNDLE.sha256")" ] || die "$BUNDLE does not match its .sha256 build record"
SIZE=$(stat -c %s "$BUNDLE")
[ "$SIZE" -lt $((5 * 1024 * 1024 * 1024)) ] || die "bundle is over 5 GiB: multipart upload is not implemented"
# The updater's own checks, over the exact zip that will be uploaded.
mkdir -p "$WORK/state"
CLOUDGRANGE_UPDATER_STATE="$WORK/state" python3 - "$UPDATER" "$BUNDLE" "$WORK" <<'PY' || exit 1
import importlib.util, os, shutil, sys
spec = importlib.util.spec_from_file_location("cg_updater", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
u = m.FoundationUpdater()
try:
    work = u.extract(sys.argv[2])
    manifest = u.load_manifest(work)
except (m.UpdateError, ValueError, OSError) as err:
    sys.exit("[foundation-publish] ERROR: the Foundation updater would refuse this bundle: %s" % err)
for name in (m.MANIFEST_NAME, m.SIGNATURE_NAME):
    if os.path.isfile(os.path.join(work, name)):
        shutil.copyfile(os.path.join(work, name), os.path.join(sys.argv[3], name))
shutil.rmtree(work, ignore_errors=True)
print("[foundation-publish] the updater accepts the manifest: %d pinned files, all matching" % len(manifest["files"]))
PY
if [ ! -f "$WORK/foundation-release.json.sig" ]; then
    log "not signed: trusted through the bundle sha256 in the channel and the manifest's per-file pins"
elif [ ! -f "$PUBKEY" ] || grep -q PLACEHOLDER "$PUBKEY"; then
    log "signed, but $PUBKEY is the placeholder: signature not checked (hosts rely on the sha256)"
else
    python3 -c '
import base64, re, sys
d = open(sys.argv[1], "rb").read(); s = d.strip()
open(sys.argv[2], "wb").write(base64.b64decode(s) if re.match(rb"^[A-Za-z0-9+/=\r\n]+$", s) else d)' \
        "$WORK/foundation-release.json.sig" "$WORK/sig.der"
    openssl dgst -sha256 -verify "$PUBKEY" -signature "$WORK/sig.der" "$WORK/foundation-release.json" >/dev/null 2>&1 \
        || die "the bundle's signature does not verify against $PUBKEY"
    log "signature verified against $PUBKEY"
fi
read -r VERSION K3S_VERSION < <(python3 - "$WORK/foundation-release.json" <<'PY'
import json, re, sys
m = json.load(open(sys.argv[1]))
if m.get("schema") != "cg-foundation-release-v1":
    sys.exit("[foundation-publish] ERROR: manifest schema is not cg-foundation-release-v1")
v = str(m.get("version") or "")
if not re.match(r"^F[0-9]{4}\.[0-9]+\.[0-9]+(-(preview|rc)\.[0-9]+)?$", v):
    sys.exit("[foundation-publish] ERROR: manifest version %r is not a Foundation version" % v)
print(v, (m.get("k3s") or {}).get("version") or "")
PY
)
[ -n "$VERSION" ] || die "could not read the manifest"
[ "$(basename "$BUNDLE")" = "cloudgrange-foundation-$VERSION.zip" ] || die "bundle name $(basename "$BUNDLE") does not match its manifest version $VERSION"
NAME="cloudgrange-foundation-$VERSION.zip"
BUNDLE_KEY="foundation/$VERSION/$NAME"
BUNDLE_URL="$PUBLIC/$BUNDLE_KEY"
log "Foundation $VERSION (K3s $K3S_VERSION), $SIZE bytes, sha256 $SHA"

# ---- read what is live ----------------------------------------------------------------------------
# Cloudflare's r2.dev refuses Python-urllib's User-Agent (HTTP 403), so reads go through curl.
fetch() { # <url> <out file>; prints found|absent, fails on anything else
    local code path
    if [[ "$1" == file://* ]]; then
        path=${1#file://}
        if [ -f "$path" ]; then cp "$path" "$2"; echo found; else echo absent; fi
        return 0
    fi
    code=$(curl -sS -A "cloudgrange-release/1" -o "$2" -w '%{http_code}' "$1") || { echo "[foundation-publish] ERROR: cannot read $1" >&2; return 1; }
    case "$code" in
        200) echo found ;;
        404) echo absent ;;
        *) echo "[foundation-publish] ERROR: $1 returned HTTP $code" >&2; return 1 ;;
    esac
}
# Immutable per version: the same bytes may be re-published, different ones may not.
found=$(fetch "$BUNDLE_URL.sha256" "$WORK/existing.sha256") || exit 1
if [ "$found" = found ]; then
    existing=$(cut -d' ' -f1 "$WORK/existing.sha256")
    [ "$existing" = "$SHA" ] || die "$BUNDLE_URL is already published with sha256 $existing; publish a new Foundation version instead"
    log "$VERSION is already published with the same content (re-publishing is a no-op for the bundle)"
fi
found=$(fetch "$CHANNEL_URL" "$WORK/channel.in.json") || exit 1
if [ "$found" = absent ]; then
    log "channel $CHANNEL_URL does not exist yet; starting it"
    echo '{"releases": []}' > "$WORK/channel.in.json"
fi

python3 - "$WORK/channel.in.json" "$WORK/foundation-release.json" "$BUNDLE_URL" "$SHA" "$SIZE" > "$WORK/channel.json" <<'PY'
import json, re, sys, time
channel_path, manifest_path, url, sha, size = sys.argv[1:6]
try:
    channel = json.load(open(channel_path))
except ValueError as err:
    sys.exit("[foundation-publish] ERROR: the live channel is not JSON: %s" % err)
releases = channel.get("releases") if isinstance(channel, dict) else None
if not isinstance(releases, list):
    sys.exit("[foundation-publish] ERROR: the live channel has no releases list; refusing to overwrite it")
m = json.load(open(manifest_path))
apt = m.get("apt") if isinstance(m.get("apt"), dict) else {}
entry = {"version": m["version"], "bundleUrl": url, "sha256": sha, "k3sVersion": (m.get("k3s") or {}).get("version"),
         "sizeBytes": int(size), "supportedPlatformVersions": m.get("supportedPlatformVersions"),
         "requiresReboot": bool(m.get("requiresReboot")), "notes": m.get("notes"),
         # AB#9171: the apt intent, copied from the release manifest so a managed foundation can tell an
         # administrator WHICH upgradable OS packages this release installs before they press Apply
         # (foundation-check buckets them into included / pending / unmanaged). ADVISORY ONLY: an apply
         # obeys the manifest inside the verified bundle, never this copy.
         "apt": {"packages": apt.get("packages") or {}, "securityUpdates": bool(apt.get("securityUpdates"))}}
key = lambda r: tuple(int(n) for n in re.findall(r"\d+", str(r.get("version"))))
releases = [r for r in releases if not (isinstance(r, dict) and r.get("version") == entry["version"])] + [entry]
releases.sort(key=key)
json.dump({"schema": "cg-foundation-channel-v1", "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "releases": releases}, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
[ -z "$CHANNEL_OUT" ] || cp "$WORK/channel.json" "$CHANNEL_OUT"

if [ "$PUBLISH" != true ]; then
    log "DRY RUN — nothing uploaded. --publish would upload:"
    log "  $BUNDLE_KEY (+ .sha256)  ->  $BUNDLE_URL"
    log "  $CHANNEL_KEY             ->  $CHANNEL_URL"
    cat "$WORK/channel.json"
    exit 0
fi

# ---- upload ---------------------------------------------------------------------------------------
SECRET=$(printf '%s' "$CF_TOKEN" | sha256sum | cut -d' ' -f1)
S3="https://$CF_ACCOUNT_ID.r2.cloudflarestorage.com/$R2_BUCKET"
put() { # <file> <key> <content-type> <cache-control>
    local code
    code=$(curl -sS -o "$WORK/put.out" -w '%{http_code}' --aws-sigv4 "aws:amz:auto:s3" --user "$CF_TOKEN_ID:$SECRET" \
        -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" -H "Content-Type: $3" -H "Cache-Control: $4" -T "$1" "$S3/$2")
    log "PUT $2 -> HTTP $code"
    [ "$code" = 200 ] || { head -c 400 "$WORK/put.out" >&2; echo >&2; exit 1; }
}
printf '%s  %s\n' "$SHA" "$NAME" > "$WORK/$NAME.sha256"
# Bundle first: the channel must never point at a bundle that is not there yet.
put "$BUNDLE" "$BUNDLE_KEY" application/zip "public, max-age=31536000, immutable"
put "$WORK/$NAME.sha256" "$BUNDLE_KEY.sha256" text/plain "public, max-age=31536000, immutable"
remote=$(curl -sSI "$BUNDLE_URL" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')
[ "$remote" = "$SIZE" ] || die "public size of $BUNDLE_URL is '$remote', expected $SIZE"
put "$WORK/channel.json" "$CHANNEL_KEY" application/json "max-age=60"

# Verify what a managed host's foundation-check will actually read.
curl -sSf "$CHANNEL_URL?v=$SHA" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
hit = [r for r in doc["releases"] if r.get("version") == sys.argv[1] and r.get("sha256") == sys.argv[2]]
assert hit, "the public channel does not list this release yet"
print("[foundation-publish] public channel lists", sys.argv[1], "->", hit[0]["bundleUrl"])' "$VERSION" "$SHA"
log "published Foundation $VERSION"
