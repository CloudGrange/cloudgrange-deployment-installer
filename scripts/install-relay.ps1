#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# install-relay.ps1 — Install the CloudGrange relay agent on a Windows Docker Desktop host.
#
# Usage:
#   .\install-relay.ps1 -ApiUrl <URL> -ApiKey <KEY> -SiteId <SITE-ID> [-Version <TAG>]

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ApiUrl,

    [Parameter(Mandatory)]
    [string]$ApiKey,

    [Parameter(Mandatory)]
    [string]$SiteId,

    [string]$Version = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ContainerName  = 'cloudgrange-relay'
$ImageBase      = 'ghcr.io/cloudgrange-cloud/cloudgrange-relay'
$ReleasesUrl    = 'https://api.github.com/repos/cloudgrange-cloud/cloudgrange-relay/releases'
$HealthTimeout  = 30

# ----------------------------------------------------------------------------
# Docker check
# ----------------------------------------------------------------------------
$dockerExe = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerExe) {
    Write-Error @"

Docker is not installed or not on PATH.

Install Docker Desktop for Windows:
  https://docs.docker.com/desktop/install/windows-install/

"@
    exit 1
}

try {
    $null = docker info 2>&1
} catch {
    Write-Error @"

Docker daemon is not running, or you do not have permission to access it.

Start Docker Desktop from the Start Menu, then re-run this script.

"@
    exit 1
}

# ----------------------------------------------------------------------------
# Resolve version
# ----------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Version)) {
    Write-Host "Resolving latest relay version..."
    try {
        $release = Invoke-RestMethod -Uri "$ReleasesUrl/latest" -Headers @{ 'User-Agent' = 'cloudgrange-installer' }
        $Version = $release.tag_name
        Write-Host "Latest version: $Version"
    } catch {
        Write-Warning "Could not resolve latest version from GitHub releases. Falling back to 'latest' tag."
        $Version = 'latest'
    }
}

$Image = "${ImageBase}:${Version}"

# ----------------------------------------------------------------------------
# Pull image
# ----------------------------------------------------------------------------
Write-Host "Pulling $Image ..."
docker pull $Image
if ($LASTEXITCODE -ne 0) {
    Write-Error "docker pull failed with exit code $LASTEXITCODE."
    exit 1
}

# ----------------------------------------------------------------------------
# Verify image digest against GitHub releases manifest (best-effort)
# ----------------------------------------------------------------------------
if ($Version -ne 'latest') {
    $ManifestUrl = "https://github.com/cloudgrange-cloud/cloudgrange-relay/releases/download/$Version/cloudgrange-relay.sha256"
    Write-Host "Verifying image digest from $ManifestUrl ..."
    try {
        $Manifest = Invoke-WebRequest -Uri $ManifestUrl -UseBasicParsing -ErrorAction Stop
        $ExpectedDigest = ($Manifest.Content -split "`n" | Where-Object { $_ -match 'cloudgrange-relay' } | Select-Object -First 1) -split '\s+' | Select-Object -First 1
        if ($ExpectedDigest) {
            $ActualDigest = (docker inspect --format='{{index .RepoDigests 0}}' $Image 2>$null) -replace '^.*@', ''
            if (-not $ActualDigest) {
                Write-Warning "Could not retrieve local image digest — skipping verification."
            } elseif ($ActualDigest -like "*$ExpectedDigest*") {
                Write-Host "Digest verified: $ActualDigest"
            } else {
                Write-Error @"
Image digest mismatch.
  Expected (from manifest): $ExpectedDigest
  Actual:                   $ActualDigest
Do not run untrusted images. Aborting.
"@
                exit 1
            }
        } else {
            Write-Warning "Could not parse expected digest from manifest — skipping verification."
        }
    } catch {
        Write-Warning "Digest manifest not available for this version — skipping verification."
    }
}

# ----------------------------------------------------------------------------
# Remove existing container if present
# ----------------------------------------------------------------------------
$existing = docker inspect $ContainerName 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "Stopping and removing existing container '$ContainerName' ..."
    docker rm -f $ContainerName | Out-Null
}

# ----------------------------------------------------------------------------
# Run the relay container
# ----------------------------------------------------------------------------
Write-Host "Starting relay container ..."
docker run -d `
    --name $ContainerName `
    --restart unless-stopped `
    -e "RELAY_API_URL=$ApiUrl" `
    -e "RELAY_API_KEY=$ApiKey" `
    -e "RELAY_SITE_ID=$SiteId" `
    $Image

if ($LASTEXITCODE -ne 0) {
    Write-Error "docker run failed with exit code $LASTEXITCODE."
    exit 1
}

# ----------------------------------------------------------------------------
# Wait for healthy
# ----------------------------------------------------------------------------
Write-Host "Waiting up to ${HealthTimeout}s for container to become healthy ..."
$Elapsed = 0
$Healthy = $false

while ($Elapsed -lt $HealthTimeout) {
    $Inspect  = docker inspect $ContainerName 2>$null | ConvertFrom-Json
    $Status   = $Inspect[0].State.Status
    $HealthSt = if ($Inspect[0].State.Health) { $Inspect[0].State.Health.Status } else { 'none' }

    if ($Status -eq 'running' -and ($HealthSt -eq 'healthy' -or $HealthSt -eq 'none')) {
        $Healthy = $true
        break
    }

    if ($Status -eq 'exited' -or $Status -eq 'dead') {
        Write-Host ""
        Write-Host "Error: Container exited unexpectedly. Logs:" -ForegroundColor Red
        docker logs $ContainerName 2>&1 | Select-Object -Last 20
        exit 1
    }

    Start-Sleep -Seconds 2
    $Elapsed += 2
}

if (-not $Healthy) {
    $FinalStatus = (docker inspect --format='{{.State.Status}}' $ContainerName 2>$null)
    Write-Warning "Container did not report healthy within ${HealthTimeout}s. Status: $FinalStatus"
    Write-Host "Check logs with:  docker logs $ContainerName"
    exit 1
}

# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "Relay agent connected. Check the CloudGrange portal to confirm Active status."
Write-Host ""
Write-Host "Useful commands:"
Write-Host "  View logs:   docker logs -f $ContainerName"
Write-Host "  Stop relay:  docker stop $ContainerName"
Write-Host "  Uninstall:   .\uninstall-relay.ps1"
