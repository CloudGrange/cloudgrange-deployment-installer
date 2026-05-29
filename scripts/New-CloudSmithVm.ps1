#Requires -RunAsAdministrator
# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0
# ADR-029: provisions cloudsmith-docker Hyper-V VM — Gen2, Ubuntu 24.04, Docker CE host
#
# Supports two invocation modes:
#   Dot-sourced: . .\New-CloudSmithVm.ps1 then call New-CloudSmithVm -VmIp ...
#   Direct:      powershell.exe -File New-CloudSmithVm.ps1 -VmIp ... (used by PS7 installer)
#
# Hyper-V cmdlets (Get-VMSwitch, New-VM, etc.) require Windows PowerShell (PS5.1).
# The main installer (PS7) delegates VM provisioning here via powershell.exe.

# Script-level param block MUST be the first statement after #Requires/comments.
param(
    [string]$VmIp             = '192.168.100.10',
    [string]$VhdxPath         = 'C:\ProgramData\CloudSmith\cloudsmith-docker.vhdx',
    [string]$Mode             = 'Online',
    [string]$BundledImagePath = '',
    [string]$SshPublicKey     = '',
    # Path to the SSH public key file. Preferred over -SshPublicKey when invoking via
    # powershell.exe -File to avoid argument-splitting on the space inside the key string.
    [string]$SshPublicKeyFile = ''
)

function New-CloudSmithVm {
    [CmdletBinding()]
    param(
        [string]$VmIp    = '192.168.100.10',
        [string]$VhdxPath = 'C:\ProgramData\CloudSmith\cloudsmith-docker.vhdx',
        [string]$Mode    = 'Online',
        [string]$BundledImagePath = '',
        # Password for the cloudsmith OS user, set via cloud-init. Generated fresh per install;
        # lives in memory only. When null/empty, the account is locked (SSH key only).
        [SecureString]$VmUserPassword = $null,
        # SSH public key (openssh format: "ssh-ed25519 AAAA... comment") to add to
        # the cloudsmith user's authorized_keys via cloud-init. When provided, the
        # installer uses SSH (not Hyper-V PowerShell Direct) to run guest commands.
        [string]$SshPublicKey = ''
    )

    $ErrorActionPreference = 'Stop'

    $vmName     = 'cloudsmith-docker'
    $switchName = 'cloudsmith-internal'
    $hostIp     = '192.168.100.1'
    $vmGateway  = '192.168.100.1'
    $natName    = 'CloudSmithNAT'

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

    # Remove any existing cloudsmith-docker VM before (re)provisioning.
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

    # Hyper-V internal switch + WinNAT so the cloudsmith-docker VM has internet access.
    # An Internal switch provides a private network; WinNAT adds outbound NAT so the
    # nested VM can pull images from ghcr.io, update packages, etc.
    if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
        Write-Host "  Creating Hyper-V internal switch: $switchName"
        New-VMSwitch -Name $switchName -SwitchType Internal | Out-Null
    }
    # Assign the host-side IP on the switch NIC (gateway for the nested VM).
    # The adapter may take a moment to appear after New-VMSwitch; retry up to 10 seconds.
    $hostNic = $null
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
    # Create WinNAT for outbound internet from the nested VM's subnet.
    if (-not (Get-NetNat -Name $natName -ErrorAction SilentlyContinue)) {
        Write-Host "  Creating WinNAT: $natName (192.168.100.0/24)"
        New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix '192.168.100.0/24' | Out-Null
    }

    # Ensure VHDX directory exists
    $vhdxDir = Split-Path $VhdxPath -Parent
    New-Item -ItemType Directory -Path $vhdxDir -Force | Out-Null

    # Obtain Ubuntu 24.04 cloud image
    $cloudImagePath = Join-Path $vhdxDir 'ubuntu-24.04-cloudimg.img'
    if ($Mode -eq 'Online') {
        if (-not (Test-Path $cloudImagePath)) {
            Write-Host "  Downloading Ubuntu 24.04 cloud image..."
            $imgUrl = 'https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img'
            Invoke-WebRequest -Uri $imgUrl -OutFile $cloudImagePath -UseBasicParsing
        }
        # Verify SHA-256 against Canonical's checksum file
        $checksumUrl = 'https://cloud-images.ubuntu.com/noble/current/SHA256SUMS'
        $checksums = (Invoke-WebRequest -Uri $checksumUrl -UseBasicParsing).Content
        $expectedHash = ($checksums -split "`n" | Where-Object { $_ -match 'noble-server-cloudimg-amd64.img' }) -split '\s+' | Select-Object -First 1
        $actualHash = (Get-FileHash -Path $cloudImagePath -Algorithm SHA256).Hash
        if ($expectedHash -and $expectedHash -ine $actualHash) {
            Write-Error "Ubuntu cloud image checksum mismatch. Re-download aborted."
        }
    } elseif ($Mode -eq 'Bundled') {
        $cloudImagePath = $BundledImagePath
        if (-not (Test-Path $cloudImagePath)) {
            Write-Error "Bundled image not found at: $cloudImagePath"
        }
    }

    # Convert .img to VHDX using qemu-img (required for Hyper-V Gen2).
    # The installer auto-installs QEMU in Install-CloudSmithPrereqs; this is a
    # belt-and-braces check in case the function is called directly.
    $qemuImgCmd = Get-Command qemu-img -ErrorAction SilentlyContinue
    $qemuImg = if ($qemuImgCmd) { $qemuImgCmd.Source } else { $null }
    if (-not $qemuImg) {
        . "$PSScriptRoot\CloudSmith-Prereqs.ps1"
        Initialize-CloudSmithPrereqs
        $qemuImgCmd = Get-Command qemu-img -ErrorAction SilentlyContinue
        $qemuImg = if ($qemuImgCmd) { $qemuImgCmd.Source } else { $null }
        if (-not $qemuImg) {
            Write-Error "qemu-img is still missing after bootstrap. Aborting."
        }
    }
    Write-Host "  Converting cloud image to VHDX..."
    & $qemuImg convert -f qcow2 -O vhdx -o subformat=dynamic $cloudImagePath $VhdxPath

    # Clear the NTFS Sparse attribute on the freshly-converted VHDX. Hyper-V
    # Gen2 refuses to power on a sparse VHDX with 0xC03A001A; qemu-img can
    # leave the file marked sparse on NTFS even when subformat=dynamic.
    . "$PSScriptRoot\CloudSmith-Prereqs.ps1"
    Clear-CloudSmithSparseAttribute -Path $VhdxPath

    # Build cloud-init NoCloud seed ISO (user-data + meta-data)
    $ciDir = Join-Path $env:TEMP 'cloudsmith-cloud-init'
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
    cloudsmith:$plainPwd
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
LOG=/var/log/cloudsmith-init.log
echo "cloudsmith-runcmd-start $(date)" >> $LOG
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
  ip route add default via GWIP_PLACEHOLDER dev "$IFACE" 2>/dev/null || true
  printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
  echo "IP set manually on $IFACE" >> $LOG
else
  echo "IP already present (netplan)" >> $LOG
fi
# Install packages
apt-get update -q >> $LOG 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y -q openssh-server qemu-guest-agent >> $LOG 2>&1
systemctl enable --now ssh >> $LOG 2>&1
systemctl enable --now qemu-guest-agent >> $LOG 2>&1
echo "cloudsmith-runcmd-done $(date)" >> $LOG
'@
    # Substitute the actual IP/gateway into the script
    $netSetupScript = $netSetupScript -replace 'VMIP_PLACEHOLDER', $VmIp -replace 'GWIP_PLACEHOLDER', $vmGateway4

    # Pre-compute indented script block outside here-string to avoid PS5.1 parse issues
    # with complex ForEach-Object scriptblocks inside $(...)  in double-quoted strings.
    $netSetupScriptIndented = ($netSetupScript -split "`n" | ForEach-Object { "      $_" }) -join "`n"

    $userData = @"
#cloud-config
hostname: cloudsmith-docker
manage_etc_hosts: true
users:
  - name: cloudsmith
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: '*'$sshKeyLine
$chpasswdBlock
write_files:
  - path: /usr/local/bin/cloudsmith-net-setup.sh
    permissions: '0755'
    content: |
$netSetupScriptIndented
runcmd:
  - /usr/local/bin/cloudsmith-net-setup.sh
"@

    $metaData = @"
instance-id: cloudsmith-docker
local-hostname: cloudsmith-docker
"@

    # network-config: separate file for the NoCloud datasource.
    # Use a broad match to handle both 'eth0' (older udev) and 'ens*'/'enp*' (predictable names).
    # Also includes a fallback match by MAC prefix for resilience.
    # The runcmd in user-data is a belt-and-suspenders fallback if netplan doesn't apply.
    $networkConfig = @"
version: 2
ethernets:
  cloudsmith-eth:
    match:
      name: "e*"
    set-name: eth0
    dhcp4: false
    addresses: [$VmIp/24]
    routes:
      - to: default
        via: $vmGateway4
    nameservers:
      addresses: [8.8.8.8, 1.1.1.1]
"@

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

    $seedIso = Join-Path $vhdxDir 'cloud-init-seed.iso'
    # Build the NoCloud seed ISO via IMAPI2 (built into Windows since Vista).
    # No Windows ADK / oscdimg dependency — operators are not expected to install
    # developer tools to deploy CloudSmith on-prem.
    . "$PSScriptRoot\CloudSmith-Prereqs.ps1"
    Write-Host "  Building cloud-init seed ISO (IMAPI2)..."
    New-CiDataIso -SourceDir $ciDir -OutputIso $seedIso -VolumeLabel 'cidata'

    # Disk space pre-flight check — AB#1582 requires 60 GB minimum (AB#1581)
    $vhdxDrive = Split-Path $VhdxPath -Qualifier
    $freeBytes = (Get-PSDrive -Name $vhdxDrive.TrimEnd(':') -ErrorAction SilentlyContinue).Free
    if ($freeBytes -and $freeBytes -lt 64GB) {
        $freeGB = [Math]::Round($freeBytes / 1GB, 1)
        Write-Error "CS-INST-ERR-003: Insufficient disk space at $VhdxPath. Required: 60 GB free. Available: ${freeGB} GB."
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

    # Windows Firewall — forward port 443 from management NIC to VM
    $fwRuleName = 'CloudSmith-Portal-443'
    if (-not (Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $fwRuleName -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow | Out-Null
        # Port forwarding via netsh portproxy (management NIC → VM IP)
        netsh interface portproxy add v4tov4 listenport=443 connectaddress=$VmIp connectport=443 | Out-Null
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

    . "$PSScriptRoot\CloudSmith-Common.ps1"
    New-CloudSmithVm -VmIp $VmIp -VhdxPath $VhdxPath -Mode $Mode `
        -SshPublicKey $effectiveSshKey -BundledImagePath $BundledImagePath
}
