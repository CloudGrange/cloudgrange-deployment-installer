#Requires -Version 7.0
# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0

function Initialize-CloudSmith {
    [CmdletBinding()]
    param(
        [string]$VmName  = 'cloudsmith-docker',
        [bool]$UseWsl2   = $false
    )

    $initScript = {
        # Generate master secrets key (AES-256 — 32 random bytes base64-encoded)
        $key = [Convert]::ToBase64String((1..32 | ForEach-Object { [byte](Get-Random -Maximum 256) }))
        mkdir -p /etc/cloudsmith
        echo $key | tee /etc/cloudsmith/secrets.key > /dev/null
        chmod 600 /etc/cloudsmith/secrets.key
        chown cloudsmith:cloudsmith /etc/cloudsmith/secrets.key

        # Generate one-time setup token
        $token = [System.Web.Security.Membership]::GeneratePassword(32, 4) 2>/dev/null
        if (-not $token) {
            $token = [Convert]::ToBase64String((1..24 | ForEach-Object { [byte](Get-Random -Maximum 256) }))
        }
        echo $token
    }

    if ($UseWsl2) {
        $token = wsl -d Ubuntu -u root -- pwsh -Command $initScript.ToString()
    } else {
        $cred = Get-Credential -UserName 'cloudsmith' -Message 'VM credential'
        $token = Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock $initScript
    }

    return ($token | Select-Object -Last 1).Trim()
}
