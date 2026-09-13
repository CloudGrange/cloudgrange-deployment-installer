#Requires -Version 7.4
<#
.SYNOPSIS
    Runs the installer Pester 5 suites under test/unit and retains JUnit results plus a summary.
.DESCRIPTION
    Fails when any test or container fails. With -RequireNoSkipped (CI on Linux) a skipped test also
    fails the run, so platform-gated tests (hard links, fsync, flock, entry script as root) cannot
    silently stop running.
.PARAMETER EvidenceDirectory
    Fresh directory for pester-junit.xml and pester-summary.json.
.PARAMETER RequireNoSkipped
    Treat skipped tests as a failure.
.NOTES
    TaskReference: AB#8129 AB#9015 AB#9016
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceDirectory, [switch]$RequireNoSkipped)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $EvidenceDirectory) { throw 'Use a fresh Pester evidence directory.' }
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
Import-Module Pester -RequiredVersion 5.7.1 -Force

$configuration = New-PesterConfiguration
$configuration.Run.Path = @(Join-Path $PSScriptRoot 'unit')
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputFormat = 'JUnitXml'
$configuration.TestResult.OutputPath = Join-Path $EvidenceDirectory 'pester-junit.xml'
$run = Invoke-Pester -Configuration $configuration

$summary = [ordered]@{
    schema_version = 1
    platform = [Runtime.InteropServices.RuntimeInformation]::OSDescription
    powershell = $PSVersionTable.PSVersion.ToString()
    result = [string]$run.Result
    total = $run.TotalCount
    passed = $run.PassedCount
    failed = $run.FailedCount
    skipped = $run.SkippedCount
    not_run = $run.NotRunCount
    failed_containers = @($run.Containers | Where-Object { $_.Result -ne 'Passed' } | ForEach-Object { [string]$_.Item })
    failed_tests = @($run.Failed | ForEach-Object { $_.ExpandedPath })
    skipped_tests = @($run.Skipped | ForEach-Object { $_.ExpandedPath })
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'pester-summary.json')
if ($run.Result -ne 'Passed' -or $run.FailedCount -gt 0) { throw ('Pester failed: ' + $run.FailedCount + ' failed test(s); inspect retained results.') }
if ($RequireNoSkipped -and $run.SkippedCount -gt 0) { throw ('Pester skipped ' + $run.SkippedCount + ' test(s) where none may be skipped: ' + ($summary.skipped_tests -join '; ')) }
[pscustomobject]$summary
