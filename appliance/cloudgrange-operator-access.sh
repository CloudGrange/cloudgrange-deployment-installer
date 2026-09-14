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
# While setup is pending:
#   - it never publishes an expired setup token: before every publication it checks the token's age and,
#     once the token has expired, restarts the API (which issues a new token at startup) first; if no fresh
#     token is available the token is withdrawn from KVP and the banner until one is;
#   - every setup window (default 72 h) it rotates the still-temporary realm administrator password;
#   - after MAX_ROTATIONS windows (default 2, so 9 days in total) it stops publishing: the token, password
#     and SSH key are removed, CloudGrange.State becomes setup-stale, and nothing is published again until an
#     administrator re-arms it (docs/appliance-operator-access.md).
# When setup completes it removes the setup token, the temporary password and the SSH private key from KVP
# and the console, makes sure the API's token file is gone, and marks itself done.
# Import-CloudGrangeAppliance.ps1 reads the KVP items and shows them to the operator once.
# Paths and timings can be overridden with CLOUDGRANGE_* variables (test/appliance/test_operator_access.py).
set -euo pipefail

COMPOSE_DIR=${CLOUDGRANGE_COMPOSE_DIR:-/opt/cloudgrange}
STATE_DIR=${CLOUDGRANGE_STATE_DIR:-/etc/cloudgrange}
KEYDIR=${CLOUDGRANGE_OPERATOR_KEYDIR:-/run/cloudgrange-operator}
ISSUE=${CLOUDGRANGE_ISSUE_FILE:-/etc/issue.d/90-cloudgrange.issue}
KVP=${CLOUDGRANGE_KVP_TOOL:-/usr/local/lib/cloudgrange/cloudgrange-kvp.py}
POLL_SECONDS=${CLOUDGRANGE_POLL_SECONDS:-15}
SETUP_WINDOW_SECONDS=${CLOUDGRANGE_SETUP_WINDOW_SECONDS:-259200}
MAX_ROTATIONS=${CLOUDGRANGE_MAX_ROTATIONS:-2}
TOKEN_MAX_AGE_SECONDS=${CLOUDGRANGE_TOKEN_MAX_AGE_SECONDS:-86400}
TOKEN_RESTART_BACKOFF_SECONDS=${CLOUDGRANGE_TOKEN_RESTART_BACKOFF_SECONDS:-3600}
CLEARED="$STATE_DIR/operator-access-cleared"
STALE="$STATE_DIR/operator-access-stale"
WINDOW_FILE="$STATE_DIR/operator-access-window-start"
ROTATIONS_FILE="$STATE_DIR/operator-access-rotations"
TOKEN_FILE=/etc/cloudgrange/secrets/cloudgrange-initial-admin-token.txt
KC_CONFIG=/tmp/kcadm-cloudgrange.config
REALM=cloudgrange
REALM_ADMIN_USER=admin@cloudgrange.local
log() { echo "[operator-access] $*"; }

cd "$COMPOSE_DIR"
dc() { docker compose --env-file .env "$@"; }
api() { dc exec -T cloudgrange-api "$@"; }
env_value() { grep -E "^$1=" .env | head -1 | cut -d= -f2- || true; }
setup_complete() { api curl -sf http://localhost:8080/api/v1/setup/status 2>/dev/null | grep -q '"setupComplete":true'; }
# Whether first-run setup asks for the one-use token. It does not by default (CLOUDGRANGE_REQUIRE_SETUP_TOKEN).
token_required() { api curl -sf http://localhost:8080/api/v1/setup/status 2>/dev/null | grep -q '"setupTokenRequired":true'; }
kvp_set() { printf '%s' "$2" | "$KVP" set "$1"; }
read_token() {
    local t
    t=$(api cat "$TOKEN_FILE" 2>/dev/null | tr -d '\r\n' || true)
    if [[ "$t" =~ ^[0-9a-f]{64}$ ]]; then printf '%s' "$t"; fi
}
token_age() {
    local m
    m=$(api stat -c %Y "$TOKEN_FILE" 2>/dev/null | tr -d '\r\n' || true)
    if [[ "$m" =~ ^[0-9]+$ ]]; then echo $(( $(date +%s) - m )); else echo -1; fi
}
wait_api() {
    for _ in $(seq 1 180); do
        api curl -sf http://localhost:8080/health/ready >/dev/null 2>&1 && return 0
        sleep 5
    done
    return 1
}

LAST_API_RESTART=0
FRESH_TOKEN=''
TOKEN_REQUIRED=0
# Sets FRESH_TOKEN to an unexpired token and returns 0, or clears it and returns 1. An expired or missing
# token triggers one API restart (the API issues a new token at startup), at most once per backoff period.
ensure_fresh_token() {
    local t age now
    # No token is issued unless the platform requires one: never restart the API looking for it.
    if [ "$TOKEN_REQUIRED" -ne 1 ]; then FRESH_TOKEN=''; return 1; fi
    t=$(read_token)
    age=$(token_age)
    if [ -n "$t" ] && [ "$age" -ge 0 ] && [ "$age" -lt "$TOKEN_MAX_AGE_SECONDS" ]; then FRESH_TOKEN=$t; return 0; fi
    now=$(date +%s)
    if [ "$LAST_API_RESTART" -eq 0 ] || [ $(( now - LAST_API_RESTART )) -ge "$TOKEN_RESTART_BACKOFF_SECONDS" ]; then
        log "the setup token is missing or expired; restarting the API so it issues a new one before anything is published"
        LAST_API_RESTART=$now
        dc restart cloudgrange-api >/dev/null || log "WARNING: API restart failed"
        wait_api || log "WARNING: the API did not become ready after the restart"
        t=$(read_token)
        age=$(token_age)
        if [ -n "$t" ] && [ "$age" -ge 0 ] && [ "$age" -lt "$TOKEN_MAX_AGE_SECONDS" ]; then FRESH_TOKEN=$t; return 0; fi
    fi
    FRESH_TOKEN=''
    return 1
}

write_banner() {
    umask 077
    mkdir -p "$(dirname "$ISSUE")"
    {
        echo ""
        echo "  CloudGrange appliance: first-run setup (console only; removed when setup completes)"
        echo "    Setup wizard ............ https://$ADDRESS/setup"
        if [ -n "$TOKEN" ]; then
            echo "    One-use setup token ..... $TOKEN"
        elif [ "$TOKEN_REQUIRED" -eq 1 ]; then
            echo "    One-use setup token ..... (being re-issued; check again in a few minutes)"
        fi
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
    if [ -n "$TOKEN" ]; then
        kvp_set CloudGrange.SetupToken "$TOKEN"
    else
        "$KVP" delete CloudGrange.SetupToken
    fi
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

withdraw_credentials() {
    # $1 = final CloudGrange.State
    "$KVP" delete CloudGrange.SetupToken CloudGrange.RealmAdminPassword CloudGrange.SshPrivateKey
    kvp_set CloudGrange.State "$1"
    if [ -f "$ISSUE" ]; then shred -u "$ISSUE" 2>/dev/null || rm -f "$ISSUE"; fi
    agetty --reload 2>/dev/null || true
    if [ -d "$KEYDIR" ]; then
        find "$KEYDIR" -type f -exec shred -u {} + 2>/dev/null || true
        rm -rf "$KEYDIR"
    fi
}

clear_access() {
    withdraw_credentials setup-complete
    remove_token_file
    rm -f "$WINDOW_FILE" "$ROTATIONS_FILE"
    touch "$CLEARED"
    log "setup is complete: removed the setup token, temporary realm admin password and operator SSH private key from KVP and the console"
}

expire_access() {
    withdraw_credentials setup-stale
    touch "$STALE"
    log "setup was not completed after $MAX_ROTATIONS rotations; stopped publishing credentials (CloudGrange.State=setup-stale). Re-arm: docs/appliance-operator-access.md"
}

# --config in /tmp (a tmpfs): Keycloak runs as a dedicated uid with no writable home directory. The session
# file holds a master-realm token, so it is deleted right after use (kc_logout).
kc() { dc exec -T -e KC_CLI_PASSWORD keycloak /opt/keycloak/bin/kcadm.sh "$@" --config "$KC_CONFIG"; }
kc_logout() { dc exec -T keycloak rm -f "$KC_CONFIG" >/dev/null 2>&1 || true; }

reset_temporary_password() {
    KC_CLI_PASSWORD=$(env_value KEYCLOAK_ADMIN_PASSWORD)
    export KC_CLI_PASSWORD
    kc config credentials --server http://localhost:8080 --realm master --user "$(env_value KEYCLOAK_ADMIN_USER)" >/dev/null
    local id actions new
    id=$(kc get users -r "$REALM" -q "username=$REALM_ADMIN_USER" -q exact=true --fields id | grep -o '"id" *: *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true)
    if [ -z "$id" ]; then
        log "realm administrator not found; removing the temporary password from KVP and the console"
        REALM_ADMIN_PASSWORD=''
        return 0
    fi
    # Guard: only while UPDATE_PASSWORD is still required, i.e. the password is still the temporary one.
    # Never overwrite a password the operator chose.
    actions=$(kc get "users/$id" -r "$REALM" --fields requiredActions || true)
    if ! printf '%s' "$actions" | grep -q UPDATE_PASSWORD; then
        log "the realm administrator already set its own password; removing the temporary password from KVP and the console"
        REALM_ADMIN_PASSWORD=''
        return 0
    fi
    new=$(openssl rand -hex 24)
    printf '{"type":"password","value":"%s","temporary":true}' "$new" | kc update "users/$id/reset-password" -r "$REALM" -f - >/dev/null
    sed -i "s/^CLOUDGRANGE_REALM_ADMIN_PASSWORD=.*/CLOUDGRANGE_REALM_ADMIN_PASSWORD=$new/" .env
    REALM_ADMIN_PASSWORD=$new
    log "rotated the temporary realm administrator password"
}

rotate_realm_password() {
    local rc=0
    reset_temporary_password || rc=$?
    kc_logout
    unset KC_CLI_PASSWORD
    return $rc
}

if [ -f "$CLEARED" ]; then log "already cleared"; exit 0; fi
if [ -f "$STALE" ]; then log "stale: credentials are not published (re-arm required)"; exit 0; fi

log "waiting for the API"
wait_api || true
if setup_complete; then clear_access; exit 0; fi

TOKEN=''
if token_required; then TOKEN_REQUIRED=1; fi
if [ "$TOKEN_REQUIRED" -eq 1 ]; then
    for _ in $(seq 1 120); do
        [ -n "$(read_token)" ] && break
        sleep 5
    done
    if [ -z "$(read_token)" ]; then log "ERROR: the setup token is not available yet"; exit 1; fi
else
    log "the platform does not require a setup token; publishing the setup URL only"
fi
REALM_ADMIN_PASSWORD=$(env_value CLOUDGRANGE_REALM_ADMIN_PASSWORD)
ADDRESS=$(env_value CLOUDGRANGE_HOSTNAME)

mkdir -p "$STATE_DIR"
[ -s "$WINDOW_FILE" ] || date +%s > "$WINDOW_FILE"
[ -s "$ROTATIONS_FILE" ] || echo 0 > "$ROTATIONS_FILE"
if [ "$TOKEN_REQUIRED" -ne 1 ]; then
    TOKEN=''
elif ensure_fresh_token; then
    TOKEN=$FRESH_TOKEN
else
    TOKEN=''; log "no unexpired setup token yet; publishing without a token"
fi
publish
log "published setup credentials to KVP and the console banner; waiting for setup to complete"

while ! setup_complete; do
    sleep "$POLL_SECONDS"
    setup_complete && break
    if ensure_fresh_token; then
        if [ "$FRESH_TOKEN" != "$TOKEN" ]; then
            TOKEN=$FRESH_TOKEN
            publish
            log "published a new setup token"
        fi
    elif [ -n "$TOKEN" ]; then
        TOKEN=''
        publish
        log "the published setup token expired; withdrew it until the API issues a new one"
    fi
    if [ $(( $(date +%s) - $(cat "$WINDOW_FILE") )) -ge "$SETUP_WINDOW_SECONDS" ]; then
        rotations=$(cat "$ROTATIONS_FILE" 2>/dev/null || echo 0)
        if [ "$rotations" -ge "$MAX_ROTATIONS" ]; then
            expire_access
            exit 0
        fi
        log "setup not completed within ${SETUP_WINDOW_SECONDS}s: rotating the temporary realm administrator password (rotation $((rotations + 1)) of $MAX_ROTATIONS)"
        rotate_realm_password
        publish
        echo $((rotations + 1)) > "$ROTATIONS_FILE"
        date +%s > "$WINDOW_FILE"
    fi
done
clear_access
