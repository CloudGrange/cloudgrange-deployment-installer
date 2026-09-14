#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — First boot of an imported CloudGrange appliance. Generates everything that
# cloudgrange-generalize.sh removed, then lets cloudgrange.service start the stack:
#   - fresh SSH host keys and machine-id
#   - fresh /opt/cloudgrange/.env secrets (Postgres, Keycloak admin + API client, Grafana, relay)
#   - CLOUDGRANGE_HOSTNAME = this VM's IPv4 address (Keycloak issuer https://<ip>/realms/cloudgrange)
#   - fresh self-signed TLS certificate for nginx
# Data volumes start empty, so Postgres, Keycloak, the API master key and the relay identity are
# all initialised with the new values. Runs once (ConditionPathExists on the marker file).
set -euo pipefail

MARKER=/etc/cloudgrange/firstboot-pending
COMPOSE_DIR=/opt/cloudgrange
[ -f "$MARKER" ] || exit 0
exec >> /var/log/cloudgrange-firstboot.log 2>&1
echo "[firstboot] start $(date -u +%FT%TZ)"

echo "[firstboot] SSH host keys and machine-id"
ssh-keygen -A
if [ ! -s /etc/machine-id ] || grep -q uninitialized /etc/machine-id; then
    rm -f /etc/machine-id
    systemd-machine-id-setup
fi
systemctl try-restart ssh.service ssh.socket 2>/dev/null || true

echo "[firstboot] waiting for an IPv4 address"
IP=''
for _ in $(seq 1 150); do
    IP=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
    [ -n "$IP" ] && break
    sleep 2
done
if [ -z "$IP" ]; then
    echo "[firstboot] ERROR: no IPv4 address after 300s; leaving marker for the next boot"
    exit 1
fi
echo "[firstboot] address: $IP"

cd "$COMPOSE_DIR"
VERSION=$(grep -E '^CLOUDGRANGE_VERSION=' .env.appliance 2>/dev/null | cut -d= -f2 || true)
rnd() { openssl rand -hex 24; }
umask 077
cat > .env <<ENVEOF
POSTGRES_PASSWORD=$(rnd)
KEYCLOAK_ADMIN_USER=admin
KEYCLOAK_ADMIN_PASSWORD=$(rnd)
GRAFANA_ADMIN_PASSWORD=$(rnd)
RELAY_ENROLLMENT_TOKEN=$(rnd)
KEYCLOAK_API_CLIENT_SECRET=$(rnd)
CLOUDGRANGE_HOSTNAME=$IP
CLOUDGRANGE_VERSION=${VERSION:-latest}
ENVEOF
chmod 600 .env
umask 022

echo "[firstboot] TLS certificate"
HELPER_IMAGE=$(head -1 "$COMPOSE_DIR/helper-images.txt")
CERT_DIR=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$CERT_DIR/cloudgrange.key" -out "$CERT_DIR/cloudgrange.crt" \
    -subj "/CN=cloudgrange" \
    -addext "subjectAltName=DNS:cloudgrange,DNS:localhost,IP:$IP,IP:127.0.0.1" \
    -addext "keyUsage=digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" 2>/dev/null
docker run --rm -v cloudgrange_nginx_certs:/certs -v "$CERT_DIR:/src:ro" "$HELPER_IMAGE" \
    sh -c "cp /src/cloudgrange.crt /certs/cloudgrange.crt && cp /src/cloudgrange.key /certs/cloudgrange.key && chmod 644 /certs/cloudgrange.crt && chmod 600 /certs/cloudgrange.key"
rm -rf "$CERT_DIR"

rm -f "$MARKER"
echo "[firstboot] complete $(date -u +%FT%TZ)"
