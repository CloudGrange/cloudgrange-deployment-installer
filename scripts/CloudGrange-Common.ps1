# Copyright 2026 CloudGrange Contributors
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

# ---------------------------------------------------------------------------------------------------------------
# AB#8129: bounded ssh/scp transport. Every ssh/scp call in the installer goes through Invoke-CloudGrangeSsh
# (enforced by scripts/Test-SshTransportOptions.py):
#   - BatchMode=yes            never prompt for a password or passphrase (with no console a prompt waits forever)
#   - ConnectTimeout=15        give up on a VM that does not answer
#   - ServerAliveInterval=15 and ServerAliveCountMax=4
#                              drop a connection that stops responding after about a minute
#   - -TimeoutSeconds          an overall limit per call: the process tree is stopped and the call throws
# ---------------------------------------------------------------------------------------------------------------
function Get-CloudGrangeSshRequiredOptions {
    return @('BatchMode=yes', 'ConnectTimeout=15', 'ServerAliveInterval=15', 'ServerAliveCountMax=4')
}

function Get-CloudGrangeSshOptions {
    # Options for ssh/scp to a freshly provisioned VM: the installer key, no host key prompt, plus the required
    # transport options.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$KeyPath)
    $options = [System.Collections.Generic.List[string]]::new()
    $options.AddRange([string[]]@('-i', $KeyPath, '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR'))
    foreach ($option in Get-CloudGrangeSshRequiredOptions) {
        $options.Add('-o')
        $options.Add($option)
    }
    return , $options.ToArray()
}

function Invoke-CloudGrangeBoundedProcess {
    # Runs a process with stdin as a pipe (never the console), optional stdin bytes and captured stdout, and stops
    # the whole process tree when it runs longer than TimeoutSeconds. Sets $LASTEXITCODE.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][ValidateRange(1, 86400)][int]$TimeoutSeconds,
        [byte[]]$StandardInput,
        [switch]$CaptureOutput,
        [string]$Description = $FilePath
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($argument in $ArgumentList) { $psi.ArgumentList.Add($argument) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $CaptureOutput.IsPresent
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        $null = $process.Start()
        $stdout = if ($CaptureOutput) { $process.StandardOutput.ReadToEndAsync() } else { $null }
        $inputWritten = $true
        try {
            if ($null -ne $StandardInput -and $StandardInput.Length -gt 0) {
                $inputWritten = $process.StandardInput.BaseStream.WriteAsync($StandardInput, 0, $StandardInput.Length).Wait($TimeoutSeconds * 1000)
            }
            if ($inputWritten) { $process.StandardInput.Close() }
        } catch [System.IO.IOException] {
            # The child exited before reading all of its input; its exit code reports the failure.
        } catch [System.AggregateException] {
            # Same, surfaced through the asynchronous write.
        }
        if (-not $inputWritten -or -not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch [System.InvalidOperationException] { }
            $null = $process.WaitForExit(10000)
            throw "CG-SSH-ERR-002: $Description did not finish within $TimeoutSeconds seconds and was stopped."
        }
        $process.WaitForExit()
        $global:LASTEXITCODE = $process.ExitCode
        if ($CaptureOutput) {
            return @($stdout.GetAwaiter().GetResult() -split "\r?\n" | Where-Object { $_ -ne '' })
        }
    } finally {
        $process.Dispose()
    }
}

function Invoke-CloudGrangeSsh {
    # The only way the installer runs ssh or scp. ArgumentList must come from Get-CloudGrangeSshOptions (plus the
    # target and command); a call without every required option, or with a conflicting value, is refused.
    [CmdletBinding()]
    param(
        [ValidateSet('ssh', 'scp')][string]$Tool = 'ssh',
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][ValidateRange(1, 86400)][int]$TimeoutSeconds,
        [byte[]]$StandardInput,
        [switch]$CaptureOutput
    )
    $required = Get-CloudGrangeSshRequiredOptions
    $requiredKeys = @($required | ForEach-Object { ($_ -split '=', 2)[0] })
    $given = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $ArgumentList.Count; $i++) {
        $value = $null
        if ($ArgumentList[$i] -ceq '-o' -and $i + 1 -lt $ArgumentList.Count) { $value = $ArgumentList[$i + 1]; $i++ }
        elseif ($ArgumentList[$i].StartsWith('-o') -and $ArgumentList[$i].Length -gt 2) { $value = $ArgumentList[$i].Substring(2) }
        if ($null -eq $value) { continue }
        $key = ($value -split '[= ]', 2)[0]
        if ($requiredKeys -contains $key -and $required -notcontains $value) {
            throw "CG-SSH-ERR-001: $Tool call sets '-o $value', which conflicts with the required transport options."
        }
        $given.Add($value)
    }
    foreach ($option in $required) {
        if (-not $given.Contains($option)) {
            throw "CG-SSH-ERR-001: $Tool call is missing '-o $option' (build its arguments with Get-CloudGrangeSshOptions)."
        }
    }
    $file = if ($IsWindows) { "$Tool.exe" } else { $Tool }
    $target = @($ArgumentList | Where-Object { $_ -like '*@*' } | Select-Object -First 1)
    Invoke-CloudGrangeBoundedProcess -FilePath $file -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds `
        -StandardInput $StandardInput -CaptureOutput:$CaptureOutput -Description "$Tool to $($target -join '')"
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
