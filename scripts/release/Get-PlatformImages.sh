#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (plan 2026-09-18 §6, E7) — every container image a Platform release can run, as the chart
# renders it. The one source for:
#   - images.txt, published with each release (New-PlatformRelease.sh): what a customer mirrors into
#     their own registry for an air-gapped bring-your-own-Kubernetes or AKS install;
#   - the images an offline Platform bundle carries (New-PlatformRelease.sh --offline-bundle).
# Derived from `helm template`, never hand-maintained, so it cannot drift from the chart. It renders
# the chart defaults and every values-*.yaml profile, each with every optional component switched on
# (promtail, the in-cluster air-gap registry, Redis and CloudNativePG through the multi-node profile),
# and adds the Platform updater's image, which is set in a ConfigMap because the API creates its Job.
# The separately installed vendor charts (cert-manager, CloudNativePG operator, MetalLB, Velero) are
# NOT Platform images and are not listed.
#
# Usage: Get-PlatformImages.sh <chart dir> [extra helm args, e.g. --set api.image.digest=...]
# Prints one reference per line, sorted, exactly as the chart renders it.
set -euo pipefail
CHART=${1:?usage: Get-PlatformImages.sh <chart dir> [helm args...]}; shift
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
KUBE=$(sed -n 's/^K3S_VERSION=//p' "$(cd "$(dirname "$0")/../.." && pwd)/release/pins.conf" | head -1)
ALL_ON=(--set observability.promtail.enabled=true --set observability.promtail.raiseInotifyLimits=true
        --set airgap.registry.enabled=true --set platformUpdater.enabled=true)
render() { helm template cg "$CHART" -n cloudgrange ${KUBE:+--kube-version "$KUBE"} "$@" >> "$WORK/all.yaml"; }
: > "$WORK/all.yaml"
render "${ALL_ON[@]}" "$@"
for f in "$CHART"/values-*.yaml; do
    # values-azure.yaml needs its AKS identifiers; placeholders are enough to render image names.
    render -f "$f" "${ALL_ON[@]}" --set global.aks.keyVaultName=kv --set global.aks.tenantId=t \
        --set global.aks.managedIdentityClientId=c "$@"
done
{
    grep -hoE '^[[:space:]]*(-[[:space:]]*)?(image|imageName):[[:space:]]*"?[^"'"'"' ]+' "$WORK/all.yaml" \
        | sed -E 's/^[[:space:]]*(-[[:space:]]*)?(image|imageName):[[:space:]]*"?//'
    sed -n 's/^[[:space:]]*CLOUDGRANGE_PLATFORM_UPDATER_IMAGE:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$WORK/all.yaml"
} | sort -u
