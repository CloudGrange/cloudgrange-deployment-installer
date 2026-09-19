#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9184/AB#9189 — Build Install-CloudGrange-K3s-Bundled.zip, the ONLY customer bundle.
# The Compose bundle and its builder (scripts/New-ReleaseBundle.sh) are retired: the
# parallel-support period the restructure plan called for is over, K3s/Helm is the only
# shipping engine, and this bundle now carries the offline payload that was the last
# remaining reason to keep the Compose one. Determinism: fixed file modes,
# SOURCE_DATE_EPOCH mtimes, C-locale sorted zip contents, so the same source tree and
# version produce a byte-identical zip regardless of build machine or time.
#
# AB#9189 — this bundle now has full offline/air-gapped parity with the Compose bundle:
# --images registry (the default) packages the pinned K3s binary, K3s's own airgap image
# tarball, and every container image the rendered chart actually references, so a host
# with no internet access can complete an --engine k3s install. The image list is derived
# from `helm template` rather than hand-maintained, so it cannot drift from the chart.
# Pass --images none for a smaller network-install-only bundle.
#
# Inputs:
#   --source DIR     an exported tree of one commit (git archive), not a working copy
#   --version V      platform version YYMM.MINOR.PATCH[-preview.N|-rc.N]; stamped into the
#                    bundled Chart.yaml (version/appVersion) and as global.image.tag
#   --out DIR        receives the zip, its .sha256, and the manifest
#   --images MODE    registry (default): pull+bundle every image for offline install;
#                    none: no images bundled (install pulls from the network)
set -euo pipefail

usage() { sed -n '5,20p' "$0" >&2; exit 2; }
SOURCE='' VERSION='' OUT='' IMAGES='registry'
while [ $# -gt 0 ]; do
    case "$1" in
        --source) SOURCE=$2; shift 2 ;;
        --version) VERSION=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        --images) IMAGES=$2; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$SOURCE" ] && [ -n "$VERSION" ] && [ -n "$OUT" ] || usage
case "$IMAGES" in registry|none) ;; *) echo "--images must be registry or none" >&2; exit 2 ;; esac
# AB#9171: the platform version scheme (pmo/decisions-2026-09-15/release-versioning.md), the same
# rule Publish-Release.sh and Set-ChartVersion.sh enforce. Never "latest", never a free-form label.
[[ "$VERSION" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(-(preview|rc)\.[0-9]+)?$ ]] || { echo "invalid version: $VERSION (want YYMM.MINOR.PATCH[-preview.N|-rc.N])" >&2; exit 1; }
SOURCE=$(cd "$SOURCE" && pwd)
PINS="$SOURCE/release"
EPOCH=${SOURCE_DATE_EPOCH:-$(tr -d '[:space:]' < "$PINS/SOURCE_DATE_EPOCH")}
[[ "$EPOCH" =~ ^[0-9]+$ ]] || { echo "invalid SOURCE_DATE_EPOCH" >&2; exit 1; }
export LC_ALL=C TZ=UTC
umask 022
log() { echo "[release-bundle-k3s] $*"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
B="$WORK/bundle"
mkdir -p "$B/scripts" "$B/charts"

log "installer + charts from $SOURCE"
cp "$SOURCE/Install-CloudGrange-Linux.sh" "$B/Install-CloudGrange-Linux.sh"
cp "$SOURCE/scripts/Install-CloudGrangeK3s.sh" "$SOURCE/scripts/New-ArtifactManifest.sh" "$B/scripts/"
# AB#9189 — the in-app updater must ship IN the bundle: Install-CloudGrangeK3s.sh installs it from
# here, and without it a K3s install has no update path short of a reinstall.
cp "$SOURCE/scripts/cloudgrange-updater-k3s.py" "$B/scripts/"
mkdir -p "$B/appliance"
cp "$SOURCE/appliance/cloudgrange-updater-k3s.service" "$B/appliance/"
# AB#9171: the key Foundation releases are verified against (installed to /etc/cloudgrange by the installer).
cp "$SOURCE/cloudgrange-signing-key.pub" "$B/cloudgrange-signing-key.pub"
cp -r "$SOURCE/charts/cloudgrange" "$B/charts/cloudgrange"
mkdir -p "$B/charts/vendor"
cp "$SOURCE/charts/vendor/"*.tgz "$B/charts/vendor/"
rm -f "$B/charts/cloudgrange/Chart.lock"
find "$B/charts/cloudgrange/charts" -maxdepth 1 -name '*.tgz' -delete

log "stamping platform version $VERSION into the chart (Chart.yaml version/appVersion, first-party image tag)"
# AB#9171: Chart.yaml carries the platform version; the first-party image tag defaults to appVersion.
bash "$SOURCE/scripts/release/Set-ChartVersion.sh" "$B/charts/cloudgrange" "$VERSION"
# The explicit values tag is kept as well: the host updater (cloudgrange-updater-k3s.py bundle_version)
# still reads the bundle version from the first `tag:` line of values.yaml.
python3 - "$B/charts/cloudgrange/values.yaml" "$VERSION" <<'PY'
import sys, re
path, version = sys.argv[1], sys.argv[2]
text = open(path).read()
text = re.sub(r'(\n\s+tag:\s*).*', rf'\g<1>{version}', text, count=1)
open(path, "w").write(text)
PY

if [ "$IMAGES" = registry ]; then
    K3S_VERSION=$(sed -n 's/^K3S_VERSION=//p' "$PINS/pins.conf" | tr -d '[:space:]')
    [[ "$K3S_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || { echo "K3S_VERSION missing or malformed in release/pins.conf" >&2; exit 1; }
    log "air-gap payload: k3s $K3S_VERSION + every image the rendered chart references"
    A="$B/airgap"
    mkdir -p "$A"
    k3s_url="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION//+/%2B}"
    curl -sfL "$k3s_url/k3s" -o "$A/k3s"
    curl -sfL "$k3s_url/k3s-airgap-images-amd64.tar" -o "$A/k3s-airgap-images-amd64.tar"
    curl -sfL "$k3s_url/sha256sum-amd64.txt" -o "$WORK/k3s-sha256sum.txt"
    # K3s publishes one checksum file covering every asset; check our two against it
    # rather than trusting the download, then emit per-file .sha256 the installer verifies.
    (cd "$A" && grep -E ' (k3s|k3s-airgap-images-amd64\.tar)$' "$WORK/k3s-sha256sum.txt" | sed 's| .*/| |' | sha256sum -c -)
    (cd "$A" && sha256sum k3s > k3s.sha256 && sha256sum k3s-airgap-images-amd64.tar > k3s-airgap-images-amd64.tar.sha256)
    # AB#9171: K3s's install.sh as of the PINNED tag, not whatever get.k3s.io serves on the day the
    # bundle is built (the same script also performs the Foundation updater's K3s upgrades). It is
    # checked against K3S_INSTALL_SH_SHA256 in release/pins.conf, then given the per-file .sha256
    # that Install-CloudGrangeK3s.sh verifies on the target.
    K3S_INSTALL_SH_SHA256=$(sed -n 's/^K3S_INSTALL_SH_SHA256=//p' "$PINS/pins.conf" | tr -d '[:space:]')
    [[ "$K3S_INSTALL_SH_SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "K3S_INSTALL_SH_SHA256 missing or malformed in release/pins.conf" >&2; exit 1; }
    curl -sfL "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION//+/%2B}/install.sh" -o "$A/k3s-install.sh"
    echo "$K3S_INSTALL_SH_SHA256  $A/k3s-install.sh" | sha256sum -c - >/dev/null \
        || { echo "k3s install.sh does not match K3S_INSTALL_SH_SHA256 in release/pins.conf" >&2; exit 1; }
    (cd "$A" && sha256sum k3s-install.sh > k3s-install.sh.sha256)

    # AB#9171: Helm too. Install-CloudGrangeK3s.sh installs it from here when the host has none, and
    # without it an offline install died at its very first stage fetching get.helm.sh.
    HELM_VERSION=$(sed -n 's/^HELM_VERSION=//p' "$PINS/pins.conf" | tr -d '[:space:]')
    HELM_SHA=$(sed -n 's/^HELM_LINUX_AMD64_SHA256=//p' "$PINS/pins.conf" | tr -d '[:space:]')
    [[ "$HELM_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$HELM_SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "HELM_VERSION/HELM_LINUX_AMD64_SHA256 missing or malformed in release/pins.conf" >&2; exit 1; }
    helm_tar="helm-${HELM_VERSION}-linux-amd64.tar.gz"
    curl -sfL "https://get.helm.sh/${helm_tar}" -o "$A/${helm_tar}"
    printf '%s  %s\n' "$HELM_SHA" "$helm_tar" > "$A/${helm_tar}.sha256sum"
    (cd "$A" && sha256sum -c "${helm_tar}.sha256sum")

    # Derive the image list from the rendered chart -- never a hand-maintained list, which
    # would silently drift the moment a subchart changes an image. cert-manager is rendered
    # separately because Install-CloudGrangeK3s.sh installs it as its own release first.
    helm template cloudgrange "$B/charts/cloudgrange" -f "$B/charts/cloudgrange/values-single-node.yaml" \
        > "$WORK/rendered.yaml"
    helm template cert-manager "$B/charts/vendor/cert-manager-v1.21.2.tgz" --set crds.enabled=true \
        >> "$WORK/rendered.yaml"
    grep -hoE '^\s+image:\s*"?[^"'"'"' ]+' "$WORK/rendered.yaml" \
        | sed -E 's/^\s+image:\s*"?//' | sort -u > "$WORK/images.txt"
    [ -s "$WORK/images.txt" ] || { echo "no images found in rendered chart" >&2; exit 1; }
    log "$(wc -l < "$WORK/images.txt") images to bundle"
    # AB#9171: the image payload is fetched and exported by the PINNED K3s's own containerd, in a
    # fresh throwaway container, never taken from the build host's Docker. preview.10 shipped four
    # cert-manager v1.21.2 images with their linux/amd64 manifest but without its config and most of
    # its layers (the owner's install died at `k3s ctr images import`: "content digest
    # sha256:6a68bd9d...: not found"). The build host's Docker (containerd image store) held image
    # records whose layer blobs were gone; `docker pull` did not restore them (the unpacked
    # snapshots already existed, so nothing was re-fetched), `docker save --platform linux/amd64`
    # refused the image, and plain `docker save` exported it anyway -- two blobs, exit 0. A fresh
    # containerd has no snapshots and no stale content: `content fetch` downloads every linux/amd64
    # blob, and `images export` cannot write an image it does not fully have. It also keeps each
    # vendor image's multi-arch index as the top-level digest, so the chart's @sha256 pins stay valid.
    K3S_IMAGE="rancher/k3s:${K3S_VERSION/+/-}"
    CTR_SOCK=/run/k3s/containerd/containerd.sock
    CTR_NAME="cg-release-images-$$-$RANDOM"
    docker image inspect "$K3S_IMAGE" >/dev/null 2>&1 || docker pull -q "$K3S_IMAGE" >/dev/null
    trap 'docker rm -f "$CTR_NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
    docker run -d --name "$CTR_NAME" --privileged --entrypoint /bin/containerd "$K3S_IMAGE" \
        --address "$CTR_SOCK" --root /var/lib/rancher/k3s/agent/containerd --state /run/k3s/containerd >/dev/null
    kctr() { docker exec "$CTR_NAME" ctr --address "$CTR_SOCK" -n k8s.io "$@"; }
    for _ in $(seq 1 60); do kctr version >/dev/null 2>&1 && break; sleep 2; done
    kctr version >/dev/null
    # One line per chart image: the fully qualified reference to fetch, then every name the chart
    # needs it under (repo:tag, plus repo@sha256:<digest> when pinned) -- the same rules the
    # structural gate checks. ctr does not expand Docker short names, hence the qualification.
    python3 - "$SOURCE/scripts/release/Test-ImageTarComplete.py" "$WORK/images.txt" > "$WORK/fetch.txt" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gate", sys.argv[1])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
for ref in (l.strip() for l in open(sys.argv[2])):
    if ref:
        print(gate.normalize(ref), *gate.expected_names(ref))
PY
    : > "$WORK/export-names.txt"
    while read -r ref names; do
        kctr content fetch --platform linux/amd64 "$ref" >/dev/null
        # shellcheck disable=SC2086 # $names is a space-separated list by construction
        [ "$names" = "$ref" ] || kctr images tag --force "$ref" $names >/dev/null
        printf '%s\n' $names >> "$WORK/export-names.txt"
    done < "$WORK/fetch.txt"
    xargs -a "$WORK/export-names.txt" docker exec "$CTR_NAME" ctr --address "$CTR_SOCK" -n k8s.io \
        images export --platform linux/amd64 - > "$WORK/images-raw.tar"
    docker rm -f "$CTR_NAME" >/dev/null
    # The export's entry order is not fixed; repack sorted with fixed owners/modes/mtimes so the
    # same inputs give a byte-identical bundle.
    mkdir -p "$WORK/img" && tar -xf "$WORK/images-raw.tar" -C "$WORK/img"
    # AB#9171: give every digest-pinned image a repo@sha256 name too, or containerd cannot resolve
    # the chart's repo:tag@sha256 reference offline (proven on kind: ImagePullBackOff without it).
    python3 "$SOURCE/scripts/release/Add-DigestImageNames.py" "$WORK/img" "$WORK/images.txt"
    # Both files carry a LIST of entries whose order docker save does not fix; sorting the
    # keys alone is not enough -- the list itself has to be sorted or two runs over the same
    # images produce different bytes.
    for j in "$WORK/img/manifest.json" "$WORK/img/index.json"; do
        [ -f "$j" ] || continue
        python3 - "$j" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
if isinstance(data, list):
    data.sort(key=lambda e: json.dumps(e, sort_keys=True))
elif isinstance(data, dict) and isinstance(data.get("manifests"), list):
    data["manifests"].sort(key=lambda e: json.dumps(e, sort_keys=True))
json.dump(data, open(path, "w"), indent=None, sort_keys=True)
PY
    done
    # AB#9171: structural gate -- every named image's linux/amd64 manifest, config and layers are in
    # the layout, and every chart image is named (repo:tag and, when pinned, repo@sha256).
    python3 "$SOURCE/scripts/release/Test-ImageTarComplete.py" "$WORK/img" "$WORK/images.txt"
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$EPOCH" \
        -cf "$A/cloudgrange-images-amd64.tar" -C "$WORK/img" .
    (cd "$A" && sha256sum cloudgrange-images-amd64.tar > cloudgrange-images-amd64.tar.sha256)
    cp "$WORK/images.txt" "$A/images.txt"
    rm -rf "$WORK/img" "$WORK/images-raw.tar"
    # AB#9171: release gate -- import the finished tarball into the pinned K3s's containerd with no
    # network, as the installer does, and resolve every chart image through CRI. Read-only mount, so
    # the bundle bytes (and reproducibility) are untouched. No skip switch: a bundle whose images
    # have not been imported offline is not a releasable bundle.
    bash "$SOURCE/scripts/release/Test-AirgapImageImport.sh" "$A/cloudgrange-images-amd64.tar" "$A/images.txt" "$K3S_VERSION"
fi

log "artifact manifest (AB#9182 — plain SHA-256, not signed)"
SOURCE_DATE_EPOCH="$EPOCH" bash "$SOURCE/scripts/New-ArtifactManifest.sh" "$B/charts/manifest.json" >/dev/null

log "SHA256SUMS"
(cd "$B" && find . -type f ! -path ./SHA256SUMS | sort | while IFS= read -r f; do sha256sum "$f" | sed 's|  \./|  |'; done) > "$WORK/SHA256SUMS"
mv "$WORK/SHA256SUMS" "$B/SHA256SUMS"

log "normalize modes and timestamps (SOURCE_DATE_EPOCH=$EPOCH)"
chmod -R u=rwX,go=rX "$B"
chmod u+x "$B/Install-CloudGrange-Linux.sh" "$B/scripts/"*.sh
find "$B" -exec touch -h -d "@$EPOCH" {} +

mkdir -p "$OUT"
ZIP="$OUT/Install-CloudGrange-K3s-Bundled.zip"
rm -f "$ZIP" "$ZIP.sha256"
(cd "$B" && find . -type f | sort | sed 's|^\./||' | zip -X -D -q -@ "$ZIP")
(cd "$OUT" && sha256sum Install-CloudGrange-K3s-Bundled.zip > Install-CloudGrange-K3s-Bundled.zip.sha256)
bundle_sha=$(awk '{print $1}' "$ZIP.sha256")
bundle_bytes=$(stat -c %s "$ZIP")

python3 - "$OUT/release-record-k3s.json" <<PY
import json, sys
record = {
    "version": "$VERSION",
    "sourceDateEpoch": int("$EPOCH"),
    "artifacts": {"Install-CloudGrange-K3s-Bundled.zip": {"sha256": "$bundle_sha", "bytes": int("$bundle_bytes")}},
    "images": "$IMAGES",
    "offlineCapable": "$IMAGES" == "registry",
}
json.dump(record, open(sys.argv[1], "w"), indent=2, sort_keys=True)
open(sys.argv[1], "a").write("\n")
PY
log "Install-CloudGrange-K3s-Bundled.zip $bundle_bytes bytes sha256 $bundle_sha"
