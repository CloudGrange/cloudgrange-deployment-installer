#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — Create the first CloudGrange realm administrator (realm role PlatformAdmin) after
# Keycloak has imported the realm. The realm import itself ships no users, so there is no
# default or placeholder credential. The password is the per-install random
# CLOUDGRANGE_REALM_ADMIN_PASSWORD from /opt/cloudgrange/.env (written by the installer or the
# appliance first boot) and is marked temporary, so the first sign-in must change it.
# Secrets never appear on a command line: the master-realm login password is passed to kcadm
# through the KC_CLI_PASSWORD environment variable and the user JSON goes over stdin.
# Idempotent: exits 0 when the user already exists. Run as root by cloudgrange-realm-admin.service.
set -euo pipefail

COMPOSE_DIR=${CLOUDGRANGE_COMPOSE_DIR:-/opt/cloudgrange}
REALM=cloudgrange
ADMIN_USER=admin@cloudgrange.local
cd "$COMPOSE_DIR"

env_value() { grep -E "^$1=" .env | head -1 | cut -d= -f2-; }
REALM_ADMIN_PASSWORD=$(env_value CLOUDGRANGE_REALM_ADMIN_PASSWORD)
KC_CLI_USER=$(env_value KEYCLOAK_ADMIN_USER)
KC_CLI_PASSWORD=$(env_value KEYCLOAK_ADMIN_PASSWORD)
if [ -z "$REALM_ADMIN_PASSWORD" ] || [ -z "$KC_CLI_USER" ] || [ -z "$KC_CLI_PASSWORD" ]; then
    echo "[realm-admin] ERROR: CLOUDGRANGE_REALM_ADMIN_PASSWORD / KEYCLOAK_ADMIN_* missing from .env" >&2
    exit 1
fi
export KC_CLI_PASSWORD

kc() { docker compose --env-file .env exec -T -e KC_CLI_PASSWORD keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

echo "[realm-admin] waiting for Keycloak and the '$REALM' realm"
for _ in $(seq 1 90); do
    if kc config credentials --server http://localhost:8080 --realm master --user "$KC_CLI_USER" >/dev/null 2>&1 \
        && kc get "realms/$REALM" --fields realm >/dev/null 2>&1; then
        break
    fi
    sleep 5
done
kc get "realms/$REALM" --fields realm >/dev/null

if kc get users -r "$REALM" -q "username=$ADMIN_USER" -q exact=true --fields id | grep -q '"id"'; then
    echo "[realm-admin] $ADMIN_USER already exists; nothing to do"
    exit 0
fi

echo "[realm-admin] creating $ADMIN_USER (PlatformAdmin, temporary random password)"
printf '{"username":"%s","email":"%s","enabled":true,"emailVerified":true,"attributes":{"org_id":["00000000-0000-0000-0000-000000000001"]},"credentials":[{"type":"password","value":"%s","temporary":true}]}' \
    "$ADMIN_USER" "$ADMIN_USER" "$REALM_ADMIN_PASSWORD" | kc create users -r "$REALM" -f - >/dev/null
kc add-roles -r "$REALM" --uusername "$ADMIN_USER" --rolename PlatformAdmin
echo "[realm-admin] done"
