#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
# AB#1598 — Generate cloudgrange-installer.sha256 for the installer package.
#
# Run this as part of the release workflow BEFORE packaging Install-CloudGrange.ps1.
# The generated .sha256 file must be distributed alongside Install-CloudGrange.ps1.
#
# Usage:
#   .\New-InstallerHash.ps1
#   .\New-InstallerHash.ps1 -InstallerPath .\Install-CloudGrange.ps1
#   .\New-InstallerHash.ps1 -InstallerPath .\Install-CloudGrange.ps1 -OutputPath .\cloudgrange-installer.sha256

[CmdletBinding()]
param(
    # Path to the installer script to hash. Defaults to Install-CloudGrange.ps1 in the same directory.
    [string]$InstallerPath = '',

    # Output path for the .sha256 file. Defaults to cloudgrange-installer.sha256 in the same directory as the installer.
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($InstallerPath)) {
    $InstallerPath = Join-Path $PSScriptRoot 'Install-CloudGrange.ps1'
}

if (-not (Test-Path $InstallerPath)) {
    Write-Error "Installer not found: $InstallerPath"
}

$InstallerPath = (Resolve-Path $InstallerPath).Path

if ([string]::IsNullOrEmpty($OutputPath)) {
    $OutputPath = Join-Path (Split-Path $InstallerPath -Parent) 'cloudgrange-installer.sha256'
}

$hash = (Get-FileHash -Path $InstallerPath -Algorithm SHA256).Hash.ToUpperInvariant()
$fileName = Split-Path $InstallerPath -Leaf

# Format: <HASH>  <filename>  (two spaces — sha256sum compatible)
$line = "$hash  $fileName"
Set-Content -Path $OutputPath -Value $line -Encoding UTF8 -NoNewline

Write-Host "SHA-256: $hash" -ForegroundColor Cyan
Write-Host "Written: $OutputPath" -ForegroundColor Green
Write-Host ""
Write-Host "Distribute 'cloudgrange-installer.sha256' alongside 'Install-CloudGrange.ps1'." -ForegroundColor Yellow
