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
  local empty; empty=$(printf '%s' "$out" | grep -c 'name: platform-updates, emptyDir')
  printf '%-34s hostPath=%s  updatesPVC=%s\n' "$label" "$host" "$pvc"
}

echo "=== how the updates directory is backed, per delivery path ==="
check "BYO helm (chart defaults)"
check "VHDX / Windows / Linux script"  -f charts/cloudgrange/values-single-node.yaml
check "AKS"                            -f charts/cloudgrange/values-azure.yaml
check "multi-node"                     -f charts/cloudgrange/values-multi-node.yaml

echo
echo "=== update trust per delivery path: HTTPS + digest pinning, no signing key (2026-09-18) ==="
for f in "" charts/cloudgrange/values-single-node.yaml charts/cloudgrange/values-azure.yaml charts/cloudgrange/values-multi-node.yaml; do
  args=(); [ -n "$f" ] && args=(-f "$f")
  out=$(helm template cg charts/cloudgrange "${args[@]}" 2>/dev/null)
  ch=$(printf '%s' "$out" | sed -n 's/^  channelUrl: "\(.*\)"$/\1/p' | head -1)
  key=$(printf '%s' "$out" | grep -c 'name: cg-platform-updater-signing')
  label=${f:-chart defaults}
  if [[ "$ch" == https://* ]] && [ "$key" = 0 ]; then echo "trust OK  : $label  channel=$ch  signing key required=no"
  else echo "trust FAIL: $label  channel=${ch:-none}  signingConfigMap=$key"; fi
done

echo
echo "=== every profile must render and lint ==="
for f in "" charts/cloudgrange/values-single-node.yaml charts/cloudgrange/values-azure.yaml charts/cloudgrange/values-multi-node.yaml; do
  if [ -z "$f" ]; then
    helm lint charts/cloudgrange >/dev/null 2>&1 && echo "lint OK   : chart defaults" || echo "lint FAIL : chart defaults"
  else
    helm lint charts/cloudgrange -f "$f" >/dev/null 2>&1 && echo "lint OK   : $f" || echo "lint FAIL : $f"
  fi
done

echo
echo "=== no latest / unpinned versions in shipped artifacts (AB#9171 B5) ==="
bash test/lint-pins.sh >/dev/null 2>/tmp/lint-pins.err && echo "pins OK    : test/lint-pins.sh" || { echo "pins FAIL  : test/lint-pins.sh"; cat /tmp/lint-pins.err; }
