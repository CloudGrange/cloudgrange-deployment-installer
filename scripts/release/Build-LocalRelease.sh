#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — Local, unsigned CloudGrange platform release build for lab previews.
# Builds the api, portal and relay images from the sibling repository checkouts, then packages the offline release
# bundle (the in-app update) in the layout release-bundle.yml produces: installer scripts, compose with digest-pinned
# images, the saved image archive, the pinned Ubuntu image, the pinned Docker CE packages and SHA256SUMS.
# Version format: docs follow pmo release versioning (YYMM.MINOR.PATCH with -preview.N / -rc.N).
#
# Run as root in WSL with Docker. Private NuGet packages are restored with CG_PKG_TOKEN when it is set (never written
# outside a temporary directory that is removed on exit).
#
# Usage:
#   Build-LocalRelease.sh --version 2609.0.0-preview.3 --repos-root /mnt/d/git/CloudGrange \
#     --assets-dir <dir with ubuntu/noble-server-cloudimg-amd64.img and docker-debs/> --out <output dir>
set -euo pipefail

VERSION=""; ROOT=""; ASSETS=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION=$2; shift 2 ;;
    --repos-root) ROOT=$2; shift 2 ;;
    --assets-dir) ASSETS=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$VERSION" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(-(preview|rc)\.[0-9]+)?$ ]] || { echo "--version must be YYMM.MINOR.PATCH[-preview.N|-rc.N]" >&2; exit 2; }
for d in "$ROOT" "$ASSETS"; do [ -d "$d" ] || { echo "missing directory: $d" >&2; exit 2; }; done
[ -n "$OUT" ] || { echo "--out is required" >&2; exit 2; }
for f in "$ASSETS/ubuntu/noble-server-cloudimg-amd64.img" "$ASSETS/docker-debs/SHA256SUMS" "$ASSETS/docker-debs/versions.txt"; do
  [ -f "$f" ] || { echo "missing asset: $f" >&2; exit 2; }
done

INSTALLER="$ROOT/cloudgrange-deployment-installer"
WORK=$(mktemp -d /root/cloudgrange-release.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT/logs"
git_() { git -c safe.directory='*' "$@"; }

secret=()
if [ -n "${CG_PKG_TOKEN:-}" ]; then
  (umask 077; printf '%s' "$CG_PKG_TOKEN" > "$WORK/nuget_token")
  secret=(--secret "id=nuget_token,src=$WORK/nuget_token")
fi

build_image() { # <service> <repository>
  local svc=$1 repo=$2 ctx="$WORK/ctx-$1"
  mkdir -p "$ctx"
  if [ -n "$(git_ -C "$ROOT/$repo" status --porcelain)" ]; then echo "WARNING: $repo has uncommitted changes; they are included" >&2; fi
  tar --exclude=.git --exclude='*/bin' --exclude='*/obj' --exclude=node_modules --exclude=dist -C "$ROOT/$repo" -cf - . | tar -xf - -C "$ctx"
  if (cd "$ctx" && docker buildx build --progress=plain --load "${secret[@]}" -t "ghcr.io/cloudgrange/cloudgrange-$svc:$VERSION" .) > "$OUT/logs/image-$svc.log" 2>&1; then
    echo "image $svc $(docker image inspect -f '{{.Id}}' "ghcr.io/cloudgrange/cloudgrange-$svc:$VERSION" | cut -c1-19) from $repo@$(git_ -C "$ROOT/$repo" rev-parse --short HEAD)"
  else
    echo "image $svc FAILED (log: $OUT/logs/image-$svc.log)" >&2
    tail -15 "$OUT/logs/image-$svc.log" >&2
    exit 1
  fi
}

build_image api cloudgrange-platform-api
build_image portal cloudgrange-portal
build_image relay cloudgrange-runtime-relay
rm -f "$WORK/nuget_token"

B="$WORK/bundle"
mkdir -p "$B/docs" "$B/docker-debs"
cd "$INSTALLER"
cp Install-CloudGrange.ps1 verify-bundle.ps1 New-SelfSignedCert.ps1 Uninstall-CloudGrange.ps1 Update-CloudGrange.ps1 "$B/"
cp -r scripts/ "$B/scripts/"
cp -r compose/ "$B/compose/"
for d in docs/prerequisites.md docs/product-installer-design.md docs/appliance-operator-access.md; do [ -f "$d" ] && cp "$d" "$B/docs/"; done
rm -f "$B/compose/.env"
find "$B" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.service' -o -name '*.yml' -o -name '*.conf' \) -exec sed -i 's/\r$//' {} +
sha256sum Install-CloudGrange.ps1 | awk '{print toupper($1)"  Install-CloudGrange.ps1"}' > "$B/cloudgrange-installer.sha256"

bash "$INSTALLER/scripts/Set-FirstPartyImagePins.sh" "$B/compose/docker-compose.yml" "$VERSION"
bash "$INSTALLER/scripts/Test-ComposeImagePins.sh" "$B/compose" > "$WORK/images.txt"
python3 "$INSTALLER/scripts/Test-ComposeHardening.py" "$B/compose" | tail -1

: > "$WORK/save.txt"
while read -r img; do
  named="${img%@sha256:*}"
  case "$img" in
    ghcr.io/cloudgrange/*) ;;
    *) docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null ;;
  esac
  docker tag "$img" "$named"
  echo "$named" >> "$WORK/save.txt"
done < "$WORK/images.txt"
xargs -a "$WORK/save.txt" docker save -o "$B/cloudgrange-images.tar"
cp "$WORK/images.txt" "$B/images.txt"
cp "$ASSETS/ubuntu/noble-server-cloudimg-amd64.img" "$B/ubuntu-24.04-cloudimg.img"
cp -r "$ASSETS/docker-debs/debs" "$ASSETS/docker-debs/SHA256SUMS" "$ASSETS/docker-debs/versions.txt" "$B/docker-debs/"
(cd "$B/docker-debs/debs" && sha256sum -c --quiet ../SHA256SUMS)

# Only the top-level manifest is excluded: nested SHA256SUMS files are bundle content (the updater checks the exact set).
cd "$B"
find . -type f ! -path ./SHA256SUMS | sort | while IFS= read -r f; do sha256sum "$f" | sed 's|  \./|  |'; done > SHA256SUMS

rm -f "$OUT/Install-CloudGrange-Bundled.zip" "$OUT/Install-CloudGrange-Bundled.zip.sha256"
zip -qr "$OUT/Install-CloudGrange-Bundled.zip" .
(cd "$OUT" && sha256sum Install-CloudGrange-Bundled.zip > Install-CloudGrange-Bundled.zip.sha256)
echo "BUNDLE $VERSION $(stat -c %s "$OUT/Install-CloudGrange-Bundled.zip") bytes sha256 $(cut -d' ' -f1 "$OUT/Install-CloudGrange-Bundled.zip.sha256")"
