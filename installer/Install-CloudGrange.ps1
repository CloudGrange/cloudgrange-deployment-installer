#Requires -Version 7.4
<#
.SYNOPSIS
    CloudGrange product installer: the single customer entry point on the management node.
.DESCRIPTION
    docs/product-installer-design.md §1.5 and §3. Runs from the extracted, SHA-256-authenticated
    install bundle on Ubuntu 24.04 under PowerShell 7 as root:

        sudo pwsh ./Install-CloudGrange.ps1 -Mode Install -SiteConfig /etc/cloudgrange/site-config.json -TrustCheckpointSha256 <hex>

    Start-up order, before any installer module is imported:
      1. platform check (Linux only)
      2. composition pin from protected state OUTSIDE the bundle (/var/lib/cloudgrange/state): the accepted
         record, else the checkpoint chain. A node with installer state that yields no pin is refused.
      3. bin/cg-trust verify-tree --manifest <bundle>/release/composition-manifest.json --root <bundle>
         [--composition-sha256 <pin>] (every mode, every resume; any difference or extra file refuses)
      4. parameters that later work packages implement are refused rather than ignored
      5. root check
    Then the CloudGrange.Installer module is imported and the mode is dispatched. The result is one
    JSON line on stdout: mode, terminal, reasonCode, message. Nothing is ever written inside the bundle.

    This build implements Plan and the Install engine (checkpoint chain, lock, request identity,
    resume). No phase implementation is registered yet, so Plan reports plan-blocked and Install
    refuses before changing anything. Verify, Update, Rollback, Restore, Uninstall and Unseal report
    mode-not-implemented.
.PARAMETER Mode
    Plan, Install, Verify, Update, Rollback, Restore, Uninstall or Unseal.
.PARAMETER SiteConfig
    Path to the cg-site-config-v1 document (kind CloudGrangeSiteConfig, schema_version 1).
.PARAMETER TrustCheckpointSha256
    SHA-256 of trust/checkpoint-<channel>.json published on the independent trust channel. Required by
    Plan and Install (cg-trust verify-composition never derives it from the bundled file).
.PARAMETER ResumeFromPrevious
    Operator confirmation to promote checkpoint.prev when checkpoint.json is corrupt; completed phases
    are re-probed.
.EXAMPLE
    sudo pwsh ./Install-CloudGrange.ps1 -Mode Plan -SiteConfig /etc/cloudgrange/site-config.json -TrustCheckpointSha256 <hex>
.NOTES
    Exit codes: 0 success, 2 refused or blocked before mutation, 3 failed during a phase, 4 not implemented.
    TaskReference: AB#8129 AB#9015
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Plan', 'Install', 'Verify', 'Update', 'Rollback', 'Restore', 'Uninstall', 'Unseal')][string]$Mode,
    [Parameter(Mandatory)][string]$SiteConfig,
    [ValidatePattern('^[0-9a-f]{64}$')][string]$TrustCheckpointSha256,
    [switch]$ResumeFromPrevious,
    [string]$ArtifactMirror,
    [string]$RegistryCredentialRef,
    [string]$EscrowMountPath,
    [string]$BackupMountPath,
    [ValidateSet('Workloads', 'Runtime', 'Purge')][string]$Retain,
    [string]$ConfirmPurge,
    [switch]$Force,
    [string]$ReceiptPath,
    [string]$Bundle,
    [string]$RecoverySet,
    [string]$EscrowPrivateKey,
    [string]$BackupDecryptionKey,
    [string]$TrustFloors,
    [switch]$AuthorizeResume,
    [ValidatePattern('^[0-9a-f]{64}$')][string]$AcknowledgeEscrow,
    [switch]$PrintSetupToken,
    [switch]$DeleteNodeRecoveryEnvelope,
    [switch]$PruneCache
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$bundleRoot = $PSScriptRoot
$stateRoot = '/var/lib/cloudgrange/state'

function Complete-CgEntry {
    param([string]$Terminal, [string]$ReasonCode, [string]$Message, [int]$ExitCode)
    [ordered]@{ mode = $Mode; terminal = $Terminal; reasonCode = $ReasonCode; message = $Message } | ConvertTo-Json -Compress
    exit $ExitCode
}

function Get-CgProtectedCompositionPin {
    <#
    .SYNOPSIS
        Reads the composition manifest digest to pin verify-tree with, from protected installer state
        outside the bundle, without importing any bundle code.
    .DESCRIPTION
        Order: trust/accepted-composition.json (written at acceptance), then checkpoint.json,
        checkpoint.prev, checkpoint.tmp (compositionSha256 is the same across one installation's chain).
        Returns $null when no installer state exists (first extraction: the bundle digest from the
        independent channel covers the manifest). Throws composition-pin-unavailable when state exists
        but no file yields a digest, so a consistent rewrite of the manifest and a module cannot pass
        verify-tree on resume.
    #>
    param([Parameter(Mandatory)][string]$StateRoot)
    $candidates = @('trust/accepted-composition.json', 'checkpoint.json', 'checkpoint.prev', 'checkpoint.tmp') | ForEach-Object { Join-Path $StateRoot $_ }
    $present = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($present.Count -eq 0) { return $null }
    foreach ($path in $present) {
        try {
            if ((Get-Item -LiteralPath $path).Length -gt 4194304) { continue }
            $value = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 64).compositionSha256
            if ($value -is [string] -and $value -cmatch '^[0-9a-f]{64}$') { return $value }
        } catch {
            continue
        }
    }
    throw 'composition-pin-unavailable'
}

if (-not $IsLinux) {
    Complete-CgEntry -Terminal 'refused' -ReasonCode 'unsupported-platform' -Message 'The management-node installer runs on Linux (Ubuntu 24.04) only.' -ExitCode 2
}

# Bind the running tree to the composition manifest before importing anything from it.
$verifier = Join-Path (Join-Path $bundleRoot 'bin') 'cg-trust'
if (-not (Test-Path -LiteralPath $verifier -PathType Leaf)) {
    Complete-CgEntry -Terminal 'refused' -ReasonCode 'verifier-missing' -Message 'bin/cg-trust is not present; the bundle tree cannot be verified.' -ExitCode 2
}
try {
    $pin = Get-CgProtectedCompositionPin -StateRoot $stateRoot
} catch {
    Complete-CgEntry -Terminal 'refused' -ReasonCode 'composition-pin-unavailable' -Message 'Installer state exists but no protected composition digest could be read; nothing was changed.' -ExitCode 2
}
$manifest = Join-Path (Join-Path $bundleRoot 'release') 'composition-manifest.json'
$treeArguments = @('verify-tree', '--manifest', $manifest, '--root', $bundleRoot)
if ($pin) { $treeArguments += @('--composition-sha256', $pin) }
$treeExit = 1
try {
    $null = & $verifier @treeArguments 2>&1
    $treeExit = $LASTEXITCODE
} catch {
    $treeExit = 1
}
if ($treeExit -ne 0) {
    Complete-CgEntry -Terminal 'refused' -ReasonCode 'tree-verification-failed' -Message ('cg-trust verify-tree refused the bundle tree (exit ' + $treeExit + '); nothing was changed.') -ExitCode 2
}

$notImplemented = @('ArtifactMirror', 'RegistryCredentialRef', 'EscrowMountPath', 'BackupMountPath', 'Retain', 'ConfirmPurge', 'Force', 'ReceiptPath', 'Bundle',
    'RecoverySet', 'EscrowPrivateKey', 'BackupDecryptionKey', 'TrustFloors', 'AuthorizeResume', 'AcknowledgeEscrow', 'PrintSetupToken', 'DeleteNodeRecoveryEnvelope', 'PruneCache') |
    Where-Object { $PSBoundParameters.ContainsKey($_) }
if (@($notImplemented).Count -gt 0) {
    Complete-CgEntry -Terminal 'not-implemented' -ReasonCode 'parameter-not-implemented' -Message ('Not implemented in this installer build: -' + (@($notImplemented) -join ', -')) -ExitCode 4
}

$userId = (& id -u 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $userId -cne '0') {
    Complete-CgEntry -Terminal 'refused' -ReasonCode 'root-required' -Message 'Run the installer as root (sudo pwsh ./Install-CloudGrange.ps1 ...).' -ExitCode 2
}

try {
    Import-Module (Join-Path $bundleRoot 'modules/CloudGrange.Installer/CloudGrange.Installer.psd1') -Force
    $result = Invoke-CgInstallerMode -Mode $Mode -BundleRoot $bundleRoot -SiteConfig $SiteConfig -TrustCheckpointSha256 $TrustCheckpointSha256 `
        -StateDirectory $stateRoot -ResumeFromPrevious:$ResumeFromPrevious
    Complete-CgEntry -Terminal $result.Terminal -ReasonCode $result.ReasonCode -Message $result.Message -ExitCode $result.ExitCode
} catch {
    $reason = if (Get-Command -Name Get-CgErrorReason -ErrorAction SilentlyContinue) { Get-CgErrorReason $_ } else { 'unexpected-error' }
    Complete-CgEntry -Terminal 'failed' -ReasonCode $reason -Message 'The installer stopped on an unexpected error; state was preserved.' -ExitCode 3
}
