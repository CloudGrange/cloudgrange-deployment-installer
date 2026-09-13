#Requires -Version 7.4
<#
.SYNOPSIS
    One installer at a time: exclusive lock on state/install.lock.
.DESCRIPTION
    FileShare.None on Linux is implemented by .NET as flock(LOCK_EX|LOCK_NB), and natively on
    Windows. The holder's PID is written to install.owner after the lock is acquired, because a
    second process cannot open the locked file itself to read it. A refused acquisition throws
    installer-already-running with the recorded PID.
.NOTES
    TaskReference: AB#8129 AB#9015
#>
Set-StrictMode -Version Latest

function Enter-CgInstallLock {
    param([Parameter(Mandatory)][string]$StateDirectory)
    $lockPath = Join-Path $StateDirectory 'install.lock'
    $ownerPath = Join-Path $StateDirectory 'install.owner'
    try {
        $stream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
        $holder = 'unknown'
        try { $holder = ([IO.File]::ReadAllText($ownerPath)).Trim() } catch { $holder = 'unknown' }
        if ($holder -notmatch '^[0-9]{1,10}$') { $holder = 'unknown' }
        throw (New-CgError 'installer-already-running' ('Another installer holds install.lock (PID ' + $holder + ').'))
    }
    try {
        Write-CgAtomicFile -Path $ownerPath -Bytes ([Text.Encoding]::ASCII.GetBytes([string]$PID))
    } catch {
        $stream.Dispose()
        throw
    }
    return [pscustomobject]@{ Stream = $stream; OwnerPath = $ownerPath; LockPath = $lockPath }
}

function Exit-CgInstallLock {
    param([Parameter(Mandatory)]$Lock)
    try {
        if (Test-Path -LiteralPath $Lock.OwnerPath -PathType Leaf) { [IO.File]::Delete($Lock.OwnerPath) }
    } finally {
        $Lock.Stream.Dispose()
    }
}
