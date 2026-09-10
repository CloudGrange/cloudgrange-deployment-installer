#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'Invoke-CompactRke2Experiment.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors){throw 'Experiment does not parse.'}
$assignment=$ast.Find({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$freeData'},$true)
$guard=$ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.StartsWith('if ([long]$freeData -lt 100GB)')},$true)
if(-not $assignment -or -not $guard){throw 'Actual disk-space parsing/guard was not found.'}
# Substitute only native df output; execute the actual production expression and
# predicate. Advanced parameter binding reproduces a misplaced -split argument.
function Invoke-ExperimentNative {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Command,[string[]]$Arguments)
    if($Command -cne 'df' -or $Arguments.Count -ne 3 -or $Arguments[0] -cne '-B1' -or
        $Arguments[1] -cne '--output=avail' -or $Arguments[2] -cne '/var/lib/rancher') { throw 'Unexpected df invocation.' }
    return $dfOutput
}
$config=@{data_mount='/var/lib/rancher'}
$cases=[Collections.Generic.List[object]]::new()
foreach($lineEnding in @("`n","`r`n")) {
    $dfOutput='       Avail'+$lineEnding+'107374182400'
    . ([scriptblock]::Create($assignment.Extent.Text))
    if([long]$freeData -ne 100GB){throw 'df available-byte value was not parsed.'}
    . ([scriptblock]::Create($guard.Extent.Text))
    $cases.Add(@{case=if($lineEnding.Length -eq 1){'LF native output'}else{'CRLF native output'};passed=$true})
}
$dfOutput="       Avail`n107374182399"
. ([scriptblock]::Create($assignment.Extent.Text))
$rejected=$false
try { . ([scriptblock]::Create($guard.Extent.Text)) } catch {
    if($_.Exception.Message -notlike 'Experiment data volume needs*'){throw}
    $rejected=$true
}
if(-not $rejected){throw 'Insufficient data space was accepted.'}
$cases.Add(@{case='Below100GiB rejected';passed=$true})
$directory=Join-Path $EvidenceDirectory ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory -Force|Out-Null
$cases|ConvertTo-Json|Set-Content (Join-Path $directory 'results.json')
Write-Output ('Three actual preflight expression cases passed. Evidence: '+$directory)
