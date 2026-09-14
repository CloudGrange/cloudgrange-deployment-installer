#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — Generalize the cloudgrange-docker VM before it is exported as an appliance VHDX.
# Run as root inside the VM by Build-CloudGrangeAppliance.ps1. Removes every install-time secret
# and identity so each imported appliance re-keys itself on first boot
# (cloudgrange-firstboot.service):
#   - Compose stack stopped; all cloudgrange_* volumes removed (Postgres/Keycloak data, API master
#     key, relay identity, TLS certs, Grafana/Prometheus/Loki data); /opt/cloudgrange/.env removed
#   - SSH host keys and every authorized_keys file removed
#   - machine-id, cloud-init instance state, seed, and logs cleaned
#   - static netplan config replaced with DHCP
#   - free blocks discarded (fstrim) so deleted data is not carried in the exported VHDX
# Container images stay loaded, so the appliance needs no registry access.
# The VM powers itself off a few seconds after this script returns.
set -euo pipefail

STAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR=/opt/cloudgrange

echo "[generalize] stopping stack and removing data volumes"
cd "$COMPOSE_DIR"
VERSION=$(grep -E '^CLOUDGRANGE_VERSION=' .env 2>/dev/null | cut -d= -f2 || true)
systemctl stop cloudgrange.service || true
if [ -f .env ]; then
    docker compose --env-file .env down --volumes --remove-orphans
else
    docker compose down --volumes --remove-orphans || true
fi
{ docker volume ls -q | grep '^cloudgrange_' || true; } | xargs -r docker volume rm
docker container prune -f >/dev/null
docker network prune -f >/dev/null
docker builder prune -af >/dev/null 2>&1 || true

# containerd's bolt metadata DB keeps deleted container specs (including their environment, i.e.
# the install-time secrets) in free pages, so removing containers is not enough. Rebuild the whole
# image store: save the images, wipe containerd/docker state, and load them into a fresh store.
echo "[generalize] rebuilding container metadata store"
mapfile -t IMAGES < <({ docker compose --env-file .env config --images; head -1 helper-images.txt; } | sort -u)
mapfile -t TAGS < <(printf '%s\n' "${IMAGES[@]}" | sed 's/@sha256:.*//' | sort -u)
IMAGE_TAR=/var/tmp/cloudgrange-generalize-images.tar
docker save -o "$IMAGE_TAR" "${TAGS[@]}"
systemctl stop docker.socket docker.service containerd.service
rm -rf /var/lib/containerd /var/lib/docker
systemctl start containerd.service docker.service
docker load -i "$IMAGE_TAR" >/dev/null
rm -f "$IMAGE_TAR"
for image in "${IMAGES[@]}"; do
    docker image inspect "$image" >/dev/null || { echo "[generalize] ERROR: $image missing after reload" >&2; exit 1; }
done
echo "[generalize] ${#IMAGES[@]} images reloaded into a fresh store"

echo "[generalize] removing install-time settings and secrets"
# The updater's backups hold a copy of .env and a database dump: none may ship.
systemctl stop cloudgrange-updater.service 2>/dev/null || true
rm -rf /var/lib/cloudgrange-updater
systemctl is-enabled cloudgrange-updater.service >/dev/null 2>&1 || { echo "[generalize] ERROR: cloudgrange-updater.service is not enabled (in-app updates would not work)" >&2; exit 1; }
if [ -f .env ]; then shred -u .env; fi
printf 'CLOUDGRANGE_VERSION=%s\n' "${VERSION:-latest}" > .env.appliance
chmod 644 .env.appliance

echo "[generalize] /opt/cloudgrange root-owned (root services execute its scripts and compose file)"
chown -R root:root "$COMPOSE_DIR"
chmod -R go-w "$COMPOSE_DIR"
if [ -n "$(find "$COMPOSE_DIR" \( ! -user root -o -perm /022 \) -print -quit)" ]; then
    echo "[generalize] ERROR: $COMPOSE_DIR still has non-root-owned or group/world-writable entries" >&2
    exit 1
fi

echo "[generalize] installing first-boot re-keying"
install -m 0755 "$STAGE_DIR/cloudgrange-firstboot.sh" /usr/local/sbin/cloudgrange-firstboot.sh
install -m 0644 "$STAGE_DIR/cloudgrange-firstboot.service" /etc/systemd/system/cloudgrange-firstboot.service
systemctl daemon-reload
systemctl enable cloudgrange-firstboot.service
mkdir -p /etc/cloudgrange
touch /etc/cloudgrange/firstboot-pending

echo "[generalize] installing operator access (Hyper-V KVP + local console until setup completes)"
install -d -m 0755 /usr/local/lib/cloudgrange
install -m 0755 "$STAGE_DIR/cloudgrange-kvp.py" /usr/local/lib/cloudgrange/cloudgrange-kvp.py
install -m 0755 "$STAGE_DIR/cloudgrange-operator-access.sh" /usr/local/sbin/cloudgrange-operator-access.sh
install -m 0644 "$STAGE_DIR/cloudgrange-operator-access.service" /etc/systemd/system/cloudgrange-operator-access.service
# KVP pools are root-only inside the guest (they hold setup credentials until setup completes).
install -d -m 0755 /etc/systemd/system/hv-kvp-daemon.service.d
printf '[Service]\nUMask=0077\n' > /etc/systemd/system/hv-kvp-daemon.service.d/10-cloudgrange-umask.conf
systemctl daemon-reload
systemctl enable cloudgrange-operator-access.service
systemctl enable hv-kvp-daemon.service 2>/dev/null || { echo "[generalize] ERROR: hv-kvp-daemon (linux-cloud-tools) is not installed" >&2; exit 1; }
# The shipped image must carry the drop-in and systemd must apply it; refuse to build otherwise.
grep -qx 'UMask=0077' /etc/systemd/system/hv-kvp-daemon.service.d/10-cloudgrange-umask.conf || { echo "[generalize] ERROR: hv-kvp-daemon UMask drop-in missing" >&2; exit 1; }
[ "$(systemctl show -p UMask --value hv-kvp-daemon.service)" = "0077" ] || { echo "[generalize] ERROR: hv-kvp-daemon does not run with UMask=0077" >&2; exit 1; }
# No KVP values, console banner or operator-access state from the build VM may ship.
systemctl stop cloudgrange-operator-access.service hv-kvp-daemon.service 2>/dev/null || true
rm -f /var/lib/hyperv/.kvp_pool_* /etc/issue.d/90-cloudgrange.issue /etc/cloudgrange/operator-access-cleared \
    /etc/cloudgrange/operator-access-stale /etc/cloudgrange/operator-access-rotations /etc/cloudgrange/operator-access-window-start
rm -rf /run/cloudgrange-operator

echo "[generalize] networking -> DHCP"
rm -f /etc/netplan/*.yaml /usr/local/bin/cloudgrange-net-setup.sh
cat > /etc/netplan/01-cloudgrange-dhcp.yaml <<'NETPLAN'
# AB#8129: appliance default. A NoCloud seed network-config using the same id overrides this.
network:
  version: 2
  ethernets:
    cloudgrange-eth:
      match:
        name: "e*"
      set-name: eth0
      dhcp4: true
NETPLAN
chmod 600 /etc/netplan/01-cloudgrange-dhcp.yaml

echo "[generalize] removing SSH host keys and authorized keys"
rm -f /etc/ssh/ssh_host_*
find /root /home -name authorized_keys -type f -delete 2>/dev/null || true

echo "[generalize] removing per-machine keys (fwupd client key)"
# fwupd regenerates its client key whenever the daemon (D-Bus activated) or fwupd-refresh runs, so
# stop and runtime-mask them first (the runtime mask is gone after the next boot). Re-checked below.
systemctl stop fwupd-refresh.timer fwupd-refresh.service fwupd.service 2>/dev/null || true
systemctl mask --runtime fwupd.service fwupd-refresh.service fwupd-refresh.timer >/dev/null 2>&1 || true
rm -f /var/lib/fwupd/pki/secret.key /var/lib/fwupd/pki/client.pem

echo "[generalize] cleaning cloud-init, machine-id, temp files, logs and history"
cloud-init clean --logs --seed --machine-id
rm -f /var/lib/dbus/machine-id
rm -rf /var/lib/cloud/instances/*
# Everything in /tmp and /var/tmp (build-host harnesses, uploads), except this script's own
# staging directory, which is removed at the very end.
find /tmp /var/tmp -mindepth 1 -maxdepth 1 ! -path "$STAGE_DIR" -exec rm -rf {} +
# Stop the log writers first: a deleted journal or syslog file that is still open keeps its blocks
# allocated until shutdown, i.e. after the free-space overwrite below.
systemctl stop rsyslog.service syslog.socket 2>/dev/null || true
systemctl stop systemd-journald.socket systemd-journald-dev-log.socket systemd-journald-audit.socket systemd-journald.service 2>/dev/null || true
rm -rf /var/log/journal/* /run/log/journal/*
find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -delete
# Truncate every remaining log: syslog, auth.log, kern.log, cloud-init, dpkg/apt, wtmp/btmp/lastlog.
find /var/log -type f -exec truncate -s 0 {} +
rm -f /root/.bash_history /home/*/.bash_history /root/.lesshst /home/*/.lesshst

# Per-machine fwupd key must still be absent right before the free-space overwrite.
rm -f /var/lib/fwupd/pki/secret.key /var/lib/fwupd/pki/client.pem
if [ -e /var/lib/fwupd/pki/secret.key ]; then
    echo "[generalize] ERROR: /var/lib/fwupd/pki/secret.key reappeared" >&2
    exit 1
fi

echo "[generalize] overwriting free space (deleted secrets must not survive in freed blocks)"
sync
dd if=/dev/zero of=/var/cloudgrange-zerofill bs=16M status=none 2>/dev/null || true
sync
rm -f /var/cloudgrange-zerofill
sync
echo "[generalize] discarding free blocks"
fstrim -av || true

echo "[generalize] complete; powering off in 5 seconds"
rm -rf "$STAGE_DIR"
systemd-run --on-active=5 /bin/systemctl poweroff >/dev/null
