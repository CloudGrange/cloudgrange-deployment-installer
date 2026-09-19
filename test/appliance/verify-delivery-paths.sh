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

echo
echo "=== air-gapped installs and updates (AB#9171 E7) ==="
# BYO / AKS: one value moves EVERY image (first-party, third-party, digest-pinned, the updater Job's)
# to the customer's mirror. Anything still pointing elsewhere would be pulled from the internet.
mirror_check() {
  local label=$1; shift
  local out refs stray
  out=$(helm template cg charts/cloudgrange -n cloudgrange --set global.imageRegistry=mirror.test/cg \
        --set observability.promtail.enabled=true --set airgap.registry.enabled=true "$@" 2>&1) \
    || { echo "mirror FAIL: $label: helm template failed: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"; return; }
  refs=$( { printf '%s\n' "$out" | grep -oE '^[[:space:]]*(-[[:space:]]*)?(image|imageName):[[:space:]]*"?[^"'"'"' ]+' \
              | sed -E 's/^[[:space:]]*(-[[:space:]]*)?(image|imageName):[[:space:]]*"?//';
            printf '%s\n' "$out" | sed -n 's/^[[:space:]]*CLOUDGRANGE_PLATFORM_UPDATER_IMAGE:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p'; } | sort -u)
  stray=$(printf '%s\n' "$refs" | grep -v '^mirror\.test/cg/' || true)
  if [ -n "$refs" ] && [ -z "$stray" ]; then
    printf 'mirror OK  : %-32s %s images, all under global.imageRegistry\n' "$label" "$(printf '%s\n' "$refs" | grep -c .)"
  else
    echo "mirror FAIL: $label: not rewritten: $(printf '%s' "$stray" | tr '\n' ' ')"
  fi
}
mirror_check "BYO helm (chart defaults)"
mirror_check "AKS"         -f charts/cloudgrange/values-azure.yaml --set global.aks.keyVaultName=kv --set global.aks.tenantId=t --set global.aks.managedIdentityClientId=c
mirror_check "multi-node"  -f charts/cloudgrange/values-multi-node.yaml
# Managed foundations: the in-cluster registry exists only in offline mode (the wrapper turns it on),
# never on a cluster CloudGrange did not provision; the bundles volume exists on every Kubernetes path.
registry_check() {
  local label=$1 want=$2; shift 2
  local out has env pvc
  out=$(helm template cg charts/cloudgrange -n cloudgrange "$@" 2>/dev/null)
  has=$(printf '%s' "$out" | grep -c 'name: cg-airgap-registry$')
  env=$(printf '%s' "$out" | grep -c 'CLOUDGRANGE_AIRGAP_REGISTRY: "cg-airgap-registry-push.cloudgrange.svc:5001"')
  pvc=$(printf '%s' "$out" | grep -c 'name: cg-platform-bundles$')
  if { [ "$want" = on ] && [ "$has" -gt 0 ] && [ "$env" = 1 ]; } || { [ "$want" = off ] && [ "$has" = 0 ] && [ "$env" = 0 ]; }; then
    printf 'airgap OK  : %-32s in-cluster registry %-3s bundlesPVC=%s\n' "$label" "$want" "$pvc"
  else
    printf 'airgap FAIL: %-32s want registry %s, got objects=%s env=%s\n' "$label" "$want" "$has" "$env"
  fi
}
registry_check "BYO helm (chart defaults)"        off
registry_check "VHDX / Windows / Linux (online)"  off -f charts/cloudgrange/values-single-node.yaml
registry_check "VHDX / Windows / Linux (offline)" on  -f charts/cloudgrange/values-single-node.yaml --set airgap.registry.enabled=true
registry_check "AKS"                              off -f charts/cloudgrange/values-azure.yaml --set global.aks.keyVaultName=kv --set global.aks.tenantId=t --set global.aks.managedIdentityClientId=c
