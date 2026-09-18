#Requires -RunAsAdministrator
#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
# AB#9186 — K3s/Helm counterpart to Build-CloudGrangeAppliance.ps1. Exports the
# cloudgrange-k3s nested VM (created by Install-CloudGrange.ps1 -Engine K3s) as a signed
# appliance VHDX, mirroring that script's structure and safety gates closely — same
# generalize-then-scan-then-sign pipeline, K3s-specific generalization scripts.
#
# Run this on the Hyper-V host AFTER a successful 'Install-CloudGrange.ps1 -Engine K3s'
# install has completed.
#
# Usage:
#   Build-CloudGrangeApplianceK3s.ps1 -OutputPath C:\CloudGrangeApplianceK3s -SshKeyPath <path> -VmIp <ip> -Version 2609.0.0-preview1

[CmdletBinding()]
param(
    [string]$OutputPath = 'C:\CloudGrangeApplianceK3s',
    # AB#9171: required and pinned. The appliance boots offline from the images baked into it, and
    # `latest` is not a version (methodology rule 4: no :latest in any shipped artifact).
    [Parameter(Mandatory)]
    [ValidatePattern('^\d{4}\.\d+\.\d+(-[0-9A-Za-z.-]+)?$')]
    [string]$Version,
    [string]$VmName = 'cloudgrange-k3s',
    [string]$CosignKeyPath = '',
    [switch]$SkipSigning,
    [string]$SshKeyPath = '',
    [string]$VmIp = '',
    [switch]$AllowUngeneralized
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\scripts\CloudGrange-Common.ps1"

$OutputPath = [IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

$vhdxName    = 'cloudgrange-appliance-k3s.vhdx'
$versionPath = Join-Path $OutputPath 'cloudgrange-appliance-k3s.version'
$vhdxPath    = Join-Path $OutputPath $vhdxName
$sha256Path  = "$vhdxPath.sha256"
$sigPath     = "$vhdxPath.sig"

Write-Progress-Step "Checking source VM: $VmName"
$vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Error "VM '$VmName' not found. Run 'Install-CloudGrange.ps1 -Engine K3s' first to create it."
}

$secretValues = @{}
if (-not $AllowUngeneralized) {
    if ([string]::IsNullOrEmpty($SshKeyPath) -or [string]::IsNullOrEmpty($VmIp) -or -not (Test-Path $SshKeyPath)) {
        Write-Error "CG-APPLK3S-ERR-001: -SshKeyPath and -VmIp are required to generalize '$VmName' before export. Refusing to export an ungeneralized appliance."
    }
    if ($vm.State -ne 'Running') {
        Write-Error "CG-APPLK3S-ERR-002: '$VmName' must be Running to generalize (state: $($vm.State))."
    }
    Write-Progress-Step "Generalizing '$VmName' (K8s secrets, SSH keys, machine-id, cloud-init, DHCP)"
    $sshOpts = Get-CloudGrangeSshOptions -KeyPath $SshKeyPath
    $stage = '/var/tmp/cloudgrange-appliance-k3s'
    Invoke-CloudGrangeSsh -ArgumentList ($sshOpts + @("cloudgrange@$VmIp", "rm -rf $stage && mkdir -p $stage/appliance")) -TimeoutSeconds 120
    if ($LASTEXITCODE -ne 0) { Write-Error "CG-APPLK3S-ERR-003: cannot reach '$VmName' over SSH at $VmIp (exit $LASTEXITCODE)." }

    # AB#9189: cloudgrange-updater-k3s.service belongs here — the generalize script installs the
    # in-app updater, and these lists are explicit, so a file the generalize step needs but nobody
    # staged fails the whole build at the install step with "cannot stat".
    foreach ($f in 'cloudgrange-generalize-k3s.sh', 'cloudgrange-firstboot-k3s.sh', 'cloudgrange-firstboot-k3s.service', 'cloudgrange-capture-secrets-k3s.sh',
                   'cloudgrange-kvp.py', 'cloudgrange-operator-access.sh', 'cloudgrange-operator-access-k3s.service',
                   'cloudgrange-updater-k3s.service') {
        Invoke-CloudGrangeSsh -Tool scp -ArgumentList ($sshOpts + @((Join-Path $PSScriptRoot "appliance\$f"), "cloudgrange@${VmIp}:$stage/appliance/$f")) -TimeoutSeconds 120
        if ($LASTEXITCODE -ne 0) { Write-Error "CG-APPLK3S-ERR-003: upload of $f failed (exit $LASTEXITCODE)." }
    }
    # Firstboot re-runs Install-CloudGrangeK3s.sh, which needs scripts/ + charts/ staged
    # persistently — re-upload them the same way Deploy-K3sHelm.ps1 did at install time
    # (that ephemeral copy was already deleted after install completed).
    Invoke-CloudGrangeSsh -ArgumentList ($sshOpts + @("cloudgrange@$VmIp", "mkdir -p $stage/scripts")) -TimeoutSeconds 60
    # AB#9171: the Foundation release signing key the Foundation updater verifies against.
    Invoke-CloudGrangeSsh -Tool scp -ArgumentList ($sshOpts + @((Join-Path $PSScriptRoot 'cloudgrange-signing-key.pub'), "cloudgrange@${VmIp}:$stage/cloudgrange-signing-key.pub")) -TimeoutSeconds 120
    foreach ($f in @('Install-CloudGrangeK3s.sh', 'New-ArtifactManifest.sh', 'cloudgrange-updater-k3s.py')) {
        Invoke-CloudGrangeSsh -Tool scp -ArgumentList ($sshOpts + @((Join-Path $PSScriptRoot "scripts\$f"), "cloudgrange@${VmIp}:$stage/scripts/$f")) -TimeoutSeconds 120
    }
    Get-ChildItem -Path (Join-Path $PSScriptRoot 'charts') -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring((Join-Path $PSScriptRoot 'charts').Length + 1) -replace '\\', '/'
        $destDir = "$stage/charts/$(Split-Path $rel -Parent)" -replace '\\', '/'
        Invoke-CloudGrangeSsh -ArgumentList ($sshOpts + @("cloudgrange@$VmIp", "mkdir -p $destDir")) -TimeoutSeconds 60
        Invoke-CloudGrangeSsh -Tool scp -ArgumentList ($sshOpts + @($_.FullName, "cloudgrange@${VmIp}:$stage/charts/$rel")) -TimeoutSeconds 120
    }
    Invoke-CloudGrangeSsh -ArgumentList ($sshOpts + @("cloudgrange@$VmIp", "sudo sed -i 's/\r$//' $stage/appliance/* $stage/scripts/*")) -TimeoutSeconds 120
    if ($LASTEXITCODE -ne 0) { Write-Error "CG-APPLK3S-ERR-003: staging on '$VmName' failed (exit $LASTEXITCODE)." }

    $captured = @(Invoke-CloudGrangeSsh -ArgumentList ($sshOpts + @("cloudgrange@$VmIp", "sudo bash $stage/appliance/cloudgrange-capture-secrets-k3s.sh")) -CaptureOutput -TimeoutSeconds 300)
    if ($LASTEXITCODE -ne 0) { Write-Error "CG-APPLK3S-ERR-006: could not capture install-time secrets for the VHDX scan (exit $LASTEXITCODE)." }
    foreach ($line in $captured) {
        $i = $line.IndexOf('=')
        if ($i -le 0) { continue }
        $secretValues[$line.Substring(0, $i)] = [System.Text.Encoding]::Latin1.GetString([Convert]::FromBase64String($line.Substring($i + 1).Trim())).TrimEnd("`n")
    }
    $captured = $null
    if ((Test-Path "$SshKeyPath.pub")) {
        $secretValues['installer ssh public key (authorized_keys residue)'] = ((Get-Content "$SshKeyPath.pub" -Raw).Trim() -split '\s+')[1]
    }
    if ($secretValues.Count -lt 5) {
        Write-Error "CG-APPLK3S-ERR-006: expected at least 5 captured secret values, got $($secretValues.Count). Refusing to build without a secret scan baseline."
    }
    Write-Host "  Captured $($secretValues.Count) install-time secret values (memory only) for the VHDX scan." -ForegroundColor Gray

    Invoke-CloudGrangeSsh -ArgumentList ($sshOpts + @("cloudgrange@$VmIp", "sudo bash $stage/appliance/cloudgrange-generalize-k3s.sh")) -TimeoutSeconds 3600
    if ($LASTEXITCODE -ne 0) { Write-Error "CG-APPLK3S-ERR-004: generalization failed inside '$VmName' (exit $LASTEXITCODE). Do not export this VM." }
    Write-Host "  Waiting for '$VmName' to power off after generalization..." -ForegroundColor Gray
    $timeout = 300; $elapsed = 0
    while ((Get-VM -Name $VmName).State -ne 'Off' -and $elapsed -lt $timeout) {
        Start-Sleep -Seconds 5; $elapsed += 5
    }
    if ((Get-VM -Name $VmName).State -ne 'Off') {
        Write-Error "CG-APPLK3S-ERR-005: '$VmName' did not power off within $timeout seconds after generalization."
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

Write-Progress-Step "Exporting VM VHDX to $vhdxPath"
$vhd = Get-VMHardDiskDrive -VMName $VmName | Select-Object -First 1
if (-not $vhd) { Write-Error "No VHD attached to VM '$VmName'." }
$sourceVhdx = $vhd.Path
Write-Host "  Source VHDX: $sourceVhdx" -ForegroundColor Gray
Copy-Item -Path $sourceVhdx -Destination $vhdxPath -Force
Optimize-VHD -Path $vhdxPath -Mode Full
Write-Host "  Exported: $vhdxPath ($('{0:N0}' -f ((Get-Item $vhdxPath).Length / 1MB)) MB)" -ForegroundColor Green

Write-Progress-Step "Scanning exported VHDX for install-time secrets"
. "$PSScriptRoot\scripts\Test-ApplianceVhdxSecrets.ps1"
$scan = Test-ApplianceVhdxSecrets -Path $vhdxPath -Values $secretValues
$secretValues = $null
$scanReport = Join-Path $OutputPath 'cloudgrange-appliance-k3s.secret-scan.txt'
@("VHDX secret scan $([DateTime]::UtcNow.ToString('s'))Z  $vhdxName  literals=$($scan.LiteralsCount)  findings=$($scan.Findings)") + $scan.Report |
    Set-Content -Path $scanReport -Encoding utf8
$scan.Report | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
if (-not $scan.Passed) {
    Remove-Item -LiteralPath $vhdxPath -Force
    Write-Error "CG-APPLK3S-ERR-007: the exported VHDX contains $($scan.Findings) install-time secret occurrence(s) (see $scanReport). The VHDX was deleted; do not release."
}
Write-Host "  Secret scan passed: 0 findings ($($scan.LiteralsCount) captured values + pattern check)." -ForegroundColor Green

Write-Progress-Step "Computing SHA-256 manifest"
$hash = (Get-FileHash -Path $vhdxPath -Algorithm SHA256).Hash
"$hash  $vhdxName" | Set-Content -Path $sha256Path -Encoding ascii
$Version | Set-Content -Path $versionPath -Encoding ascii
Write-Host "  SHA-256: $hash" -ForegroundColor Green

Write-Progress-Step "Signing appliance VHDX with cosign"
if ($SkipSigning) {
    Write-Host "  [WARNING] -SkipSigning specified — no signature will be created." -ForegroundColor Yellow
} else {
    $cosignAvailable = [bool](Get-Command cosign -ErrorAction SilentlyContinue)
    if (-not $cosignAvailable) {
        Write-Error "cosign is not installed. Install from https://docs.sigstore.dev/cosign/system_config/installation/ or use -SkipSigning for dev/test."
    }
    if (-not [string]::IsNullOrEmpty($CosignKeyPath) -and (Test-Path $CosignKeyPath)) {
        Write-Host "  Signing with key: $CosignKeyPath" -ForegroundColor Gray
        & cosign sign-blob --key $CosignKeyPath --output-signature $sigPath $vhdxPath
    } else {
        Write-Host "  Signing with keyless OIDC (requires CI OIDC context)..." -ForegroundColor Gray
        & cosign sign-blob --yes --output-signature $sigPath $vhdxPath
    }
    if ($LASTEXITCODE -ne 0) { Write-Error "cosign sign-blob failed (exit $LASTEXITCODE)." }
    Write-Host "  Signature written: $sigPath" -ForegroundColor Green
}

Write-Host ""
Write-Host "  CloudGrange K3s/Helm appliance built successfully." -ForegroundColor Green
Write-Host "  VHDX:      $vhdxPath" -ForegroundColor Cyan
Write-Host "  SHA-256:   $sha256Path" -ForegroundColor Gray
if (-not $SkipSigning) { Write-Host "  Signature: $sigPath" -ForegroundColor Gray }
Write-Host ""
