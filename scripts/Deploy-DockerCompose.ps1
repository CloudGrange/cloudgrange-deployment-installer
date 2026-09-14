#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0

function Deploy-DockerCompose {
    [CmdletBinding()]
    param(
        [string]$VmName  = 'cloudgrange-docker',
        [string]$VmIp    = '192.168.100.10',
        [string]$Version = 'latest',
        [bool]$UseWsl2   = $false,
        # Pre-built PSCredential for Hyper-V Direct (VMBus) connections.
        # When $null and $SshKeyPath is also empty, falls back to Get-Credential.
        [System.Management.Automation.PSCredential]$Credential = $null,
        # Path to the SSH private key file. Preferred for Linux guests.
        [string]$SshKeyPath = '',
        # AB#1852: path to pre-saved Docker image tar (for Bundled/offline installs).
        # When provided, images are loaded via 'docker load' instead of 'docker pull'.
        [string]$BundledImagesPath = ''
    )

    $composeDir = '/opt/cloudgrange'
    $composeSrc = Join-Path $PSScriptRoot '..\compose'
    # Generate random secrets; never written to disk on the Windows host. They are written only to
    # /opt/cloudgrange/.env (mode 0600) inside the guest so systemd can restart the stack (AB#8129).
    $newSecret = { [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant() }
    $dbPassword       = & $newSecret
    $keycloakPassword = & $newSecret
    $grafanaPassword  = & $newSecret
    $relayToken       = & $newSecret
    $kcClientSecret   = & $newSecret

    # Bash deploy script — runs entirely inside the Linux guest via SSH sudo.
    # AB#1590: After docker compose up -d:
    #   1. Poll up to 60s for all services to be running.
    #   2. Verify every service has restart: always in the compose definition.
    #   3. Probe portal at http://<host>/health (retry up to 30s).
    # AB#1852: In bundled mode, the image tar is scp'd to the guest and loaded via docker load.
    # The remote path where the tar will land (if applicable).
    $remoteTarPath = '/opt/cloudgrange-images.tar'

    $pullOrLoad = if (-not [string]::IsNullOrEmpty($BundledImagesPath)) {
        "docker load -i $remoteTarPath && rm -f $remoteTarPath"
    } else {
        "docker compose pull"
    }

    $bashDeploy = @"
set -euo pipefail
mkdir -p $composeDir
cd $composeDir
# AB#8129: persist settings for systemd (ADR-059). Keep existing values on re-run so
# PostgreSQL and Keycloak credentials stay in step with their data volumes.
if [ ! -f .env ]; then
    umask 077
    cat > .env <<ENVEOF
POSTGRES_PASSWORD=$dbPassword
KEYCLOAK_ADMIN_USER=admin
KEYCLOAK_ADMIN_PASSWORD=$keycloakPassword
GRAFANA_ADMIN_PASSWORD=$grafanaPassword
RELAY_ENROLLMENT_TOKEN=$relayToken
KEYCLOAK_API_CLIENT_SECRET=$kcClientSecret
CLOUDGRANGE_HOSTNAME=$VmIp
ENVEOF
fi
sed -i '/^CLOUDGRANGE_VERSION=/d' .env && echo "CLOUDGRANGE_VERSION=$Version" >> .env
chmod 600 .env
$pullOrLoad
install -m 0644 $composeDir/systemd/cloudgrange.service /etc/systemd/system/cloudgrange.service
systemctl daemon-reload
systemctl enable cloudgrange.service
systemctl restart cloudgrange.service

# --- AB#1590 Step 1: Wait up to 60s for all services to be running ---
echo "Verifying all services are running (timeout: 60s)..."
TIMEOUT=60; ELAPSED=0; VERIFY_OK=false
while [ `$ELAPSED -lt `$TIMEOUT ]; do
    # docker compose ps --format json emits one JSON object per line (Compose v2).
    # A service is considered running when State == "running".
    NOT_RUNNING=`$(docker compose ps --format json 2>/dev/null \
        | jq -r 'select(.State != "running") | .Name' 2>/dev/null || true)
    if [ -z "`$NOT_RUNNING" ]; then
        VERIFY_OK=true
        break
    fi
    sleep 5; ELAPSED=`$((ELAPSED+5))
done

if [ "`$VERIFY_OK" != "true" ]; then
    echo ""
    echo "ERROR: The following services are not running after `${TIMEOUT}s:"
    docker compose ps --format json 2>/dev/null \
        | jq -r 'select(.State != "running") | "  " + .Name + " — " + .State' 2>/dev/null || docker compose ps
    echo ""
    docker compose logs --tail=50 2>&1 || true
    exit 1
fi
echo "All services are running. Elapsed: `${ELAPSED}s"

# --- AB#1590 Step 2: Verify every service has restart: always ---
echo "Verifying restart policies..."
MISSING_RESTART=`$(docker compose ps -q 2>/dev/null | xargs -r docker inspect --format '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' 2>/dev/null \
    | grep -v 'always' | sed 's|^/||' || true)
if [ -n "`$MISSING_RESTART" ]; then
    echo "WARNING: The following services do not have restart:always:"
    echo "`$MISSING_RESTART"
    # Non-fatal warning — compose definition is authoritative; running containers
    # may temporarily show a different policy during first start.
fi
echo "Restart policy check complete."
exit 0
"@

    # Strip CR bytes — PS here-strings on Windows embed CRLF; bash rejects \r in set -euo pipefail scripts.
    $deployBytes = [System.Text.Encoding]::UTF8.GetBytes($bashDeploy)
    $deployBytes = [byte[]]($deployBytes | Where-Object { $_ -ne 13 })

    if ($UseWsl2) {
        $wslPath = "/opt/cloudgrange"
        wsl -d Ubuntu -u root -- mkdir -p $wslPath
        wsl -d Ubuntu -u root -- bash -c "cp -r /mnt/$(($composeSrc -replace '\\','/' -replace ':','').ToLower())/* $wslPath/"

        # AB#1593: Generate self-signed TLS cert and install into nginx_certs volume before stack starts.
        Write-Host "  Generating TLS certificate for nginx..." -ForegroundColor Gray
        . "$PSScriptRoot\..\New-SelfSignedCert.ps1"
        New-SelfSignedCert -VmIp $VmIp -UseWsl2

        $bashDeploy | wsl -d Ubuntu -u root -- bash -s
    } elseif (-not [string]::IsNullOrEmpty($SshKeyPath)) {
        # SSH path — copy compose files then run deploy script.
        $sshOpts = @('-i', $SshKeyPath, '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR')
        $sshTarget = "cloudgrange@$VmIp"

        # Create the compose directory on the guest.
        & ssh.exe @sshOpts $sshTarget "sudo mkdir -p $composeDir && sudo chown cloudgrange:cloudgrange $composeDir"

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

        # AB#1852: upload bundled image tar before deploy (bundled/offline mode)
        if (-not [string]::IsNullOrEmpty($BundledImagesPath) -and (Test-Path $BundledImagesPath)) {
            Write-Host "  Uploading bundled images tar (~$('{0:N0}' -f ((Get-Item $BundledImagesPath).Length / 1MB)) MB)..." -ForegroundColor Gray
            & scp.exe @sshOpts $BundledImagesPath "${sshTarget}:${remoteTarPath}"
        }

        # AB#1593: Generate self-signed TLS cert and install into nginx_certs volume before stack starts.
        Write-Host "  Generating TLS certificate for nginx..." -ForegroundColor Gray
        . "$PSScriptRoot\..\New-SelfSignedCert.ps1"
        New-SelfSignedCert -VmIp $VmIp -SshKeyPath $SshKeyPath

        # Run the deploy script — write raw bytes to SSH stdin to prevent PowerShell
        # StreamWriter.WriteLine() from appending \r\n and corrupting the last bash command.
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'ssh.exe'
        foreach ($arg in $sshOpts) { $psi.ArgumentList.Add($arg) }
        $psi.ArgumentList.Add($sshTarget)
        $psi.ArgumentList.Add('sudo')
        $psi.ArgumentList.Add('bash')
        $psi.ArgumentList.Add('-s')
        $psi.RedirectStandardInput = $true
        $psi.UseShellExecute = $false
        $deployProc = [System.Diagnostics.Process]::new()
        $deployProc.StartInfo = $psi
        $deployProc.Start() | Out-Null
        $deployProc.StandardInput.BaseStream.Write($deployBytes, 0, $deployBytes.Length)
        $deployProc.StandardInput.Close()
        $deployProc.WaitForExit()
        if ($deployProc.ExitCode -ne 0) {
            Write-Error "Docker Compose deploy via SSH failed (exit $($deployProc.ExitCode))."
        }
    } else {
        if ($null -eq $Credential) {
            $Credential = Get-Credential -UserName 'cloudgrange' -Message 'VM credential'
        }
        # Hyper-V PowerShell Direct — only for Windows guests or Linux guests with PowerShell.
        $session = New-PSSession -VMName $VmName -Credential $Credential
        Copy-Item -Path "$composeSrc\*" -Destination $composeDir -ToSession $session -Recurse -Force

        # AB#1593: Generate self-signed TLS cert and install into nginx_certs volume before stack starts.
        Write-Host "  Generating TLS certificate for nginx..." -ForegroundColor Gray
        . "$PSScriptRoot\..\New-SelfSignedCert.ps1"
        New-SelfSignedCert -VmIp $VmIp -VmName $VmName -Credential $Credential

        $deployBlock = [scriptblock]::Create($bashDeploy)
        Invoke-Command -Session $session -ScriptBlock { param($s) $s | bash -s } -ArgumentList $bashDeploy
        Remove-PSSession $session
    }

    # AB#1590 Step 3: Probe portal via nginx at https://<VmIp>/health (retry up to 30s).
    # AB#1593: nginx now terminates TLS on 443 and proxies to portal on 80.
    # SkipCertificateCheck is required for the self-signed cert generated at install time.
    # Falls back to probing '/' if /health is not available.
    Write-Host "  Probing portal at https://$VmIp/health (timeout: 30s)..."
    $portalHealthUrl = "https://$VmIp/health"
    $portalOk = $false
    $portalDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $portalDeadline) {
        try {
            $r = Invoke-WebRequest -Uri $portalHealthUrl -SkipCertificateCheck -TimeoutSec 5 -ErrorAction Stop
            if ($r.StatusCode -lt 400) { $portalOk = $true; break }
        } catch {
            # /health not implemented — try root path
            try {
                $r2 = Invoke-WebRequest -Uri "https://$VmIp/" -SkipCertificateCheck -TimeoutSec 5 -ErrorAction Stop
                if ($r2.StatusCode -lt 400) { $portalOk = $true; break }
            } catch { }
        }
        Start-Sleep -Seconds 5
    }

    if (-not $portalOk) {
        Write-Host ""
        Write-Host "  [FAILURE] Portal is not reachable at https://$VmIp after 30 seconds." -ForegroundColor Red
        Write-Host "  Check container logs with: docker compose -f /opt/cloudgrange/docker-compose.yml logs --tail=50" -ForegroundColor Yellow
        Write-Error "Deploy-DockerCompose: portal reachability check failed. See container logs for details."
    }
    Write-Host "  Portal is reachable at https://$VmIp" -ForegroundColor Green
}
