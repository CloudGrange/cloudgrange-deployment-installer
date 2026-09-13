#Requires -Version 7.0
<#
.SYNOPSIS
    Qualify schemas/release-bom.schema.json against its fixtures.
.DESCRIPTION
    Validates schemas/fixtures/release-bom.valid.json against the closed cg-release-bom-v1
    schema, applies every case in schemas/fixtures/release-bom.invalid-cases.json and requires
    each to be rejected. Cases marked "schema" must fail JSON Schema validation; cases marked
    "semantic" pass the schema and must fail the checks JSON Schema cannot express (unique ids,
    resolvable acyclic dependsOn, phase ordering, digest agreement between sha256 and OCI
    references, unique artifact digests). This is the WP-02 starting point for
    Test-CgReleaseBom; it proves the schema and fixtures only, never a release.
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
$phaseOrder = @('preflight','retrieve','runtime','storage','postgres','vault','identity','migrate','api','portal','gateway','module','handoff')

function Test-SchemaAcceptance {
    param([Parameter(Mandatory)][string]$Json)
    try { return [bool](Test-Json -Json $Json -SchemaFile $schemaPath -ErrorAction Stop) } catch { return $false }
}

function Get-DigestFromReference {
    param([Parameter(Mandatory)][string]$Reference)
    $match = [regex]::Match($Reference, '@sha256:([0-9a-f]{64})$')
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value
}

function Test-BomSemantic {
    # Returns stable failure codes; no output means the semantic checks passed. Callers wrap in @().
    param([Parameter(Mandatory)][hashtable]$Bom)
    $failures = [Collections.Generic.List[string]]::new()
    $members = @($Bom['members'])
    $ids = @{}
    $digests = @{}
    foreach ($member in $members) {
        if ($ids.ContainsKey($member['id'])) { $failures.Add('duplicate-member-id') } else { $ids[$member['id']] = $member }
        if ($digests.ContainsKey($member['sha256'])) { $failures.Add('duplicate-artifact-digest') } else { $digests[$member['sha256']] = $member['id'] }
        $retrieval = $member['retrieval']
        if ($retrieval['type'] -eq 'oci') {
            if ((Get-DigestFromReference $retrieval['reference']) -ne $member['sha256']) { $failures.Add('oci-reference-digest-mismatch') }
            if ($retrieval.ContainsKey('mirrorOf') -and (Get-DigestFromReference $retrieval['mirrorOf']) -ne $member['sha256']) { $failures.Add('mirror-digest-mismatch') }
        }
    }
    foreach ($member in $members) {
        foreach ($dependency in @($member['dependsOn'])) {
            if (-not $ids.ContainsKey($dependency)) { $failures.Add('dangling-depends-on'); continue }
            if ($dependency -eq $member['id']) { $failures.Add('self-dependency'); continue }
            if ([array]::IndexOf($phaseOrder, $ids[$dependency]['phase']) -gt [array]::IndexOf($phaseOrder, $member['phase'])) { $failures.Add('depends-on-later-phase') }
        }
    }
    # Cycle detection by depth-first search over resolvable edges.
    $state = @{}
    function Test-MemberCycle {
        param([string]$Id)
        if (-not $ids.ContainsKey($Id)) { return $false }
        if ($state[$Id] -eq 'active') { return $true }
        if ($state[$Id] -eq 'done') { return $false }
        $state[$Id] = 'active'
        foreach ($dependency in @($ids[$Id]['dependsOn'])) { if (Test-MemberCycle $dependency) { return $true } }
        $state[$Id] = 'done'
        return $false
    }
    foreach ($id in @($ids.Keys)) { if (Test-MemberCycle $id) { $failures.Add('dependency-cycle'); break } }
    $failures | Select-Object -Unique
}

function Edit-FixtureNode {
    # Minimal JSON-pointer patching over ConvertFrom-Json -AsHashtable output. Object keys and
    # array indexes are supported for "set"; "remove" applies to object keys only.
    param([Parameter(Mandatory)][hashtable]$Root, [Parameter(Mandatory)][string]$Pointer, $Value, [switch]$Remove)
    $parts = @($Pointer.TrimStart('/') -split '/')
    $node = $Root
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $part = $parts[$i]
        if ($node -is [Collections.IList]) { $node = $node[[int]$part] } else { $node = $node[$part] }
        if ($null -eq $node) { throw ('Fixture path does not resolve: ' + $Pointer) }
    }
    $leaf = $parts[-1]
    if ($node -is [Collections.IList]) {
        if ($Remove) { throw 'Array element removal is not supported by this fixture format.' }
        $node[[int]$leaf] = $Value
    } elseif ($Remove) {
        if (-not $node.ContainsKey($leaf)) { throw ('Fixture path does not exist for removal: ' + $Pointer) }
        $node.Remove($leaf)
    } else {
        $node[$leaf] = $Value
    }
}

if (Test-Path -LiteralPath $EvidenceDirectory) { throw 'Use a fresh release-bom evidence directory.' }
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$result = [ordered]@{
    schema_version = 1; started_utc = [DateTimeOffset]::UtcNow.ToString('o'); passed = $false
    schema_sha256 = (Get-FileHash -LiteralPath $schemaPath).Hash.ToLowerInvariant()
    valid_fixture_sha256 = (Get-FileHash -LiteralPath $validPath).Hash.ToLowerInvariant()
    cases_sha256 = (Get-FileHash -LiteralPath $casesPath).Hash.ToLowerInvariant()
    valid_accepted = $false; case_count = 0; rejected_count = 0; cases = @()
}
try {
    $validText = Get-Content -LiteralPath $validPath -Raw
    if (-not (Test-SchemaAcceptance $validText)) { throw 'The valid fixture was rejected by the schema.' }
    $validSemantics = @(Test-BomSemantic -Bom (ConvertFrom-Json $validText -AsHashtable -Depth 32))
    if ($validSemantics.Count) { throw ('The valid fixture failed semantic checks: ' + ($validSemantics -join ',')) }
    $result.valid_accepted = $true

    $cases = @(ConvertFrom-Json (Get-Content -LiteralPath $casesPath -Raw) -AsHashtable -Depth 32)
    if ($cases.Count -lt 40) { throw 'Expected at least 40 invalid cases.' }
    $caseResults = foreach ($case in $cases) {
        $bom = ConvertFrom-Json $validText -AsHashtable -Depth 32
        foreach ($patch in @($case['patches'])) {
            if ($patch['op'] -eq 'set') { Edit-FixtureNode -Root $bom -Pointer $patch['path'] -Value $patch['value'] }
            elseif ($patch['op'] -eq 'remove') { Edit-FixtureNode -Root $bom -Pointer $patch['path'] -Remove }
            else { throw ('Unknown patch op in case ' + $case['id']) }
        }
        $json = ConvertTo-Json -InputObject $bom -Depth 32
        $schemaAccepted = Test-SchemaAcceptance $json
        $semanticFailures = @(if ($schemaAccepted) { Test-BomSemantic -Bom $bom })
        $rejected = switch ($case['expected']) {
            'schema'   { -not $schemaAccepted }
            'semantic' { $schemaAccepted -and $semanticFailures.Count -gt 0 }
            default    { throw ('Unknown expectation in case ' + $case['id']) }
        }
        [ordered]@{ id = $case['id']; expected = $case['expected']; schema_accepted = $schemaAccepted; semantic_failures = @($semanticFailures); rejected = $rejected }
    }
    $result.cases = @($caseResults)
    $result.case_count = $cases.Count
    $result.rejected_count = @($caseResults | Where-Object rejected).Count
    $unexpected = @($caseResults | Where-Object { -not $_.rejected })
    if ($unexpected.Count) { throw ('Cases unexpectedly accepted: ' + (($unexpected | ForEach-Object id) -join ',')) }
    $result.passed = $true
} catch {
    $result.failure = $_.Exception.Message
    throw
} finally {
    $result.completed_utc = [DateTimeOffset]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $EvidenceDirectory 'release-bom-schema.json')
}
[pscustomobject]@{ passed = $result.passed; case_count = $result.case_count; rejected_count = $result.rejected_count }
