#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if(Test-Path -LiteralPath $EvidenceDirectory){throw 'Use a fresh qualification evidence directory.'}
New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
$result=[ordered]@{schema_version=1;started_utc=[DateTimeOffset]::UtcNow.ToString('o');passed=$false;
    source_only=$true;live_runtime_qualified=$false;product_qualified=$false;parser_count=0;analyzer_error_count=0}
try {
    $files=@(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1')
    $manifest=@(foreach($file in $files){
        $tokens=$null;$parseErrors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
        if($parseErrors){throw ('PowerShell parser rejected '+[IO.Path]::GetRelativePath($root,$file.FullName))}
        [ordered]@{path=[IO.Path]::GetRelativePath($root,$file.FullName).Replace('\','/');sha256=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()}
    })
    $result.parser_count=$files.Count
    $manifest|ConvertTo-Json -Depth 4|Set-Content (Join-Path $EvidenceDirectory 'source-manifest.json')
    Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0
    $findings=@(Invoke-ScriptAnalyzer -Path $root -Recurse -Severity Error)
    $result.analyzer_error_count=$findings.Count
    ConvertTo-Json -InputObject @($findings|Select-Object ScriptName,Line,RuleName,Message) -Depth 5|Set-Content (Join-Path $EvidenceDirectory 'analyzer.json')
    if($findings.Count){throw 'PSScriptAnalyzer found errors; inspect retained findings.'}
    & (Join-Path $root 'experiments/compact-rke2/Test-ArtifactGuards.ps1') -EvidenceDirectory (Join-Path $EvidenceDirectory 'artifact-guards')
    & (Join-Path $root 'experiments/compact-rke2/Test-PreflightParsing.ps1') -EvidenceDirectory (Join-Path $EvidenceDirectory 'preflight-parsing')
    $result.artifact_guard_cases=6
    $result.preflight_parsing_cases=3
    $result.passed=$true
} catch {
    $result.failure=$_.Exception.Message
    throw
} finally {
    $result.completed_utc=[DateTimeOffset]::UtcNow.ToString('o')
    $result|ConvertTo-Json -Depth 5|Set-Content (Join-Path $EvidenceDirectory 'results.json')
}
$result|ConvertTo-Json -Depth 5
