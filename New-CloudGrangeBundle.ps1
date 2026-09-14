#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
# AB#1852 — Generate CloudGrange offline bundle for air-gapped / bundled installs.
# Pulls all required container images and the Ubuntu cloud image, packages them
# into a self-contained zip that can be transferred to a machine without internet access.
#
# Usage:
#   .\New-CloudGrangeBundle.ps1
#   .\New-CloudGrangeBundle.ps1 -Version v1.0.0-preview1 -OutputPath C:\CloudGrangeBundle.zip

[CmdletBinding()]
param(
    [string]$Version    = 'latest',
    [string]$OutputPath = '',
    [switch]$SkipUbuntu
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot "cloudgrange-bundle-$Version.zip"
}

Write-Host "`n  CloudGrange Bundle Creator — Version: $Version" -ForegroundColor Cyan
Write-Host "  ─────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Output: $OutputPath" -ForegroundColor Gray

$bundleDir = Join-Path $env:TEMP "cloudgrange-bundle-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null

try {
    # Step 1: Copy installer scripts
    Write-Host "`n  [1/4] Copying installer files..." -ForegroundColor Cyan
    $installerFiles = @(
        'Install-CloudGrange.ps1',
        'cloudgrange-installer.sha256',
        'Update-CloudGrange.ps1',
        'Uninstall-CloudGrange.ps1',
        'New-SelfSignedCert.ps1',
        'verify-bundle.ps1'
    )
    foreach ($f in $installerFiles) {
        $src = Join-Path $PSScriptRoot $f
        if (Test-Path $src) {
            Copy-Item $src -Destination $bundleDir
        }
    }
    $scriptsDir = Join-Path $bundleDir 'scripts'
    New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'scripts\*') -Destination $scriptsDir -Recurse -Force
    $composeDir = Join-Path $bundleDir 'compose'
    New-Item -ItemType Directory -Path $composeDir -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'compose\*') -Destination $composeDir -Recurse -Force
    Write-Host "  Installer files copied" -ForegroundColor Green

    # Step 2: Download Ubuntu 24.04 cloud image
    if (-not $SkipUbuntu) {
        Write-Host "`n  [2/4] Downloading Ubuntu 24.04 cloud image (~700MB)..." -ForegroundColor Cyan
        $ubuntuDest = Join-Path $bundleDir 'ubuntu-24.04-cloudimg.img'
        $imgUrl = 'https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img'
        Invoke-WebRequest -Uri $imgUrl -OutFile $ubuntuDest -UseBasicParsing
        # Verify checksum
        $checksums = (Invoke-WebRequest -Uri 'https://cloud-images.ubuntu.com/noble/current/SHA256SUMS' -UseBasicParsing).Content
        $expected = ($checksums -split "`n" | Where-Object { $_ -match 'noble-server-cloudimg-amd64.img' }) -split '\s+' | Select-Object -First 1
        $actual = (Get-FileHash -Path $ubuntuDest -Algorithm SHA256).Hash
        if ($expected -and $expected -ine $actual) {
            Write-Error "Ubuntu image checksum mismatch — bundle aborted."
        }
        Write-Host "  Ubuntu image downloaded and verified" -ForegroundColor Green
    } else {
        Write-Host "`n  [2/4] Skipping Ubuntu image download (--SkipUbuntu)" -ForegroundColor Gray
    }

    # Step 3: Pull and save container images
    Write-Host "`n  [3/4] Pulling and saving container images..." -ForegroundColor Cyan
    # AB#8129: keep in step with compose/docker-compose.yml (the service-list source of truth).
    $images = @(
        "ghcr.io/cloudgrange/cloudgrange-api:$Version",
        "ghcr.io/cloudgrange/cloudgrange-portal:$Version",
        "ghcr.io/cloudgrange/cloudgrange-relay:$Version",
        'nginx:alpine',
        'postgres:16-alpine',
        'quay.io/keycloak/keycloak:26.6',
        'prom/prometheus:latest',
        'grafana/loki:latest',
        'grafana/grafana:12.1.1',
        'otel/opentelemetry-collector-contrib:latest'
    )
    foreach ($img in $images) {
        Write-Host "  Pulling: $img" -ForegroundColor Gray
        docker pull $img
    }
    $imageTar = Join-Path $bundleDir 'cloudgrange-images.tar'
    Write-Host "  Saving images to tar (~5-10GB)..." -ForegroundColor Gray
    docker save -o $imageTar @images
    Write-Host "  Images saved ($([Math]::Round((Get-Item $imageTar).Length / 1GB, 1)) GB)" -ForegroundColor Green

    # Step 4: Write bundle manifest
    Write-Host "`n  [4/4] Writing bundle manifest..." -ForegroundColor Cyan
    $manifest = @{
        version      = $Version
        created      = [DateTime]::UtcNow.ToString('o')
        images       = $images
        ubuntuImage  = if ($SkipUbuntu) { '' } else { 'ubuntu-24.04-cloudimg.img' }
        installerSha = (Get-Content (Join-Path $PSScriptRoot 'cloudgrange-installer.sha256') -Raw).Trim()
    } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $bundleDir 'bundle-manifest.json') -Value $manifest -Encoding UTF8

    # Generate bundle SHA-256 manifest
    $bundleSha = @{}
    Get-ChildItem $bundleDir -File -Recurse | ForEach-Object {
        $rel = $_.FullName.Substring($bundleDir.Length + 1)
        $bundleSha[$rel] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    }
    $bundleSha | ConvertTo-Json | Set-Content (Join-Path $bundleDir 'bundle.sha256.json') -Encoding UTF8

    # Compress to zip
    Write-Host "  Compressing bundle..." -ForegroundColor Gray
    if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }
    Compress-Archive -Path "$bundleDir\*" -DestinationPath $OutputPath -CompressionLevel Optimal
    $sizeMB = [Math]::Round((Get-Item $OutputPath).Length / 1MB, 0)
    Write-Host "  Bundle: $OutputPath ($sizeMB MB)" -ForegroundColor Green

    Write-Host "`n  Bundle created successfully!" -ForegroundColor Green
    Write-Host "  Transfer this file to the target machine and run:" -ForegroundColor Yellow
    Write-Host "    Expand-Archive cloudgrange-bundle-$Version.zip C:\CloudGrangeInstall" -ForegroundColor White
    Write-Host "    .\Install-CloudGrange.ps1 -Mode Bundled" -ForegroundColor White
    Write-Host ""
} finally {
    Remove-Item -Path $bundleDir -Recurse -Force -ErrorAction SilentlyContinue
}
