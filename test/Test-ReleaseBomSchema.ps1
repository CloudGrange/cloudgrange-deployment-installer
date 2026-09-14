#Requires -Version 7.4
<#
.SYNOPSIS
    Qualify schemas/release-bom.schema.json and the WP-02 validator against their fixtures.
.DESCRIPTION
    1. schemas/fixtures/release-bom.valid.json must pass the schema and every semantic rule.
    2. Every case in schemas/fixtures/release-bom.invalid-cases.json must be rejected: "schema" cases
       must fail JSON Schema validation; "semantic" cases must pass the schema and fail the semantic
       rules (Get-CgReleaseBomViolation in the CloudGrange.Installer module).
    3. Every case in schemas/fixtures/release-bom.semantic-cases.json must be rejected by
       Test-CgReleaseBom with its exact expectedCode, independent of the schema engine; when
       schemaAccepts is given, the schema result must equal it (documents where only the rule layer
       catches the defect).
    4. Every rule code in Get-CgReleaseBomRuleCatalog must be exercised by a semantic case or be one
       of the parser/binding codes covered by test/unit/ReleaseBom.Tests.ps1.
    It proves the schema, rules and fixtures only, never a release.
.PARAMETER EvidenceDirectory
    Fresh directory for release-bom-schema.json.
.NOTES
    TaskReference: AB#8129 AB#9016
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$schemaPath = Join-Path $root 'schemas/release-bom.schema.json'
$validPath = Join-Path $root 'schemas/fixtures/release-bom.valid.json'
$casesPath = Join-Path $root 'schemas/fixtures/release-bom.invalid-cases.json'
$semanticCasesPath = Join-Path $root 'schemas/fixtures/release-bom.semantic-cases.json'
Import-Module (Join-Path $root 'installer/modules/CloudGrange.Installer/CloudGrange.Installer.psd1') -Force
. (Join-Path $PSScriptRoot 'support/FixturePatch.ps1')
# Codes whose triggers cannot be expressed as a patch of the valid fixture; covered in Pester.
$pesterCoveredCodes = @('bom-unreadable', 'invalid-json', 'json-duplicate-key', 'bom-too-large', 'schema-violation',
    'configuration-schema-unreadable', 'configuration-schema-digest-mismatch', 'configuration-schema-identity-mismatch')

function Test-SchemaAcceptance {
    param([Parameter(Mandatory)][string]$Json)
    try { return [bool](Test-Json -Json $Json -SchemaFile $schemaPath -ErrorAction Stop) } catch { return $false }
}

function Invoke-BomValidation {
    param([Parameter(Mandatory)][string]$Json)
    return Test-CgReleaseBom -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($Json)) -SchemaPath $schemaPath
}

if (Test-Path -LiteralPath $EvidenceDirectory) { throw 'Use a fresh release-bom evidence directory.' }
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$result = [ordered]@{
    schema_version = 2; started_utc = [DateTimeOffset]::UtcNow.ToString('o'); passed = $false
    schema_sha256 = (Get-FileHash -LiteralPath $schemaPath).Hash.ToLowerInvariant()
    valid_fixture_sha256 = (Get-FileHash -LiteralPath $validPath).Hash.ToLowerInvariant()
    cases_sha256 = (Get-FileHash -LiteralPath $casesPath).Hash.ToLowerInvariant()
    semantic_cases_sha256 = (Get-FileHash -LiteralPath $semanticCasesPath).Hash.ToLowerInvariant()
    valid_accepted = $false; case_count = 0; rejected_count = 0; semantic_case_count = 0; semantic_rejected_count = 0
    rule_code_count = 0; uncovered_rule_codes = @(); cases = @(); semantic_cases = @()
}
try {
    $validText = Get-Content -LiteralPath $validPath -Raw
    if (-not (Test-SchemaAcceptance $validText)) { throw 'The valid fixture was rejected by the schema.' }
    $validResult = Invoke-BomValidation $validText
    if (-not $validResult.passed) { throw ('The valid fixture failed validation: ' + ($validResult.codes -join ',')) }
    $result.valid_accepted = $true

    $cases = @(ConvertFrom-Json (Get-Content -LiteralPath $casesPath -Raw) -AsHashtable -Depth 32)
    if ($cases.Count -lt 46) { throw 'Expected at least 46 invalid cases.' }
    $caseResults = foreach ($case in $cases) {
        $json = Get-PatchedFixtureJson -ValidText $validText -Case $case
        $schemaAccepted = Test-SchemaAcceptance $json
        $validation = Invoke-BomValidation $json
        $semanticFailures = @($validation.codes | Where-Object { $_ -ne 'schema-violation' })
        $rejected = switch ($case['expected']) {
            'schema' { -not $schemaAccepted -and -not $validation.passed }
            'semantic' { $schemaAccepted -and $semanticFailures.Count -gt 0 }
            default { throw ('Unknown expectation in case ' + $case['id']) }
        }
        [ordered]@{ id = $case['id']; expected = $case['expected']; schema_accepted = $schemaAccepted; semantic_failures = $semanticFailures; rejected = $rejected }
    }
    $result.cases = @($caseResults)
    $result.case_count = $cases.Count
    $result.rejected_count = @($caseResults | Where-Object rejected).Count
    $unexpected = @($caseResults | Where-Object { -not $_.rejected })
    if ($unexpected.Count) { throw ('Cases unexpectedly accepted: ' + (($unexpected | ForEach-Object id) -join ',')) }

    $semanticCases = @(ConvertFrom-Json (Get-Content -LiteralPath $semanticCasesPath -Raw) -AsHashtable -Depth 32)
    $catalog = Get-CgReleaseBomRuleCatalog
    $semanticResults = foreach ($case in $semanticCases) {
        if (-not $catalog.Contains($case['expectedCode'])) { throw ('Semantic case ' + $case['id'] + ' names an unknown code.') }
        $json = Get-PatchedFixtureJson -ValidText $validText -Case $case
        $validation = Invoke-BomValidation $json
        $schemaMatches = if ($case.ContainsKey('schemaAccepts')) { $validation.schemaAccepted -eq [bool]$case['schemaAccepts'] } else { $true }
        $codeFound = @($validation.codes) -ccontains $case['expectedCode']
        [ordered]@{
            id = $case['id']; expected_code = $case['expectedCode']; codes = @($validation.codes); schema_accepted = $validation.schemaAccepted
            schema_expectation_met = $schemaMatches; rejected = (-not $validation.passed -and $codeFound -and $schemaMatches)
        }
    }
    $result.semantic_cases = @($semanticResults)
    $result.semantic_case_count = $semanticCases.Count
    $result.semantic_rejected_count = @($semanticResults | Where-Object rejected).Count
    $failedSemantic = @($semanticResults | Where-Object { -not $_.rejected })
    if ($failedSemantic.Count) { throw ('Semantic cases not rejected with their expected code: ' + (($failedSemantic | ForEach-Object id) -join ',')) }

    $exercised = @($semanticCases | ForEach-Object { $_['expectedCode'] }) + $pesterCoveredCodes
    $result.rule_code_count = $catalog.Count
    $result.uncovered_rule_codes = @($catalog.Keys | Where-Object { $exercised -cnotcontains $_ })
    if ($result.uncovered_rule_codes.Count) { throw ('Rule codes without a fixture: ' + ($result.uncovered_rule_codes -join ',')) }
    $result.passed = $true
} catch {
    $result.failure = $_.Exception.Message
    throw
} finally {
    $result.completed_utc = [DateTimeOffset]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $EvidenceDirectory 'release-bom-schema.json')
}
[pscustomobject]@{ passed = $result.passed; case_count = $result.case_count; rejected_count = $result.rejected_count; semantic_case_count = $result.semantic_case_count; rule_code_count = $result.rule_code_count }
