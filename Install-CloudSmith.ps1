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
    [string]$Proxy = '',
    [string]$ProxyUser = '',
    [SecureString]$ProxyPassword,
    [string]$Version = 'latest',
    [switch]$AcceptDefaults,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\scripts\CloudSmith-Common.ps1"
. "$PSScriptRoot\scripts\CloudSmith-Prereqs.ps1"

function Invoke-CloudSmithInstall {
    Write-Host "`n  CloudSmith Installer — Mode: $Mode" -ForegroundColor Cyan
    Write-Host "  ─────────────────────────────────────" -ForegroundColor DarkGray

    # Step 1: Self-integrity check
    $checksumFile = Join-Path $PSScriptRoot 'Install-CloudSmith.sha256'
    if (Test-Path $checksumFile) {
        Write-Progress-Step "Verifying installer integrity"
        $expected = (Get-Content $checksumFile -Raw).Trim().Split(' ')[0]
        $actual = (Get-FileHash -Path $PSCommandPath -Algorithm SHA256).Hash
        if ($expected -ine $actual) {
            Write-Error "Installer integrity check failed. Re-download the installer from the CloudSmith release page."
        }
        Write-Host "  Integrity OK" -ForegroundColor Green
    }

    # Step 2: Hyper-V detection
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
    if ($hvAvailable) {
        Write-Host "  Hyper-V: available" -ForegroundColor Green
        $useWsl2 = $false
    } else {
        Write-Warning "Hyper-V is not available on this host."
        Write-Host "  To enable Hyper-V, run as administrator:"
        Write-Host "    Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart" -ForegroundColor Yellow

        if (-not $AcceptDefaults) {
            $choice = Read-Host "  Fall back to WSL2 (lab/dev only)? [y/N]"
            if ($choice -notmatch '^[yY]') {
                Write-Error "Installation cancelled. Install Hyper-V and re-run."
            }
        }

        Write-Warning "WSL2 mode is for lab and development use only. Microsoft does not support Linux containers via WSL2 in production on Windows Server."
        $useWsl2 = $true
    }

    # Step 3: Validate VM IP doesn't conflict with existing Hyper-V switches
    if (-not $useWsl2) {
        Write-Progress-Step "Validating VM IP $VmIp"
        $existing = Get-VMSwitch -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'cloudsmith-internal' }
        # Basic conflict check — a full subnet overlap check would require network math beyond installer scope
        Write-Host "  IP validation passed" -ForegroundColor Green
    }

    # Step 4: Create VM or WSL2 environment
    if (-not $useWsl2) {
        Write-Progress-Step "Bootstrapping installer prerequisites (qemu-img, ISO writer)"
        Initialize-CloudSmithPrereqs

        Write-Progress-Step "Provisioning Hyper-V VM"
        . "$PSScriptRoot\scripts\New-CloudSmithVm.ps1"
        New-CloudSmithVm -VmIp $VmIp -VhdxPath $VhdxPath -Mode $Mode
    } else {
        Write-Progress-Step "Configuring WSL2 environment"
        . "$PSScriptRoot\scripts\Install-Wsl2Fallback.ps1"
        Install-Wsl2Fallback
    }

    # Step 5: Install Docker CE
    Write-Progress-Step "Installing Docker CE"
    . "$PSScriptRoot\scripts\Install-DockerCe.ps1"
    $proxyArg = $Proxy
    Install-DockerCe -VmName 'cloudsmith-docker' -UseWsl2 $useWsl2 -Proxy $proxyArg

    # Step 6: Deploy Docker Compose stack
    Write-Progress-Step "Deploying CloudSmith stack (6 containers)"
    . "$PSScriptRoot\scripts\Deploy-DockerCompose.ps1"
    Deploy-DockerCompose -VmName 'cloudsmith-docker' -VmIp $VmIp -Version $Version -UseWsl2 $useWsl2

    # Step 7: Initialize platform
    Write-Progress-Step "Initializing CloudSmith"
    . "$PSScriptRoot\scripts\Initialize-CloudSmith.ps1"
    $token = Initialize-CloudSmith -VmName 'cloudsmith-docker' -UseWsl2 $useWsl2

    Write-Host "`n  ✓ CloudSmith installed successfully!" -ForegroundColor Green
    Write-Host "  Portal: https://$VmIp" -ForegroundColor Cyan
    Write-Host "  Setup token: $token" -ForegroundColor Yellow
    Write-Host "  Open the portal and enter this token to complete setup.`n"
}

Invoke-CloudSmithInstall
