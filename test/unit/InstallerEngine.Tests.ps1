#Requires -Version 7.4
<#
.SYNOPSIS
    Phase registry, modes, request identity, lock and the resumable run engine.
.NOTES
    TaskReference: AB#8129 AB#9015
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../support/TestHelpers.ps1')
    Import-Module $ModuleManifest -Force
    . (Join-Path $SupportRoot 'FakePhases.ps1')
    $canary = 'canary-3f9a'

    function Invoke-FakeRun {
        param([Parameter(Mandatory)][string]$StateDirectory, [Parameter(Mandatory)][object[]]$Registry, [string]$RequestSha256 = ('a' * 64), [scriptblock]$Redactor, [switch]$ResumeFromPrevious)
        if (-not $Redactor) { $Redactor = { param([string]$Text) $Text } }
        return Invoke-CgInstallerRun -StateDirectory $StateDirectory -RequestSha256 $RequestSha256 -CompositionSha256 ('e' * 64) -BomSha256 ('b' * 64) -CatalogPayloadSha256 ('c' * 64) `
            -ProductVersion '0.1.0-m0.rc1' -Registry $Registry -Redactor $Redactor -ResumeFromPrevious:$ResumeFromPrevious
    }

    function New-RunFixture {
        $directory = New-TestDirectory -Prefix 'cg-run'
        return [pscustomobject]@{ State = Join-Path $directory 'state'; Log = Join-Path $directory 'phases.log'; Root = $directory }
    }

    function Get-EvidenceText {
        param([Parameter(Mandatory)][string]$StateDirectory)
        $root = Join-Path $StateDirectory 'evidence'
        if (-not (Test-Path -LiteralPath $root)) { return '' }
        return (@(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n")
    }
}

Describe 'Phase registry and modes' {
    It 'lists the 13 design phases in order' {
        (Get-CgPhaseName) -join ',' | Should -BeExactly 'preflight,retrieve,runtime,storage,postgres,vault,identity,migrate,api,portal,gateway,module,handoff'
    }

    It 'marks only preflight as always re-run and leaves every phase unimplemented by default' {
        $registry = New-CgPhaseRegistry
        @($registry | Where-Object AlwaysRerun | ForEach-Object Name) | Should -Be @('preflight')
        @($registry | Where-Object { $null -ne $_.Do -or $null -ne $_.Probe }).Count | Should -Be 0
    }

    It 'rejects handlers for unknown phases' {
        { New-CgPhaseRegistry -Handlers @{ deploy = @{} } } | Should -Throw '*phase-unknown*'
    }

    It 'rejects a registry that is not in design order' {
        $fixture = New-RunFixture
        $registry = @(New-FakePhaseRegistry -LogPath $fixture.Log)
        [array]::Reverse($registry)
        { Invoke-FakeRun -StateDirectory $fixture.State -Registry $registry } | Should -Throw '*phase-registry-invalid*'
    }

    It 'defines the design modes, their terminal states and which are implemented' {
        $modes = Get-CgModeDefinition
        @($modes.Keys) | Should -Be @('Plan', 'Install', 'Verify', 'Update', 'Rollback', 'Restore', 'Uninstall', 'Unseal')
        @($modes.Keys | Where-Object { $modes[$_].Implemented }) | Should -Be @('Plan', 'Install')
        $modes['Plan'].Mutates | Should -BeFalse
        $modes['Plan'].TerminalStates | Should -Be @('plan-ok', 'plan-blocked')
        $modes['Install'].TerminalStates | Should -Be @('accepted', 'failed:<phase>')
        $modes['Verify'].TerminalStates | Should -Be @('verified', 'drift:<phase>')
        $modes['Rollback'].TerminalStates | Should -Contain 'rollback-requires-restore'
        $modes['Restore'].TerminalStates | Should -Be @('restored-read-only', 'accepted', 'blocked:<reason>')
        $modes['Uninstall'].TerminalStates | Should -Be @('uninstalled:<retention>')
    }
}

Describe 'Request identity' {
    It 'is sha256(site-config bytes || raw composition digest || raw catalog payload digest)' {
        $site = [Text.Encoding]::UTF8.GetBytes('{"kind":"CloudGrangeSiteConfig"}')
        $composition = '1' * 64
        $catalog = '2' * 64
        $expected = Get-TestBytesSha256 ([byte[]]($site + [Convert]::FromHexString($composition) + [Convert]::FromHexString($catalog)))
        Get-CgRequestSha256 -SiteConfigBytes $site -CompositionSha256 $composition -CatalogPayloadSha256 $catalog | Should -Be $expected
    }

    It 'changes when any input changes' {
        $site = [Text.Encoding]::UTF8.GetBytes('{}')
        $base = Get-CgRequestSha256 -SiteConfigBytes $site -CompositionSha256 ('1' * 64) -CatalogPayloadSha256 ('2' * 64)
        Get-CgRequestSha256 -SiteConfigBytes ([Text.Encoding]::UTF8.GetBytes('{ }')) -CompositionSha256 ('1' * 64) -CatalogPayloadSha256 ('2' * 64) | Should -Not -Be $base
        Get-CgRequestSha256 -SiteConfigBytes $site -CompositionSha256 ('3' * 64) -CatalogPayloadSha256 ('2' * 64) | Should -Not -Be $base
        Get-CgRequestSha256 -SiteConfigBytes $site -CompositionSha256 ('1' * 64) -CatalogPayloadSha256 ('4' * 64) | Should -Not -Be $base
    }
}

Describe 'Install lock' {
    It 'refuses a second holder and releases cleanly' {
        $directory = New-TestDirectory -Prefix 'cg-lock'
        $lock = Enter-CgInstallLock -StateDirectory $directory
        try {
            [IO.File]::ReadAllText((Join-Path $directory 'install.owner')) | Should -Be ([string]$PID)
            { Enter-CgInstallLock -StateDirectory $directory } | Should -Throw ('*installer-already-running*PID ' + $PID + '*')
        } finally {
            Exit-CgInstallLock -Lock $lock
        }
        Test-Path -LiteralPath (Join-Path $directory 'install.owner') | Should -BeFalse
        $again = Enter-CgInstallLock -StateDirectory $directory
        Exit-CgInstallLock -Lock $again
    }

    It 'refuses an Install run while another process holds install.lock' {
        $fixture = New-RunFixture
        $null = New-Item -ItemType Directory -Path $fixture.State
        $signals = New-TestDirectory -Prefix 'cg-signal'
        $holder = Start-Process -FilePath (Get-PwshPath) -PassThru -NoNewWindow -ArgumentList @('-NoProfile', '-NonInteractive', '-File', (Join-Path $SupportRoot 'Invoke-LockHolderChild.ps1'),
            '-ModuleManifest', $ModuleManifest, '-StateDirectory', $fixture.State, '-SignalDirectory', $signals)
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(60)
            while (-not (Test-Path -LiteralPath (Join-Path $signals 'ready')) -and [DateTime]::UtcNow -lt $deadline) { [Threading.Thread]::Sleep(100) }
            Test-Path -LiteralPath (Join-Path $signals 'ready') | Should -BeTrue
            $result = Invoke-FakeRun -StateDirectory $fixture.State -Registry (New-FakePhaseRegistry -LogPath $fixture.Log)
            $result.Terminal | Should -Be 'refused'
            $result.ReasonCode | Should -Be 'installer-already-running'
            $result.Message | Should -Match ('PID ' + $holder.Id)
            Test-Path -LiteralPath (Join-Path $fixture.State 'checkpoint.json') | Should -BeFalse
            Get-FakePhaseLog $fixture.Log | Should -BeNullOrEmpty
        } finally {
            Set-Content -LiteralPath (Join-Path $signals 'release') -Value 'release'
            $null = $holder.WaitForExit(60000)
        }
    }
}

Describe 'Invoke-CgInstallerRun' {
    It 'runs all 13 phases to accepted with a hash-chained checkpoint per transition' {
        $fixture = New-RunFixture
        $result = Invoke-FakeRun -StateDirectory $fixture.State -Registry (New-FakePhaseRegistry -LogPath $fixture.Log)
        $result.Terminal | Should -Be 'accepted'
        $result.Attempt | Should -Be 1
        $result.Recovery.Row | Should -Be 'none'
        @($result.PhaseActions | Where-Object Action -EQ 'ran').Count | Should -Be 13
        $checkpoint = Get-CgCheckpoint -StateDirectory $fixture.State
        $checkpoint['terminal'] | Should -Be 'accepted'
        $checkpoint['sequence'] | Should -Be 26
        $checkpoint['installId'] | Should -Be $result.InstallId
        foreach ($name in (Get-CgPhaseName)) {
            $checkpoint['phases'][$name]['state'] | Should -Be 'completed'
            $checkpoint['phases'][$name]['outputs']['marker'] | Should -Be ($name + '-done')
            $checkpoint['phases'][$name]['outputsSha256'] | Should -Match '^[0-9a-f]{64}$'
        }
        $checkpoint['previousCheckpointSha256'] | Should -Be (Get-TestFileSha256 (Join-Path $fixture.State 'checkpoint.prev'))
    }

    It 'returns already-accepted on a later run without running or rewriting anything' {
        $fixture = New-RunFixture
        $null = Invoke-FakeRun -StateDirectory $fixture.State -Registry (New-FakePhaseRegistry -LogPath $fixture.Log)
        $lines = @(Get-FakePhaseLog $fixture.Log).Count
        $sequence = (Get-CgCheckpoint -StateDirectory $fixture.State)['sequence']
        $result = Invoke-FakeRun -StateDirectory $fixture.State -Registry (New-FakePhaseRegistry -LogPath $fixture.Log)
        $result.Terminal | Should -Be 'accepted'
        $result.ReasonCode | Should -Be 'already-accepted'
        @(Get-FakePhaseLog $fixture.Log).Count | Should -Be $lines
        (Get-CgCheckpoint -StateDirectory $fixture.State)['sequence'] | Should -Be $sequence
    }

    It 'fails closed on an unimplemented phase without starting it or writing a checkpoint' {
        $fixture = New-RunFixture
        $result = Invoke-FakeRun -StateDirectory $fixture.State -Registry (New-CgPhaseRegistry)
        $result.Terminal | Should -Be 'failed:preflight'
        $result.ReasonCode | Should -Be 'phase-not-implemented'
        Test-Path -LiteralPath (Join-Path $fixture.State 'checkpoint.json') | Should -BeFalse
    }

    It 'records failed:storage with phase-result evidence, then resumes re-running only the failed phase' {
        $fixture = New-RunFixture
        $first = Invoke-FakeRun -StateDirectory $fixture.State -Registry (New-FakePhaseRegistry -LogPath $fixture.Log -FailPhase 'storage')
        $first.Terminal | Should -Be 'failed:storage'
        $first.ReasonCode | Should -Be 'readiness-timeout'
        $checkpoint = Get-CgCheckpoint -StateDirectory $fixture.State
        $checkpoint['phase'] | Should -Be 'storage'
        $checkpoint['phaseState'] | Should -Be 'failed'
        $checkpoint['terminal'] | Should -Be 'failed:storage'
        $checkpoint['phases']['storage']['reasonCode'] | Should -Be 'readiness-timeout'
        $evidencePath = Join-Path $fixture.State ('evidence/' + $first.InstallId + '/1/storage/phase-result.json')
        Test-Path -LiteralPath $evidencePath | Should -BeTrue
        $evidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
        $evidence.reasonCode | Should -Be 'readiness-timeout'
        $evidence.attempt | Should -Be 1

        $second = Invoke-FakeRun -StateDirectory $fixture.State -Registry (New-FakePhaseRegistry -LogPath $fixture.Log -FailPhase 'storage')
        $second.Terminal | Should -Be 'accepted'
        $second.Attempt | Should -Be 2
        $second.InstallId | Should -Be $first.InstallId
        $log = Get-FakePhaseLog $fixture.Log
        $log | Should -Contain 'do:preflight:attempt=2:previousSubState=-'
        $log | Should -Contain 'probe:retrieve:attempt=2'
        $log | Should -Not -Contain 'do:retrieve:attempt=2:previousSubState=-'
        $log | Should -Contain 'do:storage:attempt=2:previousSubState=-'
        @($second.PhaseActions | Where-Object { $_.Phase -eq 'runtime' }).Action | Should -Be 'probed'
    }

    It 'resumes after the process is killed mid-phase, re-entering that phase with its recorded sub-state' {
        $fixture = New-RunFixture
        $child = Invoke-ChildPwsh -ScriptPath (Join-Path $SupportRoot 'Invoke-EngineCrashChild.ps1') -Arguments @(
            '-ModuleManifest', $ModuleManifest, '-StateDirectory', $fixture.State, '-LogPath', $fixture.Log, '-CrashPhase', 'runtime', '-CrashSubState', 'runtime_start_requested')
        $child.ExitCode | Should -Be 137 -Because $child.Output
        $crashed = Get-CgCheckpoint -StateDirectory $fixture.State
        $crashed['phase'] | Should -Be 'runtime'
        $crashed['phaseState'] | Should -Be 'started'
        $crashed['subState'] | Should -Be 'runtime_start_requested'
        $crashed['phases']['runtime']['subState'] | Should -Be 'runtime_start_requested'

        $result = Invoke-FakeRun -StateDirectory $fixture.State -Registry (New-FakePhaseRegistry -LogPath $fixture.Log)
        $result.Terminal | Should -Be 'accepted'
        $result.Attempt | Should -Be 2
        $result.InstallId | Should -Be $crashed['installId']
        $log = Get-FakePhaseLog $fixture.Log
        $log | Should -Contain 'do:runtime:attempt=2:previousSubState=runtime_start_requested'
        $log | Should -Contain 'do:preflight:attempt=2:previousSubState=-'
        $log | Should -Not -Contain 'do:retrieve:attempt=2:previousSubState=-'
        @($log | Where-Object { $_ -like 'do:*:attempt=1:*' }).Count | Should -Be 3
    }

    It 're-runs a completed phase whose probe fails on resume' {
        $fixture = New-RunFixture
        $null = Invoke-FakeRun -StateDirectory $fixture.State -Registry (New-FakePhaseRegistry -LogPath $fixture.Log -FailPhase 'api')
        Set-Content -LiteralPath ($fixture.Log + '.drift.storage') -Value 'drift'
        $result = Invoke-FakeRun -StateDirectory $fixture.State -Registry (New-FakePhaseRegistry -LogPath $fixture.Log -FailPhase 'api')
        $result.Terminal | Should -Be 'accepted'
        @($result.PhaseActions | Where-Object Phase -EQ 'storage' | ForEach-Object Action) | Should -Be @('probe-failed', 'ran')
        @($result.PhaseActions | Where-Object Phase -EQ 'postgres' | ForEach-Object Action) | Should -Be @('probed')
    }

    It 'refuses a different request and preserves the existing checkpoint' {
        $fixture = New-RunFixture
        $null = Invoke-FakeRun -StateDirectory $fixture.State -Registry (New-FakePhaseRegistry -LogPath $fixture.Log -FailPhase 'vault')
        $before = Get-StateSnapshot $fixture.State
        $result = Invoke-FakeRun -StateDirectory $fixture.State -Registry (New-FakePhaseRegistry -LogPath $fixture.Log) -RequestSha256 ('d' * 64)
        $result.Terminal | Should -Be 'refused'
        $result.ReasonCode | Should -Be 'request-mismatch'
        Get-StateSnapshot $fixture.State | Should -Be $before
    }

    It 'refuses a corrupt checkpoint, then promotes checkpoint.prev only with -ResumeFromPrevious' {
        $fixture = New-RunFixture
        $null = Invoke-FakeRun -StateDirectory $fixture.State -Registry (New-FakePhaseRegistry -LogPath $fixture.Log -FailPhase 'storage')
        [IO.File]::WriteAllText((Join-Path $fixture.State 'checkpoint.json'), 'corrupt')
        $lines = @(Get-FakePhaseLog $fixture.Log).Count

        $refused = Invoke-FakeRun -StateDirectory $fixture.State -Registry (New-FakePhaseRegistry -LogPath $fixture.Log)
        $refused.Terminal | Should -Be 'refused'
        $refused.ReasonCode | Should -Be 'checkpoint-corrupt'
        @(Get-FakePhaseLog $fixture.Log).Count | Should -Be $lines

        $promoted = Invoke-FakeRun -StateDirectory $fixture.State -Registry (New-FakePhaseRegistry -LogPath $fixture.Log) -ResumeFromPrevious
        $promoted.Recovery.Action | Should -Be 'promote-previous'
        $promoted.Terminal | Should -Be 'accepted'
        $recoveryEvidence = Join-Path $fixture.State ('evidence/' + $promoted.InstallId + '/' + $promoted.Attempt + '/checkpoint/recovery.json')
        (Get-Content -LiteralPath $recoveryEvidence -Raw | ConvertFrom-Json).events | Should -Contain 'checkpoint-promoted-from-prev'
    }

    It 'rejects secret material in phase outputs and keeps it out of checkpoints and evidence' {
        $fixture = New-RunFixture
        $redactor = { param([string]$Text) $Text.Replace('canary-3f9a', '[REDACTED]') }
        $registry = New-FakePhaseRegistry -LogPath $fixture.Log -OutputsPhase 'retrieve' -Outputs @{ token = $canary }
        $result = Invoke-FakeRun -StateDirectory $fixture.State -Registry $registry -Redactor $redactor
        $result.Terminal | Should -Be 'failed:retrieve'
        $result.ReasonCode | Should -Be 'secret-in-checkpoint'
        [IO.File]::ReadAllText((Join-Path $fixture.State 'checkpoint.json')) | Should -Not -Match $canary
        [IO.File]::ReadAllText((Join-Path $fixture.State 'checkpoint.prev')) | Should -Not -Match $canary
        Get-EvidenceText $fixture.State | Should -Not -Match $canary
    }

    It 'redacts secret text from failure messages before writing evidence' {
        $fixture = New-RunFixture
        $redactor = { param([string]$Text) $Text.Replace('canary-3f9a', '[REDACTED]') }
        $registry = New-FakePhaseRegistry -LogPath $fixture.Log -FailPhase 'retrieve' -FailMessage ('download failed with ' + $canary)
        $result = Invoke-FakeRun -StateDirectory $fixture.State -Registry $registry -Redactor $redactor
        $result.Terminal | Should -Be 'failed:retrieve'
        $result.Message | Should -Not -Match $canary
        $text = Get-EvidenceText $fixture.State
        $text | Should -Not -Match $canary
        $text | Should -Match '\[REDACTED\]'
    }

    It 'rejects outputs that are not strings, integers or booleans' {
        $fixture = New-RunFixture
        $registry = New-FakePhaseRegistry -LogPath $fixture.Log -OutputsPhase 'preflight' -Outputs @{ nested = @{ a = 1 } }
        $result = Invoke-FakeRun -StateDirectory $fixture.State -Registry $registry
        $result.Terminal | Should -Be 'failed:preflight'
        $result.ReasonCode | Should -Be 'phase-outputs-invalid'
    }
}
