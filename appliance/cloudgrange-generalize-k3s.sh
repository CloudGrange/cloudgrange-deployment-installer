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
#
# AB#9186 real bug, found via a real appliance build: a plain `systemctl stop k3s.service`
# does NOT unmount the bind mounts kubelet creates under /var/lib/kubelet/pods/*/volumes
# (and /run/k3s) for every running pod's volumes — `rm -rf` then fails on every one of
# them with "Device or resource busy", aborting generalization. K3s ships its own
# k3s-killall.sh specifically to stop every k3s-related process AND unmount everything it
# mounted (this is also what k3s-uninstall.sh calls internally) — use that instead of a
# bare service stop.
if [ -x /usr/local/bin/k3s-killall.sh ]; then
    /usr/local/bin/k3s-killall.sh
else
    systemctl stop k3s.service 2>/dev/null || true
fi
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

echo "[generalize-k3s] installing the in-app updater (AB#9189)"
# Without this the K3s appliance has no in-app update path at all and a customer would have to
# reinstall to take a new release -- the exact gap the Compose engine's cloudgrange-updater.service
# has covered since AB#8129.
install -m 0755 "$STAGE_DIR/../scripts/cloudgrange-updater-k3s.py" /usr/local/sbin/cloudgrange-updater-k3s.py
install -m 0644 "$STAGE_DIR/cloudgrange-updater-k3s.service" /etc/systemd/system/cloudgrange-updater-k3s.service
# requests/ and incoming/ are the only places the non-root API pod may write; status/ is root-owned
# and read-only to it. 0733 gives the pod write+traverse without being able to list other tenants'
# in-flight uploads, matching the Compose volume's permission model.
install -d -m 0755 /var/lib/cloudgrange/updates
install -d -m 0733 /var/lib/cloudgrange/updates/requests /var/lib/cloudgrange/updates/incoming
install -d -m 0755 /var/lib/cloudgrange/updates/status
systemctl daemon-reload
systemctl enable cloudgrange-updater-k3s.service

echo "[generalize-k3s] installing operator access (Hyper-V KVP + local console until setup completes)"
install -d -m 0755 /usr/local/lib/cloudgrange
install -m 0755 "$STAGE_DIR/cloudgrange-kvp.py" /usr/local/lib/cloudgrange/cloudgrange-kvp.py
install -m 0755 "$STAGE_DIR/cloudgrange-operator-access.sh" /usr/local/sbin/cloudgrange-operator-access.sh
install -m 0644 "$STAGE_DIR/cloudgrange-operator-access.service" /etc/systemd/system/cloudgrange-operator-access.service
# AB#9186 real bug, found via a real appliance build: the Ubuntu 24.04 cloud image
# New-CloudGrangeVm.ps1 provisions does NOT ship linux-cloud-tools-virtual (the package
# providing hv-kvp-daemon) — this used to hard-fail here instead of installing it. Install
# it if missing rather than requiring some other, undocumented base image to have it
# already; this VM has internet access at generalize time (same assumption the rest of
# the install already makes).
if ! systemctl list-unit-files hv-kvp-daemon.service >/dev/null 2>&1; then
    echo "[generalize-k3s] hv-kvp-daemon not present — installing linux-cloud-tools-virtual"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -qq -y linux-cloud-tools-virtual linux-cloud-tools-"$(uname -r)" 2>/dev/null \
        || DEBIAN_FRONTEND=noninteractive apt-get install -qq -y linux-cloud-tools-virtual
fi
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
# AB#9186 ROOT CAUSE: these were plain deletes while the log wipe below uses `shred`. A plain
# delete releases the blocks with the key material still in them, so whether it survives into the
# exported image depends entirely on the free-space overwrite later in this script happening to
# cover those blocks. Forensics on a real export proved it does not: every remaining occurrence sat
# in FREE blocks of the root partition (debugfs icheck found no owning inode), none in any live
# file, none on /boot or the ESP, and the image has no swap. Overwriting the content in place
# before unlinking removes the residue at source and stops it depending on the free-space pass at
# all -- exactly what the log wipe already does.
find /etc/ssh -maxdepth 1 -name 'ssh_host_*' -type f -exec shred -zun 3 {} \; 2>/dev/null || true
rm -f /etc/ssh/ssh_host_*
find /root /home -name authorized_keys -type f -exec shred -zun 3 {} \; 2>/dev/null || true
find /root /home -name authorized_keys -type f -delete 2>/dev/null || true

# AB#9186: sshd/PAM record the accepted public key on login (/var/log/auth.log, journald).
# Four earlier appliance builds attacked this from the wrong end -- plain truncate, then
# reordering the wipe, then shredding file content -- each reduced the count without ever
# eliminating it, because the write that mattered happened after every one of those steps.
# See the journald-restart-on-shutdown explanation immediately below, which is the actual
# mechanism. The leaked value is a PUBLIC key (no access risk on its own), but it is
# install-time material that must not ship in a release image, so the build's secret scan
# rightly refuses the VHDX over it.
echo "[generalize-k3s] stopping logging services and shredding logs/journal"
# AB#9186 ROOT CAUSE of the residue described above: stopping journald and deleting
# /var/log/journal is not enough, because systemd STARTS JOURNALD AGAIN during the shutdown
# transaction that this script's own `systemctl poweroff` triggers. On that restart journald
# flushes its runtime (/run) journal -- which still holds the sshd "Accepted publickey" records
# from every SSH session used to drive this script -- into a freshly recreated /var/log/journal.
# That write lands AFTER the free-space wipe below, which is exactly why the residue survived a
# wipe that was itself working correctly, and why the occurrence count tracked how much SSH
# activity the VM had seen. Forensics on the exported disk confirmed the shape: every hit sat in
# blocks the filesystem considers free, none in any live file, none in the ext4 journal, and the
# image has no swap.
#
# Fix: make journald volatile for the rest of this VM's life. A journald restart during shutdown
# then has nowhere on disk to flush to. cloudgrange-firstboot-k3s.sh removes this drop-in on the
# customer's first boot, so the shipped appliance still gets normal persistent logging.
install -d -m 0755 /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=volatile\n' > /etc/systemd/journald.conf.d/00-cloudgrange-generalize.conf
systemctl stop rsyslog.service syslog.socket 2>/dev/null || true
systemctl stop systemd-journald.socket systemd-journald-dev-log.socket systemd-journald-audit.socket systemd-journald.service 2>/dev/null || true
find /var/log /run/log/journal -type f -exec shred -zun 3 {} \; 2>/dev/null || true
find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -delete
rm -rf /var/log/journal/* /run/log/journal/*
# Deny a recreated journal directory too: with Storage=volatile journald will not use it, but if
# anything else recreates it, an immutable empty directory makes a late persistent write fail
# loudly rather than silently leaving secrets in freed blocks again.
rm -rf /var/log/journal

echo "[generalize-k3s] removing per-machine keys (fwupd client key)"
systemctl stop fwupd-refresh.timer fwupd-refresh.service fwupd.service 2>/dev/null || true
systemctl mask --runtime fwupd.service fwupd-refresh.service fwupd-refresh.timer >/dev/null 2>&1 || true
rm -f /var/lib/fwupd/pki/secret.key /var/lib/fwupd/pki/client.pem

echo "[generalize-k3s] cleaning cloud-init, machine-id and temp files"
# AB#9186: cloud-init holds the installer's SSH public key too — it is delivered as user-data at
# VM creation, and cloud-init keeps copies (user-data.txt, cloud-config.txt, the NoCloud seed, the
# per-instance directory). `cloud-init clean` and `rm -rf` are plain deletes, which leave that
# content in freed blocks exactly as the authorized_keys delete did.
#
# Overwriting before unlinking is the only reliable option here, because the root filesystem is
# mounted with `discard` (see /etc/fstab): freed blocks are trimmed through to the virtual disk
# immediately, so the later free-space fill cannot be relied on to re-allocate and overwrite those
# same blocks. Shred while the file still owns them.
find /var/lib/cloud /run/cloud-init -type f -exec shred -zun 3 {} \; 2>/dev/null || true
cloud-init clean --logs --seed --machine-id
rm -f /var/lib/dbus/machine-id
rm -rf /var/lib/cloud/instances/*
find /tmp /var/tmp -mindepth 1 -maxdepth 1 ! -path "$STAGE_DIR" -exec rm -rf {} +
rm -f /root/.bash_history /home/*/.bash_history /root/.lesshst /home/*/.lesshst

rm -f /var/lib/fwupd/pki/secret.key /var/lib/fwupd/pki/client.pem
if [ -e /var/lib/fwupd/pki/secret.key ]; then
    echo "[generalize-k3s] ERROR: /var/lib/fwupd/pki/secret.key reappeared" >&2
    exit 1
fi

# Remove the staged upload BEFORE the wipe, not after: anything deleted after the free-space
# pass leaves its old contents in blocks the pass already went over.
echo "[generalize-k3s] removing the staged upload directory"
STAGE_PARENT="$(dirname "$STAGE_DIR")"
rm -rf "$STAGE_DIR"

echo "[generalize-k3s] overwriting free space (deleted secrets must not survive in freed blocks)"
# AB#9186: this pass is the ONLY thing that can clear blocks freed before this script ran — a
# forensic trace of the last remaining finding was cloud-init NoCloud seed user-data (containing
# ssh_authorized_keys) sitting in a block with no owning inode, i.e. freed long before
# generalization started. Shredding live files cannot reach those; only overwriting free space can.
#
# It used to be `dd ... 2>/dev/null || true`, which hid whether the fill did anything at all. dd is
# EXPECTED to end in ENOSPC — that is success, not failure — so the only meaningful check is
# whether it actually consumed the free space, and that is now asserted rather than assumed.
sync
# ext4 reserves 5% of blocks for root (mkfs default). `df --output=avail` reports what is
# available to NON-root users, so it can read 0 MiB while ~5% of the filesystem is still free in
# reserved blocks — and those reserved blocks are spread through the low block groups, which is
# exactly where surviving key material kept being found (blocks ~34839/~38922, free, not the
# journal, on a filesystem the fill had just reported as full). Drop the reservation to 0 for the
# duration of the fill so it genuinely reaches every free block, then restore it.
root_dev=$(findmnt -no SOURCE /)
reserved_pct_restore=5
if [ -n "$root_dev" ]; then
    reserved_blocks=$(tune2fs -l "$root_dev" 2>/dev/null | awk -F: '/Reserved block count/{gsub(/ /,"",$2);print $2}')
    total_blocks=$(tune2fs -l "$root_dev" 2>/dev/null | awk -F: '/^Block count/{gsub(/ /,"",$2);print $2}')
    if [ -n "$reserved_blocks" ] && [ -n "$total_blocks" ] && [ "$total_blocks" -gt 0 ]; then
        reserved_pct_restore=$(( (reserved_blocks * 100 + total_blocks - 1) / total_blocks ))
    fi
    echo "[generalize-k3s] temporarily dropping ext4 reserved blocks on $root_dev (was ${reserved_pct_restore}%)"
    tune2fs -m 0 "$root_dev" >/dev/null 2>&1 || true
fi

avail_kb_before=$(df --output=avail -k / | tail -1 | tr -d ' ')
echo "[generalize-k3s] free space before fill: $((avail_kb_before / 1024)) MiB"
# Fill the root filesystem. ENOSPC is the intended stopping condition.
dd if=/dev/zero of=/cloudgrange-zerofill bs=16M status=none 2>/dev/null || true
sync
filled_kb=$(du -k /cloudgrange-zerofill 2>/dev/null | awk '{print $1}')
filled_kb=${filled_kb:-0}
avail_kb_after=$(df --output=avail -k / | tail -1 | tr -d ' ')
echo "[generalize-k3s] fill wrote $((filled_kb / 1024)) MiB; free space now $((avail_kb_after / 1024)) MiB"
# The fill must leave the filesystem essentially full. Allow 64 MiB of slack for metadata and the
# root-reserved blocks; more than that means the fill stopped early and freed blocks were NOT
# overwritten, which is exactly the silent failure that let key material reach four exported images.
if [ "$avail_kb_after" -gt 65536 ]; then
    echo "[generalize-k3s] ERROR: free-space overwrite stopped early — $((avail_kb_after / 1024)) MiB still free." >&2
    echo "[generalize-k3s] Refusing to continue: blocks freed before generalization would keep their contents." >&2
    rm -f /cloudgrange-zerofill
    exit 1
fi
rm -f /cloudgrange-zerofill
sync
# Restore the reservation before shipping: 0% reserved on a root filesystem lets a runaway log
# fill the disk to the point where root itself cannot recover it.
if [ -n "$root_dev" ]; then
    echo "[generalize-k3s] restoring ext4 reserved blocks to ${reserved_pct_restore}% on $root_dev"
    tune2fs -m "$reserved_pct_restore" "$root_dev" >/dev/null 2>&1 || true
fi
echo "[generalize-k3s] discarding free blocks"
fstrim -av || true

# AB#9186 — the final, authoritative wipe.
#
# Everything above is best-effort: shredding covers live files, and the dd fill covers blocks that
# were already free when it ran. Neither can cover a block written AFTER the fill, and evidence
# said something was doing exactly that. A verified-complete fill (0 MiB free, 0% reserved) still
# left installer-key bytes in blocks that were free, not the journal, not swap, not outside the
# root partition, and not a VHDX-file artifact — which only leaves a write during the
# fill→poweroff window.
#
# Remounting the root filesystem read-only removes that window by construction: after this point
# nothing can write to the disk at all. zerofree then zeroes every unallocated block of the
# read-only filesystem, which is precisely the job it exists for and which cannot be done safely
# on a read-write mount.
echo "[generalize-k3s] installing zerofree for the final free-block wipe"
if ! command -v zerofree >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -qq -y zerofree >/dev/null 2>&1 || true
fi

if command -v zerofree >/dev/null 2>&1 && [ -n "$root_dev" ]; then
    echo "[generalize-k3s] remounting / read-only (nothing may write after this point)"
    sync
    if mount -o remount,ro / 2>/dev/null; then
        echo "[generalize-k3s] zeroing every free block on $root_dev"
        # Non-fatal: a failure here leaves the image no worse than the passes above, and the
        # build's own secret scan is the gate that decides whether it ships.
        zerofree -v "$root_dev" || echo "[generalize-k3s] WARNING: zerofree failed on $root_dev" >&2
    else
        echo "[generalize-k3s] WARNING: could not remount / read-only; skipping zerofree" >&2
    fi
else
    echo "[generalize-k3s] WARNING: zerofree unavailable; relying on the fill pass alone" >&2
fi
sync

# This must be the LAST thing the script does. Nothing may write to disk between the wipe above
# and poweroff -- that ordering is the whole point, and getting it wrong is what left the SSH
# residue in freed blocks for four builds running. journald is volatile from here on (above), so
# the shutdown transaction's own logging cannot land on disk either.
echo "[generalize-k3s] complete; powering off in 5 seconds"
cd /
# The root filesystem is read-only from here (see the zerofree step), so this is expected to fail
# and is harmless -- the staged directory's contents were already removed before the wipe.
rmdir "$STAGE_PARENT" 2>/dev/null || true
# systemd-run writes its transient unit to /run, which is tmpfs, so this still works on a
# read-only root. Use `poweroff -f` so shutdown does not try to remount or fsck the disk we just
# finished zeroing.
systemd-run --on-active=5 /bin/systemctl poweroff --force >/dev/null
