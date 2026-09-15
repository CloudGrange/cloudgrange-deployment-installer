#!/usr/bin/env bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9149 — Install CloudGrange directly on a Linux server you already own/manage.
# No Windows host, no Hyper-V, no VM provisioning: this script runs locally, as root,
# on the target Ubuntu/Debian server and stands up the same Docker Compose stack that
# the Windows installer (Install-CloudGrange.ps1) deploys inside its Hyper-V guest —
# see compose/docker-compose.yml and scripts/Deploy-DockerCompose.ps1 for the proven
# reference logic this script mirrors.
#
# Usage (run as root, from the extracted install bundle — this script expects a
# sibling ./compose directory, exactly like the bundle New-ReleaseBundle.sh produces):
#   sudo ./Install-CloudGrange-Linux.sh --hostname cloudgrange.example.com [--version 2609.0.0]
#
# What this does NOT do: create a VM, touch Hyper-V, or require a Windows host at all.
# What it DOES assume: Docker Engine + the Compose plugin are already installed
# (see https://docs.docker.com/engine/install/ for your distro) — this script does not
# install Docker itself, to avoid silently reconfiguring package repos on someone's
# existing server.

set -euo pipefail

HOSTNAME_ARG=""
VERSION="latest"
COMPOSE_DIR="/opt/cloudgrange"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: sudo $0 --hostname <fqdn-or-ip> [--version X.Y.Z] [--compose-dir /opt/cloudgrange]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --hostname)    HOSTNAME_ARG=$2; shift 2 ;;
        --version)     VERSION=$2; shift 2 ;;
        --compose-dir) COMPOSE_DIR=$2; shift 2 ;;
        -h|--help)     usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$HOSTNAME_ARG" ] || { echo "ERROR: --hostname is required (the FQDN or IP you'll browse to)." >&2; usage; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this installer must run as root (sudo $0 ...)." >&2
    exit 1
fi

if [ ! -d "$SCRIPT_DIR/compose" ]; then
    echo "ERROR: expected a 'compose' directory next to this script ($SCRIPT_DIR/compose) — is this an extracted install bundle?" >&2
    exit 1
fi

echo ""
echo "  CloudGrange Linux Installer"
echo "  ────────────────────────────"
echo "  Target hostname/IP : $HOSTNAME_ARG"
echo "  Compose directory  : $COMPOSE_DIR"
echo "  Version            : $VERSION"
echo ""

# ── Step 1: prerequisites ───────────────────────────────────────────────────
echo "Checking prerequisites..."
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is not installed. Install Docker Engine first: https://docs.docker.com/engine/install/" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: the 'docker compose' plugin is not installed (docker-compose-plugin)." >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl is required and was not found." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required and was not found." >&2; exit 1; }
echo "  OK: docker, docker compose, openssl, jq all present."

# ── Step 2: install the compose stack ───────────────────────────────────────
echo "Installing compose stack into $COMPOSE_DIR..."
mkdir -p "$COMPOSE_DIR"
cp -r "$SCRIPT_DIR/compose/." "$COMPOSE_DIR/"

# Same secret-generation and re-run behavior as Deploy-DockerCompose.ps1 (AB#8129):
# keep existing values on re-run so PostgreSQL and Keycloak credentials stay in step
# with their data volumes.
newSecret() { openssl rand -hex 24; }
cd "$COMPOSE_DIR"
if [ ! -f .env ]; then
    umask 077
    cat > .env <<ENVEOF
POSTGRES_PASSWORD=$(newSecret)
KEYCLOAK_ADMIN_USER=admin
KEYCLOAK_ADMIN_PASSWORD=$(newSecret)
GRAFANA_ADMIN_PASSWORD=$(newSecret)
RELAY_ENROLLMENT_TOKEN=$(newSecret)
KEYCLOAK_API_CLIENT_SECRET=$(newSecret)
CLOUDGRANGE_REALM_ADMIN_PASSWORD=$(newSecret)
CLOUDGRANGE_HOSTNAME=$HOSTNAME_ARG
ENVEOF
fi
grep -q '^CLOUDGRANGE_REALM_ADMIN_PASSWORD=' .env || echo "CLOUDGRANGE_REALM_ADMIN_PASSWORD=$(newSecret)" >> .env
sed -i '/^CLOUDGRANGE_VERSION=/d' .env && echo "CLOUDGRANGE_VERSION=$VERSION" >> .env
chmod 600 .env
chown -R root:root "$COMPOSE_DIR"
chmod -R go-w "$COMPOSE_DIR"

# ── Step 3: pull images (no bundled/offline mode in v1 of this script) ─────
echo "Pulling container images..."
docker compose pull
docker pull "$(head -1 helper-images.txt)"

# ── Step 4: self-signed TLS cert for nginx (mirrors New-SelfSignedCert.ps1) ─
echo "Generating TLS certificate for nginx..."
CERT_DIR="$(mktemp -d)"
trap 'rm -rf "$CERT_DIR"' EXIT
HELPER_IMAGE="$(head -1 "$COMPOSE_DIR/helper-images.txt")"

docker volume inspect cloudgrange_nginx_certs >/dev/null 2>&1 && docker run --rm \
    -v cloudgrange_nginx_certs:/certs \
    "$HELPER_IMAGE" \
    sh -c '
        if [ -f /certs/server.crt ] && [ ! -f /certs/cloudgrange.crt ]; then mv /certs/server.crt /certs/cloudgrange.crt; fi
        if [ -f /certs/server.key ] && [ ! -f /certs/cloudgrange.key ]; then mv /certs/server.key /certs/cloudgrange.key; fi
        exit 0
    ' || true

cat > "$CERT_DIR/openssl.cnf" <<OPENSSL_EOF
[req]
distinguished_name = req_dn
x509_extensions    = v3_req
prompt             = no

[req_dn]
CN = $HOSTNAME_ARG

[v3_req]
subjectAltName = @alt_names
keyUsage       = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = $HOSTNAME_ARG
DNS.2 = localhost
IP.1  = 127.0.0.1
OPENSSL_EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$CERT_DIR/cloudgrange.key" \
    -out    "$CERT_DIR/cloudgrange.crt" \
    -config "$CERT_DIR/openssl.cnf" 2>/dev/null

docker run --rm \
    -v cloudgrange_nginx_certs:/certs \
    -v "${CERT_DIR}:/src:ro" \
    "$HELPER_IMAGE" \
    sh -c "cp /src/cloudgrange.crt /certs/cloudgrange.crt && cp /src/cloudgrange.key /certs/cloudgrange.key && chmod 644 /certs/cloudgrange.crt && chmod 600 /certs/cloudgrange.key"
echo "  TLS certificate installed into nginx_certs volume."

# ── Step 5: systemd units + start (mirrors Deploy-DockerCompose.ps1 exactly) ─
install -m 0644 "$COMPOSE_DIR/systemd/cloudgrange.service" /etc/systemd/system/cloudgrange.service
systemctl daemon-reload
systemctl enable cloudgrange.service
systemctl restart cloudgrange.service

echo "Verifying all services are running (timeout: 60s)..."
TIMEOUT=60; ELAPSED=0; VERIFY_OK=false
while [ $ELAPSED -lt $TIMEOUT ]; do
    NOT_RUNNING=$(docker compose ps --format json 2>/dev/null | jq -r 'select(.State != "running") | .Name' 2>/dev/null || true)
    if [ -z "$NOT_RUNNING" ]; then VERIFY_OK=true; break; fi
    sleep 5; ELAPSED=$((ELAPSED+5))
done
if [ "$VERIFY_OK" != "true" ]; then
    echo "" ; echo "ERROR: services not running after ${TIMEOUT}s:" >&2
    docker compose ps --format json 2>/dev/null | jq -r 'select(.State != "running") | "  " + .Name + " — " + .State' 2>/dev/null || docker compose ps
    docker compose logs --tail=50 2>&1 || true
    exit 1
fi
echo "All services are running. Elapsed: ${ELAPSED}s"

install -m 0644 "$COMPOSE_DIR/systemd/cloudgrange-realm-admin.service" /etc/systemd/system/cloudgrange-realm-admin.service
systemctl daemon-reload
systemctl enable cloudgrange-realm-admin.service
systemctl restart cloudgrange-realm-admin.service
echo "Realm administrator bootstrap complete."

install -m 0755 "$COMPOSE_DIR/updater/cloudgrange-updater.py" /usr/local/sbin/cloudgrange-updater
install -m 0644 "$COMPOSE_DIR/systemd/cloudgrange-updater.service" /etc/systemd/system/cloudgrange-updater.service
systemctl daemon-reload
systemctl enable cloudgrange-updater.service
systemctl restart cloudgrange-updater.service
echo "Updater service installed."

# ── Step 6: local health probe ───────────────────────────────────────────────
echo "Probing portal at https://localhost/health/ready (timeout: 30s)..."
PORTAL_OK=false
DEADLINE=$((SECONDS + 30))
while [ $SECONDS -lt $DEADLINE ]; do
    if curl -sk --max-time 5 -o /dev/null -w '%{http_code}' https://localhost/health/ready 2>/dev/null | grep -qE '^[23]'; then
        PORTAL_OK=true; break
    fi
    if curl -sk --max-time 5 -o /dev/null -w '%{http_code}' https://localhost/ 2>/dev/null | grep -qE '^[23]'; then
        PORTAL_OK=true; break
    fi
    sleep 5
done

if [ "$PORTAL_OK" != "true" ]; then
    echo "" ; echo "  [FAILURE] Portal is not reachable at https://localhost after 30 seconds." >&2
    echo "  Check container logs with: docker compose -f $COMPOSE_DIR/docker-compose.yml logs --tail=50" >&2
    exit 1
fi

echo ""
echo "  CloudGrange is installed. Browse to https://$HOSTNAME_ARG/ to complete setup."
echo ""
