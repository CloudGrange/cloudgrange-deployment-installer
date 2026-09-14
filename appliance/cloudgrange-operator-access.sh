#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — operator access for an imported CloudGrange appliance (no network exposure, no default
# credential). After first boot has re-keyed the VM and the stack is up, this publishes:
#   - to the Hyper-V host over KVP (host administrators; root-only 0700/0600 inside the guest):
#       CloudGrange.State, .Address, .SetupUrl, .SetupToken, .RealmAdminUser, .RealmAdminPassword,
#       .SshUser, .SshPrivateKey (the operator key generated at first boot)
#   - to the VM's console login banner (/etc/issue.d, root 0600; shown by the console gettys, not SSH):
#       the setup URL, setup token and the temporary realm administrator password.
# While setup is pending it re-publishes when the API issues a new setup token, and when setup has not
# completed within the setup window (default 72 h) it rotates the credentials: the API is restarted once
# its token has expired (the API issues a new token at startup) and the still-temporary realm
# administrator password is reset to a new random value.
# When setup completes it removes the setup token, the temporary password and the SSH private key from
# KVP and the console, makes sure the API's token file is gone, and marks itself done.
# Import-CloudGrangeAppliance.ps1 reads the KVP items and shows them to the operator once.
# Paths can be overridden with CLOUDGRANGE_* variables (used by test/appliance/test_operator_access.py).
set -euo pipefail

COMPOSE_DIR=${CLOUDGRANGE_COMPOSE_DIR:-/opt/cloudgrange}
STATE_DIR=${CLOUDGRANGE_STATE_DIR:-/etc/cloudgrange}
KEYDIR=${CLOUDGRANGE_OPERATOR_KEYDIR:-/run/cloudgrange-operator}
ISSUE=${CLOUDGRANGE_ISSUE_FILE:-/etc/issue.d/90-cloudgrange.issue}
KVP=${CLOUDGRANGE_KVP_TOOL:-/usr/local/lib/cloudgrange/cloudgrange-kvp.py}
POLL_SECONDS=${CLOUDGRANGE_POLL_SECONDS:-15}
SETUP_WINDOW_SECONDS=${CLOUDGRANGE_SETUP_WINDOW_SECONDS:-259200}
TOKEN_MAX_AGE_SECONDS=${CLOUDGRANGE_TOKEN_MAX_AGE_SECONDS:-86400}
CLEARED="$STATE_DIR/operator-access-cleared"
WINDOW_FILE="$STATE_DIR/operator-access-window-start"
TOKEN_FILE=/etc/cloudgrange/secrets/cloudgrange-initial-admin-token.txt
REALM=cloudgrange
REALM_ADMIN_USER=admin@cloudgrange.local
log() { echo "[operator-access] $*"; }

cd "$COMPOSE_DIR"
dc() { docker compose --env-file .env "$@"; }
api() { dc exec -T cloudgrange-api "$@"; }
env_value() { grep -E "^$1=" .env | head -1 | cut -d= -f2- || true; }
setup_complete() { api curl -sf http://localhost:8080/api/v1/setup/status 2>/dev/null | grep -q '"setupComplete":true'; }
kvp_set() { printf '%s' "$2" | "$KVP" set "$1"; }
read_token() {
    local t
    t=$(api cat "$TOKEN_FILE" 2>/dev/null | tr -d '\r\n' || true)
    if [[ "$t" =~ ^[0-9a-f]{64}$ ]]; then printf '%s' "$t"; fi
}
wait_api() {
    for _ in $(seq 1 180); do
        api curl -sf http://localhost:8080/health/ready >/dev/null 2>&1 && return 0
        sleep 5
    done
    return 1
}

write_banner() {
    umask 077
    mkdir -p "$(dirname "$ISSUE")"
    {
        echo ""
        echo "  CloudGrange appliance: first-run setup (console only; removed when setup completes)"
        echo "    Setup wizard ............ https://$ADDRESS/setup"
        echo "    One-use setup token ..... $TOKEN"
        if [ -n "$REALM_ADMIN_PASSWORD" ]; then
            echo "    Identity administrator .. $REALM_ADMIN_USER"
            echo "    Temporary password ...... $REALM_ADMIN_PASSWORD   (must be changed at first sign-in)"
        fi
        echo "    SSH ..................... user cloudgrange; private key for Hyper-V host administrators only"
        echo "                              (KVP item CloudGrange.SshPrivateKey, see Import-CloudGrangeAppliance.ps1)"
        echo ""
    } > "$ISSUE.tmp"
    chmod 0600 "$ISSUE.tmp"
    mv -f "$ISSUE.tmp" "$ISSUE"
    umask 022
    agetty --reload 2>/dev/null || true
}

publish() {
    kvp_set CloudGrange.Address "$ADDRESS"
    kvp_set CloudGrange.SetupUrl "https://$ADDRESS/setup"
    kvp_set CloudGrange.SetupToken "$TOKEN"
    kvp_set CloudGrange.RealmAdminUser "$REALM_ADMIN_USER"
    if [ -n "$REALM_ADMIN_PASSWORD" ]; then
        kvp_set CloudGrange.RealmAdminPassword "$REALM_ADMIN_PASSWORD"
    else
        "$KVP" delete CloudGrange.RealmAdminPassword
    fi
    kvp_set CloudGrange.SshUser cloudgrange
    if [ -s "$KEYDIR/operator_ed25519" ]; then
        "$KVP" set CloudGrange.SshPrivateKey < "$KEYDIR/operator_ed25519"
        shred -u "$KEYDIR/operator_ed25519"
    fi
    # Last: host tooling waits for this item before reading the others.
    kvp_set CloudGrange.State setup-pending
    write_banner
}

remove_token_file() {
    if api test -e "$TOKEN_FILE" 2>/dev/null; then
        log "the API token file still exists after setup; removing it"
        api rm -f "$TOKEN_FILE" || log "WARNING: could not remove the API token file"
    fi
}

clear_access() {
    "$KVP" delete CloudGrange.SetupToken CloudGrange.RealmAdminPassword CloudGrange.SshPrivateKey
    kvp_set CloudGrange.State setup-complete
    if [ -f "$ISSUE" ]; then shred -u "$ISSUE" 2>/dev/null || rm -f "$ISSUE"; fi
    agetty --reload 2>/dev/null || true
    if [ -d "$KEYDIR" ]; then
        find "$KEYDIR" -type f -exec shred -u {} + 2>/dev/null || true
        rm -rf "$KEYDIR"
    fi
    remove_token_file
    rm -f "$WINDOW_FILE"
    touch "$CLEARED"
    log "setup is complete: removed the setup token, temporary realm admin password and operator SSH private key from KVP and the console"
}

# --config in /tmp (a tmpfs): Keycloak runs as a dedicated uid with no writable home directory.
kc() { dc exec -T -e KC_CLI_PASSWORD keycloak /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm-cloudgrange.config; }

rotate_realm_password() {
    # Only while the password is still the temporary one: never overwrite a password the operator chose.
    KC_CLI_PASSWORD=$(env_value KEYCLOAK_ADMIN_PASSWORD)
    export KC_CLI_PASSWORD
    kc config credentials --server http://localhost:8080 --realm master --user "$(env_value KEYCLOAK_ADMIN_USER)" >/dev/null
    local id actions new
    id=$(kc get users -r "$REALM" -q "username=$REALM_ADMIN_USER" -q exact=true --fields id | grep -o '"id" *: *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true)
    if [ -z "$id" ]; then
        log "realm administrator not found; removing the temporary password from KVP and the console"
        REALM_ADMIN_PASSWORD=''
        unset KC_CLI_PASSWORD
        return
    fi
    actions=$(kc get "users/$id" -r "$REALM" --fields requiredActions || true)
    if ! printf '%s' "$actions" | grep -q UPDATE_PASSWORD; then
        log "the realm administrator already set its own password; removing the temporary password from KVP and the console"
        REALM_ADMIN_PASSWORD=''
        unset KC_CLI_PASSWORD
        return
    fi
    new=$(openssl rand -hex 24)
    printf '{"type":"password","value":"%s","temporary":true}' "$new" | kc update "users/$id/reset-password" -r "$REALM" -f - >/dev/null
    sed -i "s/^CLOUDGRANGE_REALM_ADMIN_PASSWORD=.*/CLOUDGRANGE_REALM_ADMIN_PASSWORD=$new/" .env
    REALM_ADMIN_PASSWORD=$new
    unset KC_CLI_PASSWORD new
    log "rotated the temporary realm administrator password"
}

rotate_setup_credentials() {
    log "setup not completed within ${SETUP_WINDOW_SECONDS}s: rotating the setup token and temporary password"
    local now mtime age fresh
    now=$(date +%s)
    mtime=$(api stat -c %Y "$TOKEN_FILE" 2>/dev/null | tr -d '\r\n' || true)
    age=$(( now - ${mtime:-$now} ))
    if [ "$age" -ge "$TOKEN_MAX_AGE_SECONDS" ]; then
        log "the setup token has expired (${age}s old); restarting the API so it issues a new one"
        dc restart cloudgrange-api >/dev/null
        wait_api || log "WARNING: the API did not become ready after the restart"
    fi
    fresh=$(read_token)
    if [ -n "$fresh" ] && [ "$fresh" != "$TOKEN" ]; then TOKEN=$fresh; log "published a new setup token"; fi
    rotate_realm_password
    publish
}

if [ -f "$CLEARED" ]; then log "already cleared"; exit 0; fi

log "waiting for the API"
wait_api || true
if setup_complete; then clear_access; exit 0; fi

TOKEN=''
for _ in $(seq 1 120); do
    TOKEN=$(read_token)
    [ -n "$TOKEN" ] && break
    sleep 5
done
if [ -z "$TOKEN" ]; then log "ERROR: the setup token is not available yet"; exit 1; fi
REALM_ADMIN_PASSWORD=$(env_value CLOUDGRANGE_REALM_ADMIN_PASSWORD)
ADDRESS=$(env_value CLOUDGRANGE_HOSTNAME)

mkdir -p "$STATE_DIR"
[ -s "$WINDOW_FILE" ] || date +%s > "$WINDOW_FILE"
publish
log "published setup credentials to KVP and the console banner; waiting for setup to complete"

while ! setup_complete; do
    sleep "$POLL_SECONDS"
    setup_complete && break
    current=$(read_token)
    if [ -n "$current" ] && [ "$current" != "$TOKEN" ]; then
        TOKEN=$current
        publish
        log "the API issued a new setup token; re-published it"
    fi
    if [ $(( $(date +%s) - $(cat "$WINDOW_FILE") )) -ge "$SETUP_WINDOW_SECONDS" ]; then
        rotate_setup_credentials
        date +%s > "$WINDOW_FILE"
    fi
done
clear_access
