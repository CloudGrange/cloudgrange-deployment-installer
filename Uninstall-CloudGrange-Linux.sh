#!/usr/bin/env bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# Uninstall-CloudGrange-Linux.sh -- remove a CloudGrange install from a Linux server so the host is
# clean for a fresh Install-CloudGrange-Linux.sh run. Handles both engines this installer has shipped:
#   - K3s (current): our systemd units, then K3s itself via its own k3s-uninstall.sh
#   - Docker Compose (legacy): our compose stack's containers, networks and volumes (project "cloudgrange")
#
# Usage: sudo ./Uninstall-CloudGrange-Linux.sh [--remove-docker] [--yes]
#   --remove-docker  also purge Docker Engine/containerd (the K3s install refuses a host that has Docker).
#                    Refused if any container NOT belonging to CloudGrange exists.
#   --yes            do not prompt
set -euo pipefail

REMOVE_DOCKER=false
ASSUME_YES=false
for a in "$@"; do
    case "$a" in
        --remove-docker) REMOVE_DOCKER=true ;;
        --yes|-y) ASSUME_YES=true ;;
        -h|--help) sed -n '5,16p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $a" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

echo "This removes CloudGrange from $(hostname), including its data (database, secrets, volumes)."
$REMOVE_DOCKER && echo "It will also remove Docker Engine and containerd."
if ! $ASSUME_YES; then
    read -r -p "Type 'uninstall' to continue: " ans
    [ "$ans" = "uninstall" ] || { echo "Aborted. Nothing changed."; exit 1; }
fi

log() { echo "  -> $*"; }

# 1. Our systemd units (positive match on our unit names only).
for unit in cloudgrange.service cloudgrange-updater.service cloudgrange-updater-k3s.service \
            cloudgrange-operator-access.service cloudgrange-firstboot.service cloudgrange-airgap-route.service; do
    if systemctl list-unit-files "$unit" >/dev/null 2>&1 && systemctl list-unit-files "$unit" | grep -q "$unit"; then
        log "stopping and disabling $unit"
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
    fi
    rm -f "/etc/systemd/system/$unit" "/lib/systemd/system/$unit"
done
systemctl daemon-reload

# 2. K3s: its own uninstaller removes the cluster, its containerd, CNI and data.
if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
    log "uninstalling K3s (k3s-uninstall.sh)"
    /usr/local/bin/k3s-uninstall.sh || true
fi

# 3. Legacy Docker Compose stack: remove ONLY objects labelled with our compose project.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ids=$(docker ps -aq --filter "label=com.docker.compose.project=cloudgrange")
    [ -n "$ids" ] && { log "removing CloudGrange containers"; docker rm -f $ids >/dev/null; }
    vols=$(docker volume ls -q --filter "label=com.docker.compose.project=cloudgrange")
    [ -n "$vols" ] && { log "removing CloudGrange volumes"; docker volume rm $vols >/dev/null; }
    nets=$(docker network ls -q --filter "label=com.docker.compose.project=cloudgrange")
    [ -n "$nets" ] && { log "removing CloudGrange networks"; docker network rm $nets >/dev/null || true; }
fi

# 4. Optionally remove Docker Engine itself -- only if nothing else is using it.
if $REMOVE_DOCKER; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        others=$(docker ps -aq)
        if [ -n "$others" ]; then
            echo "ERROR: other (non-CloudGrange) containers exist; not removing Docker:" >&2
            docker ps -a --format '  {{.Names}} ({{.Image}})' >&2
            echo "Remove them yourself, or re-run without --remove-docker." >&2
            exit 1
        fi
    fi
    log "purging Docker Engine and containerd"
    systemctl disable --now docker.service docker.socket containerd.service >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get purge -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin docker.io containerd runc >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true
    rm -rf /var/lib/docker /var/lib/containerd /etc/docker
fi

# 5. Our files.
log "removing CloudGrange files"
rm -f /usr/local/sbin/cloudgrange-airgap-route.sh
rm -rf /opt/cloudgrange /etc/cloudgrange /var/lib/cloudgrange /var/lib/cloudgrange-updater \
       /var/log/cloudgrange

echo
echo "CloudGrange removed. Check the host is ready for a fresh install with:"
echo "  sudo ./Install-CloudGrange-Linux.sh --hostname <host> --preflight-only"
