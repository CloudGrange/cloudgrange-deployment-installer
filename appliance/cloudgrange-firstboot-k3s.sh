#!/bin/bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9186 — First boot of an imported K3s/Helm CloudGrange appliance. Simpler than the
# Compose engine's firstboot script: K3s's own data directory (etcd — every Secret) was
# wiped by cloudgrange-generalize-k3s.sh, so a fresh `helm install` naturally re-triggers
# AB#9178's idempotent bootstrap-secrets hook Job — no bespoke secret-regeneration logic
# needed here, just re-run the same installer used for a fresh install (AB#9182/9183).
# Runs once (ConditionPathExists on the marker file, same convention as the Compose engine).
set -euo pipefail

MARKER=/etc/cloudgrange/firstboot-pending
INSTALLER_DIR=/opt/cloudgrange-k3s-installer
[ -f "$MARKER" ] || exit 0
exec >> /var/log/cloudgrange-firstboot.log 2>&1
echo "[firstboot-k3s] start $(date -u +%FT%TZ)"

echo "[firstboot-k3s] hostname"
NIC=$(ip -o link show | awk -F': ' '$2 !~ /^(lo|docker|br-|veth|cni|flannel)/ {print $2; exit}')
MAC=$(tr -d ':' < "/sys/class/net/${NIC%%@*}/address" 2>/dev/null || true)
if [ ${#MAC} -ge 4 ]; then NEW_HOSTNAME="cloudgrange-${MAC: -4}"; else NEW_HOSTNAME="cloudgrange-$(openssl rand -hex 2)"; fi
hostnamectl set-hostname "$NEW_HOSTNAME"
if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $NEW_HOSTNAME/" /etc/hosts
else
    echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
fi
echo "[firstboot-k3s] hostname: $NEW_HOSTNAME"

echo "[firstboot-k3s] restoring persistent logging"
# AB#9186: cloudgrange-generalize-k3s.sh forces journald to Storage=volatile so that the
# journald restart inside the shutdown transaction cannot flush install-time SSH records back
# onto disk after the free-space wipe. That is a build-time measure only -- the customer's
# appliance should keep its logs across reboots, so drop the override on first boot.
rm -f /etc/systemd/journald.conf.d/00-cloudgrange-generalize.conf
rmdir /etc/systemd/journald.conf.d 2>/dev/null || true
install -d -m 2755 -g systemd-journal /var/log/journal 2>/dev/null || install -d -m 0755 /var/log/journal
systemctl restart systemd-journald.service 2>/dev/null || true

echo "[firstboot-k3s] SSH host keys and machine-id"
ssh-keygen -A
if [ ! -s /etc/machine-id ] || grep -q uninitialized /etc/machine-id; then
    rm -f /etc/machine-id
    systemd-machine-id-setup
fi
systemctl try-restart ssh.service ssh.socket 2>/dev/null || true

echo "[firstboot-k3s] operator SSH key (the private key leaves the VM only over Hyper-V KVP)"
install -d -m 0700 /run/cloudgrange-operator
rm -f /run/cloudgrange-operator/operator_ed25519 /run/cloudgrange-operator/operator_ed25519.pub
ssh-keygen -q -t ed25519 -N '' -C "cloudgrange-operator@$(hostname)" -f /run/cloudgrange-operator/operator_ed25519
install -d -m 0700 -o cloudgrange -g cloudgrange /home/cloudgrange/.ssh
cat /run/cloudgrange-operator/operator_ed25519.pub >> /home/cloudgrange/.ssh/authorized_keys
chown cloudgrange:cloudgrange /home/cloudgrange/.ssh/authorized_keys
chmod 600 /home/cloudgrange/.ssh/authorized_keys
rm -f /run/cloudgrange-operator/operator_ed25519.pub
install -d -m 0755 /etc/systemd/system/hv-kvp-daemon.service.d
printf '[Service]\nUMask=0077\n' > /etc/systemd/system/hv-kvp-daemon.service.d/10-cloudgrange-umask.conf
systemctl daemon-reload
if [ -d /var/lib/hyperv ]; then chmod 0700 /var/lib/hyperv; find /var/lib/hyperv -maxdepth 1 -name '.kvp_pool_*' -type f -exec chmod 0600 {} +; fi
systemctl enable --now hv-kvp-daemon.service 2>/dev/null || echo "[firstboot-k3s] WARNING: hv-kvp-daemon is not available; use the local console banner"

echo "[firstboot-k3s] waiting for an IPv4 address"
IP=''
for _ in $(seq 1 150); do
    IP=$(ip -4 -o addr show scope global | awk '$2 !~ /^(docker|br-|veth|cni|flannel)/ {print $4}' | cut -d/ -f1 | head -1)
    [ -n "$IP" ] && break
    sleep 2
done
if [ -z "$IP" ]; then
    echo "[firstboot-k3s] ERROR: no IPv4 address after 300s; leaving marker for the next boot"
    exit 1
fi
echo "[firstboot-k3s] address: $IP"

# AB#9171: the address the operator-access service (cloudgrange-operator-access-k3s.service)
# publishes over KVP and on the console as the setup URL.
echo "$IP" > /etc/cloudgrange/appliance-address

echo "[firstboot-k3s] running the K3s/Helm installer (fresh state -> fresh secrets via AB#9178)"
# The pinned release baked into this image (cloudgrange-generalize-k3s.sh refuses to build without one).
# Its images are already in K3s's agent/images directory, so this needs no registry.
VERSION=$(cat /etc/cloudgrange/appliance-version 2>/dev/null || true)
if [ -z "$VERSION" ] || [ "$VERSION" = latest ]; then
    echo "[firstboot-k3s] ERROR: /etc/cloudgrange/appliance-version does not name a pinned release; leaving the marker"
    exit 1
fi
rm -f /opt/cloudgrange/.install-state.json
# AB#9171 (E7): an appliance is updated only from Platform -> Updates and may sit on an isolated
# network, so it always runs in offline mode: the in-cluster registry an uploaded Platform bundle is
# loaded into, and K3s mirroring the public registries to it (online updates still work: containerd
# falls back to the public registry).
bash "$INSTALLER_DIR/scripts/Install-CloudGrangeK3s.sh" --hostname "$IP" --version "$VERSION" --offline

rm -f "$MARKER"
echo "[firstboot-k3s] complete $(date -u +%FT%TZ)"
