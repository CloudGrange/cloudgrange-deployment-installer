#Requires -Version 7.4
<#
.SYNOPSIS
    Mode dispatch behind Install-CloudGrange.ps1: bundle inputs, request identity, Plan and Install.
.DESCRIPTION
    Invoked by the entry script after verify-tree succeeded and before any phase work. Order:
      1. mode known and implemented (unimplemented modes stop with mode-not-implemented, no mutation)
      2. the state directory lies outside the bundle root (cg-trust verify-tree denies any extra file)
      3. site config present; bundled management scripts (validator, SecretRef.psm1) present
      4. cg-trust verify-composition --checkpoint trust/checkpoint-<channel>.json --checkpoint-sha256 <independent>
         --channel <channel> --release <bundle>/release --content-root <bundle> --output <temp file outside the bundle>
         --artifact-mode digest-only (retrieved members are absent until the retrieve phase; WP-04 stream-hashes them)
      5. release BOM validation (Test-CgReleaseBom, bound to the bundled site-config schema)
      6. PowerShell >= compatibility.installer.powershellMinimum
      7. site config validation through management/Test-CloudGrangeSiteConfig.ps1 (codes only)
      8. request identity = sha256(site-config bytes || compositionSha256 bytes || catalogPayloadSha256 bytes)
    Plan never mutates installer state. Install refuses before any mutation while any phase lacks an implementation.
.NOTES
    TaskReference: AB#8129 AB#9015 AB#9016
#>
Set-StrictMode -Version Latest

function Get-CgRequestSha256 {
    <#
    .SYNOPSIS
        sha256(site-config bytes || 32 raw bytes of compositionSha256 || 32 raw bytes of catalogPayloadSha256).
    .DESCRIPTION
        The two digests are appended as raw bytes, so the fixed 64-byte suffix makes the
        concatenation unambiguous.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$SiteConfigBytes,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$CompositionSha256,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$CatalogPayloadSha256
    )
    $buffer = [IO.MemoryStream]::new()
    try {
        $buffer.Write($SiteConfigBytes, 0, $SiteConfigBytes.Length)
        $composition = [Convert]::FromHexString($CompositionSha256)
        $catalog = [Convert]::FromHexString($CatalogPayloadSha256)
        $buffer.Write($composition, 0, 32)
        $buffer.Write($catalog, 0, 32)
        return Get-CgSha256Hex -Bytes $buffer.ToArray()
    } finally {
        $buffer.Dispose()
    }
}

function Get-CgJwsPayloadSha256 {
    <# SHA-256 of the decoded payload bytes of a compact JWS. Authenticity is cg-trust's job, not this function's. #>
    param([Parameter(Mandatory)][string]$CompactJws)
    $parts = $CompactJws.Trim().Split('.')
    if ($parts.Count -ne 3 -or @($parts | Where-Object { $_ -cnotmatch '^[A-Za-z0-9_-]+$' }).Count -gt 0) {
        throw (New-CgError 'catalog-malformed' 'release/catalog.jws is not a compact JWS.')
    }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } 1 { throw (New-CgError 'catalog-malformed' 'JWS payload has an invalid length.') } }
    try { $bytes = [Convert]::FromBase64String($payload) } catch { throw (New-CgError 'catalog-malformed' 'JWS payload is not base64url.') }
    return Get-CgSha256Hex -Bytes $bytes
}

function Test-CgPathInside {
    <# True when Path equals Root or lies beneath it (case-insensitive, conservative on every platform). #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $rootFull = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Root))
    $pathFull = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Path))
    if ([string]::Equals($pathFull, $rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Invoke-CgTrustVerifier {
    param([Parameter(Mandatory)][string]$BundleRoot, [Parameter(Mandatory)][string[]]$Arguments)
    $verifier = Join-Path (Join-Path $BundleRoot 'bin') 'cg-trust'
    if (-not (Test-Path -LiteralPath $verifier -PathType Leaf)) { throw (New-CgError 'verifier-missing' 'bin/cg-trust is not present in the bundle.') }
    $output = & $verifier @Arguments 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { [string]$_ }) }
}

function Get-CgInstallerInput {
    param([Parameter(Mandatory)][string]$BundleRoot, [Parameter(Mandatory)][string]$SiteConfig, [Parameter(Mandatory)][string]$TrustCheckpointSha256)
    if (-not (Test-Path -LiteralPath $SiteConfig -PathType Leaf)) { throw (New-CgError 'site-config-missing' 'The -SiteConfig file does not exist.') }
    $validator = Join-Path $BundleRoot 'management/Test-CloudGrangeSiteConfig.ps1'
    $secretRef = Join-Path $BundleRoot 'management/SecretRef.psm1'
    if (-not (Test-Path -LiteralPath $validator -PathType Leaf) -or -not (Test-Path -LiteralPath $secretRef -PathType Leaf)) {
        throw (New-CgError 'management-scripts-missing' 'The bundle lacks management/Test-CloudGrangeSiteConfig.ps1 or management/SecretRef.psm1.')
    }
    $releaseDirectory = Join-Path $BundleRoot 'release'
    $manifestPath = Join-Path $releaseDirectory 'composition-manifest.json'
    $catalogPath = Join-Path $releaseDirectory 'catalog.jws'
    $bomPath = Join-Path $releaseDirectory 'release-bom.json'
    foreach ($required in @(@($manifestPath, 'composition-manifest-missing'), @($catalogPath, 'catalog-missing'), @($bomPath, 'release-bom-missing'))) {
        if (-not (Test-Path -LiteralPath $required[0] -PathType Leaf)) { throw (New-CgError $required[1] ('Missing bundle file ' + [IO.Path]::GetRelativePath($BundleRoot, $required[0]).Replace('\', '/') + '.')) }
    }
    $channels = @(@('m0-internal', 'm0-fixture') | Where-Object { Test-Path -LiteralPath (Join-Path $BundleRoot ('trust/checkpoint-' + $_ + '.json')) -PathType Leaf })
    if ($channels.Count -eq 0) { throw (New-CgError 'trust-checkpoint-missing' 'The bundle has no trust/checkpoint-<channel>.json.') }
    if ($channels.Count -gt 1) { throw (New-CgError 'trust-checkpoint-ambiguous' 'The bundle carries trust checkpoints for more than one channel.') }
    $channel = $channels[0]

    $trustOutput = Join-Path ([IO.Path]::GetTempPath()) ('cg-trust-verify-composition-' + [guid]::NewGuid().ToString('N') + '.json')
    if (Test-CgPathInside -Path $trustOutput -Root $BundleRoot) { throw (New-CgError 'trust-output-inside-bundle' 'The verifier output would land inside the bundle tree.') }
    $trustEvidence = $null
    try {
        $trust = Invoke-CgTrustVerifier -BundleRoot $BundleRoot -Arguments @(
            'verify-composition', '--checkpoint', (Join-Path $BundleRoot ('trust/checkpoint-' + $channel + '.json')), '--checkpoint-sha256', $TrustCheckpointSha256,
            '--channel', $channel, '--release', $releaseDirectory, '--content-root', $BundleRoot, '--output', $trustOutput, '--artifact-mode', 'digest-only')
        if (Test-Path -LiteralPath $trustOutput -PathType Leaf) { $trustEvidence = [IO.File]::ReadAllText($trustOutput) }
    } finally {
        if (Test-Path -LiteralPath $trustOutput -PathType Leaf) { Remove-Item -LiteralPath $trustOutput -Force }
    }
    if ($trust.ExitCode -ne 0) { throw (New-CgError 'trust-verification-failed' ('cg-trust verify-composition exited ' + $trust.ExitCode + '.')) }

    $bom = Test-CgReleaseBom -Path $bomPath -ConfigurationSchemaPath (Join-Path $BundleRoot 'schemas/site-config-v1.schema.json')
    if (-not $bom.passed) { throw (New-CgError 'release-bom-invalid' ('Release BOM rejected: ' + ($bom.codes -join ','))) }
    $bomDocument = (ConvertFrom-CgStrictJson -Bytes ([IO.File]::ReadAllBytes($bomPath))).Value
    $minimum = [version](Get-CgMapValue $bomDocument @('compatibility', 'installer', 'powershellMinimum'))
    $running = [version]('{0}.{1}.{2}' -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor, [Math]::Max(0, $PSVersionTable.PSVersion.Patch))
    if ($running -lt $minimum) { throw (New-CgError 'powershell-version-unsupported' ('PowerShell ' + $running + ' is below the release minimum ' + $minimum + '.')) }

    $validation = & $validator -ConfigPath $SiteConfig
    if (-not $validation.passed) {
        $codes = @($validation.errors | ForEach-Object { [string]$_.code } | Select-Object -Unique)
        throw (New-CgError 'site-config-invalid' ('Site configuration rejected: ' + ($codes -join ',')))
    }
    $siteBytes = [IO.File]::ReadAllBytes($SiteConfig)
    $compositionSha = Get-CgSha256Hex -Bytes ([IO.File]::ReadAllBytes($manifestPath))
    $catalogPayloadSha = Get-CgJwsPayloadSha256 -CompactJws ([IO.File]::ReadAllText($catalogPath))
    return [pscustomobject]@{
        Channel = $channel
        SiteConfigSha256 = Get-CgSha256Hex -Bytes $siteBytes
        CompositionSha256 = $compositionSha
        CatalogPayloadSha256 = $catalogPayloadSha
        BomSha256 = $bom.sha256
        ProductVersion = [string](Get-CgMapValue $bomDocument @('product', 'version'))
        RequestSha256 = Get-CgRequestSha256 -SiteConfigBytes $siteBytes -CompositionSha256 $compositionSha -CatalogPayloadSha256 $catalogPayloadSha
        SecretRefModule = $secretRef
        TrustVerificationJson = $trustEvidence
    }
}

function Invoke-CgInstallerMode {
    <#
    .SYNOPSIS
        Dispatches one installer mode. Returns Mode, Terminal, ReasonCode, Message, ExitCode and details.
        Exit codes: 0 success, 2 refused/blocked before mutation, 3 failed during a phase, 4 not implemented.
    .PARAMETER TrustCheckpointSha256
        SHA-256 of the trust checkpoint from the independent owner channel (website / vault record). Required
        by cg-trust verify-composition for Plan and Install; never computed from the bundled file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$BundleRoot,
        [Parameter(Mandatory)][string]$SiteConfig,
        [string]$TrustCheckpointSha256,
        [string]$StateDirectory = '/var/lib/cloudgrange/state',
        [switch]$ResumeFromPrevious,
        [object[]]$Registry
    )
    $result = [ordered]@{ Mode = $Mode; Terminal = $null; ReasonCode = $null; Message = $null; ExitCode = 2; Details = $null }
    $modes = Get-CgModeDefinition
    if (-not $modes.Contains($Mode)) {
        $result.Terminal = 'refused'; $result.ReasonCode = 'mode-unknown'; $result.Message = 'Unknown mode.'
        return [pscustomobject]$result
    }
    if (-not $modes[$Mode].Implemented) {
        $result.Terminal = 'not-implemented'; $result.ReasonCode = 'mode-not-implemented'; $result.ExitCode = 4
        $result.Message = 'Mode ' + $Mode + ' is not implemented in this installer build; nothing was changed.'
        return [pscustomobject]$result
    }
    if (-not $Registry) { $Registry = New-CgPhaseRegistry }
    Assert-CgPhaseRegistry -Registry $Registry
    $blockedTerminal = if ($Mode -ceq 'Plan') { 'plan-blocked' } else { 'refused' }
    if (Test-CgPathInside -Path $StateDirectory -Root $BundleRoot) {
        $result.Terminal = $blockedTerminal; $result.ReasonCode = 'state-inside-bundle'
        $result.Message = 'The installer state directory must lie outside the release bundle; verify-tree refuses any extra file in the tree.'
        return [pscustomobject]$result
    }
    if ($TrustCheckpointSha256 -cnotmatch '^[0-9a-f]{64}$') {
        $result.Terminal = $blockedTerminal; $result.ReasonCode = 'trust-checkpoint-digest-missing'
        $result.Message = 'Supply -TrustCheckpointSha256 from the independent trust channel (lowercase hex SHA-256).'
        return [pscustomobject]$result
    }
    try {
        $inputs = Get-CgInstallerInput -BundleRoot $BundleRoot -SiteConfig $SiteConfig -TrustCheckpointSha256 $TrustCheckpointSha256
    } catch {
        $result.Terminal = $blockedTerminal; $result.ReasonCode = Get-CgErrorReason $_; $result.Message = $_.Exception.Message
        return [pscustomobject]$result
    }
    $unimplemented = @($Registry | Where-Object { $null -eq $_.Do -or $null -eq $_.Probe } | ForEach-Object Name)

    if ($Mode -ceq 'Plan') {
        $recovery = if (Test-Path -LiteralPath $StateDirectory -PathType Container) {
            Resolve-CgCheckpoint -StateDirectory $StateDirectory -NoMutation -ResumeFromPrevious:$ResumeFromPrevious
        } else {
            [pscustomobject]@{ Row = 'none'; Action = 'fresh'; Refused = $false; ReasonCode = $null; Message = $null; Checkpoint = $null }
        }
        $result.Details = [pscustomobject]@{
            Channel = $inputs.Channel; RequestSha256 = $inputs.RequestSha256; CompositionSha256 = $inputs.CompositionSha256
            BomSha256 = $inputs.BomSha256; CatalogPayloadSha256 = $inputs.CatalogPayloadSha256; ProductVersion = $inputs.ProductVersion
            RecoveryRow = $recovery.Row; RecoveryAction = $recovery.Action; Phases = @(Get-CgPhaseName); UnimplementedPhases = $unimplemented
        }
        $result.Terminal = 'plan-blocked'
        if ($recovery.Refused) { $result.ReasonCode = $recovery.ReasonCode; $result.Message = $recovery.Message }
        elseif ($null -ne $recovery.Checkpoint -and $recovery.Checkpoint['requestSha256'] -cne $inputs.RequestSha256) {
            $result.ReasonCode = 'request-mismatch'; $result.Message = 'The existing checkpoint belongs to a different request; existing installation preserved.'
        } elseif ($unimplemented.Count -gt 0) {
            $result.ReasonCode = 'phases-not-implemented'; $result.Message = 'Phases without an implementation: ' + ($unimplemented -join ',')
        } else {
            $result.Terminal = 'plan-ok'; $result.ExitCode = 0
        }
        return [pscustomobject]$result
    }

    # Install.
    if ($unimplemented.Count -gt 0) {
        $result.Terminal = 'refused'; $result.ReasonCode = 'phases-not-implemented'
        $result.Message = 'Install refused before any change: phases without an implementation: ' + ($unimplemented -join ',')
        return [pscustomobject]$result
    }
    Import-Module $inputs.SecretRefModule -Force -Scope Global
    $redactor = ConvertTo-CgSecretRefRedactor -SecretRefRedactor (New-SecretRefRedactor)
    $run = Invoke-CgInstallerRun -StateDirectory $StateDirectory -RequestSha256 $inputs.RequestSha256 -CompositionSha256 $inputs.CompositionSha256 `
        -BomSha256 $inputs.BomSha256 -CatalogPayloadSha256 $inputs.CatalogPayloadSha256 -ProductVersion $inputs.ProductVersion -Registry $Registry `
        -Redactor $redactor -ResumeFromPrevious:$ResumeFromPrevious
    $result.Terminal = $run.Terminal; $result.ReasonCode = $run.ReasonCode; $result.Message = $run.Message; $result.Details = $run
    $result.ExitCode = if ($run.Terminal -ceq 'accepted') { 0 } elseif ($run.Terminal -ceq 'refused') { 2 } else { 3 }
    return [pscustomobject]$result
}
