# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0
#
# CloudSmith installer prereq bootstrap.
#
# Goal: the operator runs Install-CloudSmith.ps1 on a clean Windows Server 2025
# box and gets a working installation with no other downloads. We DO NOT require
# Windows ADK, do not require a manual QEMU install, and do not assume the
# operator has any developer tooling.
#
# This file is dot-sourced by Install-CloudSmith.ps1 and exposes:
#   - Initialize-CloudSmithPrereqs: ensures qemu-img is available
#   - New-CiDataIso: builds a NoCloud cloud-init seed ISO using IMAPI2 (built
#     into Windows since Vista — no ADK / oscdimg required)

Set-StrictMode -Version Latest

function Initialize-CloudSmithPrereqs {
    <#
    .SYNOPSIS
        Verifies installer-side prerequisites and auto-installs the missing ones.
    .DESCRIPTION
        PowerShell 7+ is enforced by the #requires directive in Install-CloudSmith.ps1.
        Hyper-V is checked in the main installer.
        This function handles the two prerequisites the installer needs at image-conversion
        and seed-ISO-build time:
          1. qemu-img.exe — auto-installed from the upstream Windows build if missing.
          2. ISO writer — handled by IMAPI2 COM (built into Windows); no install needed.
    #>
    [CmdletBinding()]
    param()

    Write-Host "  Verifying installer prerequisites..." -ForegroundColor Gray

    # qemu-img is required to convert the Ubuntu cloud .img to a Hyper-V Gen2 .vhdx.
    if (-not (Get-Command qemu-img.exe -ErrorAction SilentlyContinue)) {
        Write-Host "  qemu-img not found — installing QEMU for Windows..."
        Install-CloudSmithQemu
    } else {
        Write-Host "  qemu-img: available" -ForegroundColor Green
    }
}

function Install-CloudSmithQemu {
    <#
    .SYNOPSIS
        Downloads and silently installs the latest QEMU for Windows build.
    .DESCRIPTION
        Source: https://qemu.weilnetz.de/w64/ — the official upstream Windows build feed
        (referenced by qemu.org). The directory contains qemu-w64-setup-YYYYMMDD.exe
        files; we pick the newest one by date.
    #>
    [CmdletBinding()]
    param(
        [string]$InstallDir = 'C:\Program Files\qemu'
    )

    $indexUrl = 'https://qemu.weilnetz.de/w64/'
    $listing = Invoke-WebRequest -Uri $indexUrl -UseBasicParsing
    $matches = [regex]::Matches($listing.Content, 'qemu-w64-setup-(\d{8})\.exe')
    if (-not $matches.Count) {
        Write-Error "Could not locate a QEMU for Windows installer at $indexUrl. Install QEMU manually and re-run."
    }
    $latest = $matches | Sort-Object { [int]$_.Groups[1].Value } -Descending | Select-Object -First 1
    $setupUrl = "$indexUrl$($latest.Value)"
    $setupExe = Join-Path $env:TEMP $latest.Value

    Write-Host "  Downloading $($latest.Value)..."
    Invoke-WebRequest -Uri $setupUrl -OutFile $setupExe -UseBasicParsing

    Write-Host "  Installing QEMU silently (NSIS /S)..."
    $proc = Start-Process -FilePath $setupExe -ArgumentList '/S' -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Error "QEMU installer exited with code $($proc.ExitCode). Inspect $setupExe manually."
    }

    if (-not (Test-Path (Join-Path $InstallDir 'qemu-img.exe'))) {
        Write-Error "QEMU installer reported success but qemu-img.exe was not found at $InstallDir."
    }

    # Add to current process PATH for this installer run.
    $env:Path = "$InstallDir;$env:Path"

    # Persist to the machine PATH so subsequent runs find qemu-img without redownload.
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath -notmatch [Regex]::Escape($InstallDir)) {
        [Environment]::SetEnvironmentVariable('Path', "$InstallDir;$machinePath", 'Machine')
    }

    Write-Host "  qemu-img installed at $InstallDir" -ForegroundColor Green
}

function Clear-CloudSmithSparseAttribute {
    <#
    .SYNOPSIS
        Removes the NTFS Sparse attribute from a VHDX file so Hyper-V will mount it.
    .DESCRIPTION
        qemu-img convert with -O vhdx -o subformat=dynamic produces a dynamically
        expanding VHDX, but on NTFS the underlying file may inherit the Sparse
        attribute. Hyper-V Generation 2 refuses to power on a VM whose disk is
        sparse, encrypted, or compressed (error 0xC03A001A — "Virtual hard disk
        files must be uncompressed and unencrypted and must not be sparse").
        fsutil sparse setflag <file> 0 clears the flag without rewriting the file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        Write-Error "Cannot clear sparse attribute — file not found: $Path"
    }

    # Get-Item returns System.IO.FileAttributes which may include SparseFile.
    $attrs = (Get-Item -LiteralPath $Path).Attributes
    if ($attrs -band [System.IO.FileAttributes]::SparseFile) {
        Write-Host "  Clearing NTFS sparse attribute on VHDX..."
        & fsutil sparse setflag $Path 0 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "fsutil exit code $LASTEXITCODE — VM may fail to start with 0xC03A001A."
        }
    }
}

function New-CiDataIso {
    <#
    .SYNOPSIS
        Builds a NoCloud cloud-init seed ISO using IMAPI2 (built into Windows).
    .DESCRIPTION
        Replaces the Windows-ADK oscdimg dependency. IMAPI2 is the Image Mastering
        API that has shipped with Windows since Vista; it is the same engine the
        File Explorer "Burn to disc" feature uses. It is fully scriptable from
        PowerShell via the IMAPI2FS.MsftFileSystemImage COM class, requires no
        installation, and produces a NoCloud-compatible ISO (volume label "cidata",
        Joliet+ISO9660 file system).
    .PARAMETER SourceDir
        Directory containing the user-data and meta-data files to embed.
    .PARAMETER OutputIso
        Output path for the ISO file. Overwritten if it exists.
    .PARAMETER VolumeLabel
        Volume label. NoCloud requires "cidata" (case-insensitive).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceDir,
        [Parameter(Mandatory)] [string]$OutputIso,
        [string]$VolumeLabel = 'cidata'
    )

    if (-not (Test-Path $SourceDir)) {
        Write-Error "Cloud-init source directory not found: $SourceDir"
    }

    # Compose the file system image.
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    try {
        # FileSystemsToCreate bitmask: 1=ISO9660, 2=Joliet, 4=UDF. NoCloud reads
        # ISO9660/Joliet so we set 3 (ISO9660 + Joliet).
        $fsi.FileSystemsToCreate = 3
        $fsi.VolumeName = $VolumeLabel
        # IMAPI_MEDIA_TYPE_DISK (13) — hard-disk image, no media size constraint.
        # ChooseImageDefaults($null) NREs without a disc recorder; ChooseImageDefaultsForMediaType
        # is the correct path when building an ISO file rather than burning a disc.
        $fsi.ChooseImageDefaultsForMediaType(13)

        $sourceFull = (Resolve-Path -LiteralPath $SourceDir).Path
        # AddTree with includeBaseDirectory=$false → files land at the ISO root.
        $fsi.Root.AddTree($sourceFull, $false)

        $resultImage = $fsi.CreateResultImage()
        $resultStream = $resultImage.ImageStream
    } catch {
        throw "IMAPI2 image composition failed: $_"
    }

    # Write the COM IStream out to disk.
    if (Test-Path $OutputIso) {
        Remove-Item -LiteralPath $OutputIso -Force
    }

    # Use the IMAPI2 helper class IStream → file. The COM IStream exposes a
    # CopyTo method but the easiest pure-PowerShell path is to write the stream
    # into a managed FileStream via a 64 KB shuttle buffer.
    $bufferSize = 65536
    $totalBytes = $resultImage.BlockSize * $resultImage.TotalBlocks
    $fileStream = [System.IO.File]::Create($OutputIso)
    try {
        # IStream has Read(IntPtr pv, ULONG cb, ULONG* pcbRead).
        # We marshal an unmanaged buffer, then copy into a managed array.
        $unmanaged = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bufferSize)
        $bytesReadPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        try {
            $remaining = $totalBytes
            while ($remaining -gt 0) {
                $toRead = [Math]::Min($bufferSize, $remaining)
                $resultStream.Read($unmanaged, $toRead, $bytesReadPtr)
                $actuallyRead = [System.Runtime.InteropServices.Marshal]::ReadInt32($bytesReadPtr)
                if ($actuallyRead -le 0) { break }
                $managed = New-Object byte[] $actuallyRead
                [System.Runtime.InteropServices.Marshal]::Copy($unmanaged, $managed, 0, $actuallyRead)
                $fileStream.Write($managed, 0, $actuallyRead)
                $remaining -= $actuallyRead
            }
        } finally {
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($unmanaged)
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($bytesReadPtr)
        }
    } finally {
        $fileStream.Dispose()
        # Release COM references.
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($resultStream)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($resultImage)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($fsi)
    }

    if (-not (Test-Path $OutputIso)) {
        Write-Error "IMAPI2 wrote zero bytes — ISO not produced at $OutputIso."
    }
}
