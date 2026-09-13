#Requires -Version 7.4
<#
.SYNOPSIS
    Shared primitives for the CloudGrange product installer: stable reason-coded errors, digests,
    strict JSON parsing, durable file writes and the internal fault-injection hook.
.DESCRIPTION
    Dot-sourced by CloudGrange.Installer.psm1. Nothing here touches the network or a runtime.
    Durable writes follow docs/product-installer-design.md §3.2: write, fsync the file, rename,
    fsync the directory. Directory fsync is only possible on Linux (the supported installer
    platform); elsewhere it is skipped and reported so tests can run on developer machines.
.NOTES
    TaskReference: AB#8129 AB#9015
#>
Set-StrictMode -Version Latest

$script:CgZeroSha256 = '0' * 64
$script:CgSha256Pattern = '^[0-9a-f]{64}$'
$script:CgProductVersionPattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9a-z]+(\.[0-9a-z]+)*)?$'
# Test-only fault hook. Never exported and never read from the environment; tests set it through
# the module scope to simulate a crash (process exit) at a named cut point.
$script:CgFaultHook = $null

function New-CgError {
    param([Parameter(Mandatory)][string]$Reason, [Parameter(Mandatory)][string]$Message)
    $exception = [InvalidOperationException]::new($Reason + ': ' + $Message)
    $exception.Data['CgReason'] = $Reason
    return $exception
}

function Get-CgErrorReason {
    param([Parameter(Mandatory)]$ErrorObject)
    $exception = if ($ErrorObject -is [Management.Automation.ErrorRecord]) { $ErrorObject.Exception } else { $ErrorObject }
    while ($null -ne $exception) {
        if ($exception.Data.Contains('CgReason')) { return [string]$exception.Data['CgReason'] }
        $exception = $exception.InnerException
    }
    return 'unexpected-error'
}

function Invoke-CgFaultPoint {
    param([Parameter(Mandatory)][string]$Name)
    if ($null -ne $script:CgFaultHook) { & $script:CgFaultHook $Name }
}

function Get-CgSha256Hex {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function ConvertTo-CgJsonBytes {
    param([Parameter(Mandatory)]$InputObject, [switch]$Compress)
    $text = ConvertTo-Json -InputObject $InputObject -Depth 32 -Compress:$Compress
    return [Text.UTF8Encoding]::new($false).GetBytes($text + "`n")
}

function ConvertFrom-CgJsonElement {
    param([Parameter(Mandatory)][Text.Json.JsonElement]$Element, [Parameter(Mandatory)][AllowEmptyString()][string]$Pointer)
    switch ($Element.ValueKind) {
        'Object' {
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $result = [ordered]@{}
            foreach ($property in $Element.EnumerateObject()) {
                if (-not $names.Add($property.Name)) {
                    throw (New-CgError 'json-duplicate-key' ('Object at ' + $Pointer + ' repeats a property name.'))
                }
                $result[$property.Name] = ConvertFrom-CgJsonElement -Element $property.Value -Pointer ($Pointer + '/' + $property.Name)
            }
            return $result
        }
        'Array' {
            $items = [Collections.Generic.List[object]]::new()
            $index = 0
            foreach ($item in $Element.EnumerateArray()) {
                $items.Add((ConvertFrom-CgJsonElement -Element $item -Pointer ($Pointer + '/' + $index)))
                $index++
            }
            return , $items.ToArray()
        }
        'String' { return $Element.GetString() }
        'Number' {
            [long]$integer = 0
            if ($Element.TryGetInt64([ref]$integer)) { return $integer }
            return $Element.GetDouble()
        }
        'True' { return $true }
        'False' { return $false }
        'Null' { return $null }
        default { throw (New-CgError 'invalid-json' 'Unsupported JSON value.') }
    }
}

function ConvertFrom-CgStrictJson {
    <#
    .SYNOPSIS
        Parses UTF-8 JSON bytes without date coercion, rejecting duplicate (case-insensitive)
        property names, comments, trailing commas and invalid UTF-8.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes, [int]$MaxBytes = 1048576)
    if ($Bytes.Length -eq 0) { throw (New-CgError 'invalid-json' 'Empty document.') }
    if ($Bytes.Length -gt $MaxBytes) { throw (New-CgError 'document-too-large' ('Document exceeds ' + $MaxBytes + ' bytes.')) }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        throw (New-CgError 'invalid-json' 'A byte order mark is not accepted.')
    }
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes) }
    catch { throw (New-CgError 'invalid-json' 'Document is not valid UTF-8.') }
    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 64
    try { $document = [Text.Json.JsonDocument]::Parse($text, $options) }
    catch { throw (New-CgError 'invalid-json' 'Document is not valid JSON.') }
    try {
        $value = ConvertFrom-CgJsonElement -Element $document.RootElement -Pointer ''
    } finally {
        $document.Dispose()
    }
    return [pscustomobject]@{ Text = $text; Value = $value }
}

function Test-CgJsonSchema {
    param([Parameter(Mandatory)][string]$Json, [Parameter(Mandatory)][string]$SchemaPath)
    try { return [bool](Test-Json -Json $Json -SchemaFile $SchemaPath -ErrorAction Stop) } catch { return $false }
}

function Get-CgSchemaPath {
    <#
    .SYNOPSIS
        Resolves a schema file in the install bundle layout (<bundle>/schemas) or the source tree
        (<repo>/schemas).
    #>
    param([Parameter(Mandatory)][string]$FileName)
    $moduleRoot = Split-Path $PSScriptRoot -Parent
    foreach ($relative in @('../../schemas', '../../../schemas')) {
        $candidate = [IO.Path]::GetFullPath((Join-Path (Join-Path $moduleRoot $relative) $FileName))
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw (New-CgError 'schema-missing' ('Schema not found: ' + $FileName))
}

function Sync-CgDirectory {
    <# Returns $true when the directory entry was fsynced, $false when the platform cannot (non-Linux). #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not $IsLinux) { return $false }
    $sync = @('/usr/bin/sync', '/bin/sync') | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $sync) { throw (New-CgError 'fsync-unavailable' 'coreutils sync is required to fsync the state directory.') }
    & $sync -- $Path
    if ($LASTEXITCODE -ne 0) { throw (New-CgError 'fsync-failed' ('Directory fsync failed with exit code ' + $LASTEXITCODE + '.')) }
    return $true
}

function Write-CgFileDurable {
    <# Writes bytes to Path (create/truncate) and fsyncs the file. Emits fault points <prefix>-partial. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes, [string]$FaultPrefix)
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $half = [int][Math]::Floor($Bytes.Length / 2)
        $stream.Write($Bytes, 0, $half)
        $stream.Flush()
        if ($FaultPrefix) { Invoke-CgFaultPoint ($FaultPrefix + '-partial') }
        $stream.Write($Bytes, $half, $Bytes.Length - $half)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function Set-CgOwnerOnlyMode {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][ValidateSet('File0600', 'File0400', 'Directory0700')][string]$Mode)
    if (-not ($IsLinux -or $IsMacOS)) { return }
    $value = switch ($Mode) {
        'File0600' { [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite }
        'File0400' { [IO.UnixFileMode]::UserRead }
        'Directory0700' { [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute }
    }
    [IO.File]::SetUnixFileMode($Path, $value)
}

function Write-CgAtomicFile {
    <# temp → fsync → rename → directory fsync, for files other than the checkpoint chain. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes, [ValidateSet('File0600', 'File0400')][string]$Mode = 'File0600')
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
        Set-CgOwnerOnlyMode -Path $directory -Mode Directory0700
    }
    $temporary = $Path + '.tmp'
    Write-CgFileDurable -Path $temporary -Bytes $Bytes
    Set-CgOwnerOnlyMode -Path $temporary -Mode $Mode
    [IO.File]::Move($temporary, $Path, $true)
    $null = Sync-CgDirectory -Path $directory
}

function Compare-CgProductVersion {
    <# SemVer 2.0 precedence for product versions. Returns -1, 0 or 1. #>
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    foreach ($value in @($Left, $Right)) {
        if (-not [regex]::IsMatch($value, $script:CgProductVersionPattern)) { throw (New-CgError 'version-invalid' 'Not a product version.') }
    }
    $split = {
        param([string]$Version)
        $dash = $Version.IndexOf('-')
        $core = if ($dash -ge 0) { $Version.Substring(0, $dash) } else { $Version }
        $pre = if ($dash -ge 0) { $Version.Substring($dash + 1) } else { '' }
        , @(@($core.Split('.') | ForEach-Object { [Numerics.BigInteger]::Parse($_) }), $pre)
    }
    $a = & $split $Left
    $b = & $split $Right
    for ($i = 0; $i -lt 3; $i++) {
        $c = $a[0][$i].CompareTo($b[0][$i])
        if ($c -ne 0) { return [Math]::Sign($c) }
    }
    if ($a[1] -eq $b[1]) { return 0 }
    if ($a[1] -eq '') { return 1 }
    if ($b[1] -eq '') { return -1 }
    $ai = $a[1].Split('.')
    $bi = $b[1].Split('.')
    for ($i = 0; $i -lt [Math]::Min($ai.Length, $bi.Length); $i++) {
        $an = $ai[$i] -match '^[0-9]+$'
        $bn = $bi[$i] -match '^[0-9]+$'
        if ($an -and $bn) { $c = [Numerics.BigInteger]::Parse($ai[$i]).CompareTo([Numerics.BigInteger]::Parse($bi[$i])) }
        elseif ($an) { $c = -1 }
        elseif ($bn) { $c = 1 }
        else { $c = [string]::CompareOrdinal($ai[$i], $bi[$i]) }
        if ($c -ne 0) { return [Math]::Sign($c) }
    }
    return [Math]::Sign($ai.Length.CompareTo($bi.Length))
}
