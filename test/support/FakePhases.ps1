#Requires -Version 7.4
<#
.SYNOPSIS
    Fake phase handlers for engine tests. Every call is appended to a log file so tests can prove
    which phases ran, were probed, or resumed from a sub-state.
.DESCRIPTION
    -CrashPhase makes that phase record -CrashSubState and exit the process with 137 on attempt 1.
    -FailPhase makes that phase throw reason -FailReason on attempt 1 (message may include -FailMessage).
    A file "<log>.drift.<phase>" makes that phase's probe fail until its Do runs again.
    -Outputs overrides the outputs returned by -OutputsPhase.
.NOTES
    TaskReference: AB#8129 AB#9015
#>
Set-StrictMode -Version Latest

function New-FakePhaseRegistry {
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [string]$CrashPhase,
        [string]$CrashSubState = 'mutation_requested',
        [string]$FailPhase,
        [string]$FailReason = 'readiness-timeout',
        [string]$FailMessage = 'bounded wait expired',
        [string]$OutputsPhase,
        [hashtable]$Outputs
    )
    $handlers = @{}
    foreach ($name in (Get-CgPhaseName)) {
        $handlers[$name] = @{
            Do = {
                param($ctx)
                $previousSubState = if ($null -ne $ctx.Previous -and $ctx.Previous.Contains('subState')) { $ctx.Previous['subState'] } else { '-' }
                Add-Content -LiteralPath $LogPath -Value ('do:' + $ctx.Phase + ':attempt=' + $ctx.Attempt + ':previousSubState=' + $previousSubState)
                $drift = $LogPath + '.drift.' + $ctx.Phase
                if (Test-Path -LiteralPath $drift) { Remove-Item -LiteralPath $drift }
                if ($ctx.Phase -ceq $CrashPhase -and $ctx.Attempt -eq 1) {
                    $ctx.SaveSubState($CrashSubState)
                    [Environment]::Exit(137)
                }
                if ($ctx.Phase -ceq $FailPhase -and $ctx.Attempt -eq 1) {
                    $exception = [InvalidOperationException]::new($FailReason + ': ' + $FailMessage)
                    $exception.Data['CgReason'] = $FailReason
                    throw $exception
                }
                if ($ctx.Phase -ceq $OutputsPhase) { return $Outputs }
                return @{ marker = ($ctx.Phase + '-done') }
            }.GetNewClosure()
            Probe = {
                param($ctx)
                Add-Content -LiteralPath $LogPath -Value ('probe:' + $ctx.Phase + ':attempt=' + $ctx.Attempt)
                return -not (Test-Path -LiteralPath ($LogPath + '.drift.' + $ctx.Phase))
            }.GetNewClosure()
        }
    }
    return New-CgPhaseRegistry -Handlers $handlers
}

function Get-FakePhaseLog {
    param([Parameter(Mandatory)][string]$LogPath)
    if (-not (Test-Path -LiteralPath $LogPath)) { return @() }
    return @(Get-Content -LiteralPath $LogPath)
}
