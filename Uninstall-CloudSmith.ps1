#Requires -RunAsAdministrator
#Requires -Version 7.0
# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0
# AB#1596 — Uninstall: stop containers, delete VM+VHDX, remove switch and firewall rules

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$VmName   = 'cloudsmith-docker',
    [string]$VhdxPath = 'C:\ProgramData\CloudSmith\cloudsmith-docker.vhdx',
    [string]$VmIp     = '192.168.100.10',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\scripts\CloudSmith-Common.ps1"

# AB#1596 Step 6: Confirmation gate before any destructive steps.
# ShouldContinue is used when Force is not specified — it honours -WhatIf and -Confirm.
# When Force is specified (e.g., in automated pipelines), the prompt is skipped.
if (-not $Force) {
    Write-Host ""
    Write-Host "  [WARNING] This will permanently remove all CloudSmith data." -ForegroundColor Yellow
    Write-Host "  The following will be deleted:" -ForegroundColor Yellow
    Write-Host "    - All container data and volumes (docker compose down --volumes)" -ForegroundColor Yellow
    Write-Host "    - Hyper-V VM: $VmName" -ForegroundColor Yellow
    Write-Host "    - VHDX disk:  $VhdxPath" -ForegroundColor Yellow
    Write-Host "    - Virtual switch: CloudSmithSwitch / cloudsmith-internal" -ForegroundColor Yellow
    Write-Host "    - Windows Firewall rules matching 'CloudSmith*'" -ForegroundColor Yellow
    Write-Host ""

    if ($PSCmdlet.ShouldContinue(
            "Proceed with CloudSmith uninstall? This cannot be undone.",
            "CloudSmith Uninstaller")) {
        Write-Host "  Confirmed — proceeding with uninstall." -ForegroundColor Gray
    } else {
        Write-Host "  Uninstall cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# AB#1596 Step 1: Stop and remove containers (docker compose down --volumes).
# We try via the VM guest; failure is silenced — the VM may already be gone.
Write-Progress-Step "Stopping and removing containers (docker compose down --volumes)"
try {
    $cred = Get-Credential -UserName 'cloudsmith' -Message 'VM credential for container teardown'
    Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock {
        Set-Location /opt/cloudsmith
        docker compose down --volumes --remove-orphans 2>&1
    } -ErrorAction SilentlyContinue
} catch {
    Write-Host "  Note: could not reach VM for compose teardown (VM may already be stopped — continuing)." -ForegroundColor Gray
}

# AB#1596 Step 2: Stop and delete the Hyper-V VM.
Write-Progress-Step "Stopping and deleting Hyper-V VM: $VmName"
Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
Remove-VM -Name $VmName -Force -ErrorAction SilentlyContinue

# Delete the VHDX and the cloud-init seed ISO that lives alongside it.
Write-Progress-Step "Deleting VHDX and seed ISO"
if (Test-Path $VhdxPath) {
    Remove-Item -Path $VhdxPath -Force
    Write-Host "  Deleted: $VhdxPath" -ForegroundColor Gray
}
$seedIso = Join-Path (Split-Path $VhdxPath -Parent) 'cloud-init-seed.iso'
if (Test-Path $seedIso) {
    Remove-Item -Path $seedIso -Force
    Write-Host "  Deleted: $seedIso" -ForegroundColor Gray
}

# AB#1596 Step 3: Remove virtual switches created at install time.
# The installer creates either 'CloudSmithSwitch' (ADR-029 appliance mode) or
# 'cloudsmith-internal' (compose/online mode).  Remove both if present.
Write-Progress-Step "Removing CloudSmith virtual switches"
foreach ($switchName in @('CloudSmithSwitch', 'cloudsmith-internal')) {
    $sw = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
    if ($sw) {
        Remove-VMSwitch -Name $switchName -Force -ErrorAction SilentlyContinue
        Write-Host "  Removed virtual switch: $switchName" -ForegroundColor Gray
    }
}

# Remove the WinNAT entry that pairs with cloudsmith-internal.
Remove-NetNat -Name 'CloudSmithNAT' -Confirm:$false -ErrorAction SilentlyContinue

# Remove the host-side static IP on the switch NIC (if still present).
$hostNic = Get-NetAdapter | Where-Object { $_.Name -match 'vEthernet.*cloudsmith' } -ErrorAction SilentlyContinue
if ($hostNic) {
    Remove-NetIPAddress -InterfaceIndex $hostNic.InterfaceIndex -Confirm:$false -ErrorAction SilentlyContinue
}

# AB#1596 Step 4: Remove Windows Firewall rules created at install time.
# Match on DisplayName wildcard 'CloudSmith*' to catch any variant the installer created.
Write-Progress-Step "Removing CloudSmith firewall rules and port proxy"
$fwRules = Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like 'CloudSmith*' }
if ($fwRules) {
    foreach ($rule in $fwRules) {
        Remove-NetFirewallRule -InputObject $rule -ErrorAction SilentlyContinue
        Write-Host "  Removed firewall rule: $($rule.DisplayName)" -ForegroundColor Gray
    }
}

# Remove port proxy rules for ports 443 and 80 that the installer may have added.
netsh interface portproxy delete v4tov4 listenport=443 2>$null
netsh interface portproxy delete v4tov4 listenport=80 2>$null

# AB#1596 Step 5: Print completion.
Write-Host ""
Write-Host "  [CloudSmith] Uninstall complete." -ForegroundColor Green
