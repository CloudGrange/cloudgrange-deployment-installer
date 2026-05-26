#Requires -Version 7.0
# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0

function Deploy-DockerCompose {
    [CmdletBinding()]
    param(
        [string]$VmName  = 'cloudsmith-docker',
        [string]$VmIp    = '192.168.100.10',
        [string]$Version = 'latest',
        [bool]$UseWsl2   = $false,
        # Pre-built PSCredential for Hyper-V Direct (VMBus) connections.
        # When $null and $SshKeyPath is also empty, falls back to Get-Credential.
        [System.Management.Automation.PSCredential]$Credential = $null,
        # Path to the SSH private key file. Preferred for Linux guests.
        [string]$SshKeyPath = ''
    )

    $composeDir = '/opt/cloudsmith'
    $composeSrc = Join-Path $PSScriptRoot '..\compose'
    # Generate a random DB password; never written to disk on the host.
    $dbPassword = [Convert]::ToBase64String((1..24 | ForEach-Object { [byte](Get-Random -Maximum 256) })) -replace '[^a-zA-Z0-9]','X'

    # Bash deploy script — runs entirely inside the Linux guest via SSH sudo.
    $bashDeploy = @"
set -euo pipefail
mkdir -p $composeDir
export DB_PASSWORD="$dbPassword"
export CLOUDSMITH_VERSION="$Version"
cd $composeDir
docker compose pull
docker compose up -d
# Wait up to 120 seconds for all containers to be healthy
TIMEOUT=120; ELAPSED=0
while [ \$ELAPSED -lt \$TIMEOUT ]; do
    UNHEALTHY=\$(docker compose ps --format json 2>/dev/null | jq -r 'select(.Health != "healthy" and .Health != "") | .Name' 2>/dev/null || true)
    [ -z "\$UNHEALTHY" ] && break
    sleep 5; ELAPSED=\$((ELAPSED+5))
done
echo "Stack deployed. Elapsed: \${ELAPSED}s"
"@

    if ($UseWsl2) {
        $wslPath = "/opt/cloudsmith"
        wsl -d Ubuntu -u root -- mkdir -p $wslPath
        wsl -d Ubuntu -u root -- bash -c "cp /mnt/$(($composeSrc -replace '\\','/' -replace ':','').ToLower())/* $wslPath/"
        $bashDeploy | wsl -d Ubuntu -u root -- bash -s
    } elseif (-not [string]::IsNullOrEmpty($SshKeyPath)) {
        # SSH path — copy compose files then run deploy script.
        $sshOpts = @('-i', $SshKeyPath, '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR')
        $sshTarget = "cloudsmith@$VmIp"

        # Create the compose directory on the guest.
        & ssh.exe @sshOpts $sshTarget "sudo mkdir -p $composeDir && sudo chown cloudsmith:cloudsmith $composeDir"

        # Copy each compose file via scp.
        $composeFiles = Get-ChildItem -Path $composeSrc -Recurse -File
        foreach ($f in $composeFiles) {
            $rel = $f.FullName.Substring($composeSrc.Length).TrimStart('\', '/')
            $destDir = "$composeDir/$(($rel | Split-Path -Parent) -replace '\\','/')".TrimEnd('/')
            if ($destDir -ne $composeDir) {
                & ssh.exe @sshOpts $sshTarget "mkdir -p $destDir"
            }
            & scp.exe @sshOpts $f.FullName "${sshTarget}:${composeDir}/$($rel -replace '\\','/')"
        }

        # Run the deploy script.
        $bashDeploy | & ssh.exe @sshOpts $sshTarget 'sudo bash -s'
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Docker Compose deploy via SSH failed (exit $LASTEXITCODE)."
        }
    } else {
        if ($null -eq $Credential) {
            $Credential = Get-Credential -UserName 'cloudsmith' -Message 'VM credential'
        }
        # Hyper-V PowerShell Direct — only for Windows guests or Linux guests with PowerShell.
        $session = New-PSSession -VMName $VmName -Credential $Credential
        Copy-Item -Path "$composeSrc\*" -Destination $composeDir -ToSession $session -Recurse -Force
        $deployBlock = [scriptblock]::Create($bashDeploy)
        Invoke-Command -Session $session -ScriptBlock { param($s) $s | bash -s } -ArgumentList $bashDeploy
        Remove-PSSession $session
    }

    # Verify portal reachable (HTTP on port 80 is the default; HTTPS on 443 requires cert setup).
    Write-Host "  Waiting for CloudSmith API at http://$VmIp ..."
    $ok = Wait-ForHttpOk -Url "http://$VmIp/api/v1/health" -TimeoutSeconds 300
    if ($ok) {
        Write-Host "  API is live" -ForegroundColor Green
    } else {
        Write-Warning "API did not become reachable within 5 minutes. Check container logs."
    }
}
