#Requires -Version 7.4
<#
.SYNOPSIS
    Mode dispatch (Invoke-CgInstallerMode) against a fake bundle, the entry script's composition pin,
    and the entry script's start-up order: platform, verify-tree before module import, unimplemented
    parameters, root.
.NOTES
    TaskReference: AB#8129 AB#9015 AB#9016
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../support/TestHelpers.ps1')
    Import-Module $ModuleManifest -Force
    . (Join-Path $SupportRoot 'FakePhases.ps1')
    $validText = Get-Content -LiteralPath $ValidBomPath -Raw
    $trustDigest = 'f' * 64

    function New-FakeBundle {
        <# Bundle tree under <parent>/bundle; state, log and site config live beside it, outside the tree. #>
        param([switch]$SiteConfigInvalid, [switch]$NoManagement, [scriptblock]$MutateBom, [string]$CatalogText = 'eyJhbGciOiJFUzI1NiJ9.eyJiIjoyfQ.c2ln', [string[]]$Channels = @('m0-internal'))
        $parent = New-TestDirectory -Prefix 'cg-bundle'
        $root = Join-Path $parent 'bundle'
        foreach ($directory in @('management', 'release', 'trust', 'schemas')) { $null = New-Item -ItemType Directory -Path (Join-Path $root $directory) -Force }
        if (-not $NoManagement) {
            Set-Content -LiteralPath (Join-Path $root 'management/Test-CloudGrangeSiteConfig.ps1') -Value @'
param([Parameter(Mandatory)][string]$ConfigPath)
$document = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if ($document.stubValid) { [pscustomobject]@{ passed = $true; errors = @() } }
else { [pscustomobject]@{ passed = $false; errors = @([pscustomobject]@{ code = 'SCHEMA_VIOLATION'; path = '/kind' }) } }
'@
            Set-Content -LiteralPath (Join-Path $root 'management/SecretRef.psm1') -Value @'
function New-SecretRefRedactor { [pscustomobject]@{ Kind = 'stub' } }
function Protect-SecretRefText { param([Parameter(Mandatory)][psobject]$Redactor, [Parameter(Mandatory)][AllowEmptyString()][string]$Text) $Text.Replace('canary-3f9a', '[REDACTED]') }
Export-ModuleMember -Function New-SecretRefRedactor, Protect-SecretRefText
'@
        }
        $schemaPath = Join-Path $root 'schemas/site-config-v1.schema.json'
        Write-TestJsonFile -Path $schemaPath -InputObject ([ordered]@{
                '$id' = 'https://cloudgrange.cloud/schemas/cg-site-config-v1.schema.json'
                properties = [ordered]@{ schema_version = @{ const = 1 }; kind = @{ const = 'CloudGrangeSiteConfig' } }
            })
        $bom = ConvertFrom-Json $validText -AsHashtable -Depth 32
        $bom['configurationSchema']['sha256'] = Get-TestFileSha256 $schemaPath
        if ($MutateBom) { & $MutateBom $bom }
        Write-TestJsonFile -Path (Join-Path $root 'release/release-bom.json') -InputObject $bom
        Set-Content -LiteralPath (Join-Path $root 'release/composition-manifest.json') -Value '{"schema":"cg-composition-v1"}'
        Set-Content -LiteralPath (Join-Path $root 'release/catalog.jws') -Value $CatalogText
        foreach ($channel in $Channels) { Set-Content -LiteralPath (Join-Path $root ('trust/checkpoint-' + $channel + '.json')) -Value '{}' }
        $sitePath = Join-Path $parent 'site-config.json'
        Set-Content -LiteralPath $sitePath -Value $(if ($SiteConfigInvalid) { '{"stubValid": false}' } else { '{"stubValid": true}' })
        return [pscustomobject]@{ Parent = $parent; Root = $root; SiteConfig = $sitePath; State = Join-Path $parent 'state'; Log = Join-Path $parent 'phases.log' }
    }

    function Invoke-Mode {
        param([Parameter(Mandatory)]$Bundle, [Parameter(Mandatory)][string]$Mode, [object[]]$Registry, [string]$SiteConfig, [string]$StateDirectory, [switch]$NoTrustDigest)
        $arguments = @{
            Mode = $Mode; BundleRoot = $Bundle.Root
            SiteConfig = $(if ($SiteConfig) { $SiteConfig } else { $Bundle.SiteConfig })
            StateDirectory = $(if ($StateDirectory) { $StateDirectory } else { $Bundle.State })
        }
        if (-not $NoTrustDigest) { $arguments.TrustCheckpointSha256 = $trustDigest }
        if ($Registry) { $arguments.Registry = $Registry }
        return Invoke-CgInstallerMode @arguments
    }
}

AfterAll {
    Get-Module -Name SecretRef | Remove-Module -Force
}

Describe 'Invoke-CgInstallerMode with a verified bundle' {
    BeforeAll {
        Mock -ModuleName CloudGrange.Installer Invoke-CgTrustVerifier { [pscustomobject]@{ ExitCode = 0; Output = @() } }
    }

    It 'reports mode-not-implemented for <_> without touching state' -ForEach @('Verify', 'Update', 'Rollback', 'Restore', 'Uninstall', 'Unseal') {
        $bundle = New-FakeBundle
        $result = Invoke-Mode -Bundle $bundle -Mode $_
        $result.Terminal | Should -Be 'not-implemented'
        $result.ReasonCode | Should -Be 'mode-not-implemented'
        $result.ExitCode | Should -Be 4
        Test-Path -LiteralPath $bundle.State | Should -BeFalse
    }

    It 'Plan is blocked while phases are unimplemented, verifies the composition with the cg-trust grammar and reports the request identity' {
        $bundle = New-FakeBundle
        $result = Invoke-Mode -Bundle $bundle -Mode 'Plan'
        $result.Terminal | Should -Be 'plan-blocked'
        $result.ReasonCode | Should -Be 'phases-not-implemented'
        $result.ExitCode | Should -Be 2
        @($result.Details.UnimplementedPhases).Count | Should -Be 13
        $result.Details.Channel | Should -Be 'm0-internal'
        $payloadSha = Get-TestBytesSha256 ([Text.Encoding]::UTF8.GetBytes('{"b":2}'))
        $compositionSha = Get-TestFileSha256 (Join-Path $bundle.Root 'release/composition-manifest.json')
        $expected = Get-CgRequestSha256 -SiteConfigBytes ([IO.File]::ReadAllBytes($bundle.SiteConfig)) -CompositionSha256 $compositionSha -CatalogPayloadSha256 $payloadSha
        $result.Details.RequestSha256 | Should -Be $expected
        $result.Details.CompositionSha256 | Should -Be $compositionSha
        $result.Details.CatalogPayloadSha256 | Should -Be $payloadSha
        $result.Details.BomSha256 | Should -Be (Get-TestFileSha256 (Join-Path $bundle.Root 'release/release-bom.json'))
        Test-Path -LiteralPath $bundle.State | Should -BeFalse
        $root = $bundle.Root
        Should -Invoke -ModuleName CloudGrange.Installer Invoke-CgTrustVerifier -Times 1 -Exactly -ParameterFilter {
            $Arguments.Count -eq 15 -and $Arguments[0] -eq 'verify-composition' -and
            $Arguments[1] -eq '--checkpoint' -and $Arguments[2] -eq (Join-Path $root 'trust/checkpoint-m0-internal.json') -and
            $Arguments[3] -eq '--checkpoint-sha256' -and $Arguments[4] -eq ('f' * 64) -and
            $Arguments[5] -eq '--channel' -and $Arguments[6] -eq 'm0-internal' -and
            $Arguments[7] -eq '--release' -and $Arguments[8] -eq (Join-Path $root 'release') -and
            $Arguments[9] -eq '--content-root' -and $Arguments[10] -eq $root -and
            $Arguments[11] -eq '--output' -and -not $Arguments[12].StartsWith($root) -and
            $Arguments[13] -eq '--artifact-mode' -and $Arguments[14] -eq 'digest-only'
        }
    }

    It 'Plan is ok with a complete registry and never mutates' {
        $bundle = New-FakeBundle
        $result = Invoke-Mode -Bundle $bundle -Mode 'Plan' -Registry (New-FakePhaseRegistry -LogPath $bundle.Log)
        $result.Terminal | Should -Be 'plan-ok'
        $result.ExitCode | Should -Be 0
        Test-Path -LiteralPath $bundle.State | Should -BeFalse
        Test-Path -LiteralPath $bundle.Log | Should -BeFalse
    }

    It 'Install refuses before any change while phases are unimplemented' {
        $bundle = New-FakeBundle
        $result = Invoke-Mode -Bundle $bundle -Mode 'Install'
        $result.Terminal | Should -Be 'refused'
        $result.ReasonCode | Should -Be 'phases-not-implemented'
        $result.ExitCode | Should -Be 2
        Test-Path -LiteralPath $bundle.State | Should -BeFalse
    }

    It 'Install runs the engine, records compositionSha256 in the checkpoint, writes nothing inside the bundle; Plan then matches' {
        $bundle = New-FakeBundle
        $treeBefore = @(Get-ChildItem -LiteralPath $bundle.Root -Recurse -Force | ForEach-Object { $_.FullName }) -join '|'
        $install = Invoke-Mode -Bundle $bundle -Mode 'Install' -Registry (New-FakePhaseRegistry -LogPath $bundle.Log)
        $install.Terminal | Should -Be 'accepted'
        $install.ExitCode | Should -Be 0
        (Get-CgCheckpoint -StateDirectory $bundle.State)['compositionSha256'] | Should -Be (Get-TestFileSha256 (Join-Path $bundle.Root 'release/composition-manifest.json'))
        @(Get-ChildItem -LiteralPath $bundle.Root -Recurse -Force | ForEach-Object { $_.FullName }) -join '|' | Should -Be $treeBefore
        $plan = Invoke-Mode -Bundle $bundle -Mode 'Plan' -Registry (New-FakePhaseRegistry -LogPath $bundle.Log)
        $plan.Terminal | Should -Be 'plan-ok'
        $plan.Details.RecoveryRow | Should -Be 'json-prev'
    }

    It 'Install redacts evidence through the bundled SecretRef redactor and exits 3 on a phase failure' {
        $bundle = New-FakeBundle
        $registry = New-FakePhaseRegistry -LogPath $bundle.Log -FailPhase 'retrieve' -FailMessage 'failed with canary-3f9a'
        $result = Invoke-Mode -Bundle $bundle -Mode 'Install' -Registry $registry
        $result.Terminal | Should -Be 'failed:retrieve'
        $result.ExitCode | Should -Be 3
        $evidence = @(Get-ChildItem -LiteralPath (Join-Path $bundle.State 'evidence') -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $evidence | Should -Not -Match 'canary-3f9a'
        $evidence | Should -Match '\[REDACTED\]'
    }

    It 'Plan reports request-mismatch against an existing checkpoint without mutation' {
        $bundle = New-FakeBundle
        $null = Invoke-Mode -Bundle $bundle -Mode 'Install' -Registry (New-FakePhaseRegistry -LogPath $bundle.Log -FailPhase 'vault')
        Set-Content -LiteralPath $bundle.SiteConfig -Value '{"stubValid": true, "changed": 1}'
        $before = Get-StateSnapshot $bundle.State
        $result = Invoke-Mode -Bundle $bundle -Mode 'Plan' -Registry (New-FakePhaseRegistry -LogPath $bundle.Log)
        $result.Terminal | Should -Be 'plan-blocked'
        $result.ReasonCode | Should -Be 'request-mismatch'
        Get-StateSnapshot $bundle.State | Should -Be $before
    }

    It 'refuses Install with request-mismatch when the site config changed' {
        $bundle = New-FakeBundle
        $null = Invoke-Mode -Bundle $bundle -Mode 'Install' -Registry (New-FakePhaseRegistry -LogPath $bundle.Log -FailPhase 'vault')
        Set-Content -LiteralPath $bundle.SiteConfig -Value '{"stubValid": true, "changed": 1}'
        $result = Invoke-Mode -Bundle $bundle -Mode 'Install' -Registry (New-FakePhaseRegistry -LogPath $bundle.Log)
        $result.Terminal | Should -Be 'refused'
        $result.ReasonCode | Should -Be 'request-mismatch'
        $result.ExitCode | Should -Be 2
    }

    It '<Mode> refuses a state directory inside the bundle tree before anything else' -ForEach @(@{ Mode = 'Plan' }, @{ Mode = 'Install' }) {
        $bundle = New-FakeBundle
        $inside = Join-Path $bundle.Root 'state'
        $result = Invoke-Mode -Bundle $bundle -Mode $Mode -Registry (New-FakePhaseRegistry -LogPath $bundle.Log) -StateDirectory $inside
        $result.ReasonCode | Should -Be 'state-inside-bundle'
        $result.ExitCode | Should -Be 2
        Test-Path -LiteralPath $inside | Should -BeFalse
        Should -Invoke -ModuleName CloudGrange.Installer Invoke-CgTrustVerifier -Times 0 -Exactly -Scope It
    }

    It '<Mode> requires the trust checkpoint digest from the independent channel' -ForEach @(@{ Mode = 'Plan' }, @{ Mode = 'Install' }) {
        $bundle = New-FakeBundle
        $result = Invoke-Mode -Bundle $bundle -Mode $Mode -Registry (New-FakePhaseRegistry -LogPath $bundle.Log) -NoTrustDigest
        $result.ReasonCode | Should -Be 'trust-checkpoint-digest-missing'
        $result.ExitCode | Should -Be 2
        Should -Invoke -ModuleName CloudGrange.Installer Invoke-CgTrustVerifier -Times 0 -Exactly -Scope It
    }

    It 'blocks <Mode> with <Reason> before mutation' -ForEach @(
        @{ Mode = 'Plan'; Reason = 'site-config-missing'; Bundle = @{}; SiteConfig = 'absent.json' }
        @{ Mode = 'Install'; Reason = 'site-config-invalid'; Bundle = @{ SiteConfigInvalid = $true } }
        @{ Mode = 'Plan'; Reason = 'management-scripts-missing'; Bundle = @{ NoManagement = $true } }
        @{ Mode = 'Plan'; Reason = 'trust-checkpoint-missing'; Bundle = @{ Channels = @() } }
        @{ Mode = 'Install'; Reason = 'trust-checkpoint-ambiguous'; Bundle = @{ Channels = @('m0-internal', 'm0-fixture') } }
        @{ Mode = 'Install'; Reason = 'release-bom-invalid'; Bundle = @{ MutateBom = { param($b) $b['product']['releaseTag'] = 'v9.9.9' } } }
        @{ Mode = 'Plan'; Reason = 'release-bom-invalid'; Bundle = @{ MutateBom = { param($b) $b['configurationSchema']['sha256'] = 'e' * 64 } } }
        @{ Mode = 'Install'; Reason = 'powershell-version-unsupported'; Bundle = @{ MutateBom = { param($b) $b['compatibility']['installer']['powershellMinimum'] = '99.0.0' } } }
        @{ Mode = 'Plan'; Reason = 'catalog-malformed'; Bundle = @{ CatalogText = 'not-a-jws' } }
    ) {
        $bundleArguments = $_['Bundle']
        $bundle = New-FakeBundle @bundleArguments
        $site = if ($_.ContainsKey('SiteConfig')) { Join-Path $bundle.Parent $_['SiteConfig'] } else { $null }
        $result = Invoke-Mode -Bundle $bundle -Mode $Mode -Registry (New-FakePhaseRegistry -LogPath $bundle.Log) -SiteConfig $site
        $result.Terminal | Should -Be $(if ($Mode -eq 'Plan') { 'plan-blocked' } else { 'refused' })
        $result.ReasonCode | Should -Be $Reason
        $result.ExitCode | Should -Be 2
        Test-Path -LiteralPath $bundle.State | Should -BeFalse
        Test-Path -LiteralPath $bundle.Log | Should -BeFalse
    }

    It 'blocks with composition-manifest-missing when the manifest is absent' {
        $bundle = New-FakeBundle
        Remove-Item -LiteralPath (Join-Path $bundle.Root 'release/composition-manifest.json')
        (Invoke-Mode -Bundle $bundle -Mode 'Plan').ReasonCode | Should -Be 'composition-manifest-missing'
    }

    It 'blocks with trust-verification-failed when cg-trust verify-composition refuses' {
        Mock -ModuleName CloudGrange.Installer Invoke-CgTrustVerifier { [pscustomobject]@{ ExitCode = 1; Output = @('denied') } }
        $bundle = New-FakeBundle
        $result = Invoke-Mode -Bundle $bundle -Mode 'Install' -Registry (New-FakePhaseRegistry -LogPath $bundle.Log)
        $result.ReasonCode | Should -Be 'trust-verification-failed'
        Test-Path -LiteralPath $bundle.State | Should -BeFalse
    }
}

Describe 'Invoke-CgInstallerMode without a verifier' {
    It 'blocks with verifier-missing when bin/cg-trust is absent' {
        $bundle = New-FakeBundle
        $result = Invoke-Mode -Bundle $bundle -Mode 'Plan'
        $result.ReasonCode | Should -Be 'verifier-missing'
        $result.Terminal | Should -Be 'plan-blocked'
    }
}

Describe 'Entry composition pin from protected state (Get-CgProtectedCompositionPin)' {
    BeforeAll {
        $entryAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'installer/Install-CloudGrange.ps1'), [ref]$null, [ref]$null)
        $pinFunction = $entryAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CgProtectedCompositionPin' }, $true)
        . ([scriptblock]::Create($pinFunction.Extent.Text))
        $pinA = 'a1' * 32
        $pinB = 'b2' * 32
    }

    It 'returns nothing when the node has no installer state' {
        Get-CgProtectedCompositionPin -StateRoot (New-TestDirectory -Prefix 'cg-pin') | Should -BeNullOrEmpty
    }

    It 'prefers the accepted-composition record' {
        $state = New-TestDirectory -Prefix 'cg-pin'
        $null = New-Item -ItemType Directory -Path (Join-Path $state 'trust')
        Set-Content -LiteralPath (Join-Path $state 'trust/accepted-composition.json') -Value ('{"compositionSha256":"' + $pinA + '"}')
        Set-Content -LiteralPath (Join-Path $state 'checkpoint.json') -Value ('{"compositionSha256":"' + $pinB + '"}')
        Get-CgProtectedCompositionPin -StateRoot $state | Should -Be $pinA
    }

    It 'reads the checkpoint chain, falling back to checkpoint.prev when checkpoint.json is corrupt' {
        $state = New-TestDirectory -Prefix 'cg-pin'
        Set-Content -LiteralPath (Join-Path $state 'checkpoint.json') -Value ('{"compositionSha256":"' + $pinB + '"}')
        Get-CgProtectedCompositionPin -StateRoot $state | Should -Be $pinB
        Set-Content -LiteralPath (Join-Path $state 'checkpoint.json') -Value 'corrupt'
        Set-Content -LiteralPath (Join-Path $state 'checkpoint.prev') -Value ('{"compositionSha256":"' + $pinA + '"}')
        Get-CgProtectedCompositionPin -StateRoot $state | Should -Be $pinA
    }

    It 'refuses when state exists but yields no well-formed digest' {
        $state = New-TestDirectory -Prefix 'cg-pin'
        Set-Content -LiteralPath (Join-Path $state 'checkpoint.json') -Value 'corrupt'
        Set-Content -LiteralPath (Join-Path $state 'checkpoint.tmp') -Value ('{"compositionSha256":"' + $pinA.ToUpperInvariant() + '"}')
        { Get-CgProtectedCompositionPin -StateRoot $state } | Should -Throw '*composition-pin-unavailable*'
    }

    It 'reads the pin from a real engine checkpoint' {
        $state = New-TestDirectory -Prefix 'cg-pin'
        $null = Write-CgCheckpoint -StateDirectory $state -State (New-TestCheckpointState -InstallId ([guid]::NewGuid().ToString()))
        Get-CgProtectedCompositionPin -StateRoot $state | Should -Be ('e' * 64)
    }
}

Describe 'Install-CloudGrange.ps1 start-up order' -Skip:(-not $IsLinux) {
    BeforeAll {
        function New-EntryBundle {
            param([int]$VerifierExit = 0, [switch]$NoVerifier)
            $root = New-TestDirectory -Prefix 'cg-entry'
            Copy-Item -LiteralPath (Join-Path $RepoRoot 'installer/Install-CloudGrange.ps1') -Destination $root
            $moduleDirectory = Join-Path $root 'modules/CloudGrange.Installer'
            $null = New-Item -ItemType Directory -Path $moduleDirectory -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'release') -Force
            Set-Content -LiteralPath (Join-Path $root 'release/composition-manifest.json') -Value '{}'
            Set-Content -LiteralPath (Join-Path $moduleDirectory 'CloudGrange.Installer.psd1') -Value "@{ RootModule = 'CloudGrange.Installer.psm1'; ModuleVersion = '0.0.1'; FunctionsToExport = @('Invoke-CgInstallerMode', 'Get-CgErrorReason') }"
            Set-Content -LiteralPath (Join-Path $moduleDirectory 'CloudGrange.Installer.psm1') -Value @'
Set-Content -LiteralPath (Join-Path $PSScriptRoot '../../imported.marker') -Value 'imported'
function Invoke-CgInstallerMode { param($Mode, $BundleRoot, $SiteConfig, $TrustCheckpointSha256, $StateDirectory, [switch]$ResumeFromPrevious) [pscustomobject]@{ Terminal = 'plan-ok'; ReasonCode = $null; Message = 'stub'; ExitCode = 0 } }
function Get-CgErrorReason { param($ErrorObject) 'unexpected-error' }
'@
            if (-not $NoVerifier) {
                $null = New-Item -ItemType Directory -Path (Join-Path $root 'bin') -Force
                $stub = "#!/bin/sh`nprintf '%s\n' `"`$@`" > `"`$(dirname `"`$0`")/../verifier-args.txt`"`nexit $VerifierExit`n"
                $verifier = Join-Path $root 'bin/cg-trust'
                [IO.File]::WriteAllText($verifier, $stub)
                [IO.File]::SetUnixFileMode($verifier, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute')
            }
            return $root
        }

        function Invoke-Entry {
            param([Parameter(Mandatory)][string]$Root, [string[]]$Extra = @(), [switch]$Sudo)
            $arguments = @('-Mode', 'Plan', '-SiteConfig', (Join-Path $Root 'site.json'), '-TrustCheckpointSha256', ('f' * 64)) + $Extra
            $child = Invoke-ChildPwsh -ScriptPath (Join-Path $Root 'Install-CloudGrange.ps1') -Arguments $arguments -Sudo:$Sudo
            return [pscustomobject]@{ ExitCode = $child.ExitCode; Result = (ConvertFrom-LastJsonLine $child.Output); Output = $child.Output }
        }
        $isRoot = ((& id -u) | Out-String).Trim() -eq '0'
        $hostHasInstallerState = Test-Path -LiteralPath '/var/lib/cloudgrange/state'
    }

    It 'refuses verifier-missing before importing any module' {
        $root = New-EntryBundle -NoVerifier
        $run = Invoke-Entry -Root $root
        $run.ExitCode | Should -Be 2 -Because $run.Output
        $run.Result.reasonCode | Should -Be 'verifier-missing'
        Test-Path -LiteralPath (Join-Path $root 'imported.marker') | Should -BeFalse
    }

    It 'runs verify-tree with the exact manifest and root, and refuses without importing when it fails' {
        if ($hostHasInstallerState) { Set-ItResult -Skipped -Because 'this host has installer state, which adds a composition pin'; return }
        $root = New-EntryBundle -VerifierExit 1
        $run = Invoke-Entry -Root $root
        $run.ExitCode | Should -Be 2 -Because $run.Output
        $run.Result.reasonCode | Should -Be 'tree-verification-failed'
        Test-Path -LiteralPath (Join-Path $root 'imported.marker') | Should -BeFalse
        @(Get-Content -LiteralPath (Join-Path $root 'verifier-args.txt')) | Should -Be @('verify-tree', '--manifest', (Join-Path $root 'release/composition-manifest.json'), '--root', $root)
    }

    It 'refuses parameters that later work packages implement instead of ignoring them' {
        $root = New-EntryBundle
        $run = Invoke-Entry -Root $root -Extra @('-ArtifactMirror', 'https://mirror.example.test')
        $run.ExitCode | Should -Be 4 -Because $run.Output
        $run.Result.reasonCode | Should -Be 'parameter-not-implemented'
        Test-Path -LiteralPath (Join-Path $root 'verifier-args.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'imported.marker') | Should -BeFalse
    }

    It 'refuses root-required for a non-root user after tree verification' {
        if ($isRoot) { Set-ItResult -Skipped -Because 'the test process runs as root'; return }
        $root = New-EntryBundle
        $run = Invoke-Entry -Root $root
        $run.ExitCode | Should -Be 2 -Because $run.Output
        $run.Result.reasonCode | Should -Be 'root-required'
        Test-Path -LiteralPath (Join-Path $root 'verifier-args.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'imported.marker') | Should -BeFalse
    }

    It 'imports the installer module only after verify-tree passes (as root)' {
        $sudoAvailable = $isRoot
        if (-not $isRoot) { & sudo -n true 2>$null; $sudoAvailable = ($LASTEXITCODE -eq 0) }
        if (-not $sudoAvailable) { Set-ItResult -Skipped -Because 'passwordless sudo is not available'; return }
        $root = New-EntryBundle
        $run = Invoke-Entry -Root $root -Sudo:(-not $isRoot)
        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Result.terminal | Should -Be 'plan-ok'
        Test-Path -LiteralPath (Join-Path $root 'imported.marker') | Should -BeTrue
    }
}

Describe 'Install-CloudGrange.ps1 on a non-Linux platform' -Skip:$IsLinux {
    It 'refuses unsupported-platform before anything else' {
        $root = New-TestDirectory -Prefix 'cg-entry'
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'installer/Install-CloudGrange.ps1') -Destination $root
        $child = Invoke-ChildPwsh -ScriptPath (Join-Path $root 'Install-CloudGrange.ps1') -Arguments @('-Mode', 'Plan', '-SiteConfig', 'site.json')
        $child.ExitCode | Should -Be 2
        (ConvertFrom-LastJsonLine $child.Output).reasonCode | Should -Be 'unsupported-platform'
    }
}
