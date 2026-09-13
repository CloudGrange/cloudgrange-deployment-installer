#Requires -Version 7.4
<#
.SYNOPSIS
    Child process that holds install.lock until a release file appears (or 120 s pass).
.PARAMETER ModuleManifest
    CloudGrange.Installer.psd1 path.
.PARAMETER StateDirectory
    State directory whose install.lock is held.
.PARAMETER SignalDirectory
    Directory for the "ready" and "release" signal files.
.NOTES
    TaskReference: AB#8129 AB#9015
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ModuleManifest,
    [Parameter(Mandatory)][string]$StateDirectory,
    [Parameter(Mandatory)][string]$SignalDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module $ModuleManifest -Force
$lock = Enter-CgInstallLock -StateDirectory $StateDirectory
try {
    Set-Content -LiteralPath (Join-Path $SignalDirectory 'ready') -Value $PID
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    while (-not (Test-Path -LiteralPath (Join-Path $SignalDirectory 'release')) -and [DateTime]::UtcNow -lt $deadline) {
        [Threading.Thread]::Sleep(100)
    }
} finally {
    Exit-CgInstallLock -Lock $lock
}
exit 0
