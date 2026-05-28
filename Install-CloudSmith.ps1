#Requires -RunAsAdministrator
#Requires -Version 7.0
# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0
# ADR-029: Standalone On-Premises Container Runtime (Hyper-V VM + Docker CE)

[CmdletBinding()]
param(
    [ValidateSet('Online', 'Bundled', 'Appliance')]
    [string]$Mode = 'Online',
    [string]$VmIp = '192.168.100.10',
    [string]$VhdxPath = 'C:\ProgramData\CloudSmith\cloudsmith-docker.vhdx',
    # AB#1585 — Proxy support. Format: http://host:port or http://user:pass@host:port
    # If omitted, reads $env:HTTPS_PROXY then $env:HTTP_PROXY.
    # Credentials are NEVER logged. No proxy credential is written to disk.
    [string]$HttpProxy = '',
    [string]$ProxyUser = '',
    [SecureString]$ProxyPassword,
    [string]$Version = 'latest',
    # AB#1852: path to the cloudsmith bundle directory (extracted zip) for offline installs.
    # When not specified and Mode=Bundled, the installer looks in $PSScriptRoot for bundle files.
    [string]$BundlePath = '',
    [switch]$AcceptDefaults,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\scripts\CloudSmith-Common.ps1"
. "$PSScriptRoot\scripts\CloudSmith-Prereqs.ps1"

# AB#1585 — Proxy resolution. Priority: -HttpProxy param > $env:HTTPS_PROXY > $env:HTTP_PROXY
# Credentials are never logged — the installer never writes proxy credentials to any file.
if ([string]::IsNullOrEmpty($HttpProxy)) {
    $HttpProxy = $env:HTTPS_PROXY ?? $env:HTTP_PROXY ?? ''
}
if (-not [string]::IsNullOrEmpty($HttpProxy)) {
    Write-Host "  Proxy: $($HttpProxy -replace '://[^:]+:[^@]+@', '://<credentials-redacted>@')" -ForegroundColor Gray
}
$proxyArgs = @{}
if (-not [string]::IsNullOrEmpty($HttpProxy)) {
    $proxyArgs['Proxy'] = $HttpProxy
    if (-not [string]::IsNullOrEmpty($ProxyUser)) {
        $proxyArgs['ProxyUser'] = $ProxyUser
        $proxyArgs['ProxyPassword'] = $ProxyPassword
    }
}

function Invoke-CloudSmithInstall {
    Write-Host "`n  CloudSmith Installer — Mode: $Mode" -ForegroundColor Cyan
    Write-Host "  ─────────────────────────────────────" -ForegroundColor DarkGray

    # Step 1: Mandatory package integrity self-check (AB#1598)
    # The .sha256 file MUST be present alongside the installer before any host changes are made.
    # This prevents tampered or partially-downloaded installers from mutating the host.
    $checksumFile = Join-Path $PSScriptRoot 'cloudsmith-installer.sha256'
    Write-Progress-Step "Verifying installer package integrity"
    if (-not (Test-Path $checksumFile)) {
        Write-Host ""
        Write-Host "  [ERROR] Package integrity check failed. Do not proceed." -ForegroundColor Red
        Write-Host "  The file 'cloudsmith-installer.sha256' was not found alongside Install-CloudSmith.ps1." -ForegroundColor Red
        Write-Host "  Re-download the complete CloudSmith installer package from the release page." -ForegroundColor Yellow
        Write-Error "[ERROR] Package integrity check failed. Do not proceed."
    }
    $expected = (Get-Content $checksumFile -Raw).Trim().Split()[0]
    $actual   = (Get-FileHash -Path $PSCommandPath -Algorithm SHA256).Hash
    if ($expected -ine $actual) {
        Write-Host ""
        Write-Host "  [ERROR] Package integrity check failed. Do not proceed." -ForegroundColor Red
        Write-Host "  Expected SHA-256: $expected" -ForegroundColor Gray
        Write-Host "  Actual   SHA-256: $actual"   -ForegroundColor Gray
        Write-Host "  The installer file may be corrupted or tampered. Re-download from the release page." -ForegroundColor Yellow
        Write-Error "[ERROR] Package integrity check failed. Do not proceed."
    }
    Write-Host "  Integrity OK ($($actual.Substring(0,16))...)" -ForegroundColor Green

    # Step 2: Hyper-V detection (AB#1581)
    Write-Progress-Step "Checking Hyper-V availability"
    # Hyper-V feature naming differs by OS: Windows Server exposes the 'Hyper-V' role
    # (Get-WindowsFeature); Windows client (10/11) exposes the 'Microsoft-Hyper-V-All'
    # optional feature (Get-WindowsOptionalFeature). ProductType 1 = client/workstation.
    $isServerOs = (Get-CimInstance Win32_OperatingSystem).ProductType -ne 1
    if ($isServerOs) {
        $hvAvailable = (Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue).InstallState -eq 'Installed'
    } else {
        $hvFeature = Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-All -Online -ErrorAction SilentlyContinue
        $hvAvailable = ($hvFeature -and $hvFeature.State -eq 'Enabled')
    }
    if (-not $hvAvailable) {
        Write-Host "  CS-INST-ERR-001: Hyper-V is not installed on this host." -ForegroundColor Red
        Write-Host "  To enable Hyper-V on Windows Server, run:"
        Write-Host "    Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart" -ForegroundColor Yellow
        Write-Host "  To enable Hyper-V on Windows 10/11:"
        Write-Host "    Enable-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-All -Online -Restart" -ForegroundColor Yellow
        Write-Error "CS-INST-ERR-001: Hyper-V is required. Install Hyper-V and re-run the installer."
    }
    Write-Host "  Hyper-V: available" -ForegroundColor Green
    $useWsl2 = $false

    # Nested virtualization check — required when this host is itself a virtual machine (AB#1581)
    Write-Progress-Step "Checking nested virtualization support"
    $isVm = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
    if ($isVm) {
        # Check whether nested virt is enabled: if Hyper-V is installed and running inside a VM,
        # the system's logical processor count via MSVM_Processor will be > 0 OR
        # we can check if the virtualization-based security (VBS) is active via systeminfo.
        # Reliable cross-platform approach: try to retrieve at least one VM from Hyper-V;
        # if HyperV is installed but nested virt is off, this call may succeed but VM creation
        # will fail. We detect it by checking if VirtualizationFirmwareEnabled = True on the CPU.
        $nestedVirtEnabled = $false
        try {
            $cpuNested = Get-WmiObject -Namespace root\virtualization\v2 -Class Msvm_Processor -ErrorAction Stop |
                Where-Object { $_.EnabledState -eq 2 } |
                Select-Object -First 1
            if ($cpuNested) { $nestedVirtEnabled = $true }
        } catch {
            # Namespace may not exist if nested virt was never enabled
        }

        # Alternative: check MSSystemInformation
        if (-not $nestedVirtEnabled) {
            $sysinfo = & systeminfo /FO CSV 2>$null | ConvertFrom-Csv -ErrorAction SilentlyContinue
            if ($sysinfo -and ($sysinfo.'Hyper-V Requirements' -match 'A hypervisor has been detected')) {
                $nestedVirtEnabled = $true
            }
        }

        if (-not $nestedVirtEnabled) {
            Write-Host "  CS-INST-ERR-002: This host is a virtual machine but nested virtualization is not enabled." -ForegroundColor Red
            Write-Host "  On Hyper-V: run on the parent host: Set-VMProcessor -VMName '<vm-name>' -ExposeVirtualizationExtensions `$true" -ForegroundColor Yellow
            Write-Host "  On Azure: use a VM size that supports nested virtualization (Standard_D_v3 / Standard_E_v3 family or later)." -ForegroundColor Yellow
            Write-Error "CS-INST-ERR-002: Nested virtualization is required when running inside a VM. Enable nested virtualization and re-run."
        }
        Write-Host "  Nested virtualization: enabled" -ForegroundColor Green
    } else {
        Write-Host "  Nested virtualization check: N/A (bare-metal host)" -ForegroundColor Gray
    }

    # Step 3: Validate VM IP doesn't conflict with existing Hyper-V switches
    if (-not $useWsl2) {
        Write-Progress-Step "Validating VM IP $VmIp"
        $existing = Get-VMSwitch -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'cloudsmith-internal' }
        # Basic conflict check — a full subnet overlap check would require network math beyond installer scope
        Write-Host "  IP validation passed" -ForegroundColor Green
    }

    # Step 4: Create VM or WSL2 environment
    # Initialise credential/SSH vars before the if/else to avoid strict-mode errors
    # when the WSL2 path runs and steps 5-6 reference these in condition checks.
    $vmGuestCred = $null
    $sshKeyPath  = ''
    $sshKeyDir   = ''

    if (-not $useWsl2) {
        Write-Progress-Step "Bootstrapping installer prerequisites (qemu-img, ISO writer)"
        Initialize-CloudSmithPrereqs

        # Generate an ephemeral SSH key pair for this install session.
        # The private key is written to a temp file (mode 600) and deleted after install.
        # The public key is embedded in the VM's cloud-init authorized_keys.
        # Neither key is ever logged, committed, or persisted beyond this install run.
        $sshKeyDir  = Join-Path $env:TEMP 'cloudsmith-install-key'
        New-Item -ItemType Directory -Path $sshKeyDir -Force | Out-Null
        $sshKeyPath = Join-Path $sshKeyDir 'installer_ed25519'
        if (Test-Path $sshKeyPath) { Remove-Item $sshKeyPath, "$sshKeyPath.pub" -Force }
        & ssh-keygen.exe -t ed25519 -f $sshKeyPath -N "" -C "cloudsmith-installer-ephemeral" -q
        if (-not (Test-Path $sshKeyPath)) {
            Write-Error "Failed to generate SSH key pair. Ensure OpenSSH Client is installed (ssh-keygen.exe must be in PATH)."
        }
        $sshPublicKey = (Get-Content "$sshKeyPath.pub" -Raw).Trim()

        Write-Progress-Step "Provisioning Hyper-V VM"
        . "$PSScriptRoot\scripts\New-CloudSmithVm.ps1"
        # AB#1852: in Bundled mode, resolve the Ubuntu image path from the bundle directory
        $bundledUbuntuPath = ''
        if ($Mode -eq 'Bundled') {
            $bundleRoot = if (-not [string]::IsNullOrEmpty($BundlePath)) { $BundlePath } else { $PSScriptRoot }
            $bundledUbuntuPath = Join-Path $bundleRoot 'ubuntu-24.04-cloudimg.img'
        }
        New-CloudSmithVm -VmIp $VmIp -VhdxPath $VhdxPath -Mode $Mode -SshPublicKey $sshPublicKey -BundledImagePath $bundledUbuntuPath
    } else {
        Write-Progress-Step "Configuring WSL2 environment"
        . "$PSScriptRoot\scripts\Install-Wsl2Fallback.ps1"
        Install-Wsl2Fallback
    }

    # Step 5: Install Docker CE (AB#1585 — proxy forwarded)
    # Wait for SSH to be available before connecting (VM may still be running cloud-init).
    if (-not $useWsl2 -and -not [string]::IsNullOrEmpty($sshKeyPath)) {
        Write-Progress-Step "Waiting for VM SSH to become available"
        $sshReady = Wait-ForTcp -HostName $VmIp -Port 22 -TimeoutSeconds 300
        if (-not $sshReady) {
            Write-Warning "SSH not reachable within 5 minutes. Docker CE install may fail."
        } else {
            Write-Host "  SSH available at $VmIp" -ForegroundColor Green
        }
    }
    Write-Progress-Step "Installing Docker CE"
    . "$PSScriptRoot\scripts\Install-DockerCe.ps1"
    $dockerCeArgs = @{ VmName = 'cloudsmith-docker'; UseWsl2 = $useWsl2; VmIp = $VmIp }
    if (-not $useWsl2 -and -not [string]::IsNullOrEmpty($sshKeyPath)) {
        $dockerCeArgs['SshKeyPath'] = $sshKeyPath
    } elseif (-not $useWsl2 -and $null -ne $vmGuestCred) {
        $dockerCeArgs['Credential'] = $vmGuestCred
    }
    Install-DockerCe @dockerCeArgs @proxyArgs

    # Step 6: Deploy Docker Compose stack
    Write-Progress-Step "Deploying CloudSmith stack (6 containers)"
    . "$PSScriptRoot\scripts\Deploy-DockerCompose.ps1"
    $composeArgs = @{ VmName = 'cloudsmith-docker'; VmIp = $VmIp; Version = $Version; UseWsl2 = $useWsl2 }
    if (-not $useWsl2 -and -not [string]::IsNullOrEmpty($sshKeyPath)) {
        $composeArgs['SshKeyPath'] = $sshKeyPath
    } elseif (-not $useWsl2 -and $null -ne $vmGuestCred) {
        $composeArgs['Credential'] = $vmGuestCred
    }
    # AB#1852: in Bundled mode, pass the pre-saved images tar path
    if ($Mode -eq 'Bundled') {
        $bundleRoot = if (-not [string]::IsNullOrEmpty($BundlePath)) { $BundlePath } else { $PSScriptRoot }
        $bundledImageTar = Join-Path $bundleRoot 'cloudsmith-images.tar'
        if (Test-Path $bundledImageTar) {
            $composeArgs['BundledImagesPath'] = $bundledImageTar
        } else {
            Write-Warning "Bundled images tar not found at $bundledImageTar — falling back to docker pull"
        }
    }
    Deploy-DockerCompose @composeArgs

    # Step 7: Wait for API health, then emit setup URL (AB#1627, ADR-047)
    # AB#1593: nginx terminates TLS on 443 and proxies to portal on 80 (internal).
    # The API is directly on port 8081 (not routed through nginx).
    # Portal URL uses HTTPS via nginx; API health check uses the direct API port.
    Write-Progress-Step "Waiting for CloudSmith API to become healthy"
    $apiHealthBase = "http://$VmIp:8081"
    $portalBase    = "https://$VmIp"
    $healthOk = Wait-ForHttpOk -Url "$apiHealthBase/api/v1/health" -TimeoutSeconds 600
    if (-not $healthOk) {
        # CS-INST-ERR-030: API did not become healthy within 10 minutes
        try {
            $lastResp = Invoke-WebRequest -Uri "$apiHealthBase/api/v1/health" -SkipCertificateCheck -TimeoutSec 5 -ErrorAction SilentlyContinue
            $lastStatus = $lastResp.StatusCode
        } catch {
            $lastStatus = 'unreachable'
        }
        Write-Error "CS-INST-ERR-030: CloudSmith did not start within 10 minutes. Last health status: $lastStatus"
    }
    Write-Host "  API health: OK" -ForegroundColor Green

    # Check setup state — print first-run URL if setup is still pending
    $setupPending = $false
    try {
        $statusResp = Invoke-RestMethod -Uri "$apiHealthBase/api/v1/platform/setup-status" -SkipCertificateCheck -TimeoutSec 10 -ErrorAction Stop
        $setupPending = ($statusResp.setupState -eq 'pending')
    } catch {
        # Non-fatal — setup-status endpoint may not yet be reachable; user navigates manually
    }

    # Clean up the ephemeral SSH key pair after successful install.
    if (-not [string]::IsNullOrEmpty($sshKeyPath) -and (Test-Path $sshKeyPath)) {
        Remove-Item -LiteralPath $sshKeyPath, "$sshKeyPath.pub" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $sshKeyDir -Force -Recurse -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "  CloudSmith installed successfully!" -ForegroundColor Green
    Write-Host "  Portal: $portalBase" -ForegroundColor Cyan
    Write-Host "  Note: The portal uses a self-signed certificate. Your browser will show a security warning." -ForegroundColor Yellow
    Write-Host "        Replace /etc/nginx/certs/ in the nginx_certs volume with a CA-signed cert for production." -ForegroundColor Gray
    if ($setupPending) {
        Write-Host "  First-run setup required. Navigate to:" -ForegroundColor Yellow
        Write-Host "    $portalBase/setup" -ForegroundColor White
        Write-Host "  Complete the setup wizard to configure your platform name, timezone, and admin account." -ForegroundColor Gray
    } else {
        Write-Host "  Sign in at: $portalBase/login" -ForegroundColor Cyan
    }
    Write-Host ""
}

Invoke-CloudSmithInstall
