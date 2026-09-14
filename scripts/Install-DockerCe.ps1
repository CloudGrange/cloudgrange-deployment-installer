#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
# ADR-029: Installs Docker CE inside the cloudgrange-docker VM via Hyper-V Direct connection

function Install-DockerCe {
    [CmdletBinding()]
    param(
        [string]$VmName  = 'cloudgrange-docker',
        [bool]$UseWsl2   = $false,
        [string]$Proxy   = '',
        # Pre-built PSCredential for Hyper-V Direct (VMBus) connections.
        # When $null and $SshKeyPath is also empty, falls back to Get-Credential (interactive only).
        [System.Management.Automation.PSCredential]$Credential = $null,
        # Path to the SSH private key file for connecting to the VM guest.
        # When provided, SSH is used instead of Hyper-V PowerShell Direct.
        # SSH is the preferred path for Linux guests (Ubuntu does not ship PowerShell).
        [string]$SshKeyPath = '',
        # VM IP address used for SSH connections. Required when $SshKeyPath is provided.
        [string]$VmIp = '192.168.100.10',
        # AB#8129: Bundled mode. Local directory holding the pinned Docker CE .deb set
        # (debs/, SHA256SUMS, versions.txt). When set, packages are uploaded and installed
        # with no network access in the guest.
        [string]$OfflinePackagesPath = ''
        # ProxyPassword is never passed to this function — it is written inside the VM only, never logged here
    )
    $remoteDebDir = '/var/tmp/cloudgrange-docker-debs'

    # Bash payload executed inside the Linux guest (Ubuntu). Kept as a single-quoted PowerShell
    # here-string so PowerShell never tries to parse '$' or backticks — bash receives the script
    # verbatim. The PROXY placeholder is substituted in PowerShell before the script ships.
    $bashTemplate = @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Block until cloud-init finishes all stages (package_update, package_install, runcmd).
# This is the definitive fix for apt lock races on first boot — cloud-init holds
# /var/lib/apt/lists/lock and /var/lib/dpkg/lock-frontend while it runs its
# package phase. Waiting for cloud-init to complete eliminates all races.
echo "Waiting for cloud-init to complete..."
sudo cloud-init status --wait --long 2>/dev/null || true
echo "cloud-init done: $(sudo cloud-init status 2>/dev/null || echo unknown)"

OFFLINE_DIR='__OFFLINE_DIR__'
if [ -n "$OFFLINE_DIR" ]; then
    # AB#8129 Bundled mode: install the pinned .deb set shipped in the bundle. No network access.
    echo "Installing Docker CE from bundled packages in $OFFLINE_DIR (offline)..."
    # SHA256SUMS lists bare .deb file names relative to debs/ (as produced by the bundle build).
    cat "$OFFLINE_DIR/versions.txt"
    cd "$OFFLINE_DIR/debs"
    sha256sum -c --quiet ../SHA256SUMS
    echo "Bundled Docker CE packages verified: $(ls *.deb | wc -l)"
    # Absolute paths to local .deb files. No --no-download: with it apt hands dpkg cache-relative
    # names and fails ("Pathname to install is not absolute"). Nothing is fetched because every
    # dependency is satisfied by the listed files or the base image; with no network any fetch
    # attempt would fail the install rather than silently succeed.
    apt-get install -y -qq --allow-downgrades "$OFFLINE_DIR"/debs/*.deb
    cd /
else
    echo "Starting Docker CE installation..."
    apt-get update -qq
    # jq is used by Deploy-DockerCompose's service-state check (AB#1590); without it the check passes vacuously.
    apt-get install -y -qq ca-certificates curl gnupg jq

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    ARCH=$(dpkg --print-architecture)
    . /etc/os-release
    REPO="deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable"
    echo "$REPO" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

systemctl enable docker
systemctl start docker

PROXY='__PROXY__'
if [ -n "$PROXY" ]; then
    mkdir -p /etc/systemd/system/docker.service.d
    # Credentials are written only if provided; they are never echoed to stdout.
    {
        echo "[Service]"
        echo "Environment=HTTP_PROXY=${PROXY}"
        echo "Environment=HTTPS_PROXY=${PROXY}"
        echo "Environment=NO_PROXY=localhost,127.0.0.1"
    } | tee /etc/systemd/system/docker.service.d/proxy.conf > /dev/null
    systemctl daemon-reload
    systemctl restart docker
fi
exit 0
'@

    # Substitute the proxy placeholder safely (single-quoted in bash, so no shell expansion risk).
    $bashScript = $bashTemplate.Replace('__PROXY__', ($Proxy -replace "'", "'\''"))
    $offlineDir = if (-not [string]::IsNullOrEmpty($OfflinePackagesPath)) { $remoteDebDir } else { '' }
    $bashScript = $bashScript.Replace('__OFFLINE_DIR__', $offlineDir)
    # Normalize line endings to LF — byte-level strip to handle any CRLF combination.
    # PowerShell here-strings on Windows embed CRLF; bash rejects \r in pipefail option names.
    $bashBytes  = [System.Text.Encoding]::UTF8.GetBytes($bashScript)
    $bashBytes  = [byte[]]($bashBytes | Where-Object { $_ -ne 13 })
    $bashScript = [System.Text.Encoding]::UTF8.GetString($bashBytes)

    # PowerShell-side scriptblock that simply pipes the bash payload to bash on the guest.
    # The guest receives the bash script via stdin; no temp file, no quoting hazards.
    $remote = {
        param([string]$Script)
        $Script | bash -s
    }

    if ($UseWsl2) {
        $bashScript | wsl -d Ubuntu -u root -- bash -s
    } elseif (-not [string]::IsNullOrEmpty($SshKeyPath)) {
        # SSH path — preferred for Linux guests. Pipe the bash script via stdin.
        # -o StrictHostKeyChecking=no / -o UserKnownHostsFile=/dev/null so the
        # ephemeral guest key doesn't cause a prompt; the VM is freshly provisioned
        # and its host key is not yet trusted on the host.
        $sshArgs = @(
            '-i', $SshKeyPath,
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
            '-o', 'LogLevel=ERROR',
            "cloudgrange@$VmIp",
            'sudo', 'bash', '-s'
        )
        if (-not [string]::IsNullOrEmpty($OfflinePackagesPath)) {
            if (-not (Test-Path (Join-Path $OfflinePackagesPath 'SHA256SUMS'))) {
                Write-Error "CG-INST-ERR-011: bundled Docker CE packages are incomplete at $OfflinePackagesPath (SHA256SUMS missing)."
            }
            Write-Host "  Uploading bundled Docker CE packages..." -ForegroundColor Gray
            $sshOnly = @('-i', $SshKeyPath, '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR')
            $stageParent = '/var/tmp/cloudgrange-docker-debs-stage'
            & ssh.exe @sshOnly "cloudgrange@$VmIp" "rm -rf $stageParent $remoteDebDir && mkdir -p $stageParent"
            if ($LASTEXITCODE -ne 0) { Write-Error "CG-INST-ERR-011: cannot prepare package upload directory (exit $LASTEXITCODE)." }
            # Copy the directory itself (no local wildcard expansion), then move it into place.
            & scp.exe -r @sshOnly ((Resolve-Path $OfflinePackagesPath).Path) "cloudgrange@${VmIp}:$stageParent/"
            if ($LASTEXITCODE -ne 0) { Write-Error "CG-INST-ERR-011: upload of bundled Docker CE packages failed (exit $LASTEXITCODE)." }
            $leaf = Split-Path -Leaf ((Resolve-Path $OfflinePackagesPath).Path)
            & ssh.exe @sshOnly "cloudgrange@$VmIp" "mv $stageParent/$leaf $remoteDebDir && rmdir $stageParent"
            if ($LASTEXITCODE -ne 0) { Write-Error "CG-INST-ERR-011: staging of bundled Docker CE packages failed (exit $LASTEXITCODE)." }
        }
        # Write raw bytes directly to SSH stdin — PowerShell's string pipeline appends
        # \r\n (Windows [Environment]::NewLine) which corrupts the last bash command.
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'ssh.exe'
        foreach ($arg in $sshArgs) { $psi.ArgumentList.Add($arg) }
        $psi.RedirectStandardInput = $true
        $psi.UseShellExecute = $false
        $sshProc = [System.Diagnostics.Process]::new()
        $sshProc.StartInfo = $psi
        $sshProc.Start() | Out-Null
        $sshProc.StandardInput.BaseStream.Write($bashBytes, 0, $bashBytes.Length)
        $sshProc.StandardInput.Close()
        $sshProc.WaitForExit()
        if ($sshProc.ExitCode -ne 0) {
            Write-Error "Docker CE installation via SSH failed (exit $($sshProc.ExitCode))."
        }
    } else {
        if ($null -eq $Credential) {
            $Credential = Get-Credential -UserName 'cloudgrange' -Message 'VM credential'
        }
        # Hyper-V PowerShell Direct — only works if PowerShell is installed in the guest.
        # For Linux guests (Ubuntu), use the -SshKeyPath path instead.
        Invoke-Command -VMName $VmName -Credential $Credential `
            -ScriptBlock $remote -ArgumentList $bashScript
    }
}
