#Requires -Version 7.4
<#
.SYNOPSIS
    Child process for crash-cut tests: writes one checkpoint and exits with 137 at the named fault point.
.DESCRIPTION
    Exit 137 means the process died at the cut (simulated SIGKILL); exit 0 means the cut was never
    reached, which the calling test treats as a failure.
.PARAMETER ModuleManifest
    CloudGrange.Installer.psd1 path.
.PARAMETER StateDirectory
    State directory holding the checkpoint chain.
.PARAMETER InstallId
    installId of the chain.
.PARAMETER FaultPoint
    checkpoint-step2-partial | checkpoint-step2-fsynced | checkpoint-step3-prev-unlinked |
    checkpoint-step3-linked | checkpoint-step4-renamed | checkpoint-step5-synced
.NOTES
    TaskReference: AB#8129 AB#9015
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ModuleManifest,
    [Parameter(Mandatory)][string]$StateDirectory,
    [Parameter(Mandatory)][string]$InstallId,
    [Parameter(Mandatory)][string]$FaultPoint
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module $ModuleManifest -Force
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$module = Get-Module CloudGrange.Installer
& $module { param($point) $script:CgFaultHook = { param($name) if ($name -ceq $point) { [Environment]::Exit(137) } }.GetNewClosure() } $FaultPoint
$null = Write-CgCheckpoint -StateDirectory $StateDirectory -State (New-TestCheckpointState -InstallId $InstallId -Phase 'retrieve' -PhaseState 'started')
exit 0
