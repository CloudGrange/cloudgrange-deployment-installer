#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — release gate: import the air-gap image tarball into the PINNED K3s's own containerd,
# with no network, exactly as Install-CloudGrangeK3s.sh does on a customer host, and fail the
# release unless every image imports and every image the chart references resolves locally.
#
# preview.10 shipped a tarball that `k3s ctr images import` rejected on the owner's server
# ("content digest sha256:6a68bd9d…: not found", cert-manager-cainjector's config blob); nothing in
# the release had ever imported it. Test-ImageTarComplete.py catches that class structurally; this
# proves it against the real importer.
#
# How: a throwaway rancher/k3s:<pinned K3S_VERSION> container (unique name, removed on exit) runs
# the containerd embedded in that K3s binary on K3s's own socket path, with --network none. Then:
#   1. ctr -n k8s.io images import --platform linux/amd64 <tarball>      (must exit 0)
#   2. ctr -n k8s.io images check                                         (every image "complete")
#   3. crictl inspecti <ref> for every line of images.txt — the CRI lookup the kubelet does, so a
#      repo:tag@sha256:… reference must resolve through its repo@sha256 name, offline.
#
# Usage: Test-AirgapImageImport.sh <cloudgrange-images-amd64.tar> <images.txt> <K3S_VERSION e.g. v1.36.4+k3s1>
# Needs: docker. Pulls rancher/k3s:<version> if it is not already present (the only network use).
set -euo pipefail

[ $# -eq 3 ] || { sed -n '4,22p' "$0" >&2; exit 2; }
TAR=$(readlink -f "$1") REFS=$(readlink -f "$2") K3S_VERSION=$3
[ -f "$TAR" ] && [ -f "$REFS" ] || { echo "missing $TAR or $REFS" >&2; exit 2; }
[[ "$K3S_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || { echo "bad K3S_VERSION: $K3S_VERSION" >&2; exit 2; }
IMAGE="rancher/k3s:${K3S_VERSION/+/-}"
SOCK=/run/k3s/containerd/containerd.sock
log() { echo "[airgap-import-gate] $*"; }

docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null
N="cg-airgap-import-gate-$$-$RANDOM"
trap 'docker rm -f "$N" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$N" --privileged --network none --entrypoint /bin/containerd \
    -v "$TAR:/airgap/images.tar:ro" -v "$REFS:/airgap/images.txt:ro" "$IMAGE" \
    --address "$SOCK" --root /var/lib/rancher/k3s/agent/containerd --state /run/k3s/containerd >/dev/null
for _ in $(seq 1 60); do
    docker exec "$N" ctr --address "$SOCK" version >/dev/null 2>&1 && break
    sleep 2
done
docker exec "$N" ctr --address "$SOCK" version >/dev/null || { docker logs "$N" 2>&1 | tail -20 >&2; echo "containerd in $IMAGE did not start" >&2; exit 1; }
log "containerd $(docker exec "$N" ctr --address "$SOCK" version | sed -n 's/^ *Version: *//p' | tail -1) from $IMAGE, no network"

log "ctr images import --platform linux/amd64 $(basename "$TAR")"
if ! docker exec "$N" ctr --address "$SOCK" -n k8s.io images import --platform linux/amd64 /airgap/images.tar; then
    echo "FAIL: the image tarball does not import into K3s $K3S_VERSION containerd" >&2
    exit 1
fi

fail=0
incomplete=$(docker exec "$N" ctr --address "$SOCK" -n k8s.io images check | awk 'NR > 1 && $0 !~ /[[:space:]]complete \(/ {print}')
if [ -n "$incomplete" ]; then
    echo "FAIL: imported images with missing content:" >&2
    echo "$incomplete" >&2
    fail=1
fi

log "resolving every chart image through CRI (what the kubelet asks), offline"
# K3s's crictl reads its endpoint from the agent's crictl.yaml, as on an installed host.
docker exec "$N" sh -c "mkdir -p /var/lib/rancher/k3s/agent/etc && printf 'runtime-endpoint: unix://$SOCK\nimage-endpoint: unix://$SOCK\n' > /var/lib/rancher/k3s/agent/etc/crictl.yaml"
n=0
while read -r ref; do
    [ -n "$ref" ] || continue
    n=$((n + 1))
    if ! docker exec "$N" crictl inspecti -q "$ref" >/dev/null 2>&1; then
        echo "FAIL: $ref does not resolve from containerd" >&2
        fail=1
    fi
done < "$REFS"
[ "$fail" -eq 0 ] || exit 1
log "PASS: $(docker exec "$N" ctr --address "$SOCK" -n k8s.io images ls -q | wc -l) image names imported, all complete; $n/$n chart images resolve offline"
