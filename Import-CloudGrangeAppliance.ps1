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

    # AB#8129: Hyper-V switch for the appliance NIC. An existing switch is used as-is; a missing one
    # is created as an Internal switch.
    [string]$SwitchName = 'cloudgrange-internal',

    # AB#8129: optional static IPv4 for networks without DHCP. When set, a NoCloud seed carrying ONLY the
    # network configuration is attached (no users, no keys). Leave empty for DHCP; the address is then
    # read from the appliance over Hyper-V KVP.
    [ValidatePattern('^$|^(\d{1,3}\.){3}\d{1,3}$')]
    [string]$VmIp = '',
    [ValidateRange(8, 32)]
    [int]$PrefixLength = 24,
    [ValidatePattern('^$|^(\d{1,3}\.){3}\d{1,3}$')]
    [string]$Gateway = '',
    [string[]]$DnsServers = @(),

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,62}$')]
    [string]$VmName = 'cloudgrange-docker',

    # AB#8129: do not add the host firewall rule and port proxy that publish the portal on host port 443.
    [switch]$SkipHostPortForward,

    # AB#8129: where to save the operator SSH private key the appliance publishes over KVP.
    # Default: %USERPROFILE%\.ssh\cloudgrange-<VmName>-operator_ed25519 (current user only).
    [string]$OperatorKeyPath = '',

    # AB#8129: how long to wait for first boot to publish the setup credentials.
    [ValidateRange(5, 60)]
    [int]$CredentialTimeoutMinutes = 20,

    # AB#8129: also return the credentials as an object (setup token and password as SecureString).
    [switch]$PassThru
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
Write-Progress-Step "Selecting Hyper-V switch '$SwitchName'"
$switchName = $SwitchName
if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name $switchName -SwitchType Internal | Out-Null
    Write-Host "  Created virtual switch: $switchName" -ForegroundColor Gray
} else {
    Write-Host "  Using existing virtual switch: $switchName (unchanged)" -ForegroundColor Gray
}
if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
    Write-Error "CG-APPL-ERR-009: a VM named '$VmName' already exists. Choose another -VmName."
}

Write-Progress-Step "Creating Hyper-V VM from appliance VHDX"
# AB#1588 Step 3: Generation 2, UEFI, dynamic memory, 2 vCPU minimum.
$vm = New-VM -Name $VmName -Generation 2 -VHDPath $AppliancePath -SwitchName $switchName
# AB#8129: the appliance hands its setup credentials to host administrators over KVP data exchange.
Enable-VMIntegrationService -VMName $VmName -Name 'Key-Value Pair Exchange'

# AB#8129: static addressing for networks without DHCP — a NoCloud seed with network-config only.
if (-not [string]::IsNullOrEmpty($VmIp)) {
    . "$PSScriptRoot\scripts\CloudGrange-Prereqs.ps1"
    $seedDir = Join-Path $applianceDir "$VmName-seed"
    New-Item -ItemType Directory -Force -Path $seedDir | Out-Null
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText((Join-Path $seedDir 'meta-data'), "instance-id: cloudgrange-appliance-$([guid]::NewGuid().ToString('N'))`nlocal-hostname: $VmName`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $seedDir 'user-data'), "#cloud-config`n", $utf8)
    $net = "version: 2`nethernets:`n  cloudgrange-eth:`n    match:`n      name: `"e*`"`n    set-name: eth0`n    dhcp4: false`n    addresses: [$VmIp/$PrefixLength]`n"
    if ($Gateway) { $net += "    routes:`n      - to: default`n        via: $Gateway`n" }
    if ($DnsServers.Count -gt 0) { $net += "    nameservers:`n      addresses: [$($DnsServers -join ', ')]`n" }
    [IO.File]::WriteAllText((Join-Path $seedDir 'network-config'), $net, $utf8)
    $seedIso = Join-Path $applianceDir "$VmName-seed.iso"
    New-CiDataIso -SourceDir $seedDir -OutputIso $seedIso -VolumeLabel 'cidata'
    Remove-Item -Recurse -Force $seedDir
    Add-VMDvdDrive -VMName $VmName -Path $seedIso
    Write-Host "  Static address $VmIp/$PrefixLength via NoCloud seed (network configuration only)" -ForegroundColor Gray
}
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

# ---------------------------------------------------------------------------
# AB#1588 Step 4: Start VM, wait for first boot (KVP) and the portal
# ---------------------------------------------------------------------------
Write-Progress-Step "Starting appliance VM"
Start-VM -Name $VmName

# AB#8129: read the appliance's guest-to-host KVP items (Hyper-V administrators only).
function Get-CloudGrangeKvpItems {
    param([Parameter(Mandatory)][string]$Name)
    $items = @{}
    $cs = @(Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$Name'" -ErrorAction SilentlyContinue)
    if ($cs.Count -ne 1) { return $items }
    $kvp = Get-CimAssociatedInstance -InputObject $cs[0] -ResultClassName Msvm_KvpExchangeComponent -ErrorAction SilentlyContinue
    if (-not $kvp -or -not $kvp.GuestExchangeItems) { return $items }
    foreach ($xmlText in $kvp.GuestExchangeItems) {
        $props = @{}
        foreach ($p in ([xml]$xmlText).INSTANCE.PROPERTY) { $props[$p.NAME] = $p.VALUE }
        if ([string]$props['Name'] -like 'CloudGrange.*') { $items[[string]$props['Name']] = [string]$props['Data'] }
    }
    return $items
}

Write-Host "  Waiting for first boot to publish the setup credentials over Hyper-V KVP (up to $CredentialTimeoutMinutes minutes)..." -ForegroundColor Gray
$deadline = [DateTime]::UtcNow.AddMinutes($CredentialTimeoutMinutes)
$kvpItems = @{}
while ([DateTime]::UtcNow -lt $deadline) {
    $kvpItems = Get-CloudGrangeKvpItems -Name $VmName
    if ($kvpItems['CloudGrange.State'] -in @('setup-pending', 'setup-complete')) { break }
    Start-Sleep -Seconds 10
}
if ($kvpItems['CloudGrange.State'] -notin @('setup-pending', 'setup-complete')) {
    Write-Host ""
    Write-Host "  [ERROR] The appliance did not publish its setup credentials within $CredentialTimeoutMinutes minutes." -ForegroundColor Red
    Write-Host "  The VM is left running. Open its console (Hyper-V Manager > Connect): the login banner shows" -ForegroundColor Yellow
    Write-Host "  the setup URL, the one-use setup token and the temporary identity administrator password." -ForegroundColor Yellow
    Write-Error "CG-APPL-ERR-008: no CloudGrange.State KVP item from '$VmName'."
}

$address   = if ($VmIp) { $VmIp } else { $kvpItems['CloudGrange.Address'] }
$portalUrl = "https://$address"
Write-Host "  Waiting for the CloudGrange portal at $portalUrl ..." -ForegroundColor Gray
if (-not (Wait-ForHttpOk -Url $portalUrl -TimeoutSeconds 180)) {
    Write-Error "CG-APPL-ERR-001: portal not reachable at $portalUrl within 3 minutes after first boot completed. The VM is left running for diagnosis."
}

# ---------------------------------------------------------------------------
# AB#1588 Step 5 / AB#8129: show the one-use setup credentials ONCE and save the operator SSH key
# ---------------------------------------------------------------------------
$result = [ordered]@{
    VmName             = $VmName
    Address            = $address
    PortalUrl          = $portalUrl
    SetupUrl           = "$portalUrl/setup"
    State              = $kvpItems['CloudGrange.State']
    RealmAdminUser     = $kvpItems['CloudGrange.RealmAdminUser']
    SetupToken         = $null
    RealmAdminPassword = $null
    SshUser            = $kvpItems['CloudGrange.SshUser']
    OperatorKeyPath    = $null
}

Write-Host ""
Write-Host "  CloudGrange appliance is live!" -ForegroundColor Green
Write-Host "  Portal:  $portalUrl" -ForegroundColor Cyan
if ($kvpItems['CloudGrange.State'] -eq 'setup-pending') {
    $sshKey = $kvpItems['CloudGrange.SshPrivateKey']
    if ($sshKey) {
        if ([string]::IsNullOrEmpty($OperatorKeyPath)) {
            $OperatorKeyPath = Join-Path $HOME ".ssh\cloudgrange-$VmName-operator_ed25519"
        }
        New-Item -ItemType Directory -Force -Path (Split-Path $OperatorKeyPath -Parent) | Out-Null
        # Create the file empty, restrict it to the current user, then write the key (LF line endings).
        [IO.File]::WriteAllText($OperatorKeyPath, '')
        $acl = [System.Security.AccessControl.FileSecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([System.Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'Allow'))
        Set-Acl -Path $OperatorKeyPath -AclObject $acl
        [IO.File]::WriteAllText($OperatorKeyPath, (($sshKey -replace "`r`n", "`n").TrimEnd("`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
        $result.OperatorKeyPath = $OperatorKeyPath
    }
    # Security: never put the token in a URL (browser history, logs, Referer). Console only, once.
    Write-Host "  First-run setup: open $portalUrl/setup and enter the one-use setup token when prompted." -ForegroundColor Cyan
    Write-Host "    Setup token:              $($kvpItems['CloudGrange.SetupToken'])" -ForegroundColor White
    Write-Host "    Identity administrator:   $($kvpItems['CloudGrange.RealmAdminUser'])" -ForegroundColor White
    Write-Host "    Temporary password:       $($kvpItems['CloudGrange.RealmAdminPassword'])  (must be changed at first sign-in)" -ForegroundColor White
    if ($result.OperatorKeyPath) {
        Write-Host "    SSH:                      ssh -i `"$OperatorKeyPath`" $($kvpItems['CloudGrange.SshUser'])@$address" -ForegroundColor White
    }
    Write-Host "  These are shown once. The appliance removes the token, the temporary password and the SSH" -ForegroundColor Yellow
    Write-Host "  private key from KVP and its console banner as soon as setup completes." -ForegroundColor Yellow
    if ($PassThru) {
        $result.SetupToken         = ConvertTo-SecureString -String $kvpItems['CloudGrange.SetupToken'] -AsPlainText -Force
        $result.RealmAdminPassword = ConvertTo-SecureString -String $kvpItems['CloudGrange.RealmAdminPassword'] -AsPlainText -Force
    }
} else {
    Write-Host "  Setup has already been completed on this appliance; its one-use credentials were removed." -ForegroundColor Cyan
}
$kvpItems = $null
Write-Host "  Note: The portal uses a self-signed certificate. Your browser will show a security warning." -ForegroundColor Yellow
Write-Host "  Operator access is documented in docs/appliance-operator-access.md." -ForegroundColor Gray
Write-Host ""

if (-not $SkipHostPortForward) {
    # Publish the portal on host port 443 for other machines on the host's network.
    $fwRuleName = 'CloudGrange-Portal-443'
    if (-not (Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $fwRuleName -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow | Out-Null
        netsh interface portproxy add v4tov4 listenport=443 connectaddress=$address connectport=443 | Out-Null
        Write-Host "  Firewall rule and port proxy configured for port 443" -ForegroundColor Gray
    }
}

if ($PassThru) { [pscustomobject]$result }
