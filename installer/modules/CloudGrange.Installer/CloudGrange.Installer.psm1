#Requires -Version 7.4
<#
.SYNOPSIS
    CloudGrange product installer module (phase engine, checkpoint chain, lock, envelopes, evidence,
    release BOM validation).
.DESCRIPTION
    Implements docs/product-installer-design.md §3 (WP-01) and the §2.3 BOM validator (WP-02).
    Phase implementations arrive in later work packages; until then Install fails closed.
.NOTES
    TaskReference: AB#8129 AB#9015 AB#9016
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($file in @('Common', 'Checkpoint', 'Lock', 'Envelope', 'Evidence', 'ReleaseBom', 'Phases', 'Entry')) {
    . (Join-Path (Join-Path $PSScriptRoot 'Private') ($file + '.ps1'))
}

Export-ModuleMember -Function @(
    'Compare-CgProductVersion'
    'ConvertFrom-CgStrictJson'
    'ConvertTo-CgSecretRefRedactor'
    'Enter-CgInstallLock'
    'Exit-CgInstallLock'
    'Get-CgCheckpoint'
    'Get-CgCheckpointPath'
    'Get-CgErrorReason'
    'Get-CgModeDefinition'
    'Get-CgPhaseName'
    'Get-CgReleaseBomRuleCatalog'
    'Get-CgReleaseBomViolation'
    'Get-CgRequestSha256'
    'Initialize-CgNodeKey'
    'Invoke-CgInstallerMode'
    'Invoke-CgInstallerRun'
    'New-CgPhaseRegistry'
    'Protect-CgEnvelope'
    'Read-CgNodeKey'
    'Resolve-CgCheckpoint'
    'Test-CgReleaseBom'
    'Unprotect-CgEnvelope'
    'Write-CgCheckpoint'
    'Write-CgEnvelopeFile'
    'Write-CgEvidence'
)
