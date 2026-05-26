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
        # When $null, falls back to Get-Credential (interactive only).
        # Pass this from the caller when running non-interactively (-AcceptDefaults).
        [System.Management.Automation.PSCredential]$Credential = $null
    )

    $composeDir   = '/opt/cloudsmith'
    $composeSrc   = Join-Path $PSScriptRoot '..\compose'
    $dbPassword   = [System.Web.Security.Membership]::GeneratePassword(32, 4)

    $deployScript = {
        param([string]$ComposeDir, [string]$DbPassword, [string]$Version)
        mkdir -p $ComposeDir
        export DB_PASSWORD="$DbPassword"
        export CLOUDSMITH_VERSION="$Version"
        cd $ComposeDir
        docker compose pull
        docker compose up -d
        # Wait for all containers healthy
        $timeout = 120; $elapsed = 0
        while ($elapsed -lt $timeout) {
            $unhealthy = docker compose ps --format json | jq -r 'select(.Health != "healthy" and .Health != "") | .Name' 2>/dev/null
            if (-not $unhealthy) { break }
            Start-Sleep 5; $elapsed += 5
        }
    }

    # Copy compose files to VM
    if ($UseWsl2) {
        $wslPath = "/opt/cloudsmith"
        wsl -d Ubuntu -u root -- mkdir -p $wslPath
        wsl -d Ubuntu -u root -- bash -c "cp /mnt/$(($composeSrc -replace '\\','/' -replace ':','').ToLower())/* $wslPath/"
        wsl -d Ubuntu -u root -- pwsh -Command $deployScript.ToString() -Args $composeDir, $dbPassword, $Version
    } else {
        if ($null -eq $Credential) {
            $Credential = Get-Credential -UserName 'cloudsmith' -Message 'VM credential'
        }
        # Copy compose files
        $session = New-PSSession -VMName $VmName -Credential $Credential
        Copy-Item -Path "$composeSrc\*" -Destination $composeDir -ToSession $session -Recurse -Force
        Invoke-Command -Session $session -ScriptBlock $deployScript -ArgumentList $composeDir, $dbPassword, $Version
        Remove-PSSession $session
    }

    # Verify portal reachable
    Write-Host "  Waiting for CloudSmith portal at https://$VmIp ..."
    $ok = Wait-ForHttpOk -Url "https://$VmIp/health" -TimeoutSeconds 120
    if ($ok) {
        Write-Host "  Portal is live" -ForegroundColor Green
    } else {
        Write-Warning "Portal did not become reachable within 2 minutes. Check container logs."
    }
}
