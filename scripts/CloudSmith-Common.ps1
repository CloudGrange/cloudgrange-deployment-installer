# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0

function Write-Progress-Step {
    param([string]$Message)
    Write-Host "`n  → $Message..." -ForegroundColor DarkCyan
}

function Wait-ForTcp {
    # $Host is an automatic read-only variable in PowerShell — using it as a
    # parameter name is a parser-time error in PS 7 ("Cannot overwrite variable
    # Host because it is read-only or constant"). The parameter is renamed
    # $HostName and aliased to '-Host' for backwards-compatible call sites.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Alias('Host')][string]$HostName,
        [int]$Port,
        [int]$TimeoutSeconds = 120
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $tc = [System.Net.Sockets.TcpClient]::new()
            $tc.Connect($HostName, $Port)
            $tc.Close()
            return $true
        } catch {
            Start-Sleep -Seconds 3
        }
    }
    return $false
}

function Wait-ForHttpOk {
    param([string]$Url, [int]$TimeoutSeconds = 180)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -SkipCertificateCheck -TimeoutSec 5 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) { return $true }
        } catch { }
        Start-Sleep -Seconds 5
    }
    return $false
}
