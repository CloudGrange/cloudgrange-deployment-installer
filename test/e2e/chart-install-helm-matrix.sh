#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — the chart must install and upgrade with Helm 3 AND Helm 4, with chart defaults, on a
# cluster CloudGrange did not build (BYO). A real `helm install --wait` with Helm v4.2.1 hung until
# its timeout: Helm 4 waits for hook resources to become Current, and a hook PVC on a
# WaitForFirstConsumer StorageClass never does. This gate installs and then upgrades (--reset-then-reuse-values,
# the flag the in-cluster updater uses)
# the chart on a throwaway kind cluster under each Helm binary it is given, and fails unless every
# run reaches STATUS: deployed with all pods Ready.
#
# Usage: test/e2e/chart-install-helm-matrix.sh <chart.tgz|chart dir> [helm-binary...]
#   default binaries: every one of `helm` and `helm4` found on PATH (need at least one v3 and one v4
#   for the gate to mean anything; the run says which versions it covered).
# Needs docker, kind, kubectl. Creates and deletes ONLY kind clusters named cg-helm-matrix-<n>.
set -uo pipefail
CHART=${1:?usage: chart-install-helm-matrix.sh <chart> [helm...]}; shift
BINS=("$@")
[ ${#BINS[@]} -gt 0 ] || for b in helm helm4; do command -v "$b" >/dev/null && BINS+=("$b"); done
[ ${#BINS[@]} -gt 0 ] || { echo "no helm binary found" >&2; exit 2; }
W=$(mktemp -d /tmp/cg-helm-matrix.XXXX); FAIL=0; n=0; COVERED=()
for H in "${BINS[@]}"; do
    n=$((n + 1)); CL=cg-helm-matrix-$n; export KUBECONFIG=$W/kc-$n
    ver=$("$H" version --short 2>/dev/null); COVERED+=("$ver")
    kind delete cluster --name $CL --kubeconfig $KUBECONFIG >/dev/null 2>&1
    kind create cluster --name $CL --kubeconfig $KUBECONFIG --wait 180s >/dev/null 2>&1 || { echo "FAIL $ver: kind"; FAIL=1; continue; }
    kubectl create namespace cloudgrange >/dev/null
    for step in install upgrade; do
        args=(install cloudgrange "$CHART" -n cloudgrange --set global.hostname=cg.matrix.local)
        [ $step = upgrade ] && args=(upgrade cloudgrange "$CHART" -n cloudgrange --reset-then-reuse-values)
        start=$(date +%s)
        if timeout 1200 "$H" "${args[@]}" --wait --timeout 15m > "$W/$n-$step.log" 2>&1 \
           && grep -q "STATUS: deployed" "$W/$n-$step.log" \
           && kubectl -n cloudgrange wait --for=condition=Ready pod -l 'app.kubernetes.io/name' --field-selector=status.phase!=Succeeded --timeout=300s >/dev/null; then
            echo "PASS $ver: $step in $(( $(date +%s) - start ))s"
        else
            echo "FAIL $ver: $step ($W/$n-$step.log)"; tail -3 "$W/$n-$step.log"; FAIL=1
        fi
    done
    kind delete cluster --name $CL --kubeconfig $KUBECONFIG >/dev/null 2>&1
done
echo "covered: ${COVERED[*]}"
exit $FAIL
