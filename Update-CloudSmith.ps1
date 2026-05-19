#Requires -RunAsAdministrator
#Requires -Version 7.0
# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
    [string]$VmName  = 'cloudsmith-docker',
    [string]$Version = 'latest',
    [bool]$UseWsl2   = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\scripts\CloudSmith-Common.ps1"

Write-Progress-Step "Pulling new CloudSmith images (version: $Version)"

$upgradeScript = {
    param([string]$Version)
    Set-Location /opt/cloudsmith
    $env:CLOUDSMITH_VERSION = $Version
    docker compose pull
    # Rolling restart — api last to minimise downtime
    docker compose up -d --no-deps postgres prometheus loki otel-collector cloudsmith-portal
    Start-Sleep 10
    docker compose up -d --no-deps cloudsmith-api
    docker compose ps
}

if ($UseWsl2) {
    wsl -d Ubuntu -u root -- pwsh -Command $upgradeScript.ToString() -Args $Version
} else {
    $cred = Get-Credential -UserName 'cloudsmith' -Message 'VM credential'
    Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock $upgradeScript -ArgumentList $Version
}

Write-Host "`n  ✓ CloudSmith updated to version: $Version" -ForegroundColor Green
