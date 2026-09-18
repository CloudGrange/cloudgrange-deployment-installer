#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (plan 2026-09-18-foundation-platform-separation section 3) — build a signed Foundation
# release: the zip the host Foundation updater (scripts/cloudgrange-updater-k3s.py) applies from
# Platform -> Updates -> Foundation, either downloaded through the Foundation channel or uploaded to
# an air-gapped host. Nothing is uploaded here; Publish-FoundationRelease.sh does that.
#
# The zip (format cg-foundation-release-v1, exactly what the updater's extract/verify_signature/
# load_manifest accept):
#   foundation-release.json       the manifest: version, requiresReboot, supportedPlatformVersions,
#                                 k3s{version, binary, installScript, airgapImages}, apt{packages,
#                                 securityUpdates}, hostFiles[] and files{path: sha256} pinning EVERY
#                                 other file in the zip
#   foundation-release.json.sig   OPTIONAL signature over those exact manifest bytes (openssl dgst
#                                 -sha256 raw DER, or cosign sign-blob base64 for a cosign key)
#   k3s/k3s, k3s/install.sh, k3s/k3s-airgap-images-amd64.tar.zst   K3s at K3S_VERSION
#   hostfiles/...                 CloudGrange's own host files (the Foundation updater and its unit)
#
# Inputs are pinned, never fetched "latest": K3S_VERSION and K3S_INSTALL_SH_SHA256 come from
# release/pins.conf; the K3s binary and airgap tarball are checked against K3s's own
# sha256sum-amd64.txt for that tag; install.sh is checked against K3S_INSTALL_SH_SHA256. A Foundation
# release is the pins file at a commit (decisions-2026-09-18/versioning-and-pinning.md), so --version
# must equal FOUNDATION_VERSION in the pins file: bump both together.
#
# Trust (owner decision 2026-09-18): a Foundation bundle is trusted through HTTPS + SHA-256 — the
# bundle's sha256 in the channel entry (or in the admin's upload request), and the per-file sha256 pins
# in foundation-release.json. A signature is OPTIONAL: with no key the bundle is complete and
# installable, it just carries no foundation-release.json.sig. To sign as well: --signing-key FILE, or
# CLOUDGRANGE_FOUNDATION_SIGNING_KEY (path) / CLOUDGRANGE_FOUNDATION_SIGNING_KEY_PEM (the key itself).
# A PEM EC/RSA key is used with openssl; a cosign key ("ENCRYPTED SIGSTORE PRIVATE KEY") with cosign
# sign-blob (password in COSIGN_PASSWORD). The record (foundation-release-record.json) says which.
#
# Before it finishes, the builder runs the updater's OWN extract / load_manifest (and, when signed,
# verify_signature) over the zip it produced, so a bundle the updater would refuse is never reported
# as built.
#
# Usage:
#   scripts/release/New-FoundationRelease.sh --version F2609.1.0 --out DIR [--signing-key FILE]
#       [--notes TEXT] [--apt-pin NAME=VERSION]... [--no-security-updates] [--requires-reboot]
#       [--supported-platforms '>=2609.0.0'] [--no-airgap-images] [--k3s-source-dir DIR]
#       [--pins FILE] [--expect-pubkey FILE] [--source DIR]
#   --k3s-source-dir  use pre-downloaded K3s files (k3s, install.sh, sha256sum-amd64.txt and, unless
#                     --no-airgap-images, k3s-airgap-images-amd64.tar.zst) instead of downloading;
#                     they are verified exactly as a download is
#   --expect-pubkey   the public key installed hosts verify with (default: cloudgrange-signing-key.pub
#                     at the repo root). A real key that does not match the signing key is an error;
#                     the placeholder is a loud warning (no host can verify anything yet).
# Needs: bash, python3, openssl, curl (unless --k3s-source-dir), cosign (only for a cosign key).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE=$REPO
PINS=${CG_PINS_FILE:-}
VERSION='' OUT='' KEY=${CLOUDGRANGE_FOUNDATION_SIGNING_KEY:-} NOTES='' K3S_DIR='' EXPECT_PUB=''
SECURITY=true REBOOT=false AIRGAP=true PLATFORMS=''
APT_PINS=()
usage() { sed -n '/^# Usage:/,/^# Needs:/p' "$0" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        --signing-key) KEY=$2; shift 2 ;;
        --notes) NOTES=$2; shift 2 ;;
        --apt-pin) APT_PINS+=("$2"); shift 2 ;;
        --no-security-updates) SECURITY=false; shift ;;
        --requires-reboot) REBOOT=true; shift ;;
        --supported-platforms) PLATFORMS=$2; shift 2 ;;
        --no-airgap-images) AIRGAP=false; shift ;;
        --k3s-source-dir) K3S_DIR=$2; shift 2 ;;
        --pins) PINS=$2; shift 2 ;;
        --expect-pubkey) EXPECT_PUB=$2; shift 2 ;;
        --source) SOURCE=$2; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done
log() { echo "[foundation-release] $*"; }
die() { echo "[foundation-release] ERROR: $*" >&2; exit 1; }
[ -n "$VERSION" ] && [ -n "$OUT" ] || usage
[[ "$VERSION" =~ ^F[0-9]{4}\.[0-9]+\.[0-9]+(-(preview|rc)\.[0-9]+)?$ ]] \
    || die "--version must be F + YYMM.MINOR.PATCH[-preview.N|-rc.N], e.g. F2609.1.0 (got '$VERSION')"
SOURCE=$(cd "$SOURCE" && pwd)
PINS=${PINS:-$SOURCE/release/pins.conf}
EXPECT_PUB=${EXPECT_PUB:-$SOURCE/cloudgrange-signing-key.pub}
UPDATER="$SOURCE/scripts/cloudgrange-updater-k3s.py"
[ -f "$PINS" ] || die "pins file $PINS not found (a Foundation release never falls back to built-in versions)"
[ -f "$UPDATER" ] || die "$UPDATER not found"
for tool in python3 openssl sha256sum; do command -v "$tool" >/dev/null || die "$tool is required"; done
export LC_ALL=C TZ=UTC
umask 022

pin() { sed -n "s/^$1=//p" "$PINS" | head -1 | tr -d '[:space:]'; }
K3S_VERSION=$(pin K3S_VERSION)
INSTALL_SH_SHA=$(pin K3S_INSTALL_SH_SHA256)
PINNED_FOUNDATION=$(pin FOUNDATION_VERSION)
[[ "$K3S_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || die "K3S_VERSION missing or malformed in $PINS"
[[ "$INSTALL_SH_SHA" =~ ^[0-9a-f]{64}$ ]] || die "K3S_INSTALL_SH_SHA256 missing or malformed in $PINS"
[ "$PINNED_FOUNDATION" = "$VERSION" ] || die "--version $VERSION is not FOUNDATION_VERSION ($PINNED_FOUNDATION) in $PINS. A Foundation release IS the pins file at a commit: set FOUNDATION_VERSION=$VERSION there (and its copy in scripts/Install-CloudGrangeK3s.sh; test/lint-pins.sh checks both), commit, then build."
EPOCH=${SOURCE_DATE_EPOCH:-$(tr -d '[:space:]' < "$SOURCE/release/SOURCE_DATE_EPOCH" 2>/dev/null || true)}
[[ "$EPOCH" =~ ^[0-9]+$ ]] || die "SOURCE_DATE_EPOCH missing (release/SOURCE_DATE_EPOCH)"

# The Platform versions this Foundation supports. Default: this Foundation's train onwards.
if [ -z "$PLATFORMS" ]; then
    train=${VERSION#F}; train=${train%%.*}
    PLATFORMS=">=$train.0.0"
fi

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE/k3s" "$STAGE/hostfiles" "$WORK/k3s-src"

# ---- K3s ------------------------------------------------------------------------------------------
AIRGAP_NAME=k3s-airgap-images-amd64.tar.zst
if [ -n "$K3S_DIR" ]; then
    log "K3s $K3S_VERSION from $K3S_DIR (verified below exactly as a download would be)"
    for f in k3s install.sh sha256sum-amd64.txt; do [ -f "$K3S_DIR/$f" ] || die "$K3S_DIR/$f missing"; cp "$K3S_DIR/$f" "$WORK/k3s-src/$f"; done
    if [ "$AIRGAP" = true ]; then
        [ -f "$K3S_DIR/$AIRGAP_NAME" ] || die "$K3S_DIR/$AIRGAP_NAME missing (or pass --no-airgap-images)"
        cp "$K3S_DIR/$AIRGAP_NAME" "$WORK/k3s-src/"
    fi
else
    command -v curl >/dev/null || die "curl is required (or pass --k3s-source-dir)"
    url="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION//+/%2B}"
    log "downloading K3s $K3S_VERSION from $url"
    curl -sfL --retry 3 "$url/k3s" -o "$WORK/k3s-src/k3s"
    curl -sfL --retry 3 "$url/sha256sum-amd64.txt" -o "$WORK/k3s-src/sha256sum-amd64.txt"
    [ "$AIRGAP" = false ] || curl -sfL --retry 3 "$url/$AIRGAP_NAME" -o "$WORK/k3s-src/$AIRGAP_NAME"
    # K3s's install.sh as of the PINNED tag, never whatever get.k3s.io serves today.
    curl -sfL --retry 3 "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION//+/%2B}/install.sh" -o "$WORK/k3s-src/install.sh"
fi
check_upstream() { # <file name> — against K3s's own checksum file for the tag
    local want
    want=$(awk -v n="$1" '{f=$2; sub(/^.*\//, "", f); sub(/^\*/, "", f); if (f == n) {print $1; exit}}' "$WORK/k3s-src/sha256sum-amd64.txt")
    [[ "$want" =~ ^[0-9a-f]{64}$ ]] || die "K3s $K3S_VERSION sha256sum-amd64.txt has no entry for $1"
    [ "$(sha256sum "$WORK/k3s-src/$1" | cut -d' ' -f1)" = "$want" ] || die "$1 does not match K3s's published SHA-256 for $K3S_VERSION"
    log "verified $1 against K3s $K3S_VERSION sha256sum-amd64.txt"
}
check_upstream k3s
[ "$AIRGAP" = false ] || check_upstream "$AIRGAP_NAME"
[ "$(sha256sum "$WORK/k3s-src/install.sh" | cut -d' ' -f1)" = "$INSTALL_SH_SHA" ] \
    || die "install.sh does not match K3S_INSTALL_SH_SHA256 in $PINS"
log "verified install.sh against K3S_INSTALL_SH_SHA256"
install -m 0755 "$WORK/k3s-src/k3s" "$STAGE/k3s/k3s"
install -m 0755 "$WORK/k3s-src/install.sh" "$STAGE/k3s/install.sh"
[ "$AIRGAP" = false ] || install -m 0644 "$WORK/k3s-src/$AIRGAP_NAME" "$STAGE/k3s/$AIRGAP_NAME"

# ---- host files -----------------------------------------------------------------------------------
# CloudGrange's own host files, as Install-CloudGrangeK3s.sh install_updater lays them down. Every
# destination must be under the updater's HOST_FILE_PREFIXES (load_manifest refuses anything else).
# source|destination|mode
HOST_FILES=(
    "scripts/cloudgrange-updater-k3s.py|/usr/local/sbin/cloudgrange-updater-k3s.py|0755"
    "appliance/cloudgrange-updater-k3s.service|/etc/systemd/system/cloudgrange-updater-k3s.service|0644"
)
: > "$WORK/hostfiles.lst"
for entry in "${HOST_FILES[@]}"; do
    IFS='|' read -r src dest mode <<< "$entry"
    [ -f "$SOURCE/$src" ] || die "host file source $SOURCE/$src missing"
    name=$(basename "$dest")
    install -m "$mode" "$SOURCE/$src" "$STAGE/hostfiles/$name"
    printf '%s|%s|%s\n' "hostfiles/$name" "$dest" "$mode" >> "$WORK/hostfiles.lst"
done

# ---- apt pins -------------------------------------------------------------------------------------
: > "$WORK/apt.lst"
for p in "${APT_PINS[@]+"${APT_PINS[@]}"}"; do
    [[ "$p" == *=* ]] || die "--apt-pin must be NAME=VERSION (got '$p')"
    printf '%s\n' "$p" >> "$WORK/apt.lst"
done

# ---- manifest -------------------------------------------------------------------------------------
GIT_COMMIT=$(git -C "$SOURCE" rev-parse HEAD 2>/dev/null || echo unknown)
GIT_DIRTY=false
[ "$GIT_COMMIT" = unknown ] || [ -z "$(git -C "$SOURCE" status --porcelain 2>/dev/null)" ] || GIT_DIRTY=true
[ "$GIT_DIRTY" = false ] || log "WARNING: $SOURCE has uncommitted changes; the release records commit $GIT_COMMIT plus local edits"
CHART_KUBE=$(sed -n 's/^kubeVersion:[[:space:]]*//p' "$SOURCE/charts/cloudgrange/Chart.yaml" 2>/dev/null | tr -d "\"'" || true)

export UPDATER STAGE VERSION K3S_VERSION AIRGAP AIRGAP_NAME SECURITY REBOOT PLATFORMS NOTES EPOCH \
       GIT_COMMIT GIT_DIRTY CHART_KUBE INSTALL_SH_SHA WORK
python3 - <<'PY'
import hashlib, importlib.util, json, os, sys, time
e = os.environ
spec = importlib.util.spec_from_file_location("cg_updater", e["UPDATER"])
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)

def fail(msg):
    sys.exit("[foundation-release] ERROR: " + msg)

stage, version, k3s_version = e["STAGE"], e["VERSION"], e["K3S_VERSION"]
# The gates the updater applies at install time, applied here first so a release that can never be
# installed is never built: the platform range must be evaluable, and the pinned K3s must be inside
# the Kubernetes range of the chart this commit ships.
try:
    updater.version_satisfies("2609.0.0", e["PLATFORMS"])
except updater.UpdateError as err:
    fail("--supported-platforms %r cannot be evaluated by the updater: %s" % (e["PLATFORMS"], err))
if e.get("CHART_KUBE"):
    if not updater.version_satisfies(k3s_version, e["CHART_KUBE"]):
        fail("pinned K3s %s is outside the chart's kubeVersion %s" % (k3s_version, e["CHART_KUBE"]))

files = {}
for root, _dirs, names in os.walk(stage):
    for name in names:
        path = os.path.join(root, name)
        rel = os.path.relpath(path, stage).replace(os.sep, "/")
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(4 << 20), b""):
                h.update(chunk)
        files[rel] = h.hexdigest()

packages = {}
with open(os.path.join(e["WORK"], "apt.lst")) as f:
    for line in f.read().splitlines():
        name, _, ver = line.partition("=")
        if not updater.APT_NAME_RE.match(name) or not updater.APT_VERSION_RE.match(ver):
            fail("invalid --apt-pin %r" % line)
        packages[name] = ver
host_files = []
with open(os.path.join(e["WORK"], "hostfiles.lst")) as f:
    for line in f.read().splitlines():
        src, dest, mode = line.split("|")
        host_files.append({"source": src, "destination": dest, "mode": mode})

k3s = {"version": k3s_version, "binary": "k3s/k3s", "installScript": "k3s/install.sh"}
if e["AIRGAP"] == "true":
    k3s["airgapImages"] = "k3s/" + e["AIRGAP_NAME"]
manifest = {
    "schema": updater.MANIFEST_SCHEMA,
    "version": version,
    "notes": e.get("NOTES") or ("CloudGrange Foundation %s: K3s %s" % (version, k3s_version)),
    "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(e["EPOCH"]))),
    "requiresReboot": e["REBOOT"] == "true",
    "supportedPlatformVersions": e["PLATFORMS"],
    "k3s": k3s,
    "apt": {"packages": packages, "securityUpdates": e["SECURITY"] == "true"},
    "hostFiles": host_files,
    "files": dict(sorted(files.items())),
    "source": {"repository": "cloudgrange-deployment-installer", "commit": e["GIT_COMMIT"],
               "dirty": e["GIT_DIRTY"] == "true", "k3sInstallShSha256": e["INSTALL_SH_SHA"]},
}
with open(os.path.join(e["WORK"], updater.MANIFEST_NAME), "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
PY
MANIFEST="$WORK/foundation-release.json"
log "manifest written ($(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["files"]))' "$MANIFEST") pinned files)"

# ---- signing --------------------------------------------------------------------------------------
if [ -z "$KEY" ] && [ -n "${CLOUDGRANGE_FOUNDATION_SIGNING_KEY_PEM:-}" ]; then
    KEY="$WORK/signing.key"
    ( umask 077; printf '%s\n' "$CLOUDGRANGE_FOUNDATION_SIGNING_KEY_PEM" > "$KEY" )
fi
SIGNED=false
PUB="$WORK/signing.pub"
if [ -n "$KEY" ]; then
    [ -f "$KEY" ] || die "signing key $KEY not found"
    if grep -q 'SIGSTORE PRIVATE KEY' "$KEY"; then
        command -v cosign >/dev/null || die "$KEY is a cosign key and cosign is not installed"
        log "signing the manifest with cosign sign-blob ($KEY)"
        cosign public-key --key "$KEY" > "$PUB"
        cosign sign-blob --yes --tlog-upload=false --key "$KEY" --output-signature "$WORK/foundation-release.json.sig" "$MANIFEST" >/dev/null
    else
        log "signing the manifest with openssl ($KEY)"
        openssl pkey -in "$KEY" -pubout -out "$PUB" 2>/dev/null || die "$KEY is not a usable private key"
        openssl dgst -sha256 -sign "$KEY" -out "$WORK/foundation-release.json.sig" "$MANIFEST"
    fi
    # openssl wants DER; cosign writes base64 (the updater accepts both, decoded the same way).
    python3 -c '
import base64, re, sys
d = open(sys.argv[1], "rb").read(); s = d.strip()
open(sys.argv[2], "wb").write(base64.b64decode(s) if re.match(rb"^[A-Za-z0-9+/=\r\n]+$", s) else d)' \
        "$WORK/foundation-release.json.sig" "$WORK/sig.der"
    openssl dgst -sha256 -verify "$PUB" -signature "$WORK/sig.der" "$MANIFEST" >/dev/null \
        || die "the signature just made does not verify against its own public key"
    SIGNED=true
    # Hosts that check signatures do so with /etc/cloudgrange/foundation-signing-key.pub, which every
    # installer copies from cloudgrange-signing-key.pub. A signature they would reject is an error.
    if [ ! -f "$EXPECT_PUB" ] || grep -q PLACEHOLDER "$EXPECT_PUB"; then
        log "note: $EXPECT_PUB is the placeholder, so hosts cannot check this signature; they rely on the sha256"
    elif ! cmp -s <(openssl pkey -pubin -in "$EXPECT_PUB" -outform DER 2>/dev/null) <(openssl pkey -pubin -in "$PUB" -outform DER); then
        die "the signing key does not match $EXPECT_PUB: installed hosts would refuse this release"
    else
        log "signing key matches $EXPECT_PUB (the key installed hosts verify with)"
    fi
fi

# ---- zip (deterministic: fixed order, fixed mtimes, fixed modes, no directories, no symlinks) ------
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
NAME="cloudgrange-foundation-$VERSION.zip"
ZIP="$OUT/$NAME"
rm -f "$ZIP" "$ZIP.sha256"
export ZIP SIGNED
python3 - <<'PY'
import os, stat, time, zipfile
e = os.environ
stage, work = e["STAGE"], e["WORK"]
stamp = time.gmtime(max(int(e["EPOCH"]), 315532800))[:6]  # zip cannot store dates before 1980
entries = [(os.path.join(work, "foundation-release.json"), "foundation-release.json", 0o644)]
if e["SIGNED"] == "true":
    entries.append((os.path.join(work, "foundation-release.json.sig"), "foundation-release.json.sig", 0o644))
rels = []
for root, _dirs, names in os.walk(stage):
    for name in names:
        path = os.path.join(root, name)
        rels.append((os.path.relpath(path, stage).replace(os.sep, "/"), path))
for rel, path in sorted(rels):
    entries.append((path, rel, 0o755 if os.stat(path).st_mode & 0o111 else 0o644))
with zipfile.ZipFile(e["ZIP"], "w", zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as z:
    for path, arc, mode in entries:
        info = zipfile.ZipInfo(arc, date_time=stamp)
        info.external_attr = (stat.S_IFREG | mode) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        info.create_system = 3
        with open(path, "rb") as src, z.open(info, "w", force_zip64=True) as dst:
            for chunk in iter(lambda: src.read(4 << 20), b""):
                dst.write(chunk)
PY

# ---- self-check with the updater's own code -------------------------------------------------------
log "self-check: the updater's extract / load_manifest$([ "$SIGNED" = true ] && echo ' / verify_signature') over $NAME"
mkdir -p "$WORK/selfcheck"
CLOUDGRANGE_UPDATER_STATE="$WORK/selfcheck" CLOUDGRANGE_FOUNDATION_PUBKEY="$PUB" python3 - "$UPDATER" "$ZIP" "$SIGNED" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cg_updater", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
u = m.FoundationUpdater()
work = u.extract(sys.argv[2])
try:
    if sys.argv[3] == "true":
        u.verify_signature(work)
    manifest = u.load_manifest(work)
except m.UpdateError as err:
    sys.exit("[foundation-release] ERROR: the updater refuses this bundle: %s" % err)
print("[foundation-release] updater accepts the manifest: %s, K3s %s, %d pinned files, %d host files"
      % (manifest["version"], manifest["k3s"]["version"], len(manifest["files"]), len(manifest["hostFiles"])))
PY

(cd "$OUT" && sha256sum "$NAME" > "$NAME.sha256")
SHA=$(cut -d' ' -f1 "$ZIP.sha256")
BYTES=$(stat -c %s "$ZIP")
python3 - "$OUT/foundation-release-record.json" "$MANIFEST" <<PY
import json, sys
m = json.load(open(sys.argv[2]))
json.dump({"version": "$VERSION", "artifact": "$NAME", "sha256": "$SHA", "bytes": int("$BYTES"),
           "signed": "$SIGNED" == "true", "k3sVersion": m["k3s"]["version"],
           "supportedPlatformVersions": m["supportedPlatformVersions"], "requiresReboot": m["requiresReboot"],
           "sourceCommit": "$GIT_COMMIT", "sourceDateEpoch": int("$EPOCH")},
          open(sys.argv[1], "w"), indent=2, sort_keys=True)
open(sys.argv[1], "a").write("\n")
PY
cp "$MANIFEST" "$OUT/foundation-release.json"

log "$NAME  $BYTES bytes  sha256 $SHA"
if [ "$SIGNED" = true ]; then
    log "signed (foundation-release.json.sig), and trusted through its sha256 like every Foundation bundle"
else
    log "not signed (no key given): trusted through its sha256 and the manifest's per-file sha256 pins"
fi
log "publish with: scripts/release/Publish-FoundationRelease.sh --bundle $ZIP   (dry run; add --publish to upload)"
