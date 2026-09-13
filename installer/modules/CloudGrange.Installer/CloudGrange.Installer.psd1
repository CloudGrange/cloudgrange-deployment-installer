@{
    RootModule = 'CloudGrange.Installer.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'c6f3e1a2-5b7d-4f0e-9a2c-3d8e7b1f4a60'
    Author = 'CloudGrange'
    CompanyName = 'CloudGrange'
    Copyright = 'Copyright CloudGrange contributors. Apache-2.0.'
    Description = 'CloudGrange product installer engine: phases, checkpoint chain, lock, envelopes, evidence and release BOM validation. TaskReference: AB#8129 AB#9015 AB#9016'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
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
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
