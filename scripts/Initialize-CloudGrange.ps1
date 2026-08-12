#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0

function Initialize-CloudGrange {
    [CmdletBinding()]
    param(
        [string]$VmName  = 'cloudgrange-docker',
        [bool]$UseWsl2   = $false
    )

    $initScript = {
        # Generate master secrets key (AES-256 — 32 random bytes base64-encoded)
        $key = [Convert]::ToBase64String((1..32 | ForEach-Object { [byte](Get-Random -Maximum 256) }))
        mkdir -p /etc/cloudgrange
        echo $key | tee /etc/cloudgrange/secrets.key > /dev/null
        chmod 600 /etc/cloudgrange/secrets.key
        chown cloudgrange:cloudgrange /etc/cloudgrange/secrets.key

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
        $cred = Get-Credential -UserName 'cloudgrange' -Message 'VM credential'
        $token = Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock $initScript
    }

    return ($token | Select-Object -Last 1).Trim()
}
