#Requires -Version 7.0
# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0
# AB#1598 — Generate cloudsmith-installer.sha256 for the installer package.
#
# Run this as part of the release workflow BEFORE packaging Install-CloudSmith.ps1.
# The generated .sha256 file must be distributed alongside Install-CloudSmith.ps1.
#
# Usage:
#   .\New-InstallerHash.ps1
#   .\New-InstallerHash.ps1 -InstallerPath .\Install-CloudSmith.ps1
#   .\New-InstallerHash.ps1 -InstallerPath .\Install-CloudSmith.ps1 -OutputPath .\cloudsmith-installer.sha256

[CmdletBinding()]
param(
    # Path to the installer script to hash. Defaults to Install-CloudSmith.ps1 in the same directory.
    [string]$InstallerPath = '',

    # Output path for the .sha256 file. Defaults to cloudsmith-installer.sha256 in the same directory as the installer.
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($InstallerPath)) {
    $InstallerPath = Join-Path $PSScriptRoot 'Install-CloudSmith.ps1'
}

if (-not (Test-Path $InstallerPath)) {
    Write-Error "Installer not found: $InstallerPath"
}

$InstallerPath = (Resolve-Path $InstallerPath).Path

if ([string]::IsNullOrEmpty($OutputPath)) {
    $OutputPath = Join-Path (Split-Path $InstallerPath -Parent) 'cloudsmith-installer.sha256'
}

$hash = (Get-FileHash -Path $InstallerPath -Algorithm SHA256).Hash.ToUpperInvariant()
$fileName = Split-Path $InstallerPath -Leaf

# Format: <HASH>  <filename>  (two spaces — sha256sum compatible)
$line = "$hash  $fileName"
Set-Content -Path $OutputPath -Value $line -Encoding UTF8 -NoNewline

Write-Host "SHA-256: $hash" -ForegroundColor Cyan
Write-Host "Written: $OutputPath" -ForegroundColor Green
Write-Host ""
Write-Host "Distribute 'cloudsmith-installer.sha256' alongside 'Install-CloudSmith.ps1'." -ForegroundColor Yellow
