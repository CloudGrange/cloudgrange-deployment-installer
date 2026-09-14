#Requires -RunAsAdministrator
#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
# AB#1858 — Export the cloudgrange-docker nested VM as a signed appliance VHDX.
#
# Run this on the Hyper-V host AFTER a successful 'Online' mode install has completed.
# The nested VM (cloudgrange-docker) is exported, signed with cosign, and a manifest
# written alongside it — ready to attach to a GitHub Release.
#
# Usage:
#   Build-CloudGrangeAppliance.ps1 -OutputPath C:\CloudGrangeAppliance [-Version 1.0.0-preview1] [-CosignKeyPath .\cosign.key]
#
# Prerequisites:
#   - Hyper-V with cloudgrange-docker VM in Saved or Off state
#   - cosign installed (https://docs.sigstore.dev/cosign/system_config/installation/)
#     OR set -SkipSigning to produce an unsigned appliance (dev/test only)

[CmdletBinding()]
param(
    # Output directory for the VHDX, SHA-256 manifest, and cosign signature.
    [string]$OutputPath = 'C:\CloudGrangeAppliance',

    # Appliance version — baked into the filename and manifest.
    [string]$Version = 'latest',

    # Name of the nested Hyper-V VM to export.
    [string]$VmName = 'cloudgrange-docker',

    # Path to the cosign private key (.key file).
    # If omitted, cosign keyless signing is attempted.
    # Use -SkipSigning to bypass entirely (not for production).
    [string]$CosignKeyPath = '',

    # Skip cosign signing — produces an unsigned appliance.
    # Import-CloudGrangeAppliance.ps1 will require -AllowUnsigned to import it.
    [switch]$SkipSigning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\scripts\CloudGrange-Common.ps1"

$OutputPath = [IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

# AB#8129: fixed filename to match the docs and Import-CloudGrangeAppliance.ps1's
# cloudgrange-appliance.sha256 fallback. The version is carried by the release tag and the
# .version sidecar written below, not the filename.
$vhdxName     = 'cloudgrange-appliance.vhdx'
$versionPath  = Join-Path $OutputPath 'cloudgrange-appliance.version'
$vhdxPath     = Join-Path $OutputPath $vhdxName
$sha256Path   = "$vhdxPath.sha256"
$sigPath      = "$vhdxPath.sig"

# ---------------------------------------------------------------------------
# Step 1: Verify the source VM exists and is in a stopped state
# ---------------------------------------------------------------------------
Write-Progress-Step "Checking source VM: $VmName"
$vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Error "VM '$VmName' not found. Run the Online installer first to create the nested VM."
}

if ($vm.State -notin @('Off', 'Saved')) {
    Write-Host "  Stopping VM '$VmName' before export (current state: $($vm.State))..." -ForegroundColor Gray
    Stop-VM -Name $VmName -Force
    $timeout = 120; $elapsed = 0
    while ((Get-VM -Name $VmName).State -ne 'Off' -and $elapsed -lt $timeout) {
        Start-Sleep -Seconds 5; $elapsed += 5
    }
    if ((Get-VM -Name $VmName).State -ne 'Off') {
        Write-Error "VM '$VmName' did not stop within $timeout seconds."
    }
}
Write-Host "  VM '$VmName' is Off — ready for export." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 2: Export and compact the VHDX
# ---------------------------------------------------------------------------
Write-Progress-Step "Exporting VM VHDX to $vhdxPath"

# Find the primary VHD attached to the VM.
$vhd = Get-VMHardDiskDrive -VMName $VmName | Select-Object -First 1
if (-not $vhd) {
    Write-Error "No VHD attached to VM '$VmName'."
}
$sourceVhdx = $vhd.Path
Write-Host "  Source VHDX: $sourceVhdx" -ForegroundColor Gray

# Copy and compact (merge checkpoints into a single VHDX, reduce sparse space).
Write-Host "  Copying and compacting VHDX (this may take several minutes)..." -ForegroundColor Gray
Copy-Item -Path $sourceVhdx -Destination $vhdxPath -Force
Optimize-VHD -Path $vhdxPath -Mode Full
Write-Host "  Exported: $vhdxPath ($('{0:N0}' -f ((Get-Item $vhdxPath).Length / 1MB)) MB)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 3: Compute SHA-256 manifest
# ---------------------------------------------------------------------------
Write-Progress-Step "Computing SHA-256 manifest"
$hash = (Get-FileHash -Path $vhdxPath -Algorithm SHA256).Hash
"$hash  $vhdxName" | Set-Content -Path $sha256Path -Encoding ascii
$Version | Set-Content -Path $versionPath -Encoding ascii
Write-Host "  SHA-256: $hash" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 4: Sign with cosign (unless -SkipSigning)
# ---------------------------------------------------------------------------
Write-Progress-Step "Signing appliance VHDX with cosign"

if ($SkipSigning) {
    Write-Host "  [WARNING] -SkipSigning specified — no signature will be created." -ForegroundColor Yellow
    Write-Host "  Import-CloudGrangeAppliance.ps1 will require -AllowUnsigned to import this appliance." -ForegroundColor Yellow
} else {
    $cosignAvailable = [bool](Get-Command cosign -ErrorAction SilentlyContinue)
    if (-not $cosignAvailable) {
        Write-Error "cosign is not installed. Install from https://docs.sigstore.dev/cosign/system_config/installation/ or use -SkipSigning for dev/test."
    }

    if (-not [string]::IsNullOrEmpty($CosignKeyPath) -and (Test-Path $CosignKeyPath)) {
        Write-Host "  Signing with key: $CosignKeyPath" -ForegroundColor Gray
        & cosign sign-blob --key $CosignKeyPath --output-signature $sigPath $vhdxPath
    } else {
        # Keyless signing via OIDC (requires CI environment with OIDC token).
        Write-Host "  Signing with keyless OIDC (requires CI OIDC context)..." -ForegroundColor Gray
        & cosign sign-blob --yes --output-signature $sigPath $vhdxPath
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Error "cosign sign-blob failed (exit $LASTEXITCODE)."
    }
    Write-Host "  Signature written: $sigPath" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Step 5: Output manifest
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  CloudGrange appliance built successfully." -ForegroundColor Green
Write-Host "  VHDX:      $vhdxPath" -ForegroundColor Cyan
Write-Host "  SHA-256:   $sha256Path" -ForegroundColor Gray
if (-not $SkipSigning) {
    Write-Host "  Signature: $sigPath" -ForegroundColor Gray
}
Write-Host ""
Write-Host "  Attach these files to a GitHub Release:" -ForegroundColor Yellow
Write-Host "    $vhdxName" -ForegroundColor White
Write-Host "    $(Split-Path $sha256Path -Leaf)" -ForegroundColor White
if (-not $SkipSigning) {
    Write-Host "    $(Split-Path $sigPath -Leaf)" -ForegroundColor White
}
Write-Host ""
