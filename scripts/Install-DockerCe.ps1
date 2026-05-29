#Requires -Version 7.0
# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0
# ADR-029: Installs Docker CE inside the cloudsmith-docker VM via Hyper-V Direct connection

function Install-DockerCe {
    [CmdletBinding()]
    param(
        [string]$VmName  = 'cloudsmith-docker',
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
        [string]$VmIp = '192.168.100.10'
        # ProxyPassword is never passed to this function — it is written inside the VM only, never logged here
    )

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

echo "Starting Docker CE installation..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

ARCH=$(dpkg --print-architecture)
. /etc/os-release
REPO="deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable"
echo "$REPO" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

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

# Smoke test
docker run --rm hello-world
'@

    # Substitute the proxy placeholder safely (single-quoted in bash, so no shell expansion risk).
    $bashScript = $bashTemplate.Replace('__PROXY__', ($Proxy -replace "'", "'\''"))
    # Normalize line endings to LF. On Windows, PowerShell here-strings use CRLF.
    # When piped over SSH, bash on Linux sees `set -euo pipefail\r` where the trailing
    # CR makes 'pipefail\r' an unrecognized option name. Strip all CR characters.
    $bashScript = $bashScript -replace "`r", ''

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
            "cloudsmith@$VmIp",
            'sudo', 'bash', '-s'
        )
        $bashScript | & ssh.exe @sshArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Docker CE installation via SSH failed (exit $LASTEXITCODE)."
        }
    } else {
        if ($null -eq $Credential) {
            $Credential = Get-Credential -UserName 'cloudsmith' -Message 'VM credential'
        }
        # Hyper-V PowerShell Direct — only works if PowerShell is installed in the guest.
        # For Linux guests (Ubuntu), use the -SshKeyPath path instead.
        Invoke-Command -VMName $VmName -Credential $Credential `
            -ScriptBlock $remote -ArgumentList $bashScript
    }
}
