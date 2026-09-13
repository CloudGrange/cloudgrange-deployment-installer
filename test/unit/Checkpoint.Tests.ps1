#Requires -Version 7.4
<#
.SYNOPSIS
    Checkpoint write order and every row of the §3.2 recovery table, using in-process cuts and
    constructed file states.
.NOTES
    TaskReference: AB#8129 AB#9015
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../support/TestHelpers.ps1')
    Import-Module $ModuleManifest -Force

    function New-Chain {
        param([int]$Count)
        $directory = New-TestDirectory -Prefix 'cg-ckpt'
        $installId = [guid]::NewGuid().ToString()
        $bytes = [Collections.Generic.List[object]]::new()
        for ($i = 1; $i -le $Count; $i++) {
            $null = Write-CgCheckpoint -StateDirectory $directory -State (New-TestCheckpointState -InstallId $installId -Attempt $i)
            $bytes.Add([IO.File]::ReadAllBytes((Join-Path $directory 'checkpoint.json')))
        }
        return [pscustomobject]@{
            Directory = $directory; InstallId = $installId; Bytes = $bytes
            Json = Join-Path $directory 'checkpoint.json'; Prev = Join-Path $directory 'checkpoint.prev'; Tmp = Join-Path $directory 'checkpoint.tmp'
        }
    }

    function Invoke-CutWrite {
        param([Parameter(Mandatory)]$Chain, [Parameter(Mandatory)][string]$Point)
        Set-TestFaultHook -Point $Point
        try {
            { Write-CgCheckpoint -StateDirectory $Chain.Directory -State (New-TestCheckpointState -InstallId $Chain.InstallId -Attempt 99) } |
                Should -Throw ('*simulated-cut:' + $Point + '*')
        } finally {
            Set-TestFaultHook
        }
    }

    function Assert-ChainIntact {
        param([Parameter(Mandatory)]$Chain)
        $current = Get-CgCheckpoint -StateDirectory $Chain.Directory
        if ([long]$current['sequence'] -eq 1) {
            $current['previousCheckpointSha256'] | Should -Be ('0' * 64)
        } else {
            $current['previousCheckpointSha256'] | Should -Be (Get-TestFileSha256 $Chain.Prev)
        }
        Test-Path -LiteralPath $Chain.Tmp | Should -BeFalse
    }
}

AfterAll {
    Set-TestFaultHook
}

Describe 'Write-CgCheckpoint atomic write order' {
    It 'starts the chain at sequence 1 with a zero predecessor and no checkpoint.prev' {
        $chain = New-Chain -Count 1
        $current = Get-CgCheckpoint -StateDirectory $chain.Directory
        $current['sequence'] | Should -Be 1
        $current['previousCheckpointSha256'] | Should -Be ('0' * 64)
        $current['schema'] | Should -BeExactly 'cg-install-checkpoint-v1'
        Test-Path -LiteralPath $chain.Prev | Should -BeFalse
        Test-Path -LiteralPath $chain.Tmp | Should -BeFalse
    }

    It 'increments sequence, chains previousCheckpointSha256 and keeps the prior bytes as checkpoint.prev' {
        $chain = New-Chain -Count 3
        $current = Get-CgCheckpoint -StateDirectory $chain.Directory
        $current['sequence'] | Should -Be 3
        $current['previousCheckpointSha256'] | Should -Be (Get-TestBytesSha256 $chain.Bytes[1])
        Get-TestFileSha256 $chain.Prev | Should -Be (Get-TestBytesSha256 $chain.Bytes[1])
        $second = (ConvertFrom-CgStrictJson -Bytes $chain.Bytes[1]).Value
        $second['previousCheckpointSha256'] | Should -Be (Get-TestBytesSha256 $chain.Bytes[0])
    }

    It 'leaves checkpoint.json untouched until the rename (cut after the tmp fsync)' {
        $chain = New-Chain -Count 2
        Invoke-CutWrite -Chain $chain -Point 'checkpoint-step2-fsynced'
        Get-TestFileSha256 $chain.Json | Should -Be (Get-TestBytesSha256 $chain.Bytes[1])
        $tmp = (ConvertFrom-CgStrictJson -Bytes ([IO.File]::ReadAllBytes($chain.Tmp))).Value
        $tmp['sequence'] | Should -Be 3
        $tmp['previousCheckpointSha256'] | Should -Be (Get-TestBytesSha256 $chain.Bytes[1])
    }

    It 'hard-links checkpoint.json to checkpoint.prev before the rename, so a current file always exists' {
        $chain = New-Chain -Count 2
        Invoke-CutWrite -Chain $chain -Point 'checkpoint-step3-linked'
        Test-Path -LiteralPath $chain.Json | Should -BeTrue
        Get-TestFileSha256 $chain.Prev | Should -Be (Get-TestFileSha256 $chain.Json)
        (Get-Item -LiteralPath $chain.Prev).LinkType | Should -Be 'HardLink'
    }

    It 'reports a directory fsync exactly on Linux' {
        $directory = New-TestDirectory -Prefix 'cg-ckpt'
        $written = Write-CgCheckpoint -StateDirectory $directory -State (New-TestCheckpointState -InstallId ([guid]::NewGuid().ToString()))
        $written.DirectorySynced | Should -Be $IsLinux
    }

    It 'refuses to chain onto an unreadable checkpoint.json' {
        $chain = New-Chain -Count 1
        [IO.File]::WriteAllText($chain.Json, '{ not json')
        { Write-CgCheckpoint -StateDirectory $chain.Directory -State (New-TestCheckpointState -InstallId $chain.InstallId) } | Should -Throw '*checkpoint-corrupt*'
        Test-Path -LiteralPath $chain.Tmp | Should -BeFalse
    }

    It 'refuses a different installId' {
        $chain = New-Chain -Count 1
        { Write-CgCheckpoint -StateDirectory $chain.Directory -State (New-TestCheckpointState -InstallId ([guid]::NewGuid().ToString())) } | Should -Throw '*checkpoint-identity-changed*'
    }

    It 'refuses a document that violates the closed checkpoint schema before writing anything' {
        $chain = New-Chain -Count 1
        $before = Get-StateSnapshot $chain.Directory
        { Write-CgCheckpoint -StateDirectory $chain.Directory -State (New-TestCheckpointState -InstallId $chain.InstallId -Phase 'deploy') } | Should -Throw '*checkpoint-invalid*'
        Get-StateSnapshot $chain.Directory | Should -Be $before
    }
}

Describe 'Get-CgCheckpoint validates on every read' {
    It 'rejects an unknown property' {
        $chain = New-Chain -Count 1
        Edit-TestCheckpointFile -Path $chain.Json -Mutate { param($d) $d['latest'] = 'yes' }
        { Get-CgCheckpoint -StateDirectory $chain.Directory } | Should -Throw '*checkpoint-corrupt*'
    }

    It 'rejects sequence 1 with a non-zero predecessor' {
        $chain = New-Chain -Count 1
        Edit-TestCheckpointFile -Path $chain.Json -Mutate { param($d) $d['previousCheckpointSha256'] = 'f' * 64 }
        { Get-CgCheckpoint -StateDirectory $chain.Directory } | Should -Throw '*checkpoint-corrupt*'
    }

    It 'rejects a later sequence with a zero predecessor' {
        $chain = New-Chain -Count 2
        Edit-TestCheckpointFile -Path $chain.Json -Mutate { param($d) $d['previousCheckpointSha256'] = '0' * 64 }
        { Get-CgCheckpoint -StateDirectory $chain.Directory } | Should -Throw '*checkpoint-corrupt*'
    }

    It 'rejects duplicate property names' {
        $chain = New-Chain -Count 1
        $text = [IO.File]::ReadAllText($chain.Json)
        [IO.File]::WriteAllText($chain.Json, $text.Replace('"sequence": 1,', '"sequence": 1, "Sequence": 1,'))
        { Get-CgCheckpoint -StateDirectory $chain.Directory } | Should -Throw '*checkpoint-corrupt*'
    }
}

Describe 'Resolve-CgCheckpoint recovery table (design §3.2)' {
    Context 'rows that resume' {
        It 'none: an empty state directory is a fresh installation and nothing is created' {
            $directory = New-TestDirectory -Prefix 'cg-ckpt'
            $result = Resolve-CgCheckpoint -StateDirectory $directory
            $result.Row | Should -Be 'none'
            $result.Action | Should -Be 'fresh'
            $result.Refused | Should -BeFalse
            $result.Checkpoint | Should -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath $directory -Force).Count | Should -Be 0
        }

        It 'json only with a zero predecessor: resume from json' {
            $chain = New-Chain -Count 1
            $before = Get-StateSnapshot $chain.Directory
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory
            $result.Row | Should -Be 'json-only-first'
            $result.Action | Should -Be 'resume'
            $result.Checkpoint['sequence'] | Should -Be 1
            $result.Mutated | Should -BeFalse
            Get-StateSnapshot $chain.Directory | Should -Be $before
        }

        It 'json + prev, no tmp, json chains to prev: resume from json' {
            $chain = New-Chain -Count 2
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory
            $result.Row | Should -Be 'json-prev'
            $result.Checkpoint['sequence'] | Should -Be 2
            $result.Mutated | Should -BeFalse
        }

        It 'json + prev, no tmp, sha256(json) == sha256(prev) (crash after step 3): resume from json' {
            $chain = New-Chain -Count 2
            [IO.File]::Copy($chain.Json, $chain.Prev, $true)
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory
            $result.Row | Should -Be 'json-prev'
            $result.Refused | Should -BeFalse
            $result.Checkpoint['sequence'] | Should -Be 2
        }
    }

    Context 'json + tmp' {
        It 'tmp valid (cut after tmp fsync, prev present): completes steps 3-5 and resumes from the new json' {
            $chain = New-Chain -Count 2
            Invoke-CutWrite -Chain $chain -Point 'checkpoint-step2-fsynced'
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory
            $result.Row | Should -Be 'json-tmp-valid'
            $result.Action | Should -Be 'complete-interrupted-write'
            $result.Checkpoint['sequence'] | Should -Be 3
            @($result.Events) | Should -Contain 'checkpoint-write-completed'
            Get-TestFileSha256 $chain.Prev | Should -Be (Get-TestBytesSha256 $chain.Bytes[1])
            Assert-ChainIntact -Chain $chain
            (Resolve-CgCheckpoint -StateDirectory $chain.Directory).Row | Should -Be 'json-prev'
            (Write-CgCheckpoint -StateDirectory $chain.Directory -State (New-TestCheckpointState -InstallId $chain.InstallId)).Sequence | Should -Be 4
        }

        It 'tmp valid (cut after prev unlinked, no prev): completes steps 3-5' {
            $chain = New-Chain -Count 2
            Invoke-CutWrite -Chain $chain -Point 'checkpoint-step3-prev-unlinked'
            Test-Path -LiteralPath $chain.Prev | Should -BeFalse
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory
            $result.Row | Should -Be 'json-tmp-valid'
            $result.Checkpoint['sequence'] | Should -Be 3
            Get-TestFileSha256 $chain.Prev | Should -Be (Get-TestBytesSha256 $chain.Bytes[1])
            Assert-ChainIntact -Chain $chain
        }

        It 'tmp valid (cut after hard link, prev equals json): completes steps 3-5' {
            $chain = New-Chain -Count 2
            Invoke-CutWrite -Chain $chain -Point 'checkpoint-step3-linked'
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory
            $result.Row | Should -Be 'json-tmp-valid'
            $result.Checkpoint['sequence'] | Should -Be 3
            Assert-ChainIntact -Chain $chain
        }

        It 'tmp partially written (unparsable): deletes tmp and resumes from json' {
            $chain = New-Chain -Count 2
            Invoke-CutWrite -Chain $chain -Point 'checkpoint-step2-partial'
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory
            $result.Row | Should -Be 'json-tmp-invalid'
            $result.Action | Should -Be 'discard-tmp'
            $result.Checkpoint['sequence'] | Should -Be 2
            Get-TestFileSha256 $chain.Json | Should -Be (Get-TestBytesSha256 $chain.Bytes[1])
            Assert-ChainIntact -Chain $chain
        }

        It 'tmp empty: deletes tmp and resumes from json' {
            $chain = New-Chain -Count 1
            [IO.File]::WriteAllBytes($chain.Tmp, [byte[]]::new(0))
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory
            $result.Row | Should -Be 'json-tmp-invalid'
            Test-Path -LiteralPath $chain.Tmp | Should -BeFalse
            $result.Checkpoint['sequence'] | Should -Be 1
        }

        It 'tmp with the wrong predecessor: deletes tmp and resumes from json' {
            $chain = New-Chain -Count 2
            Invoke-CutWrite -Chain $chain -Point 'checkpoint-step2-fsynced'
            Edit-TestCheckpointFile -Path $chain.Tmp -Mutate { param($d) $d['previousCheckpointSha256'] = 'f' * 64 }
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory
            $result.Row | Should -Be 'json-tmp-invalid'
            $result.Checkpoint['sequence'] | Should -Be 2
            Assert-ChainIntact -Chain $chain
        }

        It 'tmp with the wrong sequence: deletes tmp and resumes from json' {
            $chain = New-Chain -Count 2
            Invoke-CutWrite -Chain $chain -Point 'checkpoint-step2-fsynced'
            Edit-TestCheckpointFile -Path $chain.Tmp -Mutate { param($d) $d['sequence'] = 7 }
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory
            $result.Row | Should -Be 'json-tmp-invalid'
            $result.Checkpoint['sequence'] | Should -Be 2
        }

        It 'tmp violating the checkpoint schema: deletes tmp and resumes from json' {
            $chain = New-Chain -Count 2
            Invoke-CutWrite -Chain $chain -Point 'checkpoint-step2-fsynced'
            Edit-TestCheckpointFile -Path $chain.Tmp -Mutate { param($d) $d['secret'] = 'value' }
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory
            $result.Row | Should -Be 'json-tmp-invalid'
            $result.Checkpoint['sequence'] | Should -Be 2
        }
    }

    Context 'prev + tmp, no json (external damage)' {
        It 'tmp valid against prev: renames tmp to json' {
            $chain = New-Chain -Count 2
            Invoke-CutWrite -Chain $chain -Point 'checkpoint-step3-linked'
            [IO.File]::Delete($chain.Json)
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory
            $result.Row | Should -Be 'prev-tmp-no-json'
            $result.Action | Should -Be 'rename-tmp'
            $result.Checkpoint['sequence'] | Should -Be 3
            Assert-ChainIntact -Chain $chain
            (Resolve-CgCheckpoint -StateDirectory $chain.Directory).Row | Should -Be 'json-prev'
        }

        It 'tmp not valid against prev: restores json from prev and records checkpoint-restored-from-prev' {
            $chain = New-Chain -Count 2
            Invoke-CutWrite -Chain $chain -Point 'checkpoint-step2-partial'
            [IO.File]::Delete($chain.Json)
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory
            $result.Row | Should -Be 'prev-tmp-no-json'
            $result.Action | Should -Be 'restore-from-prev'
            @($result.Events) | Should -Contain 'checkpoint-restored-from-prev'
            $result.Checkpoint['sequence'] | Should -Be 1
            Get-TestFileSha256 $chain.Json | Should -Be (Get-TestBytesSha256 $chain.Bytes[0])
            Test-Path -LiteralPath $chain.Tmp | Should -BeFalse
            (Resolve-CgCheckpoint -StateDirectory $chain.Directory).Row | Should -Be 'json-prev'
        }
    }

    Context 'json unparsable' {
        It 'refuses checkpoint-corrupt when prev parses and preserves both files' {
            $chain = New-Chain -Count 2
            [IO.File]::WriteAllText($chain.Json, '{"schema": "cg-install-checkpoint-v1", truncated')
            $before = Get-StateSnapshot $chain.Directory
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory
            $result.Row | Should -Be 'json-unparsable'
            $result.Refused | Should -BeTrue
            $result.ReasonCode | Should -Be 'checkpoint-corrupt'
            $result.Message | Should -Match 'ResumeFromPrevious'
            Get-StateSnapshot $chain.Directory | Should -Be $before
        }

        It 'treats a schema-invalid json as unparsable' {
            $chain = New-Chain -Count 2
            Edit-TestCheckpointFile -Path $chain.Json -Mutate { param($d) $d['phase'] = 'deploy' }
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory
            $result.Row | Should -Be 'json-unparsable'
            $result.Refused | Should -BeTrue
        }

        It 'promotes prev with -ResumeFromPrevious, keeps the corrupt copy and requests re-probing' {
            $chain = New-Chain -Count 2
            [IO.File]::WriteAllText($chain.Json, 'corrupt')
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory -ResumeFromPrevious
            $result.Refused | Should -BeFalse
            $result.Action | Should -Be 'promote-previous'
            $result.ReprobeCompleted | Should -BeTrue
            @($result.Events) | Should -Contain 'checkpoint-promoted-from-prev'
            $result.Checkpoint['sequence'] | Should -Be 1
            Get-TestFileSha256 $chain.Json | Should -Be (Get-TestBytesSha256 $chain.Bytes[0])
            $corrupt = @(Get-ChildItem -LiteralPath $chain.Directory -Filter 'checkpoint.corrupt-*')
            $corrupt.Count | Should -Be 1
            [IO.File]::ReadAllText($corrupt[0].FullName) | Should -BeExactly 'corrupt'
            (Resolve-CgCheckpoint -StateDirectory $chain.Directory).Row | Should -Be 'json-prev'
        }
    }

    Context 'tmp only (crash inside the first write; installer interpretation)' {
        It 'a complete first checkpoint in tmp is renamed to json' {
            $chain = New-Chain -Count 0
            Invoke-CutWrite -Chain $chain -Point 'checkpoint-step2-fsynced'
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory
            $result.Row | Should -Be 'tmp-only-first-write'
            $result.Action | Should -Be 'complete-first-write'
            $result.Checkpoint['sequence'] | Should -Be 1
            Assert-ChainIntact -Chain $chain
        }

        It 'a partial first checkpoint in tmp is discarded and the installation is fresh' {
            $chain = New-Chain -Count 0
            Invoke-CutWrite -Chain $chain -Point 'checkpoint-step2-partial'
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory
            $result.Row | Should -Be 'tmp-only-first-write'
            $result.Action | Should -Be 'discard-first-write'
            $result.Checkpoint | Should -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath $chain.Directory -Force).Count | Should -Be 0
        }
    }

    Context 'anything else: refuse checkpoint-corrupt and modify nothing' {
        It '<Name>' -ForEach @(
            @{ Name = 'json unparsable and no prev'; Setup = { param($c) [IO.File]::Delete($c.Prev); [IO.File]::WriteAllText($c.Json, 'x') } }
            @{ Name = 'json unparsable and prev unparsable'; Setup = { param($c) [IO.File]::WriteAllText($c.Json, 'x'); [IO.File]::WriteAllText($c.Prev, 'y') } }
            @{ Name = 'json does not chain to prev'; Setup = { param($c) $null = Write-CgCheckpoint -StateDirectory $c.Directory -State (New-TestCheckpointState -InstallId $c.InstallId); [IO.File]::WriteAllBytes($c.Prev, $c.Bytes[0]) } }
            @{ Name = 'json names a predecessor but prev is missing'; Setup = { param($c) [IO.File]::Delete($c.Prev) } }
            @{ Name = 'invalid tmp while json and prev do not chain'; Setup = { param($c) $null = Write-CgCheckpoint -StateDirectory $c.Directory -State (New-TestCheckpointState -InstallId $c.InstallId); [IO.File]::WriteAllBytes($c.Prev, $c.Bytes[0]); [IO.File]::WriteAllText($c.Tmp, 'partial') } }
            @{ Name = 'prev only'; Setup = { param($c) [IO.File]::Delete($c.Json) } }
            @{ Name = 'prev unparsable with tmp and no json'; Setup = { param($c) [IO.File]::Delete($c.Json); [IO.File]::WriteAllText($c.Prev, 'y'); [IO.File]::WriteAllText($c.Tmp, 'z') } }
            @{ Name = 'tmp only with a sequence above 1'; Setup = { param($c) [IO.File]::WriteAllBytes($c.Tmp, $c.Bytes[1]); [IO.File]::Delete($c.Json); [IO.File]::Delete($c.Prev) } }
        ) {
            $chain = New-Chain -Count 2
            & $Setup $chain
            $before = Get-StateSnapshot $chain.Directory
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory
            $result.Refused | Should -BeTrue
            $result.ReasonCode | Should -Be 'checkpoint-corrupt'
            $result.Row | Should -Be 'anything-else'
            $result.Mutated | Should -BeFalse
            Get-StateSnapshot $chain.Directory | Should -Be $before
        }
    }

    Context 'Plan (-NoMutation)' {
        It 'reports the action for an interrupted write without touching files' {
            $chain = New-Chain -Count 2
            Invoke-CutWrite -Chain $chain -Point 'checkpoint-step2-fsynced'
            $before = Get-StateSnapshot $chain.Directory
            $result = Resolve-CgCheckpoint -StateDirectory $chain.Directory -NoMutation
            $result.Row | Should -Be 'json-tmp-valid'
            $result.Checkpoint['sequence'] | Should -Be 3
            $result.Mutated | Should -BeFalse
            Get-StateSnapshot $chain.Directory | Should -Be $before
        }
    }
}
