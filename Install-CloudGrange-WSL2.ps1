#Requires -RunAsAdministrator
#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
# AB#1597 — WSL2 deployment entry point (dev/lab only — NOT for production use)
#
# This script is the standalone entry point for deploying CloudGrange via the
# WSL2 fallback path. It is equivalent to running:
#   Install-CloudGrange.ps1 -Mode WSL2
#
# IMPORTANT: WSL2 mode is not supported for production use. Use the Hyper-V
# deployment modes (Online / Bundled / Appliance) in production environments.

[CmdletBinding()]
param(
    [string]$Version       = 'latest',
    [string]$DistroName    = 'Ubuntu',
    [int]$MemoryLimitGB    = 4,
    [int]$ProcessorCount   = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\scripts\CloudGrange-Common.ps1"
. "$PSScriptRoot\scripts\Install-Wsl2Fallback.ps1"

Write-Host ""
Write-Host "  CloudGrange Installer — Mode: WSL2 (dev/lab)" -ForegroundColor Cyan
Write-Host "  ─────────────────────────────────────────────" -ForegroundColor DarkGray

Install-Wsl2Fallback `
    -DistroName $DistroName `
    -Version $Version `
    -MemoryLimitGB $MemoryLimitGB `
    -ProcessorCount $ProcessorCount

Write-Host ""
Write-Host "  CloudGrange deployed (WSL2 mode)." -ForegroundColor Green
Write-Host "  Portal:  http://localhost" -ForegroundColor Cyan
Write-Host "  API:     http://localhost:8081" -ForegroundColor Cyan
Write-Host ""
Write-Host "  [WARNING] WSL2 mode is not supported for production use." -ForegroundColor Yellow
Write-Host "  For production, use: .\Install-CloudGrange.ps1 -Mode Online" -ForegroundColor Yellow
Write-Host ""
