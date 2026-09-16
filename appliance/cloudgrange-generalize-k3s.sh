#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9186 — K3s/Helm counterpart to cloudgrange-generalize.sh (Compose). Run as root
# inside the cloudgrange-k3s VM by Build-CloudGrangeApplianceK3s.ps1. Removes every
# install-time secret and identity so each imported appliance re-keys itself on first
# boot — cloudgrange-firstboot-k3s.service.
#
# Unlike Compose (which needs a bespoke firstboot .env-regeneration script because
# Compose has no native "generate-if-absent" secret mechanism), the K3s/Helm path
# re-keys almost for free: AB#9178's bootstrap-secrets hook Job already generates fresh
# secrets idempotently, server-side, whenever the Secret doesn't exist. Wiping K3s's own
# data directory (which holds etcd — every Kubernetes object, Secrets included) is
# therefore enough; a fresh `helm install` on first boot naturally re-triggers that hook.
# So this script does NOT need to hand-generate replacement values the way
# cloudgrange-generalize.sh's Compose .env block does.
#
# The machine-identity/SSH/cloud-init/log/fwupd cleanup steps below are copied verbatim
# from cloudgrange-generalize.sh (engine-agnostic security hygiene — deliberately NOT
# refactored into a shared script, to avoid touching the already-hardened, carefully
# tuned Compose generalization code while adding this K3s-specific one).
set -euo pipefail

STAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLER_DIR=/opt/cloudgrange-k3s-installer

echo "[generalize-k3s] recording the deployed version for firstboot to reuse"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
mkdir -p /etc/cloudgrange
APPLIANCE_VERSION=$(k3s kubectl get deploy cloudgrange-api -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://' || true)
echo "${APPLIANCE_VERSION:-latest}" > /etc/cloudgrange/appliance-version

echo "[generalize-k3s] staging the K3s installer + charts persistently for firstboot"
# Unlike the ephemeral SSH upload directory (removed at the end of this script), firstboot
# needs the installer + charts to still exist after reboot — same role /opt/cloudgrange
# plays for the Compose engine.
rm -rf "$INSTALLER_DIR"
mkdir -p "$INSTALLER_DIR"
cp -r "$STAGE_DIR/../scripts" "$STAGE_DIR/../charts" "$INSTALLER_DIR/" 2>/dev/null || {
    echo "[generalize-k3s] ERROR: expected scripts/ and charts/ next to the staged appliance/ directory" >&2
    exit 1
}
chmod +x "$INSTALLER_DIR/scripts/"*.sh

echo "[generalize-k3s] stopping K3s and wiping its data directory"
# K3s's own containerd (like Docker's) keeps deleted container specs — including their
# environment — in its metadata store's free pages; wiping the whole data directory,
# not just `helm uninstall`, is what actually removes install-time secrets from disk,
# the same reasoning cloudgrange-generalize.sh applies to /var/lib/docker.
systemctl stop k3s.service 2>/dev/null || true
rm -rf /var/lib/rancher/k3s /etc/rancher/k3s /var/lib/kubelet

echo "[generalize-k3s] /opt/cloudgrange root-owned (if the compose fallback path ever ran here too)"
if [ -d /opt/cloudgrange ]; then
    chown -R root:root /opt/cloudgrange
    chmod -R go-w /opt/cloudgrange
fi

echo "[generalize-k3s] installing first-boot re-keying"
install -m 0755 "$STAGE_DIR/cloudgrange-firstboot-k3s.sh" /usr/local/sbin/cloudgrange-firstboot-k3s.sh
install -m 0644 "$STAGE_DIR/cloudgrange-firstboot-k3s.service" /etc/systemd/system/cloudgrange-firstboot-k3s.service
systemctl daemon-reload
systemctl enable cloudgrange-firstboot-k3s.service
mkdir -p /etc/cloudgrange
touch /etc/cloudgrange/firstboot-pending

echo "[generalize-k3s] installing operator access (Hyper-V KVP + local console until setup completes)"
install -d -m 0755 /usr/local/lib/cloudgrange
install -m 0755 "$STAGE_DIR/cloudgrange-kvp.py" /usr/local/lib/cloudgrange/cloudgrange-kvp.py
install -m 0755 "$STAGE_DIR/cloudgrange-operator-access.sh" /usr/local/sbin/cloudgrange-operator-access.sh
install -m 0644 "$STAGE_DIR/cloudgrange-operator-access.service" /etc/systemd/system/cloudgrange-operator-access.service
install -d -m 0755 /etc/systemd/system/hv-kvp-daemon.service.d
printf '[Service]\nUMask=0077\n' > /etc/systemd/system/hv-kvp-daemon.service.d/10-cloudgrange-umask.conf
systemctl daemon-reload
systemctl enable cloudgrange-operator-access.service
systemctl enable hv-kvp-daemon.service 2>/dev/null || { echo "[generalize-k3s] ERROR: hv-kvp-daemon (linux-cloud-tools) is not installed" >&2; exit 1; }
grep -qx 'UMask=0077' /etc/systemd/system/hv-kvp-daemon.service.d/10-cloudgrange-umask.conf || { echo "[generalize-k3s] ERROR: hv-kvp-daemon UMask drop-in missing" >&2; exit 1; }
[ "$(systemctl show -p UMask --value hv-kvp-daemon.service)" = "0077" ] || { echo "[generalize-k3s] ERROR: hv-kvp-daemon does not run with UMask=0077" >&2; exit 1; }
systemctl stop cloudgrange-operator-access.service hv-kvp-daemon.service 2>/dev/null || true
rm -f /var/lib/hyperv/.kvp_pool_* /etc/issue.d/90-cloudgrange.issue /etc/cloudgrange/operator-access-cleared \
    /etc/cloudgrange/operator-access-stale /etc/cloudgrange/operator-access-rotations /etc/cloudgrange/operator-access-window-start
rm -rf /run/cloudgrange-operator

echo "[generalize-k3s] networking -> DHCP"
rm -f /etc/netplan/*.yaml /usr/local/bin/cloudgrange-net-setup.sh
cat > /etc/netplan/01-cloudgrange-dhcp.yaml <<'NETPLAN'
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

echo "[generalize-k3s] removing SSH host keys and authorized keys"
rm -f /etc/ssh/ssh_host_*
find /root /home -name authorized_keys -type f -delete 2>/dev/null || true

echo "[generalize-k3s] removing per-machine keys (fwupd client key)"
systemctl stop fwupd-refresh.timer fwupd-refresh.service fwupd.service 2>/dev/null || true
systemctl mask --runtime fwupd.service fwupd-refresh.service fwupd-refresh.timer >/dev/null 2>&1 || true
rm -f /var/lib/fwupd/pki/secret.key /var/lib/fwupd/pki/client.pem

echo "[generalize-k3s] cleaning cloud-init, machine-id, temp files, logs and history"
cloud-init clean --logs --seed --machine-id
rm -f /var/lib/dbus/machine-id
rm -rf /var/lib/cloud/instances/*
find /tmp /var/tmp -mindepth 1 -maxdepth 1 ! -path "$STAGE_DIR" -exec rm -rf {} +
systemctl stop rsyslog.service syslog.socket 2>/dev/null || true
systemctl stop systemd-journald.socket systemd-journald-dev-log.socket systemd-journald-audit.socket systemd-journald.service 2>/dev/null || true
rm -rf /var/log/journal/* /run/log/journal/*
find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -delete
find /var/log -type f -exec truncate -s 0 {} +
rm -f /root/.bash_history /home/*/.bash_history /root/.lesshst /home/*/.lesshst

rm -f /var/lib/fwupd/pki/secret.key /var/lib/fwupd/pki/client.pem
if [ -e /var/lib/fwupd/pki/secret.key ]; then
    echo "[generalize-k3s] ERROR: /var/lib/fwupd/pki/secret.key reappeared" >&2
    exit 1
fi

echo "[generalize-k3s] overwriting free space (deleted secrets must not survive in freed blocks)"
sync
dd if=/dev/zero of=/var/cloudgrange-zerofill bs=16M status=none 2>/dev/null || true
sync
rm -f /var/cloudgrange-zerofill
sync
echo "[generalize-k3s] discarding free blocks"
fstrim -av || true

echo "[generalize-k3s] complete; powering off in 5 seconds"
rm -rf "$STAGE_DIR"
systemd-run --on-active=5 /bin/systemctl poweroff >/dev/null
