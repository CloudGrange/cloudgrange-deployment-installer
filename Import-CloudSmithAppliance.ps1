#Requires -RunAsAdministrator
#Requires -Version 7.0
# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0
# ADR-029: Appliance mode — import pre-built VHDX directly into Hyper-V

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$VhdxPath,
    [string]$ChecksumPath = '',
    [string]$VmIp = '192.168.100.10',
    [string]$VmName = 'cloudsmith-docker'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\scripts\CloudSmith-Common.ps1"

# Verify VHDX checksum
if ($ChecksumPath -or (Test-Path "$VhdxPath.sha256")) {
    $csFile = if ($ChecksumPath) { $ChecksumPath } else { "$VhdxPath.sha256" }
    Write-Progress-Step "Verifying VHDX integrity"
    $expected = (Get-Content $csFile -Raw).Trim().Split(' ')[0]
    $actual   = (Get-FileHash -Path $VhdxPath -Algorithm SHA256).Hash
    if ($expected -ine $actual) {
        Write-Error "VHDX integrity check failed. Re-download the appliance from the CloudSmith release page."
    }
    Write-Host "  Integrity OK" -ForegroundColor Green
}

Write-Progress-Step "Creating Hyper-V internal switch (if needed)"
$switchName = 'cloudsmith-internal'
if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name $switchName -SwitchType Internal | Out-Null
}

Write-Progress-Step "Creating VM from appliance VHDX"
$vm = New-VM -Name $VmName -Generation 2 -VHDPath $VhdxPath -SwitchName $switchName
Set-VM -VM $vm `
    -DynamicMemory `
    -MemoryStartupBytes 4GB -MemoryMinimumBytes 1GB -MemoryMaximumBytes 8GB `
    -ProcessorCount 2 `
    -AutomaticStartAction Start -AutomaticStartDelay 30 -AutomaticStopAction ShutDown
Set-VMFirmware -VM $vm -EnableSecureBoot Off

# Firewall rule
if (-not (Get-NetFirewallRule -DisplayName 'CloudSmith-Portal-443' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'CloudSmith-Portal-443' -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow | Out-Null
    netsh interface portproxy add v4tov4 listenport=443 connectaddress=$VmIp connectport=443 | Out-Null
}

Write-Progress-Step "Starting appliance VM"
Start-VM -Name $VmName

Write-Host "  Waiting for CloudSmith portal (up to 3 minutes)..."
$ok = Wait-ForHttpOk -Url "https://$VmIp" -TimeoutSeconds 180
if ($ok) {
    Write-Host "`n  ✓ CloudSmith appliance is live!" -ForegroundColor Green
    Write-Host "  Portal: https://$VmIp" -ForegroundColor Cyan
} else {
    Write-Warning "Portal did not respond within 3 minutes. Check the VM console."
}
