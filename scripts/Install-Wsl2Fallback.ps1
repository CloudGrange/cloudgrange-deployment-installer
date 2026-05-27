#Requires -Version 7.0
# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0
# AB#1597 — WSL2 fallback deploy helper (not supported for production use)

function Install-Wsl2Fallback {
    <#
    .SYNOPSIS
        Configures WSL2 and deploys the CloudSmith Docker Compose stack inside the
        WSL2 Ubuntu distribution.

    .DESCRIPTION
        AB#1597: WSL2 mode is a dev/lab deployment path only. It is NOT supported
        for production use. This function:
          1. Generates a .wslconfig in $env:USERPROFILE with memory/cpu limits.
          2. Ensures the Ubuntu WSL2 distribution is available and running.
          3. Installs Docker CE inside the WSL2 distribution if not already present.
          4. Copies the compose stack and starts it.
          5. Verifies the portal is reachable at http://localhost.

        The prominent [WARNING] banner is mandatory per the acceptance criteria.
    #>
    [CmdletBinding()]
    param(
        [string]$DistroName  = 'Ubuntu',
        [string]$VmIp        = '127.0.0.1',
        [string]$Version     = 'latest',
        [int]$MemoryLimitGB  = 4,
        [int]$ProcessorCount = 2
    )

    # AB#1597 Step 4: Prominent production-use warning — mandatory.
    Write-Host ""
    Write-Host "  ################################################################" -ForegroundColor Yellow
    Write-Host "  [WARNING] WSL2 mode is not supported for production use." -ForegroundColor Yellow
    Write-Host "  Use Hyper-V (Online/Bundled/Appliance) mode for production." -ForegroundColor Yellow
    Write-Host "  ################################################################" -ForegroundColor Yellow
    Write-Host ""

    # AB#1597 Step 1: Generate .wslconfig with memory/cpu limits for CloudSmith.
    # These limits prevent the WSL2 VM from consuming the entire host's RAM during
    # image pulls or migrations.
    $wslConfig = @"
[wsl2]
memory=${MemoryLimitGB}GB
processors=$ProcessorCount
swap=0
localhostForwarding=true
"@
    $wslConfigPath = Join-Path $env:USERPROFILE '.wslconfig'
    Set-Content -Path $wslConfigPath -Value $wslConfig -Encoding UTF8
    Write-Host "  .wslconfig written to $wslConfigPath" -ForegroundColor Gray

    # Shutdown WSL2 to apply the new .wslconfig before starting.
    Write-Host "  Restarting WSL2 to apply .wslconfig limits..." -ForegroundColor Gray
    & wsl.exe --shutdown 2>$null

    # AB#1597 Step 2: Verify that the Ubuntu distribution exists and is WSL2.
    Write-Progress-Step "Checking WSL2 Ubuntu distribution"
    $wslList = & wsl.exe --list --verbose 2>&1 | Out-String
    if ($wslList -notmatch $DistroName) {
        Write-Host "  Ubuntu distribution not found — installing from Microsoft Store..." -ForegroundColor Gray
        # wsl --install installs Ubuntu by default and enables WSL2 automatically.
        & wsl.exe --install --distribution Ubuntu --no-launch
        if ($LASTEXITCODE -ne 0) {
            Write-Error "WSL2 Ubuntu install failed (exit $LASTEXITCODE). Run 'wsl --install' manually and re-run the installer."
        }
        Write-Host "  Ubuntu installed. A system reboot may be required to complete WSL2 setup." -ForegroundColor Yellow
    }

    # Ensure WSL2 is the default version.
    & wsl.exe --set-default-version 2 2>$null

    Write-Host "  WSL2 Ubuntu: available" -ForegroundColor Green

    # AB#1597 Step 3: Install Docker CE inside WSL2 if not present.
    Write-Progress-Step "Verifying Docker CE inside WSL2"
    $dockerCheck = & wsl.exe -d $DistroName -u root -- which docker 2>$null
    if (-not $dockerCheck) {
        Write-Host "  Docker not found — installing Docker CE inside WSL2..." -ForegroundColor Gray
        $dockerInstallScript = @'
set -euo pipefail
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
ARCH=$(dpkg --print-architecture)
. /etc/os-release
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
service docker start || true
'@
        $dockerInstallScript -replace "`r", '' | & wsl.exe -d $DistroName -u root -- bash -s
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Docker CE install inside WSL2 failed (exit $LASTEXITCODE)."
        }
    }

    # Ensure the Docker daemon is running inside WSL2.
    & wsl.exe -d $DistroName -u root -- service docker start 2>$null
    Write-Host "  Docker CE: available" -ForegroundColor Green

    # Copy the compose stack into /opt/cloudsmith inside WSL2.
    Write-Progress-Step "Deploying CloudSmith compose stack inside WSL2"
    $composeSrc = Join-Path $PSScriptRoot '..\compose'
    $composeSrcAbs = (Resolve-Path -LiteralPath $composeSrc).Path
    # Convert Windows path to WSL2 mount path (e.g., C:\foo -> /mnt/c/foo).
    $wslMountPath = '/mnt/' + ($composeSrcAbs -replace '\\','/' -replace '^([A-Za-z]):','$1').ToLower()
    $wslMountPath = $wslMountPath -replace '/+','/' # collapse double slashes

    & wsl.exe -d $DistroName -u root -- mkdir -p /opt/cloudsmith
    & wsl.exe -d $DistroName -u root -- bash -c "cp -r ${wslMountPath}/. /opt/cloudsmith/"

    # Generate a random DB password in memory only — never written to any host file.
    $dbPassword = [Convert]::ToBase64String(
        (1..24 | ForEach-Object { [byte](Get-Random -Maximum 256) })
    ) -replace '[^a-zA-Z0-9]','X'

    $wslDeployScript = @"
set -euo pipefail
export DB_PASSWORD="$dbPassword"
export CLOUDSMITH_VERSION="$Version"
cd /opt/cloudsmith
docker compose pull
docker compose up -d --remove-orphans

echo "Waiting for services (timeout 60s)..."
TIMEOUT=60; ELAPSED=0
while [ \$ELAPSED -lt \$TIMEOUT ]; do
    NOT_RUNNING=`$(docker compose ps --format json 2>/dev/null \
        | jq -r 'select(.State != "running") | .Name' 2>/dev/null || true)
    if [ -z "\$NOT_RUNNING" ]; then echo "All services running."; break; fi
    sleep 5; ELAPSED=`$((ELAPSED+5))
done
if [ \$ELAPSED -ge \$TIMEOUT ]; then
    echo "Some services not running after \${TIMEOUT}s:"; docker compose ps; exit 1
fi
"@

    $wslDeployScript -replace "`r", '' | & wsl.exe -d $DistroName -u root -- bash -s
    if ($LASTEXITCODE -ne 0) {
        Write-Error "CloudSmith compose deploy inside WSL2 failed (exit $LASTEXITCODE)."
    }

    # AB#1597 Step 5: Verify portal is reachable at http://localhost.
    # WSL2 localhostForwarding=true in .wslconfig forwards port 80 automatically.
    Write-Progress-Step "Verifying portal reachability at http://localhost"
    $portalOk = $false
    $deadline  = [DateTime]::UtcNow.AddSeconds(60)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri 'http://localhost' -TimeoutSec 5 -ErrorAction Stop
            if ($r.StatusCode -lt 400) { $portalOk = $true; break }
        } catch { }
        Start-Sleep -Seconds 5
    }
    if (-not $portalOk) {
        Write-Warning "Portal did not respond at http://localhost within 60s. Check WSL2 container logs with: wsl -d Ubuntu -u root -- docker compose -f /opt/cloudsmith/docker-compose.yml logs --tail=50"
    } else {
        Write-Host "  Portal reachable at http://localhost" -ForegroundColor Green
    }
}
