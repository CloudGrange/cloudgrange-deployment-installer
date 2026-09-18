#!/bin/bash
# Render the chart the way each delivery path actually installs it, and report how the updates
# directory is backed. The owner's requirement is that the same code works on every path:
#   helm on an existing cluster / VHDX / Windows VM script / Linux script / AKS / Azure VM.
cd "$(dirname "$0")/../.." || exit 1

check() {
  local label=$1; shift
  local out
  out=$(helm template cg charts/cloudgrange "$@" 2>/dev/null)
  local host pvc
  host=$(printf '%s' "$out" | grep -c 'path: "/var/lib/cloudgrange/updates"')
  pvc=$(printf '%s' "$out" | grep -c 'claimName: "cg-api-updates"')
  printf '%-34s hostPath=%s  updatesPVC=%s\n' "$label" "$host" "$pvc"
}

echo "=== how the updates directory is backed, per delivery path ==="
check "BYO helm (chart defaults)"
check "VHDX / Windows / Linux script"  -f charts/cloudgrange/values-single-node.yaml
check "AKS"                            -f charts/cloudgrange/values-azure.yaml
check "multi-node"                     -f charts/cloudgrange/values-multi-node.yaml

echo
echo "=== every profile must render and lint ==="
for f in "" charts/cloudgrange/values-single-node.yaml charts/cloudgrange/values-azure.yaml charts/cloudgrange/values-multi-node.yaml; do
  if [ -z "$f" ]; then
    helm lint charts/cloudgrange >/dev/null 2>&1 && echo "lint OK   : chart defaults" || echo "lint FAIL : chart defaults"
  else
    helm lint charts/cloudgrange -f "$f" >/dev/null 2>&1 && echo "lint OK   : $f" || echo "lint FAIL : $f"
  fi
done
