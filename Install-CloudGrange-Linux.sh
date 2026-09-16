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
# AB#9183: --engine k3s switches to the K3s/Helm path (scripts/Install-CloudGrangeK3s.sh)
# instead of Docker Compose — the canonical target per the platform restructure plan
# (cloudgrange-internal/pmo/plans/2026-09-15-platform-restructure-helm-k8s.md), running
# in parallel with Compose for this release cycle per that plan's own rollout order.
# --engine compose (the default, unchanged) is not going away this release — do not
# remove it until AB#9189 explicitly retires it after K3s/Helm has proven out.
#
# Usage (run as root, from the extracted install bundle — this script expects a
# sibling ./compose directory for --engine compose, or a sibling ./charts and
# ./scripts/Install-CloudGrangeK3s.sh for --engine k3s, exactly like the bundle
# New-ReleaseBundle.sh produces):
#   sudo ./Install-CloudGrange-Linux.sh --hostname cloudgrange.example.com [--version 2609.0.0]
#   sudo ./Install-CloudGrange-Linux.sh --hostname cloudgrange.example.com --engine k3s
#
# What this does NOT do: create a VM, touch Hyper-V, or require a Windows host at all.
# --engine compose prerequisites (Docker Engine + Compose plugin, openssl, jq) are
# checked and installed automatically if missing: Docker via the official
# https://get.docker.com convenience script (auto-detects apt/dnf/yum), openssl/jq via
# whichever of apt-get/dnf/yum is present. Review get.docker.com's script before running
# this on a server with other workloads if you want full control over what it changes.
# --engine k3s prerequisites (K3s itself, helm) are handled by
# scripts/Install-CloudGrangeK3s.sh — see that script for what it installs.

set -euo pipefail

HOSTNAME_ARG=""
VERSION="latest"
COMPOSE_DIR="/opt/cloudgrange"
# K3s/Helm is THE deployment model for this product — that was the whole point of the
# platform restructure. Compose remains reachable with --engine compose until AB#9189
# retires it, but it is no longer what a customer gets by default: leaving the default on
# compose meant every real install silently ran the stack the restructure replaced.
ENGINE="k3s"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: sudo $0 --hostname <fqdn-or-ip> [--version X.Y.Z] [--compose-dir /opt/cloudgrange] [--engine compose|k3s]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --hostname)    HOSTNAME_ARG=$2; shift 2 ;;
        --version)     VERSION=$2; shift 2 ;;
        --compose-dir) COMPOSE_DIR=$2; shift 2 ;;
        --engine)      ENGINE=$2; shift 2 ;;
        -h|--help)     usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$HOSTNAME_ARG" ] || { echo "ERROR: --hostname is required (the FQDN or IP you'll browse to)." >&2; usage; }
case "$ENGINE" in
    compose|k3s) ;;
    *) echo "ERROR: --engine must be 'compose' or 'k3s' (got: $ENGINE)" >&2; usage ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this installer must run as root (sudo $0 ...)." >&2
    exit 1
fi

# AB#9183: --engine k3s delegates entirely to Install-CloudGrangeK3s.sh, which has its
# own prereqs/bundle-layout checks (a sibling ./charts directory) and its own
# checkpointed, resumable install flow (AB#9182) — nothing below this point applies to
# that path, so hand off immediately rather than duplicating logic.
if [ "$ENGINE" = "k3s" ]; then
    K3S_INSTALLER="$SCRIPT_DIR/scripts/Install-CloudGrangeK3s.sh"
    [ -x "$K3S_INSTALLER" ] || { echo "ERROR: expected $K3S_INSTALLER (is this an extracted install bundle?)" >&2; exit 1; }
    exec "$K3S_INSTALLER" --hostname "$HOSTNAME_ARG" --version "$VERSION"
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

# ── Step 1: prerequisites (checked, and installed if missing) ──────────────
# AB#9149: install Docker Engine via its official convenience script (handles
# apt/dnf/yum distro detection itself and includes the Compose plugin), and
# openssl/jq via whichever native package manager is present.
echo "Checking prerequisites..."

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    echo "  Docker (and/or the Compose plugin) not found — installing via https://get.docker.com ..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi
command -v docker >/dev/null 2>&1 || { echo "ERROR: Docker install failed — docker still not found on PATH." >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: Docker installed but the 'docker compose' plugin is still missing." >&2; exit 1; }

install_pkg() {
    local pkg=$1
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq "$pkg"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q "$pkg"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q "$pkg"
    else
        echo "ERROR: no supported package manager (apt-get/dnf/yum) found to install '$pkg'. Install it manually and re-run." >&2
        exit 1
    fi
}

command -v openssl >/dev/null 2>&1 || { echo "  openssl not found — installing..."; install_pkg openssl; }
command -v jq >/dev/null 2>&1 || { echo "  jq not found — installing..."; install_pkg jq; }
command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl install failed." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq install failed." >&2; exit 1; }
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

# AB#9149 — the cert must cover the box's real routable IP too, not just 127.0.0.1,
# otherwise browsing to https://<server-ip>/ fails certificate validation even though
# https://<hostname>/ works. Detect every non-loopback IPv4 address on the host and add
# each as a SAN entry, alongside the --hostname value itself in case it's an IP.
mapfile -t HOST_IPS < <(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u)

{
    echo "[req]"
    echo "distinguished_name = req_dn"
    echo "x509_extensions    = v3_req"
    echo "prompt             = no"
    echo ""
    echo "[req_dn]"
    echo "CN = $HOSTNAME_ARG"
    echo ""
    echo "[v3_req]"
    echo "subjectAltName = @alt_names"
    echo "keyUsage       = digitalSignature, keyEncipherment, dataEncipherment"
    echo "extendedKeyUsage = serverAuth"
    echo ""
    echo "[alt_names]"
    echo "DNS.1 = $HOSTNAME_ARG"
    echo "DNS.2 = localhost"
    ip_index=1
    echo "IP.$ip_index = 127.0.0.1"
    for ip in "${HOST_IPS[@]}"; do
        ip_index=$((ip_index + 1))
        echo "IP.$ip_index = $ip"
    done
    # If --hostname was itself passed as an IP (not a DNS name), make sure it's covered too.
    if [[ "$HOSTNAME_ARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        already_present=false
        for ip in "${HOST_IPS[@]}" "127.0.0.1"; do
            [ "$ip" = "$HOSTNAME_ARG" ] && already_present=true
        done
        if [ "$already_present" = false ]; then
            ip_index=$((ip_index + 1))
            echo "IP.$ip_index = $HOSTNAME_ARG"
        fi
    fi
} > "$CERT_DIR/openssl.cnf"

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
