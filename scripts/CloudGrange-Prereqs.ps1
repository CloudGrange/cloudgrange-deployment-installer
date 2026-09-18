# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# CloudGrange installer prereq bootstrap.
#
# Goal: the operator runs Install-CloudGrange.ps1 on a clean Windows Server 2025
# box and gets a working installation with no other downloads. We DO NOT require
# Windows ADK, do not require a manual QEMU install, and do not assume the
# operator has any developer tooling.
#
# This file is dot-sourced by Install-CloudGrange.ps1 and exposes:
#   - Initialize-CloudGrangePrereqs: ensures qemu-img is available
#   - New-CiDataIso: builds a NoCloud cloud-init seed ISO using IMAPI2 (built
#     into Windows since Vista — no ADK / oscdimg required)

Set-StrictMode -Version Latest

function Initialize-CloudGrangePrereqs {
    <#
    .SYNOPSIS
        Verifies installer-side prerequisites. Fails closed when qemu-img is missing.
    .DESCRIPTION
        PowerShell 7+ is enforced by the #requires directive in Install-CloudGrange.ps1.
        Hyper-V is checked in the main installer.
          1. qemu-img — REQUIRED on PATH (AB#8129). The installer never silently downloads or
             installs software. Install QEMU for Windows yourself (see docs/prerequisites.md),
             or pass -InstallPinnedQemu to install the one pinned, SHA-512-verified build below.
          2. ISO writer — handled by IMAPI2 COM (built into Windows); no install needed.
    .PARAMETER InstallPinnedQemu
        Explicit operator opt-in: download the pinned QEMU build, verify its SHA-512 before
        execution, and install it. Any mismatch aborts before the file is run.
    #>
    [CmdletBinding()]
    param(
        [switch]$InstallPinnedQemu
    )

    Write-Host "  Verifying installer prerequisites..." -ForegroundColor Gray

    # qemu-img is required to convert the Ubuntu cloud .img to a Hyper-V Gen2 .vhdx.
    if (Get-Command qemu-img -ErrorAction SilentlyContinue) {
        Write-Host "  qemu-img: available ($((Get-Command qemu-img).Source))" -ForegroundColor Green
        return
    }
    if ($InstallPinnedQemu) {
        Write-Host "  qemu-img not found - installing the pinned QEMU build (-InstallPinnedQemu)..."
        Install-CloudGrangeQemu
        return
    }
    Write-Host "  CG-INST-ERR-004: qemu-img was not found on PATH." -ForegroundColor Red
    Write-Host "  Install QEMU for Windows (qemu-img.exe) and add it to PATH, then re-run." -ForegroundColor Yellow
    Write-Host "  See docs/prerequisites.md for the supported build and its SHA-512," -ForegroundColor Yellow
    Write-Host "  or re-run with -InstallPinnedQemu to install that verified build." -ForegroundColor Yellow
    Write-Error "CG-INST-ERR-004: qemu-img is required and was not found. Nothing was installed."
}

# Pinned QEMU for Windows build (AB#8129). SHA-512 matches upstream qemu-w64-setup-20260811.sha512,
# observed 2026-09-14. Update the version and hash together, never independently.
$script:CloudGrangeQemuVersion  = '20260811'
$script:CloudGrangeQemuSha512   = '5bcf9eed634e8575a37b74f445af41a2fe4106da512d0c30c368301d4c105037fdfab40a5287367a28a957624cddebbc8c07e16c88ab6634f554cdf3d16bf543'

function Install-CloudGrangeQemu {
    <#
    .SYNOPSIS
        Downloads the pinned QEMU for Windows build, verifies its SHA-512, then installs it.
    .DESCRIPTION
        Source: https://qemu.weilnetz.de/w64/ (upstream Windows build feed referenced by qemu.org).
        Only the pinned file name is fetched; the hash is checked before execution and a mismatch
        deletes the download and aborts (fail closed). Called only with -InstallPinnedQemu.
    #>
    [CmdletBinding()]
    param(
        [string]$InstallDir = 'C:\Program Files\qemu'
    )

    $fileName = "qemu-w64-setup-$($script:CloudGrangeQemuVersion).exe"
    $setupUrl = "https://qemu.weilnetz.de/w64/$fileName"
    $setupExe = Join-Path $env:TEMP $fileName

    Write-Host "  Downloading $fileName..."
    Invoke-WebRequest -Uri $setupUrl -OutFile $setupExe -UseBasicParsing

    $actual = (Get-FileHash -Path $setupExe -Algorithm SHA512).Hash
    if ($actual -ine $script:CloudGrangeQemuSha512) {
        Remove-Item -LiteralPath $setupExe -Force -ErrorAction SilentlyContinue
        Write-Error "CG-INST-ERR-005: $fileName SHA-512 mismatch (expected $($script:CloudGrangeQemuSha512), got $actual). The file was deleted and not executed."
    }
    Write-Host "  SHA-512 verified for $fileName" -ForegroundColor Green

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

# ---------------------------------------------------------------------------------------------
# AB#9171 (C3) — the VM's base disk. Windows PowerShell 5.1 compatible: New-CloudGrangeVm.ps1 runs
# under powershell.exe because the Hyper-V module needs it.
#
# Preferred: download the pre-converted, pinned Ubuntu base VHDX that the release publishes
# (scripts/release/New-UbuntuBaseVhdx.sh), so a customer's Windows host needs no qemu-img at all.
# Fallback, ONLY when this release pins no base VHDX or it cannot be downloaded: the pinned Ubuntu
# cloud image (by serial, never noble/current) converted locally with qemu-img. A checksum MISMATCH is
# never a reason to fall back -- it means the file was altered or the pin is wrong, so it stops.
# ---------------------------------------------------------------------------------------------

function Read-CloudGrangePins {
    <#
    .SYNOPSIS
        Reads release/pins.conf (KEY=VALUE, '#' comments) into a hashtable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "CG-INST-ERR-014: the pins file $Path is missing; this installer package is incomplete."
    }
    $pins = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^([A-Z0-9_]+)=(.*)$') { $pins[$Matches[1]] = $Matches[2].Trim() }
    }
    return $pins
}

function Get-CloudGrangeSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    # .NET directly, not Get-FileHash: under powershell.exe with a PSModulePath inherited from pwsh,
    # Microsoft.PowerShell.Utility can resolve to the PS7 copy, which 5.1 cannot load, and
    # Get-FileHash is then "not recognized" (reproduced while testing this function).
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead((Resolve-Path -LiteralPath $Path).ProviderPath)
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Invoke-CloudGrangeDownload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$OutFile)
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes large downloads many times slower on 5.1
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
}

function Get-CloudGrangePinnedBaseVhdx {
    <#
    .SYNOPSIS
        Returns a verified pre-converted base VHDX in $CacheDir, or $null when the release pins none or
        it cannot be downloaded (the caller then falls back to qemu-img). Throws on any checksum mismatch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Pins,
        [Parameter(Mandatory)][string]$CacheDir
    )
    $url     = [string]$Pins['UBUNTU_BASE_VHDX_ZIP_URL']
    $zipSha  = [string]$Pins['UBUNTU_BASE_VHDX_ZIP_SHA256']
    $vhdxSha = [string]$Pins['UBUNTU_BASE_VHDX_SHA256']
    if ([string]::IsNullOrEmpty($url) -or $zipSha -notmatch '^[0-9a-f]{64}$' -or $vhdxSha -notmatch '^[0-9a-f]{64}$') {
        Write-Host "  This release pins no pre-converted base VHDX." -ForegroundColor Gray
        return $null
    }
    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    $cached = Join-Path $CacheDir ('ubuntu-base-{0}.vhdx' -f $vhdxSha.Substring(0, 16))
    if (Test-Path -LiteralPath $cached) {
        if ((Get-CloudGrangeSha256 -Path $cached) -eq $vhdxSha) {
            Write-Host "  Base VHDX: cached and verified ($cached)" -ForegroundColor Green
            return $cached
        }
        Remove-Item -LiteralPath $cached -Force
    }
    $zip = Join-Path $CacheDir 'ubuntu-base-download.zip'
    Write-Host "  Downloading the pre-converted Ubuntu base VHDX..."
    try {
        Invoke-CloudGrangeDownload -Uri $url -OutFile $zip
    } catch {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Write-Warning "The pre-converted base VHDX is unavailable ($($_.Exception.Message)); falling back to converting the pinned cloud image with qemu-img."
        return $null
    }
    $actual = Get-CloudGrangeSha256 -Path $zip
    if ($actual -ne $zipSha) {
        Remove-Item -LiteralPath $zip -Force
        throw "CG-INST-ERR-015: the base VHDX download does not match its pinned SHA-256 (expected $zipSha, got $actual). The download was deleted. This is not retried with qemu-img: a mismatch means the file was altered or the pin is wrong."
    }
    $extract = Join-Path $CacheDir 'ubuntu-base-extract'
    Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
    Remove-Item -LiteralPath $zip -Force
    $vhdx = Get-ChildItem -LiteralPath $extract -Filter '*.vhdx' -File | Select-Object -First 1
    if (-not $vhdx) {
        Remove-Item -LiteralPath $extract -Recurse -Force
        throw "CG-INST-ERR-015: the base VHDX download contains no .vhdx file."
    }
    $actual = Get-CloudGrangeSha256 -Path $vhdx.FullName
    if ($actual -ne $vhdxSha) {
        Remove-Item -LiteralPath $extract -Recurse -Force
        throw "CG-INST-ERR-015: the extracted base VHDX does not match its pinned SHA-256 (expected $vhdxSha, got $actual)."
    }
    Move-Item -LiteralPath $vhdx.FullName -Destination $cached -Force
    Remove-Item -LiteralPath $extract -Recurse -Force
    Write-Host "  Base VHDX: downloaded and verified" -ForegroundColor Green
    return $cached
}

function Get-CloudGrangePinnedCloudImage {
    <#
    .SYNOPSIS
        The pinned Ubuntu cloud image (by serial, from release/pins.conf), downloaded once into $CacheDir
        and verified against the pinned SHA-256. Replaces the old noble/current download, which installed
        whatever Canonical published that day and checked it against a checksum fetched from the same place.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Pins,
        [Parameter(Mandatory)][string]$CacheDir
    )
    $serial = [string]$Pins['UBUNTU_CLOUDIMG_SERIAL']
    $sha    = [string]$Pins['UBUNTU_CLOUDIMG_SHA256']
    if ($serial -notmatch '^\d{8}(\.\d+)?$' -or $sha -notmatch '^[0-9a-f]{64}$') {
        throw "CG-INST-ERR-014: release/pins.conf has no valid UBUNTU_CLOUDIMG_SERIAL/UBUNTU_CLOUDIMG_SHA256."
    }
    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    $img = Join-Path $CacheDir "noble-server-cloudimg-amd64-$serial.img"
    if ((Test-Path -LiteralPath $img) -and (Get-CloudGrangeSha256 -Path $img) -eq $sha) { return $img }
    Remove-Item -LiteralPath $img -Force -ErrorAction SilentlyContinue
    Write-Host "  Downloading the pinned Ubuntu 24.04 cloud image (serial $serial)..."
    Invoke-CloudGrangeDownload -Uri "https://cloud-images.ubuntu.com/noble/$serial/noble-server-cloudimg-amd64.img" -OutFile $img
    $actual = Get-CloudGrangeSha256 -Path $img
    if ($actual -ne $sha) {
        Remove-Item -LiteralPath $img -Force
        throw "CG-INST-ERR-016: the Ubuntu cloud image (serial $serial) does not match its pinned SHA-256 (expected $sha, got $actual). The download was deleted."
    }
    return $img
}

function Convert-CloudGrangeCloudImage {
    <#
    .SYNOPSIS
        Fallback only: resize a verified cloud image to 30 GB and convert it to a dynamic VHDX with qemu-img.
    .DESCRIPTION
        Works on a scratch copy. The old code resized the cached, verified download IN PLACE, so the next
        install's checksum check always failed on it ("checksum mismatch. Re-download aborted.").
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][string]$VhdxPath,
        [switch]$InstallPinnedQemu
    )
    Initialize-CloudGrangePrereqs -InstallPinnedQemu:$InstallPinnedQemu
    $qemuImg = (Get-Command qemu-img -ErrorAction Stop).Source
    $work = "$VhdxPath.source.img"
    Copy-Item -LiteralPath $ImagePath -Destination $work -Force
    try {
        # qemu-img resize supports qcow2/raw but not VHDX subformat=dynamic, and Resize-VHD fails
        # post-conversion in SYSTEM context, so resize first. cloud-init growpart fills it on first boot.
        Write-Host "  Expanding the image to 30 GB before conversion..."
        & $qemuImg resize $work 30G
        if ($LASTEXITCODE -ne 0) { throw "qemu-img resize failed (exit $LASTEXITCODE)." }
        Write-Host "  Converting the cloud image to VHDX (qemu-img)..."
        & $qemuImg convert -f qcow2 -O vhdx -o subformat=dynamic $work $VhdxPath
        if ($LASTEXITCODE -ne 0) { throw "qemu-img convert failed (exit $LASTEXITCODE)." }
    } finally {
        Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
    }
}

function New-CloudGrangeBaseDisk {
    <#
    .SYNOPSIS
        Puts the VM's 30 GB Ubuntu 24.04 base disk at $VhdxPath: the pinned pre-converted VHDX when the
        release has one (no qemu-img), else the pinned cloud image converted with qemu-img.
    .PARAMETER BundledImagePath
        Offline installs: a base .vhdx (preferred) or a cloud .img shipped next to the installer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][string]$PinsPath,
        [string]$BundledImagePath = '',
        [switch]$InstallPinnedQemu
    )
    $pins = Read-CloudGrangePins -Path $PinsPath
    $cacheDir = Split-Path $VhdxPath -Parent
    $base = $null
    $image = $null
    if (-not [string]::IsNullOrEmpty($BundledImagePath)) {
        if (-not (Test-Path -LiteralPath $BundledImagePath)) { throw "Bundled image not found at: $BundledImagePath" }
        if ($BundledImagePath -like '*.vhdx') {
            $want = [string]$pins['UBUNTU_BASE_VHDX_SHA256']
            if ($want -match '^[0-9a-f]{64}$' -and (Get-CloudGrangeSha256 -Path $BundledImagePath) -ne $want) {
                throw "CG-INST-ERR-015: the bundled base VHDX does not match the SHA-256 pinned in release/pins.conf."
            }
            $base = $BundledImagePath
        } else {
            $want = [string]$pins['UBUNTU_CLOUDIMG_SHA256']
            if ((Get-CloudGrangeSha256 -Path $BundledImagePath) -ne $want) {
                throw "CG-INST-ERR-016: the bundled cloud image does not match the SHA-256 pinned in release/pins.conf."
            }
            $image = $BundledImagePath
        }
    } else {
        $base = Get-CloudGrangePinnedBaseVhdx -Pins $pins -CacheDir $cacheDir
        if (-not $base) { $image = Get-CloudGrangePinnedCloudImage -Pins $pins -CacheDir $cacheDir }
    }
    if ($base) {
        # A plain copy, not a differencing disk: the appliance build exports this very file.
        Write-Host "  Creating the VM disk from the pre-converted base VHDX (no qemu-img needed)..."
        Copy-Item -LiteralPath $base -Destination $VhdxPath -Force
    } else {
        Convert-CloudGrangeCloudImage -ImagePath $image -VhdxPath $VhdxPath -InstallPinnedQemu:$InstallPinnedQemu
    }
    Clear-CloudGrangeSparseAttribute -Path $VhdxPath
}

function Clear-CloudGrangeSparseAttribute {
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
        Write-Error "Cannot clear sparse attribute - file not found: $Path"
    }

    # Get-Item returns System.IO.FileAttributes which may include SparseFile.
    $attrs = (Get-Item -LiteralPath $Path).Attributes
    if ($attrs -band [System.IO.FileAttributes]::SparseFile) {
        Write-Host "  Clearing NTFS sparse attribute on VHDX..."
        & fsutil sparse setflag $Path 0 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "fsutil exit code $LASTEXITCODE - VM may fail to start with 0xC03A001A."
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
        # IMAPI_MEDIA_TYPE_DISK (13) — hard-disk image, no media size constraint.
        # ChooseImageDefaults($null) NREs without a disc recorder; ChooseImageDefaultsForMediaType
        # is the correct path when building an ISO file rather than burning a disc.
        # IMPORTANT: call ChooseImageDefaultsForMediaType FIRST — it resets FileSystemsToCreate
        # to the media default (which includes UDF for disk media). We then override it to
        # ISO9660+Joliet only. Order matters: setting FileSystemsToCreate before the call
        # has no effect because the call resets it.
        $fsi.ChooseImageDefaultsForMediaType(13)
        # FileSystemsToCreate bitmask: 1=ISO9660, 2=Joliet, 4=UDF. NoCloud datasource in
        # cloud-init requires ISO9660; UDF is not recognized as cidata by the Linux kernel
        # block-device scan. Set 3 (ISO9660 + Joliet) AFTER ChooseImageDefaultsForMediaType
        # so the override sticks.
        $fsi.FileSystemsToCreate = 3
        $fsi.VolumeName = $VolumeLabel

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

    # PowerShell 7 (.NET Core / .NET 8) does NOT dispatch IStream methods via
    # System.__ComObject the way Windows PowerShell 5.1 (.NET Framework) does —
    # the previous IStream.Read($unmanaged, $toRead, $bytesReadPtr) call throws
    # "Method invocation failed because [System.__ComObject] does not contain a
    # method named 'Read'". The canonical workaround (used by the Microsoft
    # TechNet "New-IsoFile" snippet since 2014) is to cast the COM object to
    # the typed managed interface System.Runtime.InteropServices.ComTypes.IStream
    # inside a small C# helper so the call goes through the typed interface
    # vtable rather than __ComObject's IDispatch shim.
    #
    # GCHandle.Alloc(Pinned) is used instead of /unsafe &-operator so the helper
    # compiles under both PS7 (Roslyn) and PS5.1 (csc.exe) in restricted SYSTEM
    # contexts where csc.exe may lack the /unsafe permission.
    if (-not ([System.Management.Automation.PSTypeName]'ISOFile').Type) {
        Add-Type -TypeDefinition @"
public class ISOFile {
    public static void Create(string Path, object Stream, int BlockSize, int TotalBlocks) {
        int[] pcbRead = new int[1];
        var handle = System.Runtime.InteropServices.GCHandle.Alloc(
            pcbRead, System.Runtime.InteropServices.GCHandleType.Pinned);
        try {
            byte[] buf = new byte[BlockSize];
            var o = System.IO.File.OpenWrite(Path);
            var i = Stream as System.Runtime.InteropServices.ComTypes.IStream;
            if (o != null) {
                while (TotalBlocks-- > 0) {
                    i.Read(buf, BlockSize, handle.AddrOfPinnedObject());
                    o.Write(buf, 0, pcbRead[0]);
                }
                o.Flush();
                o.Close();
            }
        } finally {
            handle.Free();
        }
    }
}
"@
    }

    try {
        [ISOFile]::Create($OutputIso, $resultStream, $resultImage.BlockSize, $resultImage.TotalBlocks)
    } finally {
        # Release COM references.
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($resultStream)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($resultImage)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($fsi)
    }

    if (-not (Test-Path $OutputIso) -or (Get-Item -LiteralPath $OutputIso).Length -eq 0) {
        Write-Error "IMAPI2 wrote zero bytes - ISO not produced at $OutputIso."
    }
}
