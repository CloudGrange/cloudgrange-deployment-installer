#Requires -RunAsAdministrator
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
# ADR-029: provisions cloudgrange-docker Hyper-V VM — Gen2, Ubuntu 24.04, Docker CE host
#
# Supports two invocation modes:
#   Dot-sourced: . .\New-CloudGrangeVm.ps1 then call New-CloudGrangeVm -VmIp ...
#   Direct:      powershell.exe -File New-CloudGrangeVm.ps1 -VmIp ... (used by PS7 installer)
#
# Hyper-V cmdlets (Get-VMSwitch, New-VM, etc.) require Windows PowerShell (PS5.1).
# The main installer (PS7) delegates VM provisioning here via powershell.exe.

# Script-level param block MUST be the first statement after #Requires/comments.
param(
    [string]$VmIp             = '192.168.100.10',
    [string]$VhdxPath         = 'C:\ProgramData\CloudGrange\cloudgrange-docker.vhdx',
    [string]$Mode             = 'Online',
    [string]$BundledImagePath = '',
    [string]$SshPublicKey     = '',
    # Path to the SSH public key file. Preferred over -SshPublicKey when invoking via
    # powershell.exe -File to avoid argument-splitting on the space inside the key string.
    [string]$SshPublicKeyFile = '',
    [string]$SwitchName       = 'cloudgrange-internal',
    # AB#9185 fix: was hardcoded to 'cloudgrange-docker' below regardless of caller, so a
    # -Engine K3s install (Install-CloudGrange.ps1 passes Deploy-K3sHelm a VmName of
    # 'cloudgrange-k3s') would still provision/replace a Hyper-V VM literally named
    # cloudgrange-docker — silently colliding with (and on rerun, deleting) any existing
    # Compose VM of that name. Found via real Hyper-V testing before it ever shipped.
    [string]$VmName           = 'cloudgrange-docker',
    [switch]$SkipHostPortForward,
    [switch]$NoDefaultGateway,
    [switch]$InstallPinnedQemu
)

function New-CloudGrangeVm {
    [CmdletBinding()]
    param(
        [string]$VmIp    = '192.168.100.10',
        [string]$VhdxPath = 'C:\ProgramData\CloudGrange\cloudgrange-docker.vhdx',
        [string]$Mode    = 'Online',
        [string]$BundledImagePath = '',
        # Password for the cloudgrange OS user, set via cloud-init. Generated fresh per install;
        # lives in memory only. When null/empty, the account is locked (SSH key only).
        [SecureString]$VmUserPassword = $null,
        # SSH public key (openssh format: "ssh-ed25519 AAAA... comment") to add to
        # the cloudgrange user's authorized_keys via cloud-init. When provided, the
        # installer uses SSH (not Hyper-V PowerShell Direct) to run guest commands.
        [string]$SshPublicKey = '',
        # AB#8129: an existing switch is used as-is (no host IP or NAT changes).
        [string]$SwitchName = 'cloudgrange-internal',
        # AB#9185: caller-supplied VM name — see the script-level param comment above for why
        # this can no longer be silently hardcoded.
        [string]$VmName = 'cloudgrange-docker',
        # AB#8129: skip the host-wide inbound 443 firewall rule and netsh portproxy.
        [switch]$SkipHostPortForward,
        # AB#8129: air-gapped VM. No default route or public DNS in cloud-init network-config;
        # the VM reaches only its own /24 (the host). Used for Bundled installs with no egress.
        [switch]$NoDefaultGateway,
        # AB#9171 (C3): only consulted on the qemu-img fallback path (no pre-converted base VHDX).
        [switch]$InstallPinnedQemu
    )

    $ErrorActionPreference = 'Stop'

    $vmName     = $VmName
    $switchName = $SwitchName
    # Gateway/host IP and NAT prefix derive from the VM IP (/24) instead of a fixed 192.168.100.x.
    $subnetBase = $VmIp -replace '\.\d+$', ''
    $hostIp     = "$subnetBase.1"
    $natPrefix  = "$subnetBase.0/24"
    $natName    = 'CloudGrangeNAT'

    # Import Hyper-V module — required in PS5.1 subprocess context (PS7 cannot load it).
    # Auto-install the Hyper-V PowerShell management tools if missing (e.g. when Hyper-V
    # hypervisor was installed via DISM without -IncludeManagementTools).
    if (-not (Get-Module -Name Hyper-V -ListAvailable -ErrorAction SilentlyContinue)) {
        Write-Host "  Installing Hyper-V PowerShell management tools..."
        $feat = Install-WindowsFeature -Name Hyper-V-PowerShell -ErrorAction SilentlyContinue
        if (-not $feat -or $feat.ExitCode -notin @('Success', 'NoChangeNeeded')) {
            # DISM fallback for environments where Install-WindowsFeature is constrained.
            & dism.exe /Online /Enable-Feature:Microsoft-Hyper-V-Management-PowerShell /NoRestart /Quiet 2>&1 | Out-Null
        }
    }
    Import-Module Hyper-V -ErrorAction Stop

    # Remove any existing cloudgrange-docker VM before (re)provisioning.
    # This releases VHDX and DVD-drive ISO file locks held by a running VM from a
    # prior install attempt, preventing "file in use" errors on VHDX convert and
    # ISO rebuild, and OOM failures from two 8 GB VMs existing simultaneously.
    $existingVm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($existingVm) {
        Write-Host "  Removing existing VM: $vmName"
        if ($existingVm.State -ne 'Off') {
            Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
        Remove-VM -Name $vmName -Force
        Write-Host "  Existing VM removed"
    }

    # Hyper-V internal switch + WinNAT so the cloudgrange-docker VM has internet access.
    # An Internal switch provides a private network; WinNAT adds outbound NAT so the
    # nested VM can pull images from ghcr.io, update packages, etc.
    # AB#8129: an existing switch (e.g. one already backed by WinNAT) is used unchanged. WinNAT
    # supports only one NAT network per host, so creating a second switch + NAT fails on hosts
    # that already run one (Docker Desktop, WSL, lab NATs).
    $createdSwitch = $false
    if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
        Write-Host "  Creating Hyper-V internal switch: $switchName"
        New-VMSwitch -Name $switchName -SwitchType Internal | Out-Null
        $createdSwitch = $true
    } else {
        Write-Host "  Using existing Hyper-V switch: $switchName (no host IP or NAT changes)"
    }
    # Assign the host-side IP on the switch NIC (gateway for the nested VM).
    # The adapter may take a moment to appear after New-VMSwitch; retry up to 10 seconds.
    $hostNic = $null
    if ($createdSwitch) {
    for ($i = 0; $i -lt 10; $i++) {
        $hostNic = Get-NetAdapter | Where-Object { $_.Name -eq "vEthernet ($switchName)" }
        if ($hostNic) { break }
        Start-Sleep -Seconds 1
    }
    if ($hostNic) {
        $existing = Get-NetIPAddress -InterfaceIndex $hostNic.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq $hostIp }
        if (-not $existing) {
            Write-Host "  Assigning host IP $hostIp to $($hostNic.Name)"
            New-NetIPAddress -InterfaceIndex $hostNic.InterfaceIndex -IPAddress $hostIp -PrefixLength 24 -ErrorAction SilentlyContinue | Out-Null
        }
        # Verify the IP was actually assigned — if not, force-remove and re-add
        $verify = Get-NetIPAddress -InterfaceIndex $hostNic.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq $hostIp }
        if (-not $verify) {
            Write-Host "  Re-assigning host IP $hostIp (first attempt failed)..."
            Remove-NetIPAddress -InterfaceIndex $hostNic.InterfaceIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceIndex $hostNic.InterfaceIndex -IPAddress $hostIp -PrefixLength 24 | Out-Null
        }
        $assignedIp = (Get-NetIPAddress -InterfaceIndex $hostNic.InterfaceIndex -AddressFamily IPv4 -EA SilentlyContinue | Where-Object { $_.IPAddress -eq $hostIp }).IPAddress
        Write-Host "  Host gateway IP: $assignedIp"
    } else {
        Write-Warning "  vEthernet ($switchName) adapter not found after 10s - host IP not assigned."
    }
    }
    # Create WinNAT for outbound internet from the nested VM's subnet, unless a NAT already
    # covers that prefix (WinNAT allows one NAT network per host).
    $coveringNat = Get-NetNat -ErrorAction SilentlyContinue | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $natPrefix }
    if ($coveringNat) {
        Write-Host "  Outbound NAT already provided by: $($coveringNat.Name) ($natPrefix)"
    } elseif ($createdSwitch -and -not (Get-NetNat -Name $natName -ErrorAction SilentlyContinue)) {
        Write-Host "  Creating WinNAT: $natName ($natPrefix)"
        New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $natPrefix | Out-Null
    }

    # Ensure VHDX directory exists
    $vhdxDir = Split-Path $VhdxPath -Parent
    New-Item -ItemType Directory -Path $vhdxDir -Force | Out-Null

    # AB#9171 (C3): the base disk. Preferred: the release's pinned, pre-converted Ubuntu base VHDX, so
    # the Windows host needs no qemu-img at all. Fallback only when the release pins none or it cannot
    # be downloaded: the pinned cloud image (by serial -- this used to download the rolling "current" image, i.e.
    # whatever Canonical published that day) converted with qemu-img. Both are verified against
    # release/pins.conf; a mismatch stops the install instead of falling back. See CloudGrange-Prereqs.ps1.
    . "$PSScriptRoot\CloudGrange-Prereqs.ps1"
    $baseDiskArgs = @{
        VhdxPath          = $VhdxPath
        PinsPath          = (Join-Path (Split-Path $PSScriptRoot -Parent) 'release\pins.conf')
        InstallPinnedQemu = $InstallPinnedQemu
    }
    if ($Mode -eq 'Bundled') { $baseDiskArgs['BundledImagePath'] = $BundledImagePath }
    New-CloudGrangeBaseDisk @baseDiskArgs

    # Build cloud-init NoCloud seed ISO (user-data + meta-data)
    # AB#9171: per VM, so a second install on the same host never collides with a running VM's seed.
    $ciDir = Join-Path $env:TEMP "cloudgrange-cloud-init-$vmName"
    New-Item -ItemType Directory -Path $ciDir -Force | Out-Null

    # Build optional chpasswd block. When a VM user password is provided, cloud-init
    # sets it via chpasswd so Hyper-V Direct (VMBus IC) PSCredential auth works.
    # The password lives only in memory during install — never written to any log or file.
    $chpasswdBlock = ''
    if ($VmUserPassword -ne $null -and $VmUserPassword.Length -gt 0) {
        $bstr     = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($VmUserPassword)
        $plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $chpasswdBlock = @"

chpasswd:
  expire: false
  list: |
    cloudgrange:$plainPwd
"@
    }

    # Build optional SSH authorized_keys line for cloud-init users block.
    $sshKeyLine = ''
    if (-not [string]::IsNullOrEmpty($SshPublicKey)) {
        $sshKeyLine = "`n    ssh_authorized_keys:`n      - $SshPublicKey"
    }

    $vmGateway4 = $VmIp -replace '\.\d+$', '.1'

    # user-data: OS configuration + belt-and-suspenders manual network setup via runcmd.
    # Network config lives in the separate network-config file, but we ALSO configure
    # the network manually via runcmd in case cloud-init's netplan module doesn't apply it
    # (e.g., if the hv_netvsc match times out before the NIC is ready at cloud-init time).
    # Build the runcmd net-setup script separately to avoid PowerShell heredoc escaping issues.
    # bash variables and command substitutions need literal dollar signs in the cloud-init YAML,
    # which in a PS double-quoted heredoc requires backtick-escaping.
    $netSetupScript = @'
#!/bin/bash
set -e
LOG=/var/log/cloudgrange-init.log
echo "cloudgrange-runcmd-start $(date)" >> $LOG
# Find first non-loopback interface
for i in $(seq 1 30); do
  IFACE=$(ip link show | grep -E '^[0-9]+:' | grep -v lo | awk -F': ' '{print $2}' | head -1)
  [ -n "$IFACE" ] && break
  sleep 2
done
echo "NIC: $IFACE" >> $LOG
if [ -z "$IFACE" ]; then echo "NO NIC" >> $LOG; exit 0; fi
# Set static IP if not already configured
if ! ip addr show "$IFACE" | grep -q "VMIP_PLACEHOLDER"; then
  ip addr flush dev "$IFACE" 2>/dev/null || true
  ip addr add VMIP_PLACEHOLDER/24 dev "$IFACE"
  ip link set "$IFACE" up
  if [ "NOGW_PLACEHOLDER" != "1" ]; then
    ip route add default via GWIP_PLACEHOLDER dev "$IFACE" 2>/dev/null || true
    printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
  fi
  echo "IP set manually on $IFACE" >> $LOG
else
  echo "IP already present (netplan)" >> $LOG
fi
# AB#8129: openssh-server ships in the Ubuntu cloud image; no package install here, so an
# air-gapped VM (no default route) completes runcmd. qemu-guest-agent is not used on Hyper-V.
systemctl enable --now ssh >> $LOG 2>&1 || true
echo "cloudgrange-runcmd-done $(date)" >> $LOG
'@
    # Substitute the actual IP/gateway into the script
    $netSetupScript = $netSetupScript -replace 'VMIP_PLACEHOLDER', $VmIp -replace 'GWIP_PLACEHOLDER', $vmGateway4 -replace 'NOGW_PLACEHOLDER', $(if ($NoDefaultGateway) { '1' } else { '0' })

    # Pre-compute indented script block outside here-string to avoid PS5.1 parse issues
    # with complex ForEach-Object scriptblocks inside $(...)  in double-quoted strings.
    $netSetupScriptIndented = ($netSetupScript -split "`n" | ForEach-Object { "      $_" }) -join "`n"

    $userData = @"
#cloud-config
hostname: $vmName
manage_etc_hosts: true
users:
  - name: cloudgrange
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: '*'$sshKeyLine
$chpasswdBlock
# AB#9171: a managed foundation. Nothing updates the OS on its own (owner decision 2026-09-18):
# cloud-init must not upgrade packages at first boot, and Ubuntu's unattended-upgrades and the
# apt-daily timers are switched off before anything else runs. OS updates are applied by an
# administrator from Platform -> Updates -> Foundation. Install-CloudGrangeK3s.sh repeats this.
package_update: false
package_upgrade: false
package_reboot_if_required: false
write_files:
  - path: /usr/local/bin/cloudgrange-net-setup.sh
    permissions: '0755'
    content: |
$netSetupScriptIndented
  - path: /etc/apt/apt.conf.d/99cloudgrange-no-automatic-updates
    permissions: '0644'
    content: |
      APT::Periodic::Update-Package-Lists "0";
      APT::Periodic::Download-Upgradeable-Packages "0";
      APT::Periodic::AutocleanInterval "0";
      APT::Periodic::Unattended-Upgrade "0";
runcmd:
  - [ systemctl, disable, --now, unattended-upgrades.service, apt-daily.timer, apt-daily-upgrade.timer ]
  - [ systemctl, mask, unattended-upgrades.service, apt-daily.timer, apt-daily-upgrade.timer ]
  - /usr/local/bin/cloudgrange-net-setup.sh
"@

    # AB#8129: unique instance-id per provisioning so cloud-init per-instance state is never reused.
    $metaData = @"
instance-id: $vmName-$([guid]::NewGuid().ToString('N'))
local-hostname: $vmName
"@

    # network-config: separate file for the NoCloud datasource.
    # Use a broad match to handle both 'eth0' (older udev) and 'ens*'/'enp*' (predictable names).
    # Also includes a fallback match by MAC prefix for resilience.
    # The runcmd in user-data is a belt-and-suspenders fallback if netplan doesn't apply.
    $networkConfig = @"
version: 2
ethernets:
  cloudgrange-eth:
    match:
      name: "e*"
    set-name: eth0
    dhcp4: false
    addresses: [$VmIp/24]
"@
    if (-not $NoDefaultGateway) {
        $networkConfig += @"

    routes:
      - to: default
        via: $vmGateway4
    nameservers:
      addresses: [8.8.8.8, 1.1.1.1]
"@
    }

    # PS5.1 Set-Content -Encoding UTF8 emits a UTF-8 BOM (0xEF 0xBB 0xBF). Cloud-init
    # checks whether user-data starts with the literal bytes '#cloud-config'; a BOM
    # prefix causes that check to fail and every cloud-config module (users, write_files,
    # runcmd) is skipped entirely. Use File.WriteAllText with an explicit no-BOM encoder.
    # Also normalize CRLF -> LF: PS5.1 heredocs use CRLF; cloud-init's YAML parser
    # handles mixed endings but pure LF avoids any edge cases.
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $userData      = $userData      -replace "`r`n", "`n"
    $metaData      = $metaData      -replace "`r`n", "`n"
    $networkConfig = $networkConfig -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText((Join-Path $ciDir 'user-data'),      $userData,      $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $ciDir 'meta-data'),      $metaData,      $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $ciDir 'network-config'), $networkConfig, $utf8NoBom)

    # AB#9171: per VM. One shared file was held open by the first VM's DVD drive, so a second install
    # on the same host (a -VmName install) failed to rebuild it ("being used by another process").
    $seedIso = Join-Path $vhdxDir "$vmName-cloud-init-seed.iso"
    # Build the NoCloud seed ISO via IMAPI2 (built into Windows since Vista).
    # No Windows ADK / oscdimg dependency — operators are not expected to install
    # developer tools to deploy CloudGrange on-prem.
    . "$PSScriptRoot\CloudGrange-Prereqs.ps1"
    Write-Host "  Building cloud-init seed ISO (IMAPI2)..."
    New-CiDataIso -SourceDir $ciDir -OutputIso $seedIso -VolumeLabel 'cidata'

    # Disk space pre-flight check — AB#1582 requires 60 GB minimum (AB#1581)
    $vhdxDrive = Split-Path $VhdxPath -Qualifier
    $freeBytes = (Get-PSDrive -Name $vhdxDrive.TrimEnd(':') -ErrorAction SilentlyContinue).Free
    if ($freeBytes -and $freeBytes -lt 64GB) {
        $freeGB = [Math]::Round($freeBytes / 1GB, 1)
        Write-Error "CG-INST-ERR-003: Insufficient disk space at $VhdxPath. Required: 60 GB free. Available: ${freeGB} GB."
    }

    # Create VM — Generation 2, 8 GB RAM (static minimum), 4 vCPU, Secure Boot (AB#1582)
    Write-Host "  Creating VM: $vmName"
    $vm = New-VM -Name $vmName -Generation 2 -VHDPath $VhdxPath -SwitchName $switchName
    Set-VM -VM $vm `
        -StaticMemory `
        -MemoryStartupBytes 8GB `
        -ProcessorCount 4 `
        -AutomaticStartAction Start `
        -AutomaticStartDelay 30 `
        -AutomaticStopAction ShutDown

    # Secure Boot: MicrosoftUEFICertificateAuthority template is required for Gen2 Linux VMs.
    # This is NOT the same as disabling Secure Boot — it uses the Microsoft-signed UEFI shim
    # that Ubuntu ships, which allows Secure Boot to stay ON while booting an unsigned Linux kernel.
    Set-VMFirmware -VM $vm -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'
    Set-VMFirmware -VM $vm -EnableSecureBoot On

    # Attach cloud-init seed ISO if created
    if (Test-Path $seedIso) {
        Add-VMDvdDrive -VM $vm -Path $seedIso
    }

    # Windows Firewall + netsh portproxy from the management NIC to the VM, for the portal (443) and,
    # AB#9171, the site relay (8443). The relay is the on-prem stack's agent endpoint (a LoadBalancer
    # Service, which K3s's servicelb publishes on the VM's own IP); forwarding only 443 left agents
    # outside the host unable to reach it through the NAT.
    if ($SkipHostPortForward) {
        Write-Host "  Skipping host 443/8443 firewall rules and portproxy (-SkipHostPortForward)"
    } else {
        foreach ($forward in @(@{ Port = 443; Rule = 'CloudGrange-Portal-443' }, @{ Port = 8443; Rule = 'CloudGrange-Relay-8443' })) {
            if (-not (Get-NetFirewallRule -DisplayName $forward.Rule -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $forward.Rule -Direction Inbound -Protocol TCP -LocalPort $forward.Port -Action Allow | Out-Null
            }
            # Re-point the forward every time: a reinstall may use a different -VmIp.
            netsh interface portproxy delete v4tov4 listenport=$($forward.Port) | Out-Null
            netsh interface portproxy add v4tov4 listenport=$($forward.Port) connectaddress=$VmIp connectport=$($forward.Port) | Out-Null
        }
    }

    Write-Host "  Starting VM..."
    Start-VM -Name $vmName

    # Wait for VM SSH to become available (max 10 minutes).
    # Ubuntu 24.04 cloud-init runcmd must: detect NIC, set static IP, run apt-get
    # (openssh-server + qemu-guest-agent), then start sshd. On a cold apt cache
    # this takes 4-8 minutes. Allow 10 minutes total.
    Write-Host "  Waiting for VM SSH to become available (up to 10 minutes)..."
    $reachable = Wait-ForTcp -HostName $VmIp -Port 22 -TimeoutSeconds 600
    if (-not $reachable) {
        Write-Warning "VM did not become reachable within 10 minutes. Check Hyper-V console."
    } else {
        Write-Host "  VM is reachable at $VmIp" -ForegroundColor Green
    }
}

# When invoked directly via powershell.exe -File (not dot-sourced), load dependencies and run.
# $MyInvocation.InvocationName is '.' when dot-sourced; the script path when run directly.
if ($MyInvocation.InvocationName -ne '.') {
    # Resolve the effective SSH public key: prefer reading from a file when -SshPublicKeyFile
    # is provided, because the key string contains spaces that can be split by the OS
    # argument parser when passed inline via powershell.exe -File ... -SshPublicKey <key>.
    $effectiveSshKey = $SshPublicKey
    if (-not [string]::IsNullOrEmpty($SshPublicKeyFile) -and (Test-Path -LiteralPath $SshPublicKeyFile)) {
        $effectiveSshKey = (Get-Content -LiteralPath $SshPublicKeyFile -Raw).Trim()
    }

    . "$PSScriptRoot\CloudGrange-Common.ps1"
    New-CloudGrangeVm -VmIp $VmIp -VhdxPath $VhdxPath -Mode $Mode `
        -SshPublicKey $effectiveSshKey -BundledImagePath $BundledImagePath `
        -SwitchName $SwitchName -VmName $VmName -SkipHostPortForward:$SkipHostPortForward -NoDefaultGateway:$NoDefaultGateway `
        -InstallPinnedQemu:$InstallPinnedQemu
}
