#Requires -Version 7.4
<#
.SYNOPSIS
    Crash cuts: a child process is killed (exit 137) at every checkpoint write step; recovery must
    resume (never checkpoint-corrupt) and the chain must keep extending.
.NOTES
    TaskReference: AB#8129 AB#9015
#>

BeforeDiscovery {
    $laterWriteCuts = @(
        @{ Point = 'checkpoint-step2-partial'; Row = 'json-tmp-invalid'; Sequence = 2 }
        @{ Point = 'checkpoint-step2-fsynced'; Row = 'json-tmp-valid'; Sequence = 3 }
        @{ Point = 'checkpoint-step3-prev-unlinked'; Row = 'json-tmp-valid'; Sequence = 3 }
        @{ Point = 'checkpoint-step3-linked'; Row = 'json-tmp-valid'; Sequence = 3 }
        @{ Point = 'checkpoint-step4-renamed'; Row = 'json-prev'; Sequence = 3 }
        @{ Point = 'checkpoint-step5-synced'; Row = 'json-prev'; Sequence = 3 }
    )
    $firstWriteCuts = @(
        @{ Point = 'checkpoint-step2-partial'; Row = 'tmp-only-first-write'; Sequence = 0 }
        @{ Point = 'checkpoint-step2-fsynced'; Row = 'tmp-only-first-write'; Sequence = 1 }
        @{ Point = 'checkpoint-step4-renamed'; Row = 'json-only-first'; Sequence = 1 }
        @{ Point = 'checkpoint-step5-synced'; Row = 'json-only-first'; Sequence = 1 }
    )
}

BeforeAll {
    . (Join-Path $PSScriptRoot '../support/TestHelpers.ps1')
    Import-Module $ModuleManifest -Force
    $crashChild = Join-Path $SupportRoot 'Invoke-CheckpointCrashChild.ps1'

    function Invoke-CrashAt {
        param([string]$Directory, [string]$InstallId, [string]$Point)
        $child = Invoke-ChildPwsh -ScriptPath $crashChild -Arguments @('-ModuleManifest', $ModuleManifest, '-StateDirectory', $Directory, '-InstallId', $InstallId, '-FaultPoint', $Point)
        $child.ExitCode | Should -Be 137 -Because ('the child must die at ' + $Point + '. Output: ' + $child.Output)
    }
}

Describe 'Checkpoint crash cuts (process killed at each write step)' {
    It 'third write killed at <Point> recovers via <Row> to sequence <Sequence> and the chain keeps extending' -ForEach $laterWriteCuts {
        $directory = New-TestDirectory -Prefix 'cg-crash'
        $installId = [guid]::NewGuid().ToString()
        $null = Write-CgCheckpoint -StateDirectory $directory -State (New-TestCheckpointState -InstallId $installId)
        $null = Write-CgCheckpoint -StateDirectory $directory -State (New-TestCheckpointState -InstallId $installId)
        Invoke-CrashAt -Directory $directory -InstallId $installId -Point $Point

        $result = Resolve-CgCheckpoint -StateDirectory $directory
        $result.Refused | Should -BeFalse -Because $result.Message
        $result.Row | Should -Be $Row
        $result.Checkpoint['sequence'] | Should -Be $Sequence
        Test-Path -LiteralPath (Join-Path $directory 'checkpoint.tmp') | Should -BeFalse
        $current = Get-CgCheckpoint -StateDirectory $directory
        $current['previousCheckpointSha256'] | Should -Be (Get-TestFileSha256 (Join-Path $directory 'checkpoint.prev'))

        (Write-CgCheckpoint -StateDirectory $directory -State (New-TestCheckpointState -InstallId $installId)).Sequence | Should -Be ($Sequence + 1)
        $again = Resolve-CgCheckpoint -StateDirectory $directory
        $again.Row | Should -Be 'json-prev'
        $again.Refused | Should -BeFalse
    }

    It 'first write killed at <Point> recovers via <Row> (sequence <Sequence>) and the chain starts cleanly' -ForEach $firstWriteCuts {
        $directory = New-TestDirectory -Prefix 'cg-crash'
        $installId = [guid]::NewGuid().ToString()
        Invoke-CrashAt -Directory $directory -InstallId $installId -Point $Point

        $result = Resolve-CgCheckpoint -StateDirectory $directory
        $result.Refused | Should -BeFalse -Because $result.Message
        $result.Row | Should -Be $Row
        if ($Sequence -eq 0) {
            $result.Checkpoint | Should -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $directory 'checkpoint.json') | Should -BeFalse
        } else {
            $result.Checkpoint['sequence'] | Should -Be $Sequence
        }
        Test-Path -LiteralPath (Join-Path $directory 'checkpoint.tmp') | Should -BeFalse
        (Write-CgCheckpoint -StateDirectory $directory -State (New-TestCheckpointState -InstallId $installId)).Sequence | Should -Be ($Sequence + 1)
        (Resolve-CgCheckpoint -StateDirectory $directory).Refused | Should -BeFalse
    }
}
