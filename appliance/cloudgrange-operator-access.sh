#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — operator access for an imported CloudGrange appliance (no network exposure, no default
# credential). After first boot has re-keyed the VM and the stack is up, this publishes:
#   - to the Hyper-V host over KVP (readable only by host administrators):
#       CloudGrange.State, .Address, .SetupUrl, .SetupToken, .RealmAdminUser, .RealmAdminPassword,
#       .SshUser, .SshPrivateKey (the operator key generated at first boot)
#   - to the VM's LOCAL console login banner (/etc/issue.d): the setup URL, setup token and the
#     temporary realm administrator password. Not shown over SSH or the network.
# It then waits until setup has completed and removes the setup token, the temporary password and
# the SSH private key from KVP and the console, and marks itself done. Import-CloudGrangeAppliance.ps1
# reads the KVP items and shows them to the operator once.
set -euo pipefail

COMPOSE_DIR=/opt/cloudgrange
CLEARED=/etc/cloudgrange/operator-access-cleared
KEYDIR=/run/cloudgrange-operator
ISSUE=/etc/issue.d/90-cloudgrange.issue
KVP=/usr/local/lib/cloudgrange/cloudgrange-kvp.py
log() { echo "[operator-access] $*"; }

cd "$COMPOSE_DIR"
api() { docker compose --env-file .env exec -T cloudgrange-api "$@"; }
env_value() { grep -E "^$1=" .env | head -1 | cut -d= -f2-; }
setup_complete() { api curl -sf http://localhost:8080/api/v1/setup/status 2>/dev/null | grep -q '"setupComplete":true'; }
kvp_set() { printf '%s' "$2" | "$KVP" set "$1"; }

clear_access() {
    "$KVP" delete CloudGrange.SetupToken CloudGrange.RealmAdminPassword CloudGrange.SshPrivateKey
    kvp_set CloudGrange.State setup-complete
    if [ -f "$ISSUE" ]; then shred -u "$ISSUE" 2>/dev/null || rm -f "$ISSUE"; fi
    agetty --reload 2>/dev/null || true
    if [ -d "$KEYDIR" ]; then
        find "$KEYDIR" -type f -exec shred -u {} + 2>/dev/null || true
        rm -rf "$KEYDIR"
    fi
    touch "$CLEARED"
    log "setup is complete: removed the setup token, temporary realm admin password and operator SSH private key from KVP and the console"
}

if [ -f "$CLEARED" ]; then log "already cleared"; exit 0; fi

log "waiting for the API"
for _ in $(seq 1 180); do
    api curl -sf http://localhost:8080/health/ready >/dev/null 2>&1 && break
    sleep 5
done
if setup_complete; then clear_access; exit 0; fi

TOKEN=''
for _ in $(seq 1 120); do
    TOKEN=$(api cat /etc/cloudgrange/secrets/cloudgrange-initial-admin-token.txt 2>/dev/null | tr -d '\r\n' || true)
    [[ "$TOKEN" =~ ^[0-9a-f]{64}$ ]] && break
    TOKEN=''
    sleep 5
done
if [ -z "$TOKEN" ]; then log "ERROR: the setup token is not available yet"; exit 1; fi
REALM_ADMIN_PASSWORD=$(env_value CLOUDGRANGE_REALM_ADMIN_PASSWORD)
ADDRESS=$(env_value CLOUDGRANGE_HOSTNAME)

kvp_set CloudGrange.Address "$ADDRESS"
kvp_set CloudGrange.SetupUrl "https://$ADDRESS/setup"
kvp_set CloudGrange.SetupToken "$TOKEN"
kvp_set CloudGrange.RealmAdminUser "admin@cloudgrange.local"
kvp_set CloudGrange.RealmAdminPassword "$REALM_ADMIN_PASSWORD"
kvp_set CloudGrange.SshUser cloudgrange
if [ -s "$KEYDIR/operator_ed25519" ]; then
    "$KVP" set CloudGrange.SshPrivateKey < "$KEYDIR/operator_ed25519"
    shred -u "$KEYDIR/operator_ed25519"
fi
# Last: host tooling waits for this item before reading the others.
kvp_set CloudGrange.State setup-pending

umask 077
mkdir -p /etc/issue.d
cat > "$ISSUE" <<ISSUEEOF

  CloudGrange appliance: first-run setup (local console only; removed when setup completes)
    Setup wizard ............ https://$ADDRESS/setup
    One-use setup token ..... $TOKEN
    Identity administrator .. admin@cloudgrange.local
    Temporary password ...... $REALM_ADMIN_PASSWORD   (must be changed at first sign-in)
    SSH ..................... user cloudgrange; private key for Hyper-V host administrators only
                              (KVP item CloudGrange.SshPrivateKey, see Import-CloudGrangeAppliance.ps1)

ISSUEEOF
umask 022
agetty --reload 2>/dev/null || true
unset TOKEN REALM_ADMIN_PASSWORD
log "published setup credentials to KVP and the local console; waiting for setup to complete"

while ! setup_complete; do sleep 15; done
clear_access
