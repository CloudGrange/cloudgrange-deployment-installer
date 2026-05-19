#Requires -RunAsAdministrator
#Requires -Version 7.0
# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
    [string]$VmName   = 'cloudsmith-docker',
    [string]$VhdxPath = 'C:\ProgramData\CloudSmith\cloudsmith-docker.vhdx',
    [string]$VmIp     = '192.168.100.10',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\scripts\CloudSmith-Common.ps1"

if (-not $Force) {
    Write-Warning "WARNING: This will permanently delete all CloudSmith data. This cannot be undone."
    $confirm = Read-Host "  Type 'DELETE' to confirm"
    if ($confirm -ne 'DELETE') {
        Write-Host "Uninstall cancelled." -ForegroundColor Yellow
        exit 0
    }
}

Write-Progress-Step "Stopping containers"
$cred = Get-Credential -UserName 'cloudsmith' -Message 'VM credential'
try {
    Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock {
        Set-Location /opt/cloudsmith
        docker compose down -v --remove-orphans
    } -ErrorAction SilentlyContinue
} catch { }

Write-Progress-Step "Stopping and deleting VM"
Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
Remove-VM -Name $VmName -Force -ErrorAction SilentlyContinue

Write-Progress-Step "Deleting VHDX"
if (Test-Path $VhdxPath) { Remove-Item -Path $VhdxPath -Force }
$seedIso = Join-Path (Split-Path $VhdxPath -Parent) 'cloud-init-seed.iso'
if (Test-Path $seedIso) { Remove-Item -Path $seedIso -Force }

Write-Progress-Step "Removing Hyper-V switch"
Remove-VMSwitch -Name 'cloudsmith-internal' -Force -ErrorAction SilentlyContinue

Write-Progress-Step "Removing Windows Firewall rule and port proxy"
Remove-NetFirewallRule -DisplayName 'CloudSmith-Portal-443' -ErrorAction SilentlyContinue
netsh interface portproxy delete v4tov4 listenport=443 2>$null

Write-Host "`n  ✓ CloudSmith uninstalled. No orphaned resources remain." -ForegroundColor Green
