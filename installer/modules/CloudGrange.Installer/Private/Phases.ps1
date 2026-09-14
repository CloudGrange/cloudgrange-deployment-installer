#Requires -Version 7.4
<#
.SYNOPSIS
    Phase registry, mode table and the resumable run engine (docs/product-installer-design.md §3.3-§3.4).
.DESCRIPTION
    The 13 phases run in a fixed order. Each registered phase provides Pre (optional), Do and Probe
    script blocks that receive a context object. Engine rules:
      - install.lock is taken first; the §3.2 recovery table runs under the lock before phase work.
      - A checkpoint whose requestSha256 differs from the current inputs is refused (request-mismatch).
      - Completed phases are re-probed on resume; a passing probe skips the phase, a failing probe
        re-runs it (Do is idempotent by contract). preflight always re-runs.
      - Every phase writes a started checkpoint before mutation and a completed checkpoint with
        outputs (identities, digests, paths; never secrets) after its probe passes. Phases may record
        sub-states through $context.SaveSubState('name').
      - A failure writes a failed checkpoint (terminal failed:<phase>) and redacted phase-result.json.
      - Phases without Do/Probe fail closed with phase-not-implemented and are not started.
    This work package registers no phase implementations; WP-06 onwards add them.
.NOTES
    TaskReference: AB#8129 AB#9015
#>
Set-StrictMode -Version Latest

$script:CgPhaseNames = @('preflight', 'retrieve', 'runtime', 'storage', 'postgres', 'vault', 'identity', 'migrate', 'api', 'portal', 'gateway', 'module', 'handoff')

function Get-CgPhaseName {
    return , @($script:CgPhaseNames)
}

function Get-CgModeDefinition {
    <# Modes and terminal states from design §3.3; Unseal is the post-reboot unseal entry named in §3.4 phase 6. #>
    $definition = [ordered]@{}
    $definition['Plan'] = [pscustomobject]@{ Mutates = $false; Implemented = $true; TerminalStates = @('plan-ok', 'plan-blocked') }
    $definition['Install'] = [pscustomobject]@{ Mutates = $true; Implemented = $true; TerminalStates = @('accepted', 'failed:<phase>') }
    $definition['Verify'] = [pscustomobject]@{ Mutates = $false; Implemented = $false; TerminalStates = @('verified', 'drift:<phase>') }
    $definition['Update'] = [pscustomobject]@{ Mutates = $true; Implemented = $false; TerminalStates = @('accepted', 'failed:<phase>') }
    $definition['Rollback'] = [pscustomobject]@{ Mutates = $true; Implemented = $false; TerminalStates = @('accepted', 'rollback-requires-restore') }
    $definition['Restore'] = [pscustomobject]@{ Mutates = $true; Implemented = $false; TerminalStates = @('restored-read-only', 'accepted', 'blocked:<reason>') }
    $definition['Uninstall'] = [pscustomobject]@{ Mutates = $true; Implemented = $false; TerminalStates = @('uninstalled:<retention>') }
    $definition['Unseal'] = [pscustomobject]@{ Mutates = $true; Implemented = $false; TerminalStates = @('unsealed') }
    return $definition
}

function New-CgPhaseRegistry {
    <#
    .SYNOPSIS
        Builds the ordered 13-phase registry. -Handlers maps phase name to @{ Pre; Do; Probe }.
    #>
    param([hashtable]$Handlers = @{})
    foreach ($key in $Handlers.Keys) {
        if ([Array]::IndexOf($script:CgPhaseNames, [string]$key) -lt 0) { throw (New-CgError 'phase-unknown' ('Unknown phase ' + $key + '.')) }
    }
    $order = 0
    $registry = foreach ($name in $script:CgPhaseNames) {
        $order++
        $handler = if ($Handlers.ContainsKey($name)) { $Handlers[$name] } else { @{} }
        [pscustomobject]@{
            Name = $name
            Order = $order
            AlwaysRerun = ($name -ceq 'preflight')
            Pre = if ($handler.Contains('Pre')) { [scriptblock]$handler['Pre'] } else { $null }
            Do = if ($handler.Contains('Do')) { [scriptblock]$handler['Do'] } else { $null }
            Probe = if ($handler.Contains('Probe')) { [scriptblock]$handler['Probe'] } else { $null }
        }
    }
    return , @($registry)
}

function Assert-CgPhaseRegistry {
    param([Parameter(Mandatory)][object[]]$Registry)
    $names = @($Registry | ForEach-Object { [string]$_.Name })
    if (($names -join ',') -cne ($script:CgPhaseNames -join ',')) {
        throw (New-CgError 'phase-registry-invalid' 'The phase registry must list the 13 design phases in order.')
    }
}

function Test-CgTrue {
    param([AllowNull()]$Value)
    return ($Value -is [bool] -and $Value)
}

function ConvertTo-CgPhaseOutput {
    param([AllowNull()]$Outputs, [Parameter(Mandatory)][scriptblock]$Redactor)
    $result = [ordered]@{}
    if ($null -eq $Outputs) { return $result }
    if ($Outputs -isnot [Collections.IDictionary]) { throw (New-CgError 'phase-outputs-invalid' 'Phase Do must return one dictionary of outputs or nothing.') }
    if ($Outputs.Count -gt 64) { throw (New-CgError 'phase-outputs-invalid' 'Too many phase outputs.') }
    foreach ($key in $Outputs.Keys) {
        if ([string]$key -cnotmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$') { throw (New-CgError 'phase-outputs-invalid' 'Phase output names must be identifiers.') }
        $value = $Outputs[$key]
        if ($value -is [bool]) {
            $result[[string]$key] = $value
        } elseif ($value -is [int] -or $value -is [long]) {
            $result[[string]$key] = [long]$value
        } elseif ($value -is [string]) {
            if ($value.Length -gt 512) { throw (New-CgError 'phase-outputs-invalid' 'Phase output values are limited to 512 characters.') }
            if ((Invoke-CgRedactor -Redactor $Redactor -Text $value) -cne $value) {
                throw (New-CgError 'secret-in-checkpoint' ('Phase output ' + $key + ' contains secret material; checkpoints carry identities and digests only.'))
            }
            $result[[string]$key] = $value
        } else {
            throw (New-CgError 'phase-outputs-invalid' 'Phase output values must be strings, integers or booleans.')
        }
    }
    return $result
}

function Save-CgRunCheckpoint {
    param(
        [Parameter(Mandatory)][hashtable]$Run,
        [Parameter(Mandatory)][string]$PhaseName,
        [Parameter(Mandatory)][ValidateSet('started', 'completed', 'failed')][string]$PhaseState,
        [string]$SubState,
        [string]$Terminal
    )
    if ($SubState) {
        if ($SubState -cnotmatch '^[a-z][a-z0-9_]{0,63}$') { throw (New-CgError 'substate-invalid' 'Sub-state names are lowercase identifiers.') }
        $Run.Phases[$PhaseName]['subState'] = $SubState
    }
    $state = [ordered]@{
        installId = $Run.InstallId; mode = $Run.Mode; requestSha256 = $Run.RequestSha256; compositionSha256 = $Run.CompositionSha256; bomSha256 = $Run.BomSha256
        catalogPayloadSha256 = $Run.CatalogPayloadSha256; productVersion = $Run.ProductVersion; attempt = $Run.Attempt
        phase = $PhaseName; phaseState = $PhaseState; subState = $SubState; terminal = $Terminal; phases = $Run.Phases
    }
    $written = Write-CgCheckpoint -StateDirectory $Run.StateDirectory -State $state
    $Run.Sequence = $written.Sequence
    return $written
}

function New-CgPhaseContext {
    param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][string]$PhaseName, [AllowNull()]$Previous, [hashtable]$PhaseInput)
    $context = [pscustomobject]@{
        InstallId = $Run.InstallId; Attempt = $Run.Attempt; Mode = $Run.Mode; StateDirectory = $Run.StateDirectory
        Phase = $PhaseName; Previous = $Previous; Input = $PhaseInput; Run = $Run
    }
    Add-Member -InputObject $context -MemberType ScriptMethod -Name SaveSubState -Value {
        param([string]$SubState)
        $null = Save-CgRunCheckpoint -Run $this.Run -PhaseName $this.Phase -PhaseState started -SubState $SubState
    }
    return $context
}

function Invoke-CgInstallerRun {
    <#
    .SYNOPSIS
        Runs (or resumes) the Install phases against a state directory. Returns an outcome object with
        Terminal (accepted | failed:<phase> | refused), ReasonCode, InstallId, Attempt, Recovery and
        PhaseActions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateDirectory,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$RequestSha256,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$CompositionSha256,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$BomSha256,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$CatalogPayloadSha256,
        [Parameter(Mandatory)][ValidatePattern('^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9a-z]+(\.[0-9a-z]+)*)?$')][string]$ProductVersion,
        [Parameter(Mandatory)][object[]]$Registry,
        [Parameter(Mandatory)][scriptblock]$Redactor,
        [ValidateSet('Install')][string]$Mode = 'Install',
        [switch]$ResumeFromPrevious,
        [hashtable]$PhaseInput = @{}
    )
    Assert-CgPhaseRegistry -Registry $Registry
    if (-not (Test-Path -LiteralPath $StateDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $StateDirectory -Force
        Set-CgOwnerOnlyMode -Path $StateDirectory -Mode Directory0700
    }
    $outcome = [ordered]@{
        Mode = $Mode; Terminal = $null; ReasonCode = $null; Message = $null; InstallId = $null; Attempt = $null
        Recovery = $null; PhaseActions = [Collections.Generic.List[object]]::new()
    }
    try {
        $lock = Enter-CgInstallLock -StateDirectory $StateDirectory
    } catch {
        $outcome.Terminal = 'refused'; $outcome.ReasonCode = Get-CgErrorReason $_; $outcome.Message = $_.Exception.Message
        return [pscustomobject]$outcome
    }
    try {
        Invoke-CgInstallerRunCore
    } finally {
        Exit-CgInstallLock -Lock $lock
    }
    return [pscustomobject]$outcome
}

function Invoke-CgInstallerRunCore {
    # Runs in the caller's (Invoke-CgInstallerRun) dynamic scope and fills $outcome.
    $recovery = Resolve-CgCheckpoint -StateDirectory $StateDirectory -ResumeFromPrevious:$ResumeFromPrevious
    $outcome.Recovery = [pscustomobject]@{ Row = $recovery.Row; Action = $recovery.Action; Events = @($recovery.Events); ReprobeCompleted = $recovery.ReprobeCompleted }
    if ($recovery.Refused) {
        $outcome.Terminal = 'refused'; $outcome.ReasonCode = $recovery.ReasonCode; $outcome.Message = $recovery.Message
        return
    }
    $existing = $recovery.Checkpoint
    $phases = [ordered]@{}
    if ($null -ne $existing) {
        if ($existing['requestSha256'] -cne $RequestSha256) {
            $outcome.Terminal = 'refused'; $outcome.ReasonCode = 'request-mismatch'
            $outcome.Message = 'The checkpoint belongs to a different site configuration or composition; existing installation preserved.'
            return
        }
        if ($existing['mode'] -cne $Mode) {
            $outcome.Terminal = 'refused'; $outcome.ReasonCode = 'checkpoint-mode-mismatch'
            $outcome.Message = 'The checkpoint was written by mode ' + $existing['mode'] + '; existing installation preserved.'
            return
        }
        $installId = [string]$existing['installId']
        $outcome.InstallId = $installId
        if ($existing.Contains('terminal') -and $existing['terminal'] -ceq 'accepted') {
            $outcome.Terminal = 'accepted'; $outcome.ReasonCode = 'already-accepted'; $outcome.Attempt = [int]$existing['attempt']
            return
        }
        $attempt = [int]$existing['attempt'] + 1
        foreach ($name in $script:CgPhaseNames) {
            if ($existing['phases'].Contains($name)) { $phases[$name] = $existing['phases'][$name] }
        }
    } else {
        $installId = [guid]::NewGuid().ToString('D')
        $attempt = 1
    }
    $outcome.InstallId = $installId
    $outcome.Attempt = $attempt
    $run = @{
        StateDirectory = $StateDirectory; InstallId = $installId; Mode = $Mode; RequestSha256 = $RequestSha256; CompositionSha256 = $CompositionSha256; BomSha256 = $BomSha256
        CatalogPayloadSha256 = $CatalogPayloadSha256; ProductVersion = $ProductVersion; Attempt = $attempt; Phases = $phases; Sequence = 0
    }
    if ($recovery.Events.Count -gt 0) {
        $null = Write-CgEvidence -StateDirectory $StateDirectory -InstallId $installId -Attempt $attempt -Phase 'checkpoint' -Name 'recovery.json' -Redactor $Redactor `
            -Content ([ordered]@{ row = $recovery.Row; action = $recovery.Action; events = @($recovery.Events); reprobeCompleted = $recovery.ReprobeCompleted })
    }

    foreach ($phase in $Registry) {
        $name = $phase.Name
        $previous = if ($phases.Contains($name)) { $phases[$name] } else { $null }
        if ($null -ne $previous -and $previous['state'] -ceq 'completed' -and -not $phase.AlwaysRerun) {
            $probeOk = $false
            if ($null -ne $phase.Probe) {
                try { $probeOk = Test-CgTrue (& $phase.Probe (New-CgPhaseContext -Run $run -PhaseName $name -Previous $previous -PhaseInput $PhaseInput)) } catch { $probeOk = $false }
            }
            if ($probeOk) {
                $outcome.PhaseActions.Add([pscustomobject]@{ Phase = $name; Action = 'probed' })
                continue
            }
            $outcome.PhaseActions.Add([pscustomobject]@{ Phase = $name; Action = 'probe-failed' })
        }
        if ($null -eq $phase.Do -or $null -eq $phase.Probe) {
            $outcome.Terminal = 'failed:' + $name; $outcome.ReasonCode = 'phase-not-implemented'
            $outcome.Message = 'Phase ' + $name + ' has no implementation in this installer build; nothing was started for it.'
            return
        }
        $entry = [ordered]@{ state = 'started'; startedUtc = Get-CgUtcNow }
        if ($null -ne $previous -and $previous.Contains('subState')) { $entry['subState'] = $previous['subState'] }
        $phases[$name] = $entry
        $null = Save-CgRunCheckpoint -Run $run -PhaseName $name -PhaseState started
        $context = New-CgPhaseContext -Run $run -PhaseName $name -Previous $previous -PhaseInput $PhaseInput
        try {
            if ($null -ne $phase.Pre -and -not (Test-CgTrue (& $phase.Pre $context))) {
                throw (New-CgError 'precondition-failed' ('Phase ' + $name + ' preconditions are not met.'))
            }
            $raw = & $phase.Do $context
            $outputs = ConvertTo-CgPhaseOutput -Outputs $raw -Redactor $Redactor
            if (-not (Test-CgTrue (& $phase.Probe $context))) {
                throw (New-CgError 'postcondition-failed' ('Phase ' + $name + ' postcondition probe failed.'))
            }
            $entry = $phases[$name]
            $entry['state'] = 'completed'
            $entry['completedUtc'] = Get-CgUtcNow
            $entry['outputsSha256'] = Get-CgSha256Hex -Bytes (ConvertTo-CgJsonBytes -InputObject $outputs -Compress)
            $entry['outputs'] = $outputs
            $terminal = if ($name -ceq 'handoff') { 'accepted' } else { $null }
            $null = Save-CgRunCheckpoint -Run $run -PhaseName $name -PhaseState completed -Terminal $terminal
            $outcome.PhaseActions.Add([pscustomobject]@{ Phase = $name; Action = 'ran' })
        } catch {
            $reason = Get-CgErrorReason $_
            if ($reason -cnotmatch '^[a-z][a-z0-9-]{0,63}$') { $reason = 'unexpected-error' }
            $message = Invoke-CgRedactor -Redactor $Redactor -Text $_.Exception.Message
            $entry = $phases[$name]
            $entry['state'] = 'failed'
            $entry['failedUtc'] = Get-CgUtcNow
            $entry['reasonCode'] = $reason
            $null = Save-CgRunCheckpoint -Run $run -PhaseName $name -PhaseState failed -Terminal ('failed:' + $name)
            $null = Write-CgEvidence -StateDirectory $StateDirectory -InstallId $installId -Attempt $attempt -Phase $name -Name 'phase-result.json' -Redactor $Redactor `
                -Content ([ordered]@{
                    phase = $name; subState = if ($entry.Contains('subState')) { $entry['subState'] } else { $null }; reasonCode = $reason; attempt = $attempt
                    startedUtc = $entry['startedUtc']; failedUtc = $entry['failedUtc']; message = $message
                    requestSha256 = $RequestSha256; bomSha256 = $BomSha256; catalogPayloadSha256 = $CatalogPayloadSha256
                })
            $outcome.Terminal = 'failed:' + $name; $outcome.ReasonCode = $reason; $outcome.Message = $message
            $outcome.PhaseActions.Add([pscustomobject]@{ Phase = $name; Action = 'failed' })
            return
        }
    }
    $outcome.Terminal = 'accepted'
}
