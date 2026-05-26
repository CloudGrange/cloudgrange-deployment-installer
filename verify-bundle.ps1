#Requires -Version 7.0
<#
.SYNOPSIS
    Verify the SHA-256 manifest of a CloudSmith bundled distribution ZIP (AB#1587).

.DESCRIPTION
    Reads SHA256SUMS from the bundle ZIP and verifies each contained file against
    its expected hash. Exits with code 0 if all hashes match, or code 1 if any
    file is missing or corrupted.

.PARAMETER BundlePath
    Path to the Install-CloudSmith-Bundled.zip file to verify.

.PARAMETER ExtractPath
    Optional directory to extract to. Defaults to a temp directory.

.EXAMPLE
    .\verify-bundle.ps1 -BundlePath .\Install-CloudSmith-Bundled.zip
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $BundlePath,

    [string] $ExtractPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $BundlePath)) {
    Write-Error "Bundle not found: $BundlePath"
}

# Work in a temp dir if no extract path given
$ownTemp = $false
if ([string]::IsNullOrEmpty($ExtractPath)) {
    $ExtractPath = Join-Path $env:TEMP "cloudsmith-bundle-verify-$(Get-Random)"
    $ownTemp = $true
}

try {
    Write-Host "Extracting bundle to $ExtractPath..." -ForegroundColor Gray
    if (Test-Path $ExtractPath) { Remove-Item -Path $ExtractPath -Recurse -Force }
    Expand-Archive -Path $BundlePath -DestinationPath $ExtractPath

    $manifestPath = Join-Path $ExtractPath 'SHA256SUMS'
    if (-not (Test-Path $manifestPath)) {
        Write-Error "SHA256SUMS manifest not found in bundle. The bundle may be corrupted or was not created by the CloudSmith release workflow."
    }

    $manifest = Get-Content $manifestPath | Where-Object { $_ -match '\S' } | ForEach-Object {
        $parts = $_ -split '\s+', 2
        [pscustomobject]@{ Hash = $parts[0].ToUpperInvariant(); File = $parts[1].TrimStart('*') }
    }

    $passed = 0
    $failed = 0
    $missing = 0

    foreach ($entry in $manifest) {
        $fullPath = Join-Path $ExtractPath $entry.File
        if (-not (Test-Path $fullPath)) {
            Write-Host "[MISSING] $($entry.File)" -ForegroundColor Red
            $missing++
            continue
        }
        $actual = (Get-FileHash -Path $fullPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actual -eq $entry.Hash) {
            Write-Host "[OK]      $($entry.File)" -ForegroundColor Green
            $passed++
        } else {
            Write-Host "[FAIL]    $($entry.File)" -ForegroundColor Red
            Write-Host "          Expected: $($entry.Hash)" -ForegroundColor Gray
            Write-Host "          Actual:   $actual" -ForegroundColor Gray
            $failed++
        }
    }

    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "Bundle verification — Summary" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "Files checked: $($manifest.Count)"
    Write-Host "Passed:  $passed" -ForegroundColor Green
    Write-Host "Failed:  $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })
    Write-Host "Missing: $missing" -ForegroundColor $(if ($missing -gt 0) { 'Red' } else { 'Green' })

    if ($failed -gt 0 -or $missing -gt 0) {
        Write-Host ""
        Write-Host "Bundle verification FAILED. Do not use this bundle — re-download from the release page." -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "All files verified. Bundle is intact." -ForegroundColor Green
    exit 0
} finally {
    if ($ownTemp -and (Test-Path $ExtractPath)) {
        Remove-Item -Path $ExtractPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
