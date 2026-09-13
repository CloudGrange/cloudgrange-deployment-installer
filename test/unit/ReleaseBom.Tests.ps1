#Requires -Version 7.4
<#
.SYNOPSIS
    Release BOM validator: valid fixture, strict parsing, site-config schema binding, every legacy and
    semantic fixture case, rule-catalog coverage, version precedence and the CLI.
.NOTES
    TaskReference: AB#8129 AB#9016
#>

BeforeDiscovery {
    $fixtureRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../schemas/fixtures'))
    $legacyCases = @(ConvertFrom-Json (Get-Content -LiteralPath (Join-Path $fixtureRoot 'release-bom.invalid-cases.json') -Raw) -AsHashtable -Depth 32)
    $semanticCases = @(ConvertFrom-Json (Get-Content -LiteralPath (Join-Path $fixtureRoot 'release-bom.semantic-cases.json') -Raw) -AsHashtable -Depth 32)
}

BeforeAll {
    . (Join-Path $PSScriptRoot '../support/TestHelpers.ps1')
    . (Join-Path $SupportRoot 'FixturePatch.ps1')
    Import-Module $ModuleManifest -Force
    $validText = Get-Content -LiteralPath $ValidBomPath -Raw
    $semanticCasesPath = Join-Path $RepoRoot 'schemas/fixtures/release-bom.semantic-cases.json'
    $pesterCoveredCodes = @('bom-unreadable', 'invalid-json', 'json-duplicate-key', 'bom-too-large', 'schema-violation',
        'configuration-schema-unreadable', 'configuration-schema-digest-mismatch', 'configuration-schema-identity-mismatch')

    function Test-BomText {
        param([Parameter(Mandatory)][string]$Json, [string]$ConfigurationSchemaPath)
        $arguments = @{ Bytes = [Text.UTF8Encoding]::new($false).GetBytes($Json) }
        if ($ConfigurationSchemaPath) { $arguments.ConfigurationSchemaPath = $ConfigurationSchemaPath }
        return Test-CgReleaseBom @arguments
    }

    function New-BoundSchemaFixture {
        <# Writes a site-config schema file and returns BOM JSON whose configurationSchema.sha256 matches it. #>
        param([string]$Id = 'https://cloudgrange.cloud/schemas/cg-site-config-v1.schema.json', [string]$Kind = 'CloudGrangeSiteConfig', [int]$SchemaVersion = 1)
        $directory = New-TestDirectory -Prefix 'cg-bom'
        $schemaPath = Join-Path $directory 'site-config-v1.schema.json'
        Write-TestJsonFile -Path $schemaPath -InputObject ([ordered]@{
                '$schema' = 'https://json-schema.org/draft/2020-12/schema'; '$id' = $Id
                properties = [ordered]@{ schema_version = @{ const = $SchemaVersion }; kind = @{ const = $Kind } }
            })
        $bom = ConvertFrom-Json $validText -AsHashtable -Depth 32
        $bom['configurationSchema']['sha256'] = Get-TestFileSha256 $schemaPath
        return [pscustomobject]@{ SchemaPath = $schemaPath; Json = (ConvertTo-Json -InputObject $bom -Depth 32) }
    }
}

Describe 'Valid release BOM' {
    It 'accepts the valid fixture with no findings' {
        $result = Test-CgReleaseBom -Path $ValidBomPath
        $result.passed | Should -BeTrue -Because ($result.codes -join ',')
        $result.schemaAccepted | Should -BeTrue
        @($result.errors).Count | Should -Be 0
        $result.sha256 | Should -Be (Get-TestFileSha256 $ValidBomPath)
    }
}

Describe 'Site-config schema binding (schemaId, kind, schemaVersion, digest)' {
    It 'accepts a schema file whose digest and identity match' {
        $fixture = New-BoundSchemaFixture
        $result = Test-BomText -Json $fixture.Json -ConfigurationSchemaPath $fixture.SchemaPath
        $result.passed | Should -BeTrue -Because ($result.codes -join ',')
    }

    It 'rejects schema bytes that do not hash to configurationSchema.sha256' {
        $fixture = New-BoundSchemaFixture
        Add-Content -LiteralPath $fixture.SchemaPath -Value ' '
        (Test-BomText -Json $fixture.Json -ConfigurationSchemaPath $fixture.SchemaPath).codes | Should -Contain 'configuration-schema-digest-mismatch'
    }

    It 'rejects a schema file with <Name>' -ForEach @(
        @{ Name = 'another $id'; Arguments = @{ Id = 'https://cloudgrange.cloud/schemas/cg-site-config-v2.schema.json' } }
        @{ Name = 'another kind const'; Arguments = @{ Kind = 'CloudGrangeTopology' } }
        @{ Name = 'another schema_version const'; Arguments = @{ SchemaVersion = 2 } }
    ) {
        $fixture = New-BoundSchemaFixture @Arguments
        $result = Test-BomText -Json $fixture.Json -ConfigurationSchemaPath $fixture.SchemaPath
        $result.codes | Should -Contain 'configuration-schema-identity-mismatch'
        $result.codes | Should -Not -Contain 'configuration-schema-digest-mismatch'
    }

    It 'reports a missing schema file' {
        (Test-CgReleaseBom -Path $ValidBomPath -ConfigurationSchemaPath (Join-Path (New-TestDirectory) 'absent.json')).codes | Should -Contain 'configuration-schema-unreadable'
    }
}

Describe 'Strict parsing' {
    It 'reports bom-unreadable for a missing file' {
        (Test-CgReleaseBom -Path (Join-Path (New-TestDirectory) 'absent.json')).codes | Should -Be @('bom-unreadable')
    }

    It 'rejects <Name>' -ForEach @(
        @{ Name = 'a duplicate property'; Mutate = { param($t) $t.Replace('"channel": "m0-fixture",', '"channel": "m0-fixture", "channel": "m0-internal",') }; Code = 'json-duplicate-key' }
        @{ Name = 'properties differing only in case'; Mutate = { param($t) $t.Replace('"channel": "m0-fixture",', '"channel": "m0-fixture", "Channel": "m0-fixture",') }; Code = 'json-duplicate-key' }
        @{ Name = 'truncated JSON'; Mutate = { param($t) $t.Substring(0, 200) }; Code = 'invalid-json' }
        @{ Name = 'a comment'; Mutate = { param($t) '// c' + "`n" + $t }; Code = 'invalid-json' }
        @{ Name = 'a non-object root'; Mutate = { param($t) '[' + $t + ']' }; Code = 'bom-shape-invalid' }
    ) {
        $result = Test-BomText -Json (& $Mutate $validText)
        $result.passed | Should -BeFalse
        $result.codes | Should -Contain $Code
    }

    It 'rejects a UTF-8 byte order mark' {
        $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.UTF8Encoding]::new($false).GetBytes($validText))
        (Test-CgReleaseBom -Bytes $bytes).codes | Should -Be @('invalid-json')
    }

    It 'rejects invalid UTF-8' {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($validText)
        $bytes[20] = 0xFF
        (Test-CgReleaseBom -Bytes $bytes).codes | Should -Be @('invalid-json')
    }

    It 'rejects documents larger than 1 MiB' {
        (Test-BomText -Json ($validText + (' ' * 1048576))).codes | Should -Be @('bom-too-large')
    }

    It 'reports schema-violation alongside rule codes for a structurally invalid document' {
        $case = @{ id = 'x'; patches = @(@{ op = 'set'; path = '/members/6/retrieval/reference'; value = 'ghcr.io/cloudgrange/api:latest' }) }
        $result = Test-BomText -Json (Get-PatchedFixtureJson -ValidText $validText -Case $case)
        $result.schemaAccepted | Should -BeFalse
        $result.codes | Should -Contain 'schema-violation'
        $result.codes | Should -Contain 'oci-reference-not-digest-pinned'
    }
}

Describe 'Legacy WP-00 fixture cases' {
    It '<id> is rejected (<expected>)' -ForEach $legacyCases {
        $result = Test-BomText -Json (Get-PatchedFixtureJson -ValidText $validText -Case $_)
        $result.passed | Should -BeFalse
        if ($_['expected'] -eq 'schema') {
            $result.schemaAccepted | Should -BeFalse
        } else {
            $result.schemaAccepted | Should -BeTrue
            @($result.codes | Where-Object { $_ -ne 'schema-violation' }).Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'Semantic fixture cases' {
    It '<id> is rejected with <expectedCode>' -ForEach $semanticCases {
        $result = Test-BomText -Json (Get-PatchedFixtureJson -ValidText $validText -Case $_)
        $result.passed | Should -BeFalse
        $result.codes | Should -Contain $_['expectedCode']
        if ($_.ContainsKey('schemaAccepts')) { $result.schemaAccepted | Should -Be ([bool]$_['schemaAccepts']) }
    }
}

Describe 'Rule catalog coverage' {
    It 'exercises every rule code through a semantic fixture case or a unit test in this file' {
        $cases = @(ConvertFrom-Json (Get-Content -LiteralPath $semanticCasesPath -Raw) -AsHashtable -Depth 32)
        $exercised = @($cases | ForEach-Object { $_['expectedCode'] }) + $pesterCoveredCodes
        $catalog = Get-CgReleaseBomRuleCatalog
        @($catalog.Keys | Where-Object { $exercised -cnotcontains $_ }) | Should -BeNullOrEmpty
        @($exercised | Where-Object { -not $catalog.Contains($_) }) | Should -BeNullOrEmpty
    }
}

Describe 'Compare-CgProductVersion (SemVer precedence)' {
    It '<Left> vs <Right> is <Expected>' -ForEach @(
        @{ Left = '0.1.0'; Right = '0.1.0'; Expected = 0 }
        @{ Left = '0.1.0-m0.rc1'; Right = '0.1.0'; Expected = -1 }
        @{ Left = '0.1.0-m0.rc2'; Right = '0.1.0-m0.rc1'; Expected = 1 }
        @{ Left = '0.1.0-m0.rc10'; Right = '0.1.0-m0.rc9'; Expected = -1 }
        @{ Left = '1.0.0-1'; Right = '1.0.0-alpha'; Expected = -1 }
        @{ Left = '1.0.0-alpha'; Right = '1.0.0-alpha.1'; Expected = -1 }
        @{ Left = '1.0.0-alpha.10'; Right = '1.0.0-alpha.9'; Expected = 1 }
        @{ Left = '10.0.0'; Right = '9.99.99'; Expected = 1 }
    ) {
        Compare-CgProductVersion -Left $Left -Right $Right | Should -Be $Expected
    }
}

Describe 'Test-CgReleaseBom.ps1 CLI' {
    It 'exits 0 for the valid fixture and 1 for a rejected BOM' {
        $cli = Join-Path $RepoRoot 'installer/Test-CgReleaseBom.ps1'
        $ok = Invoke-ChildPwsh -ScriptPath $cli -Arguments @('-Path', $ValidBomPath)
        $ok.ExitCode | Should -Be 0 -Because $ok.Output
        $badPath = Join-Path (New-TestDirectory) 'bad.json'
        [IO.File]::WriteAllText($badPath, $validText.Replace('"releaseTag": "v0.1.0-m0.rc1"', '"releaseTag": "latest"'))
        $bad = Invoke-ChildPwsh -ScriptPath $cli -Arguments @('-Path', $badPath)
        $bad.ExitCode | Should -Be 1 -Because $bad.Output
        $bad.Output | Should -Match 'release-tag-version-mismatch|schema-violation'
    }
}
