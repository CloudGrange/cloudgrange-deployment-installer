#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
# AB#8129 — unit tests for scripts/Test-ApplianceVhdxSecrets.ps1 (post-export VHDX secret gate). Each detector
# (captured literals, <NAME>(PASSWORD|TOKEN|SECRET)=<48 hex> pattern) is asserted independently, including
# matches that straddle the 16 MB read-chunk boundary and near-misses that must not count.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\scripts\Test-ApplianceVhdxSecrets.ps1')

    function New-TestImage {
        param([string]$Path, [int]$SizeBytes = 40MB, [hashtable]$Plants = @{})
        $bytes = [byte[]]::new($SizeBytes)
        [System.Random]::new(11).NextBytes($bytes)
        # Random bytes can never form the ASCII pattern; keep them outside [0-9a-f] runs anyway.
        foreach ($offset in $Plants.Keys) {
            $b = [System.Text.Encoding]::ASCII.GetBytes([string]$Plants[$offset])
            [Array]::Copy($b, 0, $bytes, [int64]$offset, $b.Length)
        }
        [IO.File]::WriteAllBytes($Path, $bytes)
    }
    function New-Hex([int]$Length) { -join ((1..$Length) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) }) }
}

Describe 'Test-ApplianceVhdxSecrets' {
    It 'passes a clean image' {
        $p = Join-Path $TestDrive 'clean.bin'; New-TestImage -Path $p
        $r = Test-ApplianceVhdxSecrets -Path $p -Values @{ 'env:X' = (New-Hex 48) }
        $r.Passed | Should -BeTrue
        $r.Findings | Should -Be 0
    }

    It 'finds a captured literal on its own (pattern detector silent)' {
        $literal = New-Hex 64
        $p = Join-Path $TestDrive 'literal.bin'; New-TestImage -Path $p -Plants @{ (30MB) = "noise $literal noise" }
        $r = Test-ApplianceVhdxSecrets -Path $p -Values @{ 'api_secrets:token' = $literal }
        $r.Findings | Should -Be 1
        ($r.Report | Where-Object { $_ -like 'api_secrets:token*' }) | Should -Match ': 1$'
        ($r.Report | Where-Object { $_ -like 'pattern*' }) | Should -Match ': 0$'
    }

    It 'finds a literal that straddles the 16 MB chunk boundary exactly once' {
        $literal = New-Hex 64
        $p = Join-Path $TestDrive 'literal-boundary.bin'; New-TestImage -Path $p -Plants @{ (16MB - 30) = $literal }
        (Test-ApplianceVhdxSecrets -Path $p -Values @{ 'env:Y' = $literal }).Findings | Should -Be 1
    }

    It 'finds the PASSWORD/TOKEN/SECRET assignment pattern (48 lowercase hex) on its own, with no literals captured' {
        $p = Join-Path $TestDrive 'pattern.bin'
        New-TestImage -Path $p -Plants @{ (16MB - 20) = "POSTGRES_PASSWORD=$(New-Hex 48)"; (5MB) = "RELAY_ENROLLMENT_TOKEN=$(New-Hex 48)"; (25MB) = "KEYCLOAK_API_CLIENT_SECRET=$(New-Hex 48)" }
        $r = Test-ApplianceVhdxSecrets -Path $p -Values @{}
        $r.LiteralsCount | Should -Be 0
        $r.Findings | Should -Be 3
        $r.Passed | Should -BeFalse
    }

    It 'ignores near-misses: 47 or 49 hex characters, uppercase hex, and other assignments' {
        $p = Join-Path $TestDrive 'near.bin'
        New-TestImage -Path $p -Plants @{
            (1MB) = "X_PASSWORD=$(New-Hex 47)Z"
            (2MB) = "X_TOKEN=$(New-Hex 49)"
            (3MB) = "X_SECRET=$((New-Hex 48).ToUpperInvariant())"
            (4MB) = "CLOUDGRANGE_VERSION=$(New-Hex 48)"
        }
        (Test-ApplianceVhdxSecrets -Path $p -Values @{}).Findings | Should -Be 0
    }

    It 'ignores captured values shorter than 16 characters (too generic to scan for)' {
        $p = Join-Path $TestDrive 'short.bin'; New-TestImage -Path $p -Plants @{ (1MB) = 'shortvalue' }
        $r = Test-ApplianceVhdxSecrets -Path $p -Values @{ 'env:SHORT' = 'shortvalue' }
        $r.LiteralsCount | Should -Be 0
        $r.Findings | Should -Be 0
    }

    It 'never includes a secret value in its report' {
        $literal = New-Hex 64
        $p = Join-Path $TestDrive 'report.bin'; New-TestImage -Path $p -Plants @{ (1MB) = $literal }
        $r = Test-ApplianceVhdxSecrets -Path $p -Values @{ 'env:Z' = $literal }
        ($r.Report -join "`n") | Should -Not -Match $literal
    }
}
