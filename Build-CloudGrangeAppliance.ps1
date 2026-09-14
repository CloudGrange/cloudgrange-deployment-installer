#Requires -RunAsAdministrator
#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
# AB#1858 — Export the cloudgrange-docker nested VM as a signed appliance VHDX.
#
# Run this on the Hyper-V host AFTER a successful 'Online' mode install has completed.
# The nested VM (cloudgrange-docker) is exported, signed with cosign, and a manifest
# written alongside it. This is a documented Hyper-V host step; the VHDX SHA-256 is recorded, not reproducible
# (docs/releases/reproducible-build.md).
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
    [switch]$SkipSigning,

    # AB#8129: SSH access to the RUNNING source VM, used to generalize it before export
    # (appliance/cloudgrange-generalize.sh). Install with -KeepInstallerSshKey to obtain the key.
    [string]$SshKeyPath = '',
    [string]$VmIp = '',

    # AB#8129: dev/test only. Export without generalizing. The VHDX then carries install-time
    # secrets, SSH keys, static IP and cloud-init identity — never ship such an image.
    [switch]$AllowUngeneralized
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

# ---------------------------------------------------------------------------
# Step 1b (AB#8129): generalize the running VM so the appliance carries no install-time identity
# ---------------------------------------------------------------------------
$secretValues = @{}
if (-not $AllowUngeneralized) {
    if ([string]::IsNullOrEmpty($SshKeyPath) -or [string]::IsNullOrEmpty($VmIp) -or -not (Test-Path $SshKeyPath)) {
        Write-Error "CG-APPL-ERR-001: -SshKeyPath and -VmIp are required to generalize '$VmName' before export (use Install-CloudGrange.ps1 -KeepInstallerSshKey). Refusing to export an ungeneralized appliance."
    }
    if ($vm.State -ne 'Running') {
        Write-Error "CG-APPL-ERR-002: '$VmName' must be Running to generalize (state: $($vm.State))."
    }
    Write-Progress-Step "Generalizing '$VmName' (secrets, SSH keys, machine-id, cloud-init, DHCP)"
    # AB#8129: every ssh/scp call is bounded (BatchMode, connect and keepalive timeouts, overall -TimeoutSeconds).
    $sshOpts = Get-CloudGrangeSshOptions -KeyPath $SshKeyPath
    $stage = '/var/tmp/cloudgrange-appliance'
    Invoke-CloudGrangeSsh -ArgumentList ($sshOpts + @("cloudgrange@$VmIp", "rm -rf $stage && mkdir -p $stage")) -TimeoutSeconds 120
    if ($LASTEXITCODE -ne 0) { Write-Error "CG-APPL-ERR-003: cannot reach '$VmName' over SSH at $VmIp (exit $LASTEXITCODE)." }
    foreach ($f in 'cloudgrange-generalize.sh', 'cloudgrange-firstboot.sh', 'cloudgrange-firstboot.service', 'cloudgrange-capture-secrets.sh',
                   'cloudgrange-kvp.py', 'cloudgrange-operator-access.sh', 'cloudgrange-operator-access.service') {
        Invoke-CloudGrangeSsh -Tool scp -ArgumentList ($sshOpts + @((Join-Path $PSScriptRoot "appliance\$f"), "cloudgrange@${VmIp}:$stage/$f")) -TimeoutSeconds 120
        if ($LASTEXITCODE -ne 0) { Write-Error "CG-APPL-ERR-003: upload of $f failed (exit $LASTEXITCODE)." }
    }
    Invoke-CloudGrangeSsh -ArgumentList ($sshOpts + @("cloudgrange@$VmIp", "sudo sed -i 's/\r$//' $stage/*")) -TimeoutSeconds 120
    if ($LASTEXITCODE -ne 0) { Write-Error "CG-APPL-ERR-003: staging on '$VmName' failed (exit $LASTEXITCODE)." }

    # Capture the install-time secret values (memory only) for the post-export VHDX scan (step 2b).
    $captured = @(Invoke-CloudGrangeSsh -ArgumentList ($sshOpts + @("cloudgrange@$VmIp", "sudo bash $stage/cloudgrange-capture-secrets.sh")) -CaptureOutput -TimeoutSeconds 300)
    if ($LASTEXITCODE -ne 0) { Write-Error "CG-APPL-ERR-006: could not capture install-time secrets for the VHDX scan (exit $LASTEXITCODE)." }
    foreach ($line in $captured) {
        $i = $line.IndexOf('=')
        if ($i -le 0) { continue }
        $secretValues[$line.Substring(0, $i)] = [System.Text.Encoding]::Latin1.GetString([Convert]::FromBase64String($line.Substring($i + 1).Trim())).TrimEnd("`n")
    }
    $captured = $null
    if ((Test-Path "$SshKeyPath.pub")) {
        $secretValues['installer ssh public key (authorized_keys residue)'] = ((Get-Content "$SshKeyPath.pub" -Raw).Trim() -split '\s+')[1]
    }
    if (@($secretValues.Keys | Where-Object { $_ -like 'env:*' }).Count -lt 5) {
        Write-Error "CG-APPL-ERR-006: expected at least 5 .env secrets on '$VmName', captured $(@($secretValues.Keys | Where-Object { $_ -like 'env:*' }).Count). Refusing to build without a secret scan baseline."
    }
    Write-Host "  Captured $($secretValues.Count) install-time secret values (memory only) for the VHDX scan." -ForegroundColor Gray

    # Generalization reloads every image into a fresh container store; allow up to an hour.
    Invoke-CloudGrangeSsh -ArgumentList ($sshOpts + @("cloudgrange@$VmIp", "sudo bash $stage/cloudgrange-generalize.sh")) -TimeoutSeconds 3600
    if ($LASTEXITCODE -ne 0) { Write-Error "CG-APPL-ERR-004: generalization failed inside '$VmName' (exit $LASTEXITCODE). Do not export this VM." }
    Write-Host "  Waiting for '$VmName' to power off after generalization..." -ForegroundColor Gray
    $timeout = 300; $elapsed = 0
    while ((Get-VM -Name $VmName).State -ne 'Off' -and $elapsed -lt $timeout) {
        Start-Sleep -Seconds 5; $elapsed += 5
    }
    if ((Get-VM -Name $VmName).State -ne 'Off') {
        Write-Error "CG-APPL-ERR-005: '$VmName' did not power off within $timeout seconds after generalization."
    }
    Write-Host "  '$VmName' generalized and powered off." -ForegroundColor Green
} else {
    Write-Host "  [WARNING] -AllowUngeneralized: exporting WITHOUT generalization (dev/test only)." -ForegroundColor Yellow
}
$vm = Get-VM -Name $VmName

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
# Step 2b (AB#8129): release gate — scan the exported VHDX bytes for install-time secrets
# ---------------------------------------------------------------------------
Write-Progress-Step "Scanning exported VHDX for install-time secrets"
. "$PSScriptRoot\scripts\Test-ApplianceVhdxSecrets.ps1"
$scan = Test-ApplianceVhdxSecrets -Path $vhdxPath -Values $secretValues
$secretValues = $null
$scanReport = Join-Path $OutputPath 'cloudgrange-appliance.secret-scan.txt'
@("VHDX secret scan $([DateTime]::UtcNow.ToString('s'))Z  $vhdxName  literals=$($scan.LiteralsCount)  findings=$($scan.Findings)") + $scan.Report |
    Set-Content -Path $scanReport -Encoding utf8
$scan.Report | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
if (-not $scan.Passed) {
    Remove-Item -LiteralPath $vhdxPath -Force
    Write-Error "CG-APPL-ERR-007: the exported VHDX contains $($scan.Findings) install-time secret occurrence(s) (see $scanReport). The VHDX was deleted; do not release."
}
Write-Host "  Secret scan passed: 0 findings ($($scan.LiteralsCount) captured values + pattern check)." -ForegroundColor Green

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
Write-Host "  Record these files with the release baseline (docs/releases/):" -ForegroundColor Yellow
Write-Host "    $vhdxName" -ForegroundColor White
Write-Host "    $(Split-Path $sha256Path -Leaf)" -ForegroundColor White
if (-not $SkipSigning) {
    Write-Host "    $(Split-Path $sigPath -Leaf)" -ForegroundColor White
}
Write-Host ""
