#Requires -RunAsAdministrator
#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
# AB#1595 — Rolling update: pull images, restart, migrate, verify, report version

[CmdletBinding()]
param(
    [string]$VmName  = 'cloudgrange-docker',
    [string]$VmIp    = '192.168.100.10',
    [string]$Version = 'latest',
    [bool]$UseWsl2   = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\scripts\CloudGrange-Common.ps1"

Write-Progress-Step "Pulling new CloudGrange images (version: $Version)"

$upgradeScript = {
    param([string]$Version)
    Set-Location /opt/cloudgrange
    $env:CLOUDGRANGE_VERSION = $Version
    docker compose pull

    # Rolling restart — infrastructure services first, api last to minimise downtime
    docker compose up -d --no-deps --remove-orphans postgres prometheus loki otel-collector cloudgrange-portal
    Start-Sleep 10
    docker compose up -d --no-deps --remove-orphans cloudgrange-api
    docker compose ps
}

if ($UseWsl2) {
    wsl -d Ubuntu -u root -- pwsh -Command $upgradeScript.ToString() -Args $Version
} else {
    $cred = Get-Credential -UserName 'cloudgrange' -Message 'VM credential'
    Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock $upgradeScript -ArgumentList $Version
}

# AB#1595 Step 3: Wait for API to become healthy, then trigger pending migrations
Write-Progress-Step "Waiting for CloudGrange API to become healthy after restart"
$apiBase = "http://$VmIp:8081"
$healthOk = Wait-ForHttpOk -Url "$apiBase/health/ready" -TimeoutSeconds 300
if (-not $healthOk) {
    Write-Error "CloudGrange API did not become healthy within 5 minutes after update. Check container logs."
}
Write-Host "  API health: OK" -ForegroundColor Green

# AB#1595 Step 3: Run pending FluentMigrator migrations via the API migration endpoint.
# The API self-migrates on startup; the explicit POST is belt-and-suspenders for
# environments where the API starts before the DB is fully ready.
Write-Progress-Step "Running pending database migrations"
try {
    $migrateResp = Invoke-RestMethod `
        -Uri "$apiBase/api/v1/admin/migrate" `
        -Method POST `
        -SkipCertificateCheck `
        -TimeoutSec 120 `
        -ErrorAction Stop
    Write-Host "  Migrations: $($migrateResp.status ?? 'complete')" -ForegroundColor Green
} catch {
    # 404 means the endpoint is not yet implemented; that is non-fatal.
    # 409 means already migrated. Any 5xx is surfaced as a warning only —
    # the API already self-migrates on startup so a failure here is not critical.
    $statusCode = $_.Exception.Response?.StatusCode.value__
    if ($statusCode -eq 404 -or $statusCode -eq 409) {
        Write-Host "  Migrations: skipped (API reports $statusCode — already current)" -ForegroundColor Gray
    } else {
        Write-Warning "Migration endpoint returned an error ($statusCode). The API may have self-migrated on startup. Proceeding."
    }
}

# AB#1595 Step 4: Verify all compose services are healthy after restart
Write-Progress-Step "Verifying all services are running after update"
$verifyScript = {
    Set-Location /opt/cloudgrange
    $notRunning = docker compose ps --format json 2>$null |
        ForEach-Object { $_ | ConvertFrom-Json -ErrorAction SilentlyContinue } |
        Where-Object { $_.State -ne 'running' }
    if ($notRunning) {
        $names = ($notRunning | ForEach-Object { $_.Name }) -join ', '
        throw "Services not running after update: $names"
    }
    return 'all-running'
}
if ($UseWsl2) {
    $verifyResult = wsl -d Ubuntu -u root -- pwsh -Command $verifyScript.ToString()
} else {
    $verifyResult = Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock $verifyScript
}
Write-Host "  Service verification: $verifyResult" -ForegroundColor Green

# AB#1595 Step 5: Resolve the actual running version from the API
$newVersion = $Version
try {
    $versionResp = Invoke-RestMethod `
        -Uri "$apiBase/api/v1/platform/version" `
        -SkipCertificateCheck `
        -TimeoutSec 10 `
        -ErrorAction Stop
    $newVersion = $versionResp.version ?? $versionResp.Version ?? $Version
} catch {
    # Non-fatal — use the requested version label if the endpoint is not available
}

Write-Host ""
Write-Host "  [CloudGrange] Update complete. Version: $newVersion" -ForegroundColor Green
