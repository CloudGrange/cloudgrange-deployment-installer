#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# install-relay.ps1 — Install the CloudGrange relay agent on a Windows Docker Desktop host.
# Standalone path: installs ONLY the relay container against a remote core API, using an
# enrollment token issued by the portal's Sites & Relays "Add a site" wizard (or by
# POST /api/v1/relays/enroll-token directly). Does not touch the rest of the on-prem stack.
#
# Usage:
#   .\install-relay.ps1 -ApiUrl <URL> -ApiKey <KEY> -SiteId <SITE-ID> [-Name <NAME>] [-Version <TAG>]
#
# AB#9196: org/repo corrected from the placeholder "cloudgrange-cloud/cloudgrange-installer"
# (neither exists) to this repo's real remote, github.com/CloudGrange/cloudgrange-deployment-installer.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ApiUrl,

    [Parameter(Mandatory)]
    [string]$ApiKey,

    [Parameter(Mandatory)]
    [string]$SiteId,

    [string]$Name = "",

    [string]$Version = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ContainerName  = 'cloudgrange-relay'
$VolumeName     = 'cloudgrange-relay-identity'
$ImageBase      = 'ghcr.io/cloudgrange/cloudgrange-relay'
# AB#9196: relay releases live in cloudgrange-runtime-relay (the relay's own repo), not a
# nonexistent "cloudgrange-relay" repo, and the org is "CloudGrange" not "cloudgrange-cloud".
$ReleasesUrl    = 'https://api.github.com/repos/CloudGrange/cloudgrange-runtime-relay/releases'
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
    # AB#9196: this manifest asset is not currently published by cloudgrange-runtime-relay's
    # release workflow, so this step stays best-effort until that changes.
    $ManifestUrl = "https://github.com/CloudGrange/cloudgrange-runtime-relay/releases/download/$Version/cloudgrange-relay.sha256"
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
# AB#9196: env vars corrected to match what the relay binary actually reads
# (cloudgrange-runtime-relay/src/CloudGrange.Relay/Program.cs). The previous
# RELAY_API_URL/RELAY_API_KEY names are not read by the relay at all — RELAY_PAAS_URL is
# required and throws on startup if unset, so every standalone install using the old names
# would fail immediately. A named volume persists the relay's enrolled identity (private key +
# relayId under RELAY_IDENTITY_DIR) across container recreates, so re-running this script (or a
# restart) does not force a doomed re-enrollment with an already-consumed token.
Write-Host "Ensuring identity volume '$VolumeName' exists ..."
docker volume create $VolumeName | Out-Null

Write-Host "Starting relay container ..."
$dockerArgs = @(
    'run', '-d',
    '--name', $ContainerName,
    '--restart', 'unless-stopped',
    '-e', "RELAY_PAAS_URL=$ApiUrl",
    '-e', "RELAY_ENROLLMENT_TOKEN=$ApiKey",
    '-e', "RELAY_SITE_ID=$SiteId",
    '-v', "${VolumeName}:/var/lib/cloudgrange-relay/identity"
)
if ($Name) { $dockerArgs += @('-e', "RELAY_DISPLAY_NAME=$Name") }
$dockerArgs += $Image

docker @dockerArgs

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
Write-Host ""
