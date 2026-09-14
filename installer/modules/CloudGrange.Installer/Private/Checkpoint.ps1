#Requires -Version 7.4
<#
.SYNOPSIS
    cg-install-checkpoint-v1 engine: hash-chained atomic writes and start-up recovery.
.DESCRIPTION
    Implements docs/future-profiles/rke2-bom-installer-design.md §3.2 exactly.

    Write order (every checkpoint):
      1. previousCheckpointSha256 = sha256(current checkpoint.json bytes) or 64 zeros; sequence = current + 1
      2. write checkpoint.tmp and fsync it
      3. if checkpoint.json exists: unlink checkpoint.prev, then hard-link checkpoint.json -> checkpoint.prev
      4. rename checkpoint.tmp -> checkpoint.json (atomic replace)
      5. fsync the state directory

    Recovery rows (Resolve-CgCheckpoint .Row):
      none                 nothing present                                   fresh installation
      json-only-first      json only, predecessor is 64 zeros                 resume from json
      json-prev            json + prev, json chains to prev or equals prev    resume from json
      json-tmp-valid       tmp chains to json with sequence + 1               complete steps 3-5, resume from new json
      json-tmp-invalid     tmp unparsable / wrong predecessor / wrong sequence delete tmp, resume from json
      prev-tmp-no-json     external damage                                   tmp valid vs prev -> rename; else restore json from prev
      json-unparsable      json unparsable, prev parses                       refuse checkpoint-corrupt; -ResumeFromPrevious promotes prev
      tmp-only-first-write only tmp (crash during the very first write)       valid first checkpoint -> rename; unparsable -> discard
      anything-else                                                           refuse checkpoint-corrupt, nothing modified
    The tmp-only-first-write row is an installer interpretation: the design's table has no row for
    a crash inside the first write, and §9.2 requires power loss during a checkpoint write to never
    produce checkpoint-corrupt.
.NOTES
    TaskReference: AB#8129 AB#9015
#>
Set-StrictMode -Version Latest

function Get-CgUtcNow {
    return [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function Get-CgCheckpointPath {
    param([Parameter(Mandatory)][string]$StateDirectory)
    return [pscustomobject]@{
        Directory = $StateDirectory
        Json = Join-Path $StateDirectory 'checkpoint.json'
        Prev = Join-Path $StateDirectory 'checkpoint.prev'
        Tmp = Join-Path $StateDirectory 'checkpoint.tmp'
    }
}

function Read-CgCheckpointBytes {
    <# Returns the checkpoint as an ordered dictionary, or $null when it does not parse or validate. #>
    param([AllowNull()][AllowEmptyCollection()][byte[]]$Bytes)
    # A zero-length file is unrolled to $null by PowerShell expressions; both mean "does not parse".
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return $null }
    try { $parsed = ConvertFrom-CgStrictJson -Bytes $Bytes -MaxBytes 4194304 } catch { return $null }
    if ($parsed.Value -isnot [Collections.IDictionary]) { return $null }
    if (-not (Test-CgJsonSchema -Json $parsed.Text -SchemaPath (Get-CgSchemaPath -FileName 'install-checkpoint-v1.schema.json'))) { return $null }
    $value = $parsed.Value
    if (($value['sequence'] -eq 1) -ne ($value['previousCheckpointSha256'] -eq $script:CgZeroSha256)) { return $null }
    return $value
}

function Get-CgCheckpoint {
    <# Reads and validates checkpoint.json after recovery. Returns $null when absent. #>
    param([Parameter(Mandatory)][string]$StateDirectory)
    $paths = Get-CgCheckpointPath -StateDirectory $StateDirectory
    if (-not (Test-Path -LiteralPath $paths.Json -PathType Leaf)) { return $null }
    $value = Read-CgCheckpointBytes -Bytes ([IO.File]::ReadAllBytes($paths.Json))
    if ($null -eq $value) { throw (New-CgError 'checkpoint-corrupt' 'checkpoint.json does not parse or validate.') }
    return $value
}

function New-CgHardLink {
    param([Parameter(Mandatory)][string]$Link, [Parameter(Mandatory)][string]$Target)
    $null = New-Item -ItemType HardLink -Path $Link -Target $Target -ErrorAction Stop
}

function Write-CgCheckpoint {
    <#
    .SYNOPSIS
        Appends the next checkpoint to the chain using the §3.2 atomic write order.
    .PARAMETER State
        Dictionary with installId, mode, requestSha256, bomSha256, catalogPayloadSha256,
        productVersion, attempt, phase, phaseState, phases and optional subState/terminal.
        sequence, updatedUtc and previousCheckpointSha256 are computed here.
    #>
    param([Parameter(Mandatory)][string]$StateDirectory, [Parameter(Mandatory)][Collections.IDictionary]$State)
    $paths = Get-CgCheckpointPath -StateDirectory $StateDirectory
    $hasJson = Test-Path -LiteralPath $paths.Json -PathType Leaf
    # Step 1.
    if ($hasJson) {
        $currentBytes = [IO.File]::ReadAllBytes($paths.Json)
        $current = Read-CgCheckpointBytes -Bytes $currentBytes
        if ($null -eq $current) { throw (New-CgError 'checkpoint-corrupt' 'Refusing to chain onto an unreadable checkpoint.json.') }
        if ($current['installId'] -ne $State['installId']) { throw (New-CgError 'checkpoint-identity-changed' 'installId differs from the existing checkpoint.') }
        $previousSha256 = Get-CgSha256Hex -Bytes $currentBytes
        $sequence = [long]$current['sequence'] + 1
    } else {
        $previousSha256 = $script:CgZeroSha256
        $sequence = [long]1
    }
    $document = [ordered]@{
        schema = 'cg-install-checkpoint-v1'
        installId = [string]$State['installId']
        sequence = $sequence
        mode = [string]$State['mode']
        requestSha256 = [string]$State['requestSha256']
        compositionSha256 = [string]$State['compositionSha256']
        bomSha256 = [string]$State['bomSha256']
        catalogPayloadSha256 = [string]$State['catalogPayloadSha256']
        productVersion = [string]$State['productVersion']
        attempt = [long]$State['attempt']
        phase = [string]$State['phase']
        phaseState = [string]$State['phaseState']
    }
    if ($State.Contains('subState') -and $State['subState']) { $document['subState'] = [string]$State['subState'] }
    if ($State.Contains('terminal') -and $State['terminal']) { $document['terminal'] = [string]$State['terminal'] }
    $document['phases'] = $State['phases']
    $document['updatedUtc'] = Get-CgUtcNow
    $document['previousCheckpointSha256'] = $previousSha256
    $bytes = ConvertTo-CgJsonBytes -InputObject $document
    if ($null -eq (Read-CgCheckpointBytes -Bytes $bytes)) { throw (New-CgError 'checkpoint-invalid' 'The new checkpoint does not satisfy install-checkpoint-v1.') }

    # Step 2.
    Write-CgFileDurable -Path $paths.Tmp -Bytes $bytes -FaultPrefix 'checkpoint-step2'
    Set-CgOwnerOnlyMode -Path $paths.Tmp -Mode File0600
    Invoke-CgFaultPoint 'checkpoint-step2-fsynced'
    # Step 3.
    if ($hasJson) {
        if (Test-Path -LiteralPath $paths.Prev -PathType Leaf) { [IO.File]::Delete($paths.Prev) }
        Invoke-CgFaultPoint 'checkpoint-step3-prev-unlinked'
        New-CgHardLink -Link $paths.Prev -Target $paths.Json
        Invoke-CgFaultPoint 'checkpoint-step3-linked'
    }
    # Step 4.
    [IO.File]::Move($paths.Tmp, $paths.Json, $true)
    Invoke-CgFaultPoint 'checkpoint-step4-renamed'
    # Step 5.
    $directorySynced = Sync-CgDirectory -Path $StateDirectory
    Invoke-CgFaultPoint 'checkpoint-step5-synced'
    return [pscustomobject]@{ Document = $document; Sha256 = Get-CgSha256Hex -Bytes $bytes; Sequence = $sequence; DirectorySynced = $directorySynced }
}

function Complete-CgCheckpointWrite {
    <# Recovery for json + valid tmp: redo steps 3-5. #>
    param([Parameter(Mandatory)]$Paths)
    if (Test-Path -LiteralPath $Paths.Prev -PathType Leaf) { [IO.File]::Delete($Paths.Prev) }
    New-CgHardLink -Link $Paths.Prev -Target $Paths.Json
    [IO.File]::Move($Paths.Tmp, $Paths.Json, $true)
    $null = Sync-CgDirectory -Path $Paths.Directory
}

function Copy-CgCheckpointToJson {
    param([Parameter(Mandatory)]$Paths, [Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)][string]$TemporaryName)
    $temporary = Join-Path $Paths.Directory $TemporaryName
    Write-CgFileDurable -Path $temporary -Bytes $Bytes
    Set-CgOwnerOnlyMode -Path $temporary -Mode File0600
    [IO.File]::Move($temporary, $Paths.Json, $true)
    $null = Sync-CgDirectory -Path $Paths.Directory
}

function Resolve-CgCheckpoint {
    <#
    .SYNOPSIS
        Applies the §3.2 recovery table to whatever checkpoint files exist. Call it while holding
        install.lock and before any phase work. -NoMutation reports the action without touching files
        (used by Plan).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateDirectory, [switch]$ResumeFromPrevious, [switch]$NoMutation)
    $paths = Get-CgCheckpointPath -StateDirectory $StateDirectory
    $result = [pscustomobject]@{
        Row = ''; Action = ''; Refused = $false; ReasonCode = $null; Message = $null
        Checkpoint = $null; Events = [Collections.Generic.List[string]]::new(); ReprobeCompleted = $false; Mutated = $false
    }
    $hasJson = Test-Path -LiteralPath $paths.Json -PathType Leaf
    $hasPrev = Test-Path -LiteralPath $paths.Prev -PathType Leaf
    $hasTmp = Test-Path -LiteralPath $paths.Tmp -PathType Leaf
    $jsonBytes = if ($hasJson) { [IO.File]::ReadAllBytes($paths.Json) } else { $null }
    $prevBytes = if ($hasPrev) { [IO.File]::ReadAllBytes($paths.Prev) } else { $null }
    $tmpBytes = if ($hasTmp) { [IO.File]::ReadAllBytes($paths.Tmp) } else { $null }
    $json = if ($hasJson) { Read-CgCheckpointBytes -Bytes $jsonBytes } else { $null }
    $prev = if ($hasPrev) { Read-CgCheckpointBytes -Bytes $prevBytes } else { $null }
    $tmp = if ($hasTmp) { Read-CgCheckpointBytes -Bytes $tmpBytes } else { $null }

    $refuse = {
        param([string]$Row, [string]$Message)
        $result.Row = $Row; $result.Action = 'refuse'; $result.Refused = $true
        $result.ReasonCode = 'checkpoint-corrupt'; $result.Message = $Message
    }

    if (-not ($hasJson -or $hasPrev -or $hasTmp)) {
        $result.Row = 'none'; $result.Action = 'fresh'
        return $result
    }

    if ($hasJson -and $null -eq $json) {
        if ($null -ne $prev -and $ResumeFromPrevious) {
            $result.Row = 'json-unparsable'; $result.Action = 'promote-previous'; $result.Checkpoint = $prev
            $result.ReprobeCompleted = $true; $result.Events.Add('checkpoint-promoted-from-prev')
            if (-not $NoMutation) {
                $corruptPath = Join-Path $StateDirectory ('checkpoint.corrupt-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ', [Globalization.CultureInfo]::InvariantCulture))
                [IO.File]::Move($paths.Json, $corruptPath)
                Copy-CgCheckpointToJson -Paths $paths -Bytes $prevBytes -TemporaryName 'checkpoint.promote.tmp'
                $result.Mutated = $true
            }
        } elseif ($null -ne $prev) {
            & $refuse 'json-unparsable' 'checkpoint.json does not parse; checkpoint.prev does. Both preserved. Re-run with -ResumeFromPrevious to promote checkpoint.prev after every completed phase is re-probed.'
        } else {
            & $refuse 'anything-else' 'checkpoint.json does not parse and no valid checkpoint.prev exists. Nothing modified.'
        }
        return $result
    }

    if ($hasJson) {
        $jsonSha = Get-CgSha256Hex -Bytes $jsonBytes
        if ($hasTmp -and $null -ne $tmp -and $tmp['previousCheckpointSha256'] -eq $jsonSha -and [long]$tmp['sequence'] -eq ([long]$json['sequence'] + 1)) {
            $result.Row = 'json-tmp-valid'; $result.Action = 'complete-interrupted-write'; $result.Checkpoint = $tmp
            $result.Events.Add('checkpoint-write-completed')
            if (-not $NoMutation) { Complete-CgCheckpointWrite -Paths $paths; $result.Mutated = $true }
            return $result
        }
        $chainOk = $false
        if ($hasPrev) {
            $prevSha = Get-CgSha256Hex -Bytes $prevBytes
            $chainOk = ($json['previousCheckpointSha256'] -eq $prevSha) -or ($jsonSha -eq $prevSha)
        } else {
            $chainOk = $json['previousCheckpointSha256'] -eq $script:CgZeroSha256
        }
        if (-not $chainOk) {
            if ($hasPrev) { & $refuse 'anything-else' 'checkpoint.json does not chain to checkpoint.prev. Nothing modified.' }
            else { & $refuse 'anything-else' 'checkpoint.json names a predecessor but checkpoint.prev is missing. Nothing modified.' }
            return $result
        }
        if ($hasTmp) {
            $result.Row = 'json-tmp-invalid'; $result.Action = 'discard-tmp'; $result.Events.Add('checkpoint-tmp-discarded')
            if (-not $NoMutation) { [IO.File]::Delete($paths.Tmp); $null = Sync-CgDirectory -Path $StateDirectory; $result.Mutated = $true }
        } elseif ($hasPrev) {
            $result.Row = 'json-prev'; $result.Action = 'resume'
        } else {
            $result.Row = 'json-only-first'; $result.Action = 'resume'
        }
        $result.Checkpoint = $json
        return $result
    }

    if ($hasPrev -and $hasTmp) {
        if ($null -eq $prev) {
            & $refuse 'anything-else' 'checkpoint.json is missing and checkpoint.prev does not parse. Nothing modified.'
            return $result
        }
        $result.Row = 'prev-tmp-no-json'
        $prevSha = Get-CgSha256Hex -Bytes $prevBytes
        if ($null -ne $tmp -and $tmp['previousCheckpointSha256'] -eq $prevSha -and [long]$tmp['sequence'] -eq ([long]$prev['sequence'] + 1)) {
            $result.Action = 'rename-tmp'; $result.Checkpoint = $tmp; $result.Events.Add('checkpoint-tmp-renamed-without-json')
            if (-not $NoMutation) { [IO.File]::Move($paths.Tmp, $paths.Json); $null = Sync-CgDirectory -Path $StateDirectory; $result.Mutated = $true }
        } else {
            $result.Action = 'restore-from-prev'; $result.Checkpoint = $prev; $result.Events.Add('checkpoint-restored-from-prev')
            if (-not $NoMutation) {
                Copy-CgCheckpointToJson -Paths $paths -Bytes $prevBytes -TemporaryName 'checkpoint.restore.tmp'
                [IO.File]::Delete($paths.Tmp)
                $null = Sync-CgDirectory -Path $StateDirectory
                $result.Mutated = $true
            }
        }
        return $result
    }

    if ($hasTmp) {
        if ($null -ne $tmp -and [long]$tmp['sequence'] -eq 1) {
            $result.Row = 'tmp-only-first-write'; $result.Action = 'complete-first-write'; $result.Checkpoint = $tmp
            $result.Events.Add('checkpoint-first-write-completed')
            if (-not $NoMutation) { [IO.File]::Move($paths.Tmp, $paths.Json); $null = Sync-CgDirectory -Path $StateDirectory; $result.Mutated = $true }
        } elseif ($null -eq $tmp) {
            $result.Row = 'tmp-only-first-write'; $result.Action = 'discard-first-write'
            $result.Events.Add('checkpoint-first-write-discarded')
            if (-not $NoMutation) { [IO.File]::Delete($paths.Tmp); $null = Sync-CgDirectory -Path $StateDirectory; $result.Mutated = $true }
        } else {
            & $refuse 'anything-else' 'Only checkpoint.tmp exists and it is not a first checkpoint. Nothing modified.'
        }
        return $result
    }

    & $refuse 'anything-else' 'Only checkpoint.prev exists. Nothing modified.'
    return $result
}
