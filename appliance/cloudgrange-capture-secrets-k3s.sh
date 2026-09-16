#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9186 — K3s/Helm counterpart to cloudgrange-capture-secrets.sh. Prints the source
# VM's install-time secret values, base64-encoded, one "label=<b64>" per line, for
# Build-CloudGrangeApplianceK3s.ps1's post-export VHDX secret scan. Run as root BEFORE
# cloudgrange-generalize-k3s.sh, while K3s is still up and the pods are still running.
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
KC="k3s kubectl"

# The bootstrap Secret's values are already base64 in the K8s API's own representation.
$KC get secret cloudgrange-secrets -o json | python3 -c '
import json, sys
doc = json.load(sys.stdin)
for k, v in doc.get("data", {}).items():
    print(f"secret:{k}={v}")
'

# The API's PostgresEncryptedSecretsProvider master key (mounted at /etc/cloudgrange in
# the api pod, matching the Compose engine's api_secrets volume).
$KC exec deploy/cloudgrange-api -- sh -c \
    'find /etc/cloudgrange -maxdepth 1 -type f -size -65k 2>/dev/null | while read -r f; do echo "api-secrets:$(basename "$f")=$(base64 -w0 < "$f")"; done' 2>/dev/null || true

# The relay's persisted identity (mounted at /var/lib/cloudgrange-relay/identity).
$KC exec deploy/cloudgrange-relay -- sh -c \
    'find /var/lib/cloudgrange-relay/identity -maxdepth 1 -type f -size -65k 2>/dev/null | while read -r f; do echo "relay-identity:$(basename "$f")=$(base64 -w0 < "$f")"; done' 2>/dev/null || true

if [ -s /var/lib/fwupd/pki/secret.key ]; then
    printf 'fwupd:secret.key=%s\n' "$(base64 -w0 < /var/lib/fwupd/pki/secret.key)"
fi

# cert-manager's self-signed Certificate — the private key line, same spot-check the
# Compose script does for its openssl-generated cert.
$KC get secret cloudgrange-tls -o jsonpath='{.data.tls\.key}' 2>/dev/null | base64 -d 2>/dev/null | sed -n 2p | tr -d '\n' | \
    { line=$(cat); [ -n "$line" ] && printf 'tls:private-key-line2=%s\n' "$(printf '%s' "$line" | base64 -w0)"; } || true
