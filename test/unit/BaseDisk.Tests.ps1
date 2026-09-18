#Requires -Version 7.4
<#
.SYNOPSIS
    AB#9171 (plan C3): the Windows script's VM base disk. The pinned, pre-converted Ubuntu VHDX is used
    when the release has one (no qemu-img); otherwise the pinned cloud image (by serial) is converted
    with qemu-img. A checksum mismatch stops the install and never falls back.
#>
Set-StrictMode -Version Latest

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\scripts\CloudGrange-Prereqs.ps1')
    function script:Get-Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    function script:Write-Pins([string]$Path, [hashtable]$Values) {
        $lines = @('# test pins', 'K3S_VERSION=v1.36.4+k3s1')
        foreach ($k in $Values.Keys) { $lines += "$k=$($Values[$k])" }
        Set-Content -LiteralPath $Path -Value $lines -Encoding ascii
    }
}

Describe 'New-CloudGrangeBaseDisk' {
    BeforeEach {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("cg-basedisk-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $script:root = $root
        $script:vhdxPath = Join-Path $root 'vm\cloudgrange-k3s.vhdx'
        New-Item -ItemType Directory -Path (Split-Path $script:vhdxPath) | Out-Null
        $script:pins = Join-Path $root 'pins.conf'

        # A published artifact: a zip holding one .vhdx.
        $src = Join-Path $root 'src'
        New-Item -ItemType Directory -Path $src | Out-Null
        $script:baseBody = 'pre-converted-base-vhdx-' + [guid]::NewGuid()
        Set-Content -LiteralPath (Join-Path $src 'ubuntu-noble-20260911-hyperv-gen2-30g.vhdx') -Value $script:baseBody -NoNewline
        $script:vhdxSha = Get-Sha (Join-Path $src 'ubuntu-noble-20260911-hyperv-gen2-30g.vhdx')
        $script:zip = Join-Path $root 'published.zip'
        Compress-Archive -Path (Join-Path $src '*.vhdx') -DestinationPath $script:zip
        $script:zipSha = Get-Sha $script:zip

        $script:imgBody = 'cloud-image-' + [guid]::NewGuid()
        $img = Join-Path $root 'cloud.img'
        Set-Content -LiteralPath $img -Value $script:imgBody -NoNewline
        $script:imgSha = Get-Sha $img
        $script:img = $img

        Mock Clear-CloudGrangeSparseAttribute { }
        Mock Initialize-CloudGrangePrereqs { throw 'qemu-img must not be needed on this path' }
        Mock Convert-CloudGrangeCloudImage { Set-Content -LiteralPath $VhdxPath -Value "converted:$ImagePath" -NoNewline }
        $script:downloads = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-CloudGrangeDownload {
            $script:downloads.Add($Uri)
            if ($Uri -like '*.vhdx.zip') { Copy-Item -LiteralPath $script:zip -Destination $OutFile; return }
            if ($Uri -like '*cloud-images.ubuntu.com*') { Copy-Item -LiteralPath $script:img -Destination $OutFile; return }
            throw "unexpected download $Uri"
        }
    }
    AfterEach { Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'uses the pinned pre-converted VHDX and never needs qemu-img' {
        Write-Pins $script:pins @{ UBUNTU_CLOUDIMG_SERIAL = '20260911'; UBUNTU_CLOUDIMG_SHA256 = $script:imgSha
            UBUNTU_BASE_VHDX_ZIP_URL = 'https://example.invalid/base.vhdx.zip'; UBUNTU_BASE_VHDX_ZIP_SHA256 = $script:zipSha
            UBUNTU_BASE_VHDX_SHA256 = $script:vhdxSha }
        New-CloudGrangeBaseDisk -VhdxPath $script:vhdxPath -PinsPath $script:pins
        Get-Content -LiteralPath $script:vhdxPath -Raw | Should -Be $script:baseBody
        Should -Invoke Convert-CloudGrangeCloudImage -Times 0
        Should -Invoke Initialize-CloudGrangePrereqs -Times 0
        Should -Invoke Clear-CloudGrangeSparseAttribute -Times 1
        ($script:downloads -join ' ') | Should -Not -Match 'cloud-images'
    }

    It 'reuses a cached, verified base VHDX without downloading again' {
        Write-Pins $script:pins @{ UBUNTU_CLOUDIMG_SERIAL = '20260911'; UBUNTU_CLOUDIMG_SHA256 = $script:imgSha
            UBUNTU_BASE_VHDX_ZIP_URL = 'https://example.invalid/base.vhdx.zip'; UBUNTU_BASE_VHDX_ZIP_SHA256 = $script:zipSha
            UBUNTU_BASE_VHDX_SHA256 = $script:vhdxSha }
        New-CloudGrangeBaseDisk -VhdxPath $script:vhdxPath -PinsPath $script:pins
        New-CloudGrangeBaseDisk -VhdxPath $script:vhdxPath -PinsPath $script:pins
        Should -Invoke Invoke-CloudGrangeDownload -Times 1 -Exactly
    }

    It 'falls back to the pinned cloud image (by serial, not noble/current) when no base VHDX is pinned' {
        Mock Initialize-CloudGrangePrereqs { }
        Write-Pins $script:pins @{ UBUNTU_CLOUDIMG_SERIAL = '20260911'; UBUNTU_CLOUDIMG_SHA256 = $script:imgSha
            UBUNTU_BASE_VHDX_ZIP_URL = ''; UBUNTU_BASE_VHDX_ZIP_SHA256 = ''; UBUNTU_BASE_VHDX_SHA256 = '' }
        New-CloudGrangeBaseDisk -VhdxPath $script:vhdxPath -PinsPath $script:pins
        Should -Invoke Convert-CloudGrangeCloudImage -Times 1
        $script:downloads | Should -Contain 'https://cloud-images.ubuntu.com/noble/20260911/noble-server-cloudimg-amd64.img'
        ($script:downloads -join ' ') | Should -Not -Match '/current/'
    }

    It 'falls back to qemu-img when the base VHDX cannot be downloaded' {
        Write-Pins $script:pins @{ UBUNTU_CLOUDIMG_SERIAL = '20260911'; UBUNTU_CLOUDIMG_SHA256 = $script:imgSha
            UBUNTU_BASE_VHDX_ZIP_URL = 'https://example.invalid/missing.zip'; UBUNTU_BASE_VHDX_ZIP_SHA256 = $script:zipSha
            UBUNTU_BASE_VHDX_SHA256 = $script:vhdxSha }
        Mock Invoke-CloudGrangeDownload {
            $script:downloads.Add($Uri)
            if ($Uri -like '*missing.zip') { throw '404 Not Found' }
            Copy-Item -LiteralPath $script:img -Destination $OutFile
        }
        New-CloudGrangeBaseDisk -VhdxPath $script:vhdxPath -PinsPath $script:pins -WarningAction SilentlyContinue
        Should -Invoke Convert-CloudGrangeCloudImage -Times 1
    }

    It 'stops on a base VHDX checksum mismatch instead of falling back' {
        Write-Pins $script:pins @{ UBUNTU_CLOUDIMG_SERIAL = '20260911'; UBUNTU_CLOUDIMG_SHA256 = $script:imgSha
            UBUNTU_BASE_VHDX_ZIP_URL = 'https://example.invalid/base.vhdx.zip'; UBUNTU_BASE_VHDX_ZIP_SHA256 = ('0' * 64)
            UBUNTU_BASE_VHDX_SHA256 = $script:vhdxSha }
        { New-CloudGrangeBaseDisk -VhdxPath $script:vhdxPath -PinsPath $script:pins } | Should -Throw '*CG-INST-ERR-015*'
        Should -Invoke Convert-CloudGrangeCloudImage -Times 0
        Test-Path -LiteralPath $script:vhdxPath | Should -BeFalse
    }

    It 'stops on a cloud image checksum mismatch' {
        Write-Pins $script:pins @{ UBUNTU_CLOUDIMG_SERIAL = '20260911'; UBUNTU_CLOUDIMG_SHA256 = ('f' * 64)
            UBUNTU_BASE_VHDX_ZIP_URL = ''; UBUNTU_BASE_VHDX_ZIP_SHA256 = ''; UBUNTU_BASE_VHDX_SHA256 = '' }
        { New-CloudGrangeBaseDisk -VhdxPath $script:vhdxPath -PinsPath $script:pins } | Should -Throw '*CG-INST-ERR-016*'
        Should -Invoke Convert-CloudGrangeCloudImage -Times 0
    }

    It 'fails closed without a pins file' {
        { New-CloudGrangeBaseDisk -VhdxPath $script:vhdxPath -PinsPath (Join-Path $script:root 'absent.conf') } | Should -Throw '*CG-INST-ERR-014*'
    }
}

Describe 'Windows wrapper wiring' {
    BeforeAll { $script:repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }

    It 'no longer requires qemu-img before the VM is created' {
        $installer = Get-Content -LiteralPath (Join-Path $script:repo 'Install-CloudGrange.ps1') -Raw
        $installer | Should -Not -Match '(?m)^\s*Initialize-CloudGrangePrereqs\b'
        $vm = Get-Content -LiteralPath (Join-Path $script:repo 'scripts\New-CloudGrangeVm.ps1') -Raw
        $vm | Should -Match 'New-CloudGrangeBaseDisk'
        $vm | Should -Not -Match 'noble/current'
    }

    It 'forwards the relay port as well as the portal port' {
        $vm = Get-Content -LiteralPath (Join-Path $script:repo 'scripts\New-CloudGrangeVm.ps1') -Raw
        $vm | Should -Match 'Port = 8443'
        $vm | Should -Match 'Port = 443'
    }

    It 'uploads the Foundation updater with every Windows-script install' {
        $deploy = Get-Content -LiteralPath (Join-Path $script:repo 'scripts\Deploy-K3sHelm.ps1') -Raw
        foreach ($f in 'cloudgrange-updater-k3s.py', 'cloudgrange-updater-k3s.service', 'cloudgrange-signing-key.pub') {
            $deploy | Should -Match ([regex]::Escape($f))
        }
    }

    It 'pins the base VHDX in the one pins file' {
        $pins = Get-Content -LiteralPath (Join-Path $script:repo 'release\pins.conf') -Raw
        foreach ($k in 'UBUNTU_BASE_VHDX_ZIP_URL', 'UBUNTU_BASE_VHDX_ZIP_SHA256', 'UBUNTU_BASE_VHDX_SHA256') {
            $pins | Should -Match "(?m)^$k="
        }
    }
}
