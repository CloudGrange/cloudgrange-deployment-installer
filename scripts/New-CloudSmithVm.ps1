#Requires -RunAsAdministrator
# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0
# ADR-029: provisions cloudsmith-docker Hyper-V VM — Gen2, Ubuntu 24.04, Docker CE host

function New-CloudSmithVm {
    [CmdletBinding()]
    param(
        [string]$VmIp    = '192.168.100.10',
        [string]$VhdxPath = 'C:\ProgramData\CloudSmith\cloudsmith-docker.vhdx',
        [string]$Mode    = 'Online',
        [string]$BundledImagePath = ''
    )

    $vmName   = 'cloudsmith-docker'
    $switchName = 'cloudsmith-internal'

    # Hyper-V internal switch
    if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
        Write-Host "  Creating Hyper-V internal switch: $switchName"
        New-VMSwitch -Name $switchName -SwitchType Internal | Out-Null
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

    # Convert .img to VHDX using qemu-img (required for Hyper-V Gen2)
    $qemuImg = (Get-Command qemu-img -ErrorAction SilentlyContinue)?.Source
    if (-not $qemuImg) {
        Write-Error "qemu-img is required to convert the cloud image to VHDX. Install QEMU for Windows: https://www.qemu.org/download/#windows"
    }
    Write-Host "  Converting cloud image to VHDX..."
    & $qemuImg convert -f qcow2 -O vhdx -o subformat=dynamic $cloudImagePath $VhdxPath

    # Build cloud-init NoCloud seed ISO (user-data + meta-data)
    $ciDir = Join-Path $env:TEMP 'cloudsmith-cloud-init'
    New-Item -ItemType Directory -Path $ciDir -Force | Out-Null

    $userData = @"
#cloud-config
hostname: cloudsmith-docker
manage_etc_hosts: true
users:
  - name: cloudsmith
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: '*'
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses: [$VmIp/24]
      gateway4: $(($VmIp -replace '\.\d+$', '.1'))
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
"@

    $metaData = @"
instance-id: cloudsmith-docker
local-hostname: cloudsmith-docker
"@

    Set-Content -Path (Join-Path $ciDir 'user-data') -Value $userData -Encoding UTF8
    Set-Content -Path (Join-Path $ciDir 'meta-data') -Value $metaData -Encoding UTF8

    $seedIso = Join-Path $vhdxDir 'cloud-init-seed.iso'
    # Use oscdimg (Windows ADK) or mkisofs to create NoCloud ISO
    $oscdimg = (Get-Command oscdimg -ErrorAction SilentlyContinue)?.Source
    if ($oscdimg) {
        & $oscdimg -j1 -o -m -lcidata $ciDir $seedIso | Out-Null
    } else {
        Write-Warning "oscdimg not found — cloud-init seed ISO could not be created. Install Windows ADK or use the Appliance mode."
    }

    # Create VM — Generation 2, dynamic RAM 4 GB (max 8 GB), 2 vCPU
    Write-Host "  Creating VM: $vmName"
    $vm = New-VM -Name $vmName -Generation 2 -VHDPath $VhdxPath -SwitchName $switchName
    Set-VM -VM $vm `
        -DynamicMemory `
        -MemoryStartupBytes 4GB `
        -MemoryMinimumBytes 1GB `
        -MemoryMaximumBytes 8GB `
        -ProcessorCount 2 `
        -AutomaticStartAction Start `
        -AutomaticStartDelay 30 `
        -AutomaticStopAction ShutDown

    # Disable Secure Boot for Ubuntu (required for Gen2 Linux VMs)
    Set-VMFirmware -VM $vm -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'
    Set-VMFirmware -VM $vm -EnableSecureBoot Off

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

    # Wait for VM to become reachable (max 3 minutes)
    Write-Host "  Waiting for VM to boot (up to 3 minutes)..."
    $reachable = Wait-ForTcp -Host $VmIp -Port 22 -TimeoutSeconds 180
    if (-not $reachable) {
        Write-Warning "VM did not become reachable within 3 minutes. Check Hyper-V console."
    } else {
        Write-Host "  VM is reachable at $VmIp" -ForegroundColor Green
    }
}
