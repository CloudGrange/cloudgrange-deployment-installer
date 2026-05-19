# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0

function Write-Progress-Step {
    param([string]$Message)
    Write-Host "`n  → $Message..." -ForegroundColor DarkCyan
}

function Wait-ForTcp {
    param([string]$Host, [int]$Port, [int]$TimeoutSeconds = 120)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $tc = [System.Net.Sockets.TcpClient]::new()
            $tc.Connect($Host, $Port)
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
            if ($resp.StatusCode -lt 400) { return $true }
        } catch { }
        Start-Sleep -Seconds 5
    }
    return $false
}
