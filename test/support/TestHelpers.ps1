#Requires -Version 7.4
<#
.SYNOPSIS
    Shared helpers for the installer Pester suites (test/unit) and their child-process scripts.
.DESCRIPTION
    Dot-source inside BeforeAll (or at the top of a child script). Variables are plain assignments so
    they are visible to It blocks. Test directories are created under $TestDrive when Pester provides
    it (auto-removed), otherwise under the system temp directory.
.NOTES
    TaskReference: AB#8129 AB#9015 AB#9016
#>
Set-StrictMode -Version Latest

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$ModuleManifest = Join-Path $RepoRoot 'installer/modules/CloudGrange.Installer/CloudGrange.Installer.psd1'
$SupportRoot = $PSScriptRoot
$ValidBomPath = Join-Path $RepoRoot 'schemas/fixtures/release-bom.valid.json'

function Get-PwshPath {
    return (Get-Process -Id $PID).Path
}

function New-TestDirectory {
    param([string]$Prefix = 'cg')
    $base = if (Test-Path -LiteralPath 'variable:TestDrive') { (Get-Variable -Name TestDrive -ValueOnly) } else { [IO.Path]::GetTempPath() }
    $path = Join-Path $base ($Prefix + '-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $path -Force
    return $path
}

function Get-TestFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TestBytesSha256 {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function New-TestCheckpointState {
    param([Parameter(Mandatory)][string]$InstallId, [string]$Phase = 'preflight', [string]$PhaseState = 'started', [int]$Attempt = 1, [string]$RequestSha256 = ('a' * 64))
    $phases = [ordered]@{}
    $phases[$Phase] = [ordered]@{ state = $PhaseState; startedUtc = '2026-09-13T00:00:00.000Z' }
    return [ordered]@{
        installId = $InstallId; mode = 'Install'; requestSha256 = $RequestSha256; compositionSha256 = ('e' * 64); bomSha256 = ('b' * 64); catalogPayloadSha256 = ('c' * 64)
        productVersion = '0.1.0-m0.rc1'; attempt = $Attempt; phase = $Phase; phaseState = $PhaseState; phases = $phases
    }
}

function Get-StateSnapshot {
    <# JSON of name -> sha256 for every file directly in a directory, for "nothing modified" assertions. #>
    param([Parameter(Mandatory)][string]$Directory)
    $snapshot = [ordered]@{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -File -Force | Sort-Object Name)) { $snapshot[$file.Name] = Get-TestFileSha256 $file.FullName }
    return ($snapshot | ConvertTo-Json -Compress)
}

function Set-TestFaultHook {
    <# In-process cut: throws at the named fault point (state inspection only; crash tests use child processes). #>
    param([string]$Point)
    $module = Get-Module CloudGrange.Installer
    if ($Point) {
        & $module { param($p) $script:CgFaultHook = { param($name) if ($name -ceq $p) { throw ('simulated-cut:' + $name) } }.GetNewClosure() } $Point
    } else {
        & $module { $script:CgFaultHook = $null }
    }
}

function Invoke-ChildPwsh {
    param([Parameter(Mandatory)][string]$ScriptPath, [string[]]$Arguments = @(), [switch]$Sudo)
    $pwsh = Get-PwshPath
    if ($Sudo) { $output = & sudo -n $pwsh -NoProfile -NonInteractive -File $ScriptPath @Arguments 2>&1 }
    else { $output = & $pwsh -NoProfile -NonInteractive -File $ScriptPath @Arguments 2>&1 }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (@($output | ForEach-Object { [string]$_ }) -join "`n") }
}

function ConvertFrom-LastJsonLine {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $line = @($Text -split "`n" | Where-Object { $_.Trim().StartsWith('{') }) | Select-Object -Last 1
    if (-not $line) { throw ('No JSON result line in output: ' + $Text) }
    return ($line | ConvertFrom-Json)
}

function Write-TestJsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$InputObject)
    [IO.File]::WriteAllBytes($Path, [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $InputObject -Depth 32) + "`n"))
}

function Edit-TestCheckpointFile {
    <# Parses a checkpoint file strictly, applies -Mutate to the dictionary and rewrites it. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][scriptblock]$Mutate)
    $document = (ConvertFrom-CgStrictJson -Bytes ([IO.File]::ReadAllBytes($Path))).Value
    & $Mutate $document
    Write-TestJsonFile -Path $Path -InputObject $document
}
