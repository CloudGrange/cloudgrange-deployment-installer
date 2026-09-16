#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0

# AB#9185: K3s/Helm counterpart to Deploy-DockerCompose.ps1 — same calling convention
# (VmName/VmIp/Version/UseWsl2/Credential/SshKeyPath), same bounded ssh/scp transport
# (Get-CloudGrangeSshOptions, Invoke-CloudGrangeSsh), reusing the SAME Hyper-V VM
# provisioning Install-CloudGrange.ps1 already does for Compose — a Linux VM with SSH
# access is exactly what K3s needs too, no separate VM flow required. Runs alongside
# Deploy-DockerCompose.ps1, not instead of it, per the plan's parallel-support period.
. (Join-Path $PSScriptRoot 'CloudGrange-Common.ps1')

function Deploy-K3sHelm {
    [CmdletBinding()]
    param(
        [string]$VmName  = 'cloudgrange-k3s',
        [string]$VmIp    = '192.168.100.10',
        [string]$Version = 'latest',
        [bool]$UseWsl2   = $false,
        [System.Management.Automation.PSCredential]$Credential = $null,
        [string]$SshKeyPath = ''
    )

    if ($UseWsl2 -or [string]::IsNullOrEmpty($SshKeyPath)) {
        throw "CG-K3S-ERR-001: Deploy-K3sHelm currently requires SSH-key auth to a Linux VM (UseWsl2/Credential paths not yet supported for the K3s engine)."
    }

    $sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $sshOpts    = Get-CloudGrangeSshOptions -KeyPath $SshKeyPath
    $sshTarget  = "cloudgrange@$VmIp"
    $uploadDir  = '/tmp/cloudgrange-k3s-install'

    Write-Host "  Uploading K3s installer + Helm charts to $VmIp..." -ForegroundColor DarkCyan
    Invoke-CloudGrangeSsh -ArgumentList ($sshOpts + @($sshTarget, "rm -rf $uploadDir && mkdir -p $uploadDir/scripts")) -TimeoutSeconds 120

    # Same per-file scp pattern Deploy-DockerCompose.ps1 uses for the compose/ tree —
    # scp has no reliable recursive-copy flag behavior across OpenSSH client versions,
    # so each file is uploaded individually with its relative path preserved.
    $filesToUpload = @(
        (Join-Path $sourceRoot 'scripts\Install-CloudGrangeK3s.sh'),
        (Join-Path $sourceRoot 'scripts\New-ArtifactManifest.sh')
    )
    $filesToUpload += Get-ChildItem -Path (Join-Path $sourceRoot 'charts') -Recurse -File

    foreach ($f in $filesToUpload) {
        $fileInfo = if ($f -is [System.IO.FileInfo]) { $f } else { Get-Item -LiteralPath $f }
        $rel = $fileInfo.FullName.Substring($sourceRoot.Length + 1) -replace '\\', '/'
        $destDir = "$uploadDir/$(Split-Path $rel -Parent)" -replace '\\', '/'
        if ($destDir -ne "$uploadDir/") {
            Invoke-CloudGrangeSsh -ArgumentList ($sshOpts + @($sshTarget, "mkdir -p $destDir")) -TimeoutSeconds 120
        }
        Invoke-CloudGrangeSsh -Tool scp -ArgumentList ($sshOpts + @($fileInfo.FullName, "${sshTarget}:${uploadDir}/$rel")) -TimeoutSeconds 120
    }

    Write-Host "  Running the K3s/Helm installer on $VmIp (this can take several minutes)..." -ForegroundColor DarkCyan
    # scripts/ and charts/ land as siblings under $uploadDir, matching
    # Install-CloudGrangeK3s.sh's own $(dirname .../..)/charts resolution.
    $remoteCmd = "chmod +x $uploadDir/scripts/*.sh && sudo bash $uploadDir/scripts/Install-CloudGrangeK3s.sh --hostname $VmIp --version $Version"
    Invoke-CloudGrangeSsh -ArgumentList ($sshOpts + @($sshTarget, $remoteCmd)) -TimeoutSeconds 1800
    if ($LASTEXITCODE -ne 0) {
        throw "CG-K3S-ERR-002: Install-CloudGrangeK3s.sh exited $LASTEXITCODE on the VM. SSH in to inspect: ssh -i $SshKeyPath $sshTarget"
    }

    Invoke-CloudGrangeSsh -ArgumentList ($sshOpts + @($sshTarget, "rm -rf $uploadDir")) -TimeoutSeconds 60
    Write-Host "  K3s/Helm deploy complete." -ForegroundColor Green
}
