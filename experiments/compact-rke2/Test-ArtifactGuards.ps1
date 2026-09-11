#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'Invoke-CompactRke2Experiment.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors) { throw 'Experiment does not parse.' }
$definition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-ExperimentArtifacts'},$true)
# Run the actual pre-install validator without invoking any Linux mutation.
. ([scriptblock]::Create($definition.Extent.Text))
$fixture = Join-Path $EvidenceDirectory ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$manifest = Get-Content (Join-Path $PSScriptRoot 'artifacts.json') -Raw | ConvertFrom-Json
foreach ($artifact in $manifest.artifacts) {
    $path = Join-Path $fixture $artifact.name
    [IO.File]::WriteAllBytes($path,[byte[]](1,2,3,4))
    $artifact.bytes = 4
    $artifact.sha256 = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
}
Test-ExperimentArtifacts $manifest $fixture
$cases = [Collections.Generic.List[object]]::new()
$cases.Add(@{case='Complete unchanged fixture accepted';passed=$true})
foreach ($change in @('same-size tampering','truncation','missing artifact','path escape','wrong runtime')) {
    $candidate = $manifest | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $firstPath = Join-Path $fixture $candidate.artifacts[0].name
    [IO.File]::WriteAllBytes($firstPath,[byte[]](1,2,3,4))
    switch ($change) {
        'same-size tampering' { [IO.File]::WriteAllBytes($firstPath,[byte[]](1,2,3,5)) }
        'truncation' { [IO.File]::WriteAllBytes($firstPath,[byte[]](1,2,3)) }
        'missing artifact' { Remove-Item -LiteralPath $firstPath }
        'path escape' { $candidate.artifacts[0].name = '../outside.tar.gz' }
        'wrong runtime' { $candidate.rke2_version = 'v0.0.0' }
    }
    $rejected = $false
    try { Test-ExperimentArtifacts $candidate $fixture } catch {
        if ($_.Exception.Message -notmatch '^(Artifact content rejected|Unexpected artifact set|Unsupported experiment manifest)') { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw ('Changed artifact was accepted: '+$change) }
    $cases.Add(@{case=$change;passed=$true})
}
$cases | ConvertTo-Json | Set-Content (Join-Path $fixture 'results.json')
Write-Output ('Six actual pre-install artifact guard cases passed. Evidence: '+$fixture)
