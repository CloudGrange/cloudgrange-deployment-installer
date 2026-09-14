#Requires -Version 7.4
<#
.SYNOPSIS
    Child process for engine crash tests: runs Install with fake phases and dies (exit 137) inside -CrashPhase
    after that phase records -CrashSubState.
.PARAMETER ModuleManifest
    CloudGrange.Installer.psd1 path.
.PARAMETER StateDirectory
    State directory.
.PARAMETER LogPath
    Fake phase call log.
.PARAMETER CrashPhase
    Phase to crash in.
.PARAMETER CrashSubState
    Sub-state checkpointed immediately before the crash.
.NOTES
    TaskReference: AB#8129 AB#9015
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ModuleManifest,
    [Parameter(Mandatory)][string]$StateDirectory,
    [Parameter(Mandatory)][string]$LogPath,
    [Parameter(Mandatory)][string]$CrashPhase,
    [Parameter(Mandatory)][string]$CrashSubState
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module $ModuleManifest -Force
. (Join-Path $PSScriptRoot 'FakePhases.ps1')
$registry = New-FakePhaseRegistry -LogPath $LogPath -CrashPhase $CrashPhase -CrashSubState $CrashSubState
$null = Invoke-CgInstallerRun -StateDirectory $StateDirectory -RequestSha256 ('a' * 64) -CompositionSha256 ('e' * 64) -BomSha256 ('b' * 64) -CatalogPayloadSha256 ('c' * 64) `
    -ProductVersion '0.1.0-m0.rc1' -Registry $registry -Redactor { param([string]$Text) $Text }
exit 0
