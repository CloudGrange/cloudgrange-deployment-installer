#Requires -RunAsAdministrator
#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
# ADR-029: Standalone On-Premises Container Runtime (Hyper-V VM + Docker CE)

[CmdletBinding()]
param(
    [ValidateSet('Online', 'Bundled', 'Appliance')]
    [string]$Mode = 'Online',
    # AB#9185/9183: K3s/Helm is the deployment model for this product. Compose remains
    # reachable with -Engine Compose for unmigrated installs (both engines support -Mode
    # Bundled since AB#9171), but it is no longer the default — leaving the default on Compose meant every install
    # that did not pass -Engine silently deployed the stack the restructure replaced.
    # Install-CloudGrange-Linux.sh's own default was flipped for the same reason; these
    # two entry points must agree.
    [ValidateSet('Compose', 'K3s')]
    [string]$Engine = 'K3s',
    [string]$VmIp = '192.168.100.10',
    # AB#9171: the Hyper-V VM name. Defaults per engine (cloudgrange-k3s / cloudgrange-docker).
    # A second install on the same host MUST pass its own name (and -VmIp): provisioning removes and
    # replaces an existing VM of this name, and the VHDX path defaults to <name>.vhdx.
    [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9-]{0,62}$')]
    [string]$VmName = '',
    # AB#9171: the DNS name or IP address users browse to, when that is not the VM IP: for example the
    # Windows host's own address, which forwards 443 and 8443 to the VM. It becomes the certificate
    # SAN, the sign-in (SSO) host and the CLI server, so it must be the address clients really use.
    # Empty = -VmIp (reachable from this host only).
    [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$')]
    [string]$Hostname = '',
    [string]$VhdxPath = 'C:\ProgramData\CloudGrange\cloudgrange-docker.vhdx',
    # AB#1585 — Proxy support. Format: http://host:port or http://user:pass@host:port
    # If omitted, reads $env:HTTPS_PROXY then $env:HTTP_PROXY.
    # Credentials are NEVER logged. No proxy credential is written to disk.
    [string]$HttpProxy = '',
    [string]$ProxyUser = '',
    [SecureString]$ProxyPassword,
    # AB#9171 (C1): empty = the release the chart pins (K3s engine). It used to default to 'latest', so
    # the wrapper, not the chart, chose the Platform build. Pass a YYMM.MINOR.PATCH to override.
    [string]$Version = '',
    # AB#1852: path to the cloudgrange bundle directory (extracted zip) for offline installs.
    # When not specified and Mode=Bundled, the installer looks in $PSScriptRoot for bundle files.
    [string]$BundlePath = '',
    [switch]$AcceptDefaults,
    [switch]$Force,
    # AB#8129: Hyper-V switch for the VM. When it already exists (for example a switch that
    # already has WinNAT, which allows only one NAT per host), it is used as-is: no host IP or
    # NAT changes are made.
    [string]$SwitchName = 'cloudgrange-internal',
    # AB#8129: skip the host-wide inbound 443 firewall rule and netsh portproxy to the VM.
    [switch]$SkipHostPortForward,
    # AB#8129: air-gapped VM — no default route in cloud-init network-config (Bundled mode only).
    [switch]$NoDefaultGateway,
    # AB#8129: explicit opt-in to install the pinned, SHA-512-verified QEMU build when qemu-img
    # is missing. Without it the installer fails closed (see docs/prerequisites.md).
    [switch]$InstallPinnedQemu,
    # AB#8129: keep the ephemeral installer SSH key (path printed) so Build-CloudGrangeAppliance.ps1
    # can generalize the VM before export. Default: the key is deleted after install.
    [switch]$KeepInstallerSshKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# AB#9171: -Mode Bundled runs the K3s engine like every other mode. Install-CloudGrange-K3s-Bundled.zip
# carries K3s, its airgap images, every chart image and a pinned Helm (New-ReleaseBundleK3s.sh). This
# script used to downgrade an offline install to Compose silently whenever -Engine was not passed,
# because the K3s bundle had no offline images; that gap is closed, so the downgrade is gone and
# Compose (legacy, unmigrated installs) is reachable only by asking for it explicitly.

. "$PSScriptRoot\scripts\CloudGrange-Common.ps1"
. "$PSScriptRoot\scripts\CloudGrange-Prereqs.ps1"

# AB#1585 — Proxy resolution. Priority: -HttpProxy param > $env:HTTPS_PROXY > $env:HTTP_PROXY
# Credentials are never logged — the installer never writes proxy credentials to any file.
if ([string]::IsNullOrEmpty($HttpProxy)) {
    $HttpProxy = $env:HTTPS_PROXY ?? $env:HTTP_PROXY ?? ''
}
if (-not [string]::IsNullOrEmpty($HttpProxy)) {
    Write-Host "  Proxy: $($HttpProxy -replace '://[^:]+:[^@]+@', '://<credentials-redacted>@')" -ForegroundColor Gray
}
$proxyArgs = @{}
if (-not [string]::IsNullOrEmpty($HttpProxy)) {
    $proxyArgs['Proxy'] = $HttpProxy
    if (-not [string]::IsNullOrEmpty($ProxyUser)) {
        $proxyArgs['ProxyUser'] = $ProxyUser
        $proxyArgs['ProxyPassword'] = $ProxyPassword
    }
}

$effectiveVmName = if ($VmName) { $VmName } elseif ($Engine -eq 'K3s') { 'cloudgrange-k3s' } else { 'cloudgrange-docker' }

function Invoke-CloudGrangeInstall {
    Write-Host "`n  CloudGrange Installer — Mode: $Mode" -ForegroundColor Cyan
    Write-Host "  ─────────────────────────────────────" -ForegroundColor DarkGray

    # Step 1: Mandatory package integrity self-check (AB#1598)
    # The .sha256 file MUST be present alongside the installer before any host changes are made.
    # This prevents tampered or partially-downloaded installers from mutating the host.
    $checksumFile = Join-Path $PSScriptRoot 'cloudgrange-installer.sha256'
    Write-Progress-Step "Verifying installer package integrity"
    if (-not (Test-Path $checksumFile)) {
        Write-Host ""
        Write-Host "  [ERROR] Package integrity check failed. Do not proceed." -ForegroundColor Red
        Write-Host "  The file 'cloudgrange-installer.sha256' was not found alongside Install-CloudGrange.ps1." -ForegroundColor Red
        Write-Host "  Re-download the complete CloudGrange installer package from the release page." -ForegroundColor Yellow
        Write-Error "[ERROR] Package integrity check failed. Do not proceed."
    }
    $expected = (Get-Content $checksumFile -Raw).Trim().Split()[0]
    $actual   = (Get-FileHash -Path $PSCommandPath -Algorithm SHA256).Hash
    if ($expected -ine $actual) {
        Write-Host ""
        Write-Host "  [ERROR] Package integrity check failed. Do not proceed." -ForegroundColor Red
        Write-Host "  Expected SHA-256: $expected" -ForegroundColor Gray
        Write-Host "  Actual   SHA-256: $actual"   -ForegroundColor Gray
        Write-Host "  The installer file may be corrupted or tampered. Re-download from the release page." -ForegroundColor Yellow
        Write-Error "[ERROR] Package integrity check failed. Do not proceed."
    }
    Write-Host "  Integrity OK ($($actual.Substring(0,16))...)" -ForegroundColor Green

    # Step 2: Hyper-V detection (AB#1581)
    Write-Progress-Step "Checking Hyper-V availability"
    # Hyper-V feature naming differs by OS: Windows Server exposes the 'Hyper-V' role
    # (Get-WindowsFeature); Windows client (10/11) exposes the 'Microsoft-Hyper-V-All'
    # optional feature (Get-WindowsOptionalFeature). ProductType 1 = client/workstation.
    $isServerOs = (Get-CimInstance Win32_OperatingSystem).ProductType -ne 1
    if ($isServerOs) {
        $hvAvailable = (Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue).InstallState -eq 'Installed'
    } else {
        $hvFeature = Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-All -Online -ErrorAction SilentlyContinue
        $hvAvailable = ($hvFeature -and $hvFeature.State -eq 'Enabled')
    }
    if (-not $hvAvailable) {
        Write-Host "  CG-INST-ERR-001: Hyper-V is not installed on this host." -ForegroundColor Red
        Write-Host "  To enable Hyper-V on Windows Server, run:"
        Write-Host "    Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart" -ForegroundColor Yellow
        Write-Host "  To enable Hyper-V on Windows 10/11:"
        Write-Host "    Enable-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-All -Online -Restart" -ForegroundColor Yellow
        Write-Error "CG-INST-ERR-001: Hyper-V is required. Install Hyper-V and re-run the installer."
    }
    Write-Host "  Hyper-V: available" -ForegroundColor Green
    $useWsl2 = $false

    # Nested virtualization check — required when this host is itself a virtual machine (AB#1581)
    Write-Progress-Step "Checking nested virtualization support"
    $isVm = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
    if ($isVm) {
        # Check whether nested virt is enabled: if Hyper-V is installed and running inside a VM,
        # the system's logical processor count via MSVM_Processor will be > 0 OR
        # we can check if the virtualization-based security (VBS) is active via systeminfo.
        # Reliable cross-platform approach: try to retrieve at least one VM from Hyper-V;
        # if HyperV is installed but nested virt is off, this call may succeed but VM creation
        # will fail. We detect it by checking if VirtualizationFirmwareEnabled = True on the CPU.
        $nestedVirtEnabled = $false
        try {
            $cpuNested = Get-WmiObject -Namespace root\virtualization\v2 -Class Msvm_Processor -ErrorAction Stop |
                Where-Object { $_.EnabledState -eq 2 } |
                Select-Object -First 1
            if ($cpuNested) { $nestedVirtEnabled = $true }
        } catch {
            # Namespace may not exist if nested virt was never enabled
        }

        # Alternative: check MSSystemInformation
        if (-not $nestedVirtEnabled) {
            $sysinfo = & systeminfo /FO CSV 2>$null | ConvertFrom-Csv -ErrorAction SilentlyContinue
            if ($sysinfo -and ($sysinfo.'Hyper-V Requirements' -match 'A hypervisor has been detected')) {
                $nestedVirtEnabled = $true
            }
        }

        if (-not $nestedVirtEnabled) {
            Write-Host "  CG-INST-ERR-002: This host is a virtual machine but nested virtualization is not enabled." -ForegroundColor Red
            Write-Host "  On Hyper-V: run on the parent host: Set-VMProcessor -VMName '<vm-name>' -ExposeVirtualizationExtensions `$true" -ForegroundColor Yellow
            Write-Host "  On Azure: use a VM size that supports nested virtualization (Standard_D_v3 / Standard_E_v3 family or later)." -ForegroundColor Yellow
            Write-Error "CG-INST-ERR-002: Nested virtualization is required when running inside a VM. Enable nested virtualization and re-run."
        }
        Write-Host "  Nested virtualization: enabled" -ForegroundColor Green
    } else {
        Write-Host "  Nested virtualization check: N/A (bare-metal host)" -ForegroundColor Gray
    }

    # Step 3: Validate VM IP doesn't conflict with existing Hyper-V switches
    # Hyper-V cmdlets are not available in PS7 — this check runs via powershell.exe (PS5.1).
    if (-not $useWsl2) {
        Write-Progress-Step "Validating VM IP $VmIp"
        # AB#9171: refuse an IP another machine already answers on, unless it is the VM this run
        # replaces (a re-run). Without this a second install on the host silently took over the
        # first install's address. Hyper-V does not report guest IPs without KVP, so ping is the probe.
        $ownVmExists = [bool](& powershell.exe -NonInteractive -NoProfile -Command "Import-Module Hyper-V -ErrorAction SilentlyContinue; [bool](Get-VM -Name '$effectiveVmName' -ErrorAction SilentlyContinue)" 2>$null | Select-String -SimpleMatch 'True')
        if (-not $ownVmExists -and (Test-Connection -TargetName $VmIp -Count 1 -TimeoutSeconds 2 -Quiet -ErrorAction SilentlyContinue)) {
            Write-Error "CG-INST-ERR-014: $VmIp already answers on the network and no VM named '$effectiveVmName' exists to replace. Pick a free -VmIp (and a -VmName for a second install on this host)."
        }
        Write-Host "  IP validation passed" -ForegroundColor Green
    }

    # Step 4: Create VM or WSL2 environment
    # Initialise credential/SSH vars before the if/else to avoid strict-mode errors
    # when the WSL2 path runs and steps 5-6 reference these in condition checks.
    $vmGuestCred = $null
    $sshKeyPath  = ''
    $sshKeyDir   = ''

    if (-not $useWsl2) {
        # AB#9171 (C3): qemu-img is no longer required up front. The VM's base disk is the release's
        # pinned, pre-converted Ubuntu VHDX; qemu-img (and -InstallPinnedQemu) is only needed on the
        # fallback path when that is unavailable, and New-CloudGrangeVm.ps1 checks for it there.
        if ($NoDefaultGateway -and $Mode -ne 'Bundled') {
            Write-Error "CG-INST-ERR-012: -NoDefaultGateway requires -Mode Bundled (Online mode needs registry access)."
        }

        # Generate an ephemeral SSH key pair for this install session.
        # The private key is written to a temp file (mode 600) and deleted after install.
        # The public key is embedded in the VM's cloud-init authorized_keys.
        # Neither key is ever logged, committed, or persisted beyond this install run.
        $sshKeyDir  = Join-Path $env:TEMP $(if ($VmName) { "cloudgrange-install-key-$VmName" } else { 'cloudgrange-install-key' })
        New-Item -ItemType Directory -Path $sshKeyDir -Force | Out-Null
        $sshKeyPath = Join-Path $sshKeyDir 'installer_ed25519'
        if (Test-Path $sshKeyPath) { Remove-Item $sshKeyPath, "$sshKeyPath.pub" -Force }
        # Use ProcessStartInfo.ArgumentList to reliably pass the empty passphrase.
        # In PS7.3+ on Windows, the default native arg-passing mode drops empty string
        # arguments — so `& ssh-keygen -N ""` arrives at the process as `-N -C` (passphrase
        # becomes the literal string "-C"), producing a passphrase-protected key that SSH
        # cannot use non-interactively. ProcessStartInfo.ArgumentList builds the argv array
        # directly via CreateProcess, bypassing PowerShell's marshaling entirely.
        $sshKeygenExe = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source
        $psi = New-Object System.Diagnostics.ProcessStartInfo($sshKeygenExe)
        @('-t', 'ed25519', '-f', $sshKeyPath, '-N', '', '-C', 'cloudgrange-installer-ephemeral', '-q') |
            ForEach-Object { $psi.ArgumentList.Add($_) }
        $psi.UseShellExecute = $false
        $keygen = [System.Diagnostics.Process]::Start($psi)
        $keygen.WaitForExit()
        if ($keygen.ExitCode -ne 0) {
            Write-Error "ssh-keygen exited with code $($keygen.ExitCode). Ensure OpenSSH Client is installed."
        }
        if (-not (Test-Path $sshKeyPath)) {
            Write-Error "Failed to generate SSH key pair. Ensure OpenSSH Client is installed (ssh-keygen.exe must be in PATH)."
        }
        $sshPublicKey = (Get-Content "$sshKeyPath.pub" -Raw).Trim()

        Write-Progress-Step "Provisioning Hyper-V VM"
        # AB#1852: in Bundled mode, resolve the Ubuntu image path from the bundle directory
        $bundledUbuntuPath = ''
        if ($Mode -eq 'Bundled') {
            $bundleRoot = if (-not [string]::IsNullOrEmpty($BundlePath)) { $BundlePath } else { $PSScriptRoot }
            # AB#9171 (C3): prefer the pre-converted base VHDX (no qemu-img); a cloud .img still works.
            $bundledVhdx = Get-ChildItem -Path $bundleRoot -Filter 'ubuntu-noble-*-hyperv-gen2-30g.vhdx' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            $bundledUbuntuPath = if ($bundledVhdx) { $bundledVhdx.FullName } else { Join-Path $bundleRoot 'ubuntu-24.04-cloudimg.img' }
        }
        # AB#9185 fix: New-CloudGrangeVm.ps1 used to hardcode the VM name to
        # cloudgrange-docker regardless of -Engine, so a K3s install would provision (and on
        # rerun, silently delete/replace) a Hyper-V VM literally named cloudgrange-docker —
        # colliding with any existing Compose VM of that name. Give each engine its own VM
        # name and VHDX path; only override the VHDX default (never an explicit -VhdxPath
        # the caller supplied) so a user-specified path is still honored for either engine.
        $effectiveVhdxPath = $VhdxPath
        if ($VhdxPath -eq 'C:\ProgramData\CloudGrange\cloudgrange-docker.vhdx') {
            $effectiveVhdxPath = "C:\ProgramData\CloudGrange\$effectiveVmName.vhdx"
        }
        # New-CloudGrangeVm.ps1 uses Hyper-V cmdlets that require Windows PowerShell (PS5.1).
        # Invoke via powershell.exe so the Hyper-V module loads correctly while the main
        # installer continues to run under PS7.
        $vmArgs = @(
            '-NonInteractive', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', "$PSScriptRoot\scripts\New-CloudGrangeVm.ps1",
            '-VmIp', $VmIp,
            '-VhdxPath', $effectiveVhdxPath,
            '-Mode', $Mode,
            '-SshPublicKeyFile', "$sshKeyPath.pub",
            '-BundledImagePath', $bundledUbuntuPath,
            '-SwitchName', $SwitchName,
            '-VmName', $effectiveVmName
        )
        if ($SkipHostPortForward) { $vmArgs += '-SkipHostPortForward' }
        if ($InstallPinnedQemu)   { $vmArgs += '-InstallPinnedQemu' }
        if ($NoDefaultGateway)    { $vmArgs += '-NoDefaultGateway' }
        & powershell.exe @vmArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Error "CG-INST-ERR-010: VM provisioning failed (exit $LASTEXITCODE). Check Hyper-V event log for details."
        }
    } else {
        Write-Progress-Step "Configuring WSL2 environment"
        . "$PSScriptRoot\scripts\Install-Wsl2Fallback.ps1"
        Install-Wsl2Fallback
    }

    # Step 5-6: install the runtime and deploy the stack. AB#9185: the K3s/Helm engine
    # skips Docker CE + Compose entirely — Install-CloudGrangeK3s.sh (run remotely by
    # Deploy-K3sHelm.ps1) installs K3s itself and does the chart install in one step.
    if (-not $useWsl2 -and -not [string]::IsNullOrEmpty($sshKeyPath)) {
        Write-Progress-Step "Waiting for VM SSH to become available"
        $sshReady = Wait-ForTcp -HostName $VmIp -Port 22 -TimeoutSeconds 300
        if (-not $sshReady) {
            Write-Warning "SSH not reachable within 5 minutes. Install may fail."
        } else {
            Write-Host "  SSH available at $VmIp" -ForegroundColor Green
        }
    }

    if ($Engine -eq 'K3s') {
        Write-Progress-Step "Deploying CloudGrange via K3s/Helm"
        . "$PSScriptRoot\scripts\Deploy-K3sHelm.ps1"
        $k3sArgs = @{ VmName = $effectiveVmName; VmIp = $VmIp; Version = $Version; UseWsl2 = $useWsl2 }
        if ($Hostname) { $k3sArgs['Hostname'] = $Hostname }
        if ($Mode -eq 'Bundled') {
            # AB#9171: the airgap/ directory of an extracted Install-CloudGrange-K3s-Bundled.zip.
            $bundleRoot = if (-not [string]::IsNullOrEmpty($BundlePath)) { $BundlePath } else { $PSScriptRoot }
            $airgap = Join-Path $bundleRoot 'airgap'
            if (-not (Test-Path (Join-Path $airgap 'k3s.sha256'))) {
                Write-Error "CG-INST-ERR-013: -Mode Bundled needs the airgap/ directory of an extracted Install-CloudGrange-K3s-Bundled.zip at $airgap (pass -BundlePath)."
            }
            $k3sArgs['AirgapPath'] = $airgap
        }
        if (-not $useWsl2 -and -not [string]::IsNullOrEmpty($sshKeyPath)) {
            $k3sArgs['SshKeyPath'] = $sshKeyPath
        } elseif (-not $useWsl2 -and $null -ne $vmGuestCred) {
            $k3sArgs['Credential'] = $vmGuestCred
        }
        Deploy-K3sHelm @k3sArgs
    } else {
        Write-Progress-Step "Installing Docker CE"
        . "$PSScriptRoot\scripts\Install-DockerCe.ps1"
        $dockerCeArgs = @{ VmName = $effectiveVmName; UseWsl2 = $useWsl2; VmIp = $VmIp }
        if (-not $useWsl2 -and -not [string]::IsNullOrEmpty($sshKeyPath)) {
            $dockerCeArgs['SshKeyPath'] = $sshKeyPath
        } elseif (-not $useWsl2 -and $null -ne $vmGuestCred) {
            $dockerCeArgs['Credential'] = $vmGuestCred
        }
        # AB#8129: Bundled mode installs Docker CE from the pinned .deb set in the bundle (no network).
        if ($Mode -eq 'Bundled') {
            $bundleRoot = if (-not [string]::IsNullOrEmpty($BundlePath)) { $BundlePath } else { $PSScriptRoot }
            $bundledDebs = Join-Path $bundleRoot 'docker-debs'
            if (-not (Test-Path (Join-Path $bundledDebs 'SHA256SUMS'))) {
                Write-Error "CG-INST-ERR-011: Bundled mode requires docker-debs/ in the bundle ($bundledDebs)."
            }
            $dockerCeArgs['OfflinePackagesPath'] = $bundledDebs
        }
        Install-DockerCe @dockerCeArgs @proxyArgs

        Write-Progress-Step "Deploying CloudGrange Docker Compose stack"
        . "$PSScriptRoot\scripts\Deploy-DockerCompose.ps1"
        # Compose (legacy, unmigrated installs only) keeps its old default tag.
        $composeArgs = @{ VmName = $effectiveVmName; VmIp = $VmIp; Version = $(if ($Version) { $Version } else { 'latest' }); UseWsl2 = $useWsl2 }
        if (-not $useWsl2 -and -not [string]::IsNullOrEmpty($sshKeyPath)) {
            $composeArgs['SshKeyPath'] = $sshKeyPath
        } elseif (-not $useWsl2 -and $null -ne $vmGuestCred) {
            $composeArgs['Credential'] = $vmGuestCred
        }
        # AB#1852: in Bundled mode, pass the pre-saved images tar path
        if ($Mode -eq 'Bundled') {
            $bundleRoot = if (-not [string]::IsNullOrEmpty($BundlePath)) { $BundlePath } else { $PSScriptRoot }
            $bundledImageTar = Join-Path $bundleRoot 'cloudgrange-images.tar'
            if (Test-Path $bundledImageTar) {
                $composeArgs['BundledImagesPath'] = $bundledImageTar
            } else {
                Write-Warning "Bundled images tar not found at $bundledImageTar — falling back to docker pull"
            }
        }
        Deploy-DockerCompose @composeArgs
    }

    # Step 7: Wait for API health, then emit setup URL (AB#1627, ADR-047)
    # AB#1593 / AB#8129: nginx terminates TLS on 443 and is the only published entry point. The API
    # has no host port; /health/ and /api/ reach it through edge nginx -> portal proxy -> API.
    Write-Progress-Step "Waiting for CloudGrange API to become healthy"
    $apiHealthBase = "https://${VmIp}"
    $portalBase    = "https://$(if ($Hostname) { $Hostname } else { $VmIp })"
    $healthOk = Wait-ForHttpOk -Url "$apiHealthBase/health/ready" -TimeoutSeconds 600
    if (-not $healthOk) {
        # CG-INST-ERR-030: API did not become healthy within 10 minutes
        try {
            $lastResp = Invoke-WebRequest -Uri "$apiHealthBase/health/ready" -SkipCertificateCheck -TimeoutSec 5 -ErrorAction SilentlyContinue
            $lastStatus = $lastResp.StatusCode
        } catch {
            $lastStatus = 'unreachable'
        }
        Write-Error "CG-INST-ERR-030: CloudGrange did not start within 10 minutes. Last health status: $lastStatus"
    }
    Write-Host "  API health: OK" -ForegroundColor Green

    # Check setup state — print first-run URL if setup is still pending
    $setupPending = $false
    $setupTokenRequired = $false
    try {
        # AB#8129: the API route is /api/v1/setup/status and returns { setupComplete, platformName, publicUrl }.
        $statusResp = Invoke-RestMethod -Uri "$apiHealthBase/api/v1/setup/status" -SkipCertificateCheck -TimeoutSec 10 -ErrorAction Stop
        $setupPending = -not [bool]$statusResp.setupComplete
        # AB#9171: only look for the one-use token when the platform says it wants one.
        $setupTokenRequired = [bool]($statusResp.PSObject.Properties['setupTokenRequired'] -and $statusResp.setupTokenRequired)
    } catch {
        # Non-fatal — setup-status endpoint may not yet be reachable; user navigates manually
    }

    # AB#8129 / AB#8894: first-run credentials. POST /api/v1/setup requires the one-use setup token
    # the API wrote to its secrets volume; the realm administrator was created with a random temporary
    # password. Both are read from inside the VM over SSH and shown ONLY on this console (never in a
    # URL or a file written by the installer).
    $setupToken = ''
    $realmAdminPassword = ''
    if (-not [string]::IsNullOrEmpty($sshKeyPath) -and (Test-Path $sshKeyPath)) {
      # AB#9171: these reads only DISPLAY credentials after a successful install. A hang or error here
      # (seen live: CG-SSH-ERR-002 after "API health: OK") must never turn a working install into a failure.
      try {
        $credSsh = Get-CloudGrangeSshOptions -KeyPath $sshKeyPath
        if ($Engine -eq 'K3s') {
            # AB#9185: the K3s engine's API pod and its bootstrap secrets Secret (AB#9178)
            # replace the Compose engine's docker-compose-exec and .env file reads above.
            if ($setupPending -and $setupTokenRequired) {
                # CLOUDGRANGE_REQUIRE_SETUP_TOKEN is off by default, so this file normally does not
                # exist — 2>/dev/null keeps that expected, handled-below miss from printing a raw
                # "cat: ... No such file or directory" to the console on every ordinary install.
                $setupToken = ((Invoke-CloudGrangeSsh -ArgumentList ($credSsh + @("cloudgrange@$VmIp", 'sudo k3s kubectl exec deploy/cloudgrange-api -- cat /etc/cloudgrange/secrets/cloudgrange-initial-admin-token.txt 2>/dev/null')) -CaptureOutput -TimeoutSeconds 120) -join '').Trim()
                if ($setupToken -notmatch '^[0-9a-f]{32,}$') { $setupToken = '' }
            }
            $realmAdminPassword = ((Invoke-CloudGrangeSsh -ArgumentList ($credSsh + @("cloudgrange@$VmIp", "sudo k3s kubectl get secret cloudgrange-secrets -o jsonpath='{.data.realm-admin-password}' | base64 -d")) -CaptureOutput -TimeoutSeconds 120) -join '').Trim()
        } else {
            if ($setupPending) {
                $setupToken = ((Invoke-CloudGrangeSsh -ArgumentList ($credSsh + @("cloudgrange@$VmIp", 'cd /opt/cloudgrange && sudo docker compose exec -T cloudgrange-api cat /etc/cloudgrange/secrets/cloudgrange-initial-admin-token.txt 2>/dev/null')) -CaptureOutput -TimeoutSeconds 120) -join '').Trim()
                if ($setupToken -notmatch '^[0-9a-f]{32,}$') { $setupToken = '' }
            }
            $realmAdminPassword = ((Invoke-CloudGrangeSsh -ArgumentList ($credSsh + @("cloudgrange@$VmIp", "sudo grep '^CLOUDGRANGE_REALM_ADMIN_PASSWORD=' /opt/cloudgrange/.env | cut -d= -f2")) -CaptureOutput -TimeoutSeconds 120) -join '').Trim()
        }
      } catch {
        Write-Warning "CloudGrange is installed, but the installer could not read the first-run credentials from the VM ($($_.Exception.Message)). Open the portal to run the setup wizard."
      }
    }

    # Clean up the ephemeral SSH key pair after successful install, unless an appliance build
    # needs it to generalize the VM (-KeepInstallerSshKey, AB#8129).
    if ($KeepInstallerSshKey -and -not [string]::IsNullOrEmpty($sshKeyPath) -and (Test-Path $sshKeyPath)) {
        Write-Host "  Installer SSH key kept for appliance build: $sshKeyPath" -ForegroundColor Yellow
        Write-Host "  Build-CloudGrangeAppliance.ps1 removes its authorized_keys entry; delete this key afterwards." -ForegroundColor Yellow
    } elseif (-not [string]::IsNullOrEmpty($sshKeyPath) -and (Test-Path $sshKeyPath)) {
        Remove-Item -LiteralPath $sshKeyPath, "$sshKeyPath.pub" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $sshKeyDir -Force -Recurse -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "  CloudGrange installed successfully!" -ForegroundColor Green
    Write-Host "  Portal: $portalBase" -ForegroundColor Cyan
    Write-Host "  Note: The portal uses a self-signed certificate. Your browser will show a security warning." -ForegroundColor Yellow
    if ($Engine -eq 'K3s') {
        Write-Host "        Replace cert-manager's self-signed ClusterIssuer with a customer-provided CA or ACME issuer for production." -ForegroundColor Gray
    } else {
        Write-Host "        Replace /etc/nginx/certs/ in the nginx_certs volume with a CA-signed cert for production." -ForegroundColor Gray
    }
    if ($setupPending) {
        Write-Host "  First-run setup: open $portalBase in a browser; the setup wizard starts on the first visit." -ForegroundColor Yellow
        Write-Host "  Complete the setup wizard to configure your platform name, timezone, and admin account." -ForegroundColor Gray
        if ($setupToken) {
            # Only when the platform was configured to require the one-use token (CLOUDGRANGE_REQUIRE_SETUP_TOKEN=true).
            Write-Host "  One-use setup token (required by POST /api/v1/setup, header X-CloudGrange-Setup-Token):" -ForegroundColor Yellow
            Write-Host "    $setupToken" -ForegroundColor White
            Write-Host "  Keep it secret: whoever presents it first completes setup. It is deleted once setup succeeds." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Sign in at: $portalBase/login" -ForegroundColor Cyan
    }
    if ($realmAdminPassword) {
        Write-Host "  Identity administrator: admin@cloudgrange.local" -ForegroundColor Cyan
        Write-Host "    Temporary password (must be changed at first sign-in): $realmAdminPassword" -ForegroundColor White
    }
    Write-Host ""
}

Invoke-CloudGrangeInstall
