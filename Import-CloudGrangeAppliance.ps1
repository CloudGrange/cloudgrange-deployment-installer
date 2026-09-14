#Requires -RunAsAdministrator
#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
# AB#1588 — Import pre-built VHDX appliance into Hyper-V (3-minute SLA)
# AB#1589 — SHA-256 + cosign signature validation before any VM creation

[CmdletBinding()]
param(
    # AB#1588 Step 1: path to the pre-built VHDX file.
    [Parameter(Mandatory)]
    [string]$AppliancePath,

    # Optional: explicit path to the sha256 manifest. Defaults to <AppliancePath>.sha256
    # and then falls back to cloudgrange-appliance.sha256 in the same directory.
    [string]$ChecksumPath = '',

    # Optional: explicit path to the cosign signature file.
    # Defaults to <AppliancePath>.sig alongside the VHDX.
    [string]$SignaturePath = '',

    # Optional: path to the cosign public key used to verify the signature.
    # Defaults to cloudgrange-signing-key.pub in the same directory as the VHDX,
    # then falls back to the key bundled with the installer.
    [string]$SigningKeyPath = '',

    # Allow import of an unsigned appliance (no .sig file present).
    # When a .sig file IS present, cosign verification is always mandatory regardless of this switch.
    # Do NOT use in production — unsigned appliances cannot be traced to a known-good build.
    [switch]$AllowUnsigned,

    [string]$VmIp   = '192.168.100.10',
    [string]$VmName = 'cloudgrange-docker'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\scripts\CloudGrange-Common.ps1"

$applianceDir = Split-Path $AppliancePath -Parent

# ---------------------------------------------------------------------------
# AB#1589 Step 2: SHA-256 validation — mandatory, fail hard if missing/mismatch
# ---------------------------------------------------------------------------
Write-Progress-Step "Verifying appliance VHDX integrity (SHA-256)"

if (-not (Test-Path $AppliancePath)) {
    Write-Error "Appliance VHDX not found: $AppliancePath"
}

# Resolve checksum file: explicit param → <vhdx>.sha256 → cloudgrange-appliance.sha256 in same dir
$resolvedChecksumPath = $ChecksumPath
if ([string]::IsNullOrEmpty($resolvedChecksumPath)) {
    $candidate1 = "$AppliancePath.sha256"
    $candidate2 = Join-Path $applianceDir 'cloudgrange-appliance.sha256'
    if (Test-Path $candidate1) {
        $resolvedChecksumPath = $candidate1
    } elseif (Test-Path $candidate2) {
        $resolvedChecksumPath = $candidate2
    }
}

if ([string]::IsNullOrEmpty($resolvedChecksumPath) -or -not (Test-Path $resolvedChecksumPath)) {
    Write-Host ""
    Write-Host "  [ERROR] SHA-256 manifest not found." -ForegroundColor Red
    Write-Host "  Expected at: $AppliancePath.sha256" -ForegroundColor Red
    Write-Host "           or: $(Join-Path $applianceDir 'cloudgrange-appliance.sha256')" -ForegroundColor Red
    Write-Host "  Download the manifest from the same release page as the VHDX." -ForegroundColor Yellow
    Write-Error "Appliance integrity check failed: sha256 manifest is missing. Aborting before any VM creation."
}

$checksumLine = (Get-Content $resolvedChecksumPath -Raw).Trim()
# Support both bare-hash and BSD/GNU formats: "<hash>  <filename>" or "<hash> *<filename>"
$expectedHash = ($checksumLine -split '\s+')[0].ToUpperInvariant()

Write-Host "  Computing SHA-256 of $(Split-Path $AppliancePath -Leaf) ..."
$actualHash = (Get-FileHash -Path $AppliancePath -Algorithm SHA256).Hash.ToUpperInvariant()

if ($expectedHash -ne $actualHash) {
    Write-Host ""
    Write-Host "  [ERROR] VHDX integrity check FAILED." -ForegroundColor Red
    Write-Host "  Expected: $expectedHash" -ForegroundColor Gray
    Write-Host "  Actual:   $actualHash"   -ForegroundColor Gray
    Write-Host "  The appliance file may be corrupted or tampered. Re-download from the release page." -ForegroundColor Yellow
    Write-Error "Appliance SHA-256 mismatch. VM creation aborted."
}
Write-Host "  SHA-256 OK ($($actualHash.Substring(0,16))...)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# AB#1589 Step 3: cosign signature validation — mandatory per ADR-045
#
# Rules:
#   - Sig file PRESENT:  cosign verification is mandatory. Any failure is a hard abort.
#                        cosign must be installed; missing cosign is also a hard abort.
#   - Sig file ABSENT:   --AllowUnsigned is required to proceed (not production-safe).
#                        Without --AllowUnsigned the import is aborted.
# ---------------------------------------------------------------------------
Write-Progress-Step "Verifying cosign signature (ADR-045)"

# Resolve signature path
$resolvedSigPath = $SignaturePath
if ([string]::IsNullOrEmpty($resolvedSigPath)) {
    $resolvedSigPath = "$AppliancePath.sig"
}

# Resolve signing key path: explicit → same dir as VHDX → installer dir
$resolvedKeyPath = $SigningKeyPath
if ([string]::IsNullOrEmpty($resolvedKeyPath)) {
    $keyInApplianceDir = Join-Path $applianceDir 'cloudgrange-signing-key.pub'
    $keyInInstallerDir = Join-Path $PSScriptRoot 'cloudgrange-signing-key.pub'
    if (Test-Path $keyInApplianceDir) {
        $resolvedKeyPath = $keyInApplianceDir
    } elseif (Test-Path $keyInInstallerDir) {
        $resolvedKeyPath = $keyInInstallerDir
    }
}

$cosignAvailable = [bool](Get-Command cosign -ErrorAction SilentlyContinue)
$sigFilePresent  = Test-Path $resolvedSigPath

if ($sigFilePresent) {
    # Signature file is present — verification is MANDATORY (ADR-045).
    if (-not $cosignAvailable) {
        Write-Host ""
        Write-Host "  [ERROR] A signature file was found but cosign is not installed." -ForegroundColor Red
        Write-Host "  Install cosign from https://docs.sigstore.dev/cosign/system_config/installation/" -ForegroundColor Yellow
        Write-Host "  Signature verification is required by ADR-045. Aborting import." -ForegroundColor Red
        throw "cosign is required to verify the appliance signature but is not installed. Aborting import."
    }
    if ([string]::IsNullOrEmpty($resolvedKeyPath) -or -not (Test-Path $resolvedKeyPath)) {
        Write-Host ""
        Write-Host "  [ERROR] Signing key not found — cannot verify the appliance signature." -ForegroundColor Red
        Write-Host "  Place cloudgrange-signing-key.pub alongside the VHDX or in the installer directory." -ForegroundColor Yellow
        throw "Signing key not found. Signature verification is required by ADR-045. Aborting import."
    }
    Write-Host "  Running: cosign verify-blob --key $resolvedKeyPath --signature $resolvedSigPath $AppliancePath" -ForegroundColor Gray
    $cosignResult = & cosign verify-blob `
        --key $resolvedKeyPath `
        --signature $resolvedSigPath `
        $AppliancePath 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  cosign signature: VALID" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "  [ERROR] cosign signature verification FAILED." -ForegroundColor Red
        Write-Host "  Output: $cosignResult" -ForegroundColor Gray
        Write-Host "  The appliance cannot be trusted. Do not use an appliance that fails signature verification." -ForegroundColor Red
        throw "Signature verification failed. Aborting import."
    }
} else {
    # No signature file present.
    if (-not $AllowUnsigned) {
        Write-Host ""
        Write-Host "  [ERROR] No cosign signature file found alongside the VHDX." -ForegroundColor Red
        Write-Host "  Expected: $resolvedSigPath" -ForegroundColor Gray
        Write-Host "  Importing an unsigned appliance is not permitted without the -AllowUnsigned switch." -ForegroundColor Red
        Write-Host "  WARNING: -AllowUnsigned bypasses provenance verification and is NOT safe for production." -ForegroundColor Yellow
        throw "No signature file found and -AllowUnsigned was not specified. Aborting import."
    }
    Write-Host "  [WARNING] No signature file found. Proceeding because -AllowUnsigned was specified." -ForegroundColor Yellow
    Write-Host "  This appliance has not had its provenance verified. Do not use in production." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# AB#1588 Step 3: Create Hyper-V VM from the validated VHDX
# ---------------------------------------------------------------------------
Write-Progress-Step "Creating Hyper-V internal switch (if needed)"
$switchName = 'cloudgrange-internal'
if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name $switchName -SwitchType Internal | Out-Null
    Write-Host "  Created virtual switch: $switchName" -ForegroundColor Gray
}

Write-Progress-Step "Creating Hyper-V VM from appliance VHDX"
# AB#1588 Step 3: Generation 2, UEFI, dynamic memory, 2 vCPU minimum.
$vm = New-VM -Name $VmName -Generation 2 -VHDPath $AppliancePath -SwitchName $switchName
Set-VM -VM $vm `
    -DynamicMemory `
    -MemoryStartupBytes 4GB `
    -MemoryMinimumBytes 2GB `
    -MemoryMaximumBytes 8GB `
    -ProcessorCount 2 `
    -AutomaticStartAction Start `
    -AutomaticStartDelay 30 `
    -AutomaticStopAction ShutDown

# Secure Boot: use the Microsoft UEFI CA template so the pre-built Ubuntu appliance boots signed.
Set-VMFirmware -VM $vm -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'
Set-VMFirmware -VM $vm -EnableSecureBoot On

# Open firewall for portal access
$fwRuleName = 'CloudGrange-Portal-443'
if (-not (Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $fwRuleName -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow | Out-Null
    netsh interface portproxy add v4tov4 listenport=443 connectaddress=$VmIp connectport=443 | Out-Null
    Write-Host "  Firewall rule and port proxy configured for port 443" -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# AB#1588 Step 4: Start VM and wait for portal — 3-minute SLA (hard requirement)
# ---------------------------------------------------------------------------
Write-Progress-Step "Starting appliance VM"
Start-VM -Name $VmName

Write-Host "  Waiting for CloudGrange portal to become reachable (SLA: 3 minutes)..." -ForegroundColor Gray
$portalUrl   = "https://$VmIp"
$slaSeconds  = 180
$ok          = Wait-ForHttpOk -Url $portalUrl -TimeoutSeconds $slaSeconds

if (-not $ok) {
    # AB#1588 hard SLA failure — stop the VM and surface a clear error.
    Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "  [ERROR] Portal did not become reachable within 3 minutes." -ForegroundColor Red
    Write-Host "  The appliance VM has been stopped. Check the Hyper-V console for boot errors." -ForegroundColor Red
    Write-Error "CG-APPL-ERR-001: 3-minute SLA exceeded — portal not reachable at $portalUrl. VM stopped."
}

# ---------------------------------------------------------------------------
# AB#1588 Step 5: Print admin URL and initial setup token
# ---------------------------------------------------------------------------
# The appliance emits the initial setup token to the VM's startup log at
# /var/log/cloudgrange-init.log — retrieve it from the setup-status API endpoint.
$setupToken = ''
try {
    # AB#8129: the API has no host port; it is reached through nginx TLS on 443.
    $apiBase    = "https://${VmIp}"
    $statusResp = Invoke-RestMethod -Uri "$apiBase/api/v1/setup/status" `
        -SkipCertificateCheck -TimeoutSec 10 -ErrorAction Stop
    if ($statusResp.setupToken) {
        $setupToken = $statusResp.setupToken
    }
} catch {
    # Non-fatal — token may not be exposed via the API in this appliance version
}

Write-Host ""
Write-Host "  CloudGrange appliance is live!" -ForegroundColor Green
Write-Host "  Portal:  $portalUrl" -ForegroundColor Cyan
if ($setupToken) {
    # Security: never embed the token in a URL query parameter — it would appear in browser
    # history, server access logs, proxy logs, and Referer headers. Print it to the terminal
    # only and instruct the operator to enter it via the setup wizard form (POST body).
    Write-Host "  Initial admin token: $setupToken" -ForegroundColor White
    Write-Host "  Open $portalUrl/setup in your browser and enter this token when prompted." -ForegroundColor Cyan
    Write-Host "  Keep this token secret — it grants full admin access during first-run setup." -ForegroundColor Yellow
} else {
    Write-Host "  Navigate to $portalUrl/setup to complete first-run setup." -ForegroundColor Cyan
}
Write-Host "  Note: The portal uses a self-signed certificate. Your browser will show a security warning." -ForegroundColor Yellow
Write-Host ""
