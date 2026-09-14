#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
# AB#8129 — unit tests for the bounded ssh/scp transport in scripts/CloudGrange-Common.ps1: the required transport
# options are always present and cannot be overridden, and a call that runs past its timeout is stopped (the whole
# process tree) and throws. A child pwsh stands in for ssh.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\scripts\CloudGrange-Common.ps1')
    $script:pwsh = (Get-Process -Id $PID).Path
    $script:required = @('BatchMode=yes', 'ConnectTimeout=15', 'ServerAliveInterval=15', 'ServerAliveCountMax=4')
    function Remove-Option([string[]]$Arguments, [string]$Option) {
        $out = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $Arguments.Count; $i++) {
            if ($Arguments[$i] -ceq '-o' -and $i + 1 -lt $Arguments.Count -and $Arguments[$i + 1] -ceq $Option) { $i++; continue }
            $out.Add($Arguments[$i])
        }
        return , $out.ToArray()
    }
}

Describe 'Get-CloudGrangeSshOptions' {
    It 'adds every required transport option as an -o pair after the key' {
        $options = Get-CloudGrangeSshOptions -KeyPath 'C:\keys\installer'
        $options[0..1] | Should -Be @('-i', 'C:\keys\installer')
        foreach ($option in $script:required) {
            $index = [Array]::IndexOf($options, $option)
            $index | Should -BeGreaterThan 0 -Because "$option must be present"
            $options[$index - 1] | Should -Be '-o'
        }
    }
}

Describe 'Invoke-CloudGrangeSsh' {
    It 'refuses a call missing <_>' -ForEach @('BatchMode=yes', 'ConnectTimeout=15', 'ServerAliveInterval=15', 'ServerAliveCountMax=4') {
        $arguments = Remove-Option -Arguments ((Get-CloudGrangeSshOptions -KeyPath 'k') + @('cloudgrange@192.0.2.1', 'id')) -Option $_
        { Invoke-CloudGrangeSsh -ArgumentList $arguments -TimeoutSeconds 5 } | Should -Throw "*CG-SSH-ERR-001*missing '-o $_'*"
    }

    It 'refuses a conflicting value placed before the required options' {
        $arguments = @('-o', 'BatchMode=no') + (Get-CloudGrangeSshOptions -KeyPath 'k') + @('cloudgrange@192.0.2.1', 'id')
        { Invoke-CloudGrangeSsh -ArgumentList $arguments -TimeoutSeconds 5 } | Should -Throw '*CG-SSH-ERR-001*BatchMode=no*'
    }

    It 'refuses a conflicting value in the joined -oOption form' {
        $arguments = (Get-CloudGrangeSshOptions -KeyPath 'k') + @('-oConnectTimeout=0', 'cloudgrange@192.0.2.1', 'id')
        { Invoke-CloudGrangeSsh -ArgumentList $arguments -TimeoutSeconds 5 } | Should -Throw '*CG-SSH-ERR-001*ConnectTimeout=0*'
    }

    It 'makes the timeout mandatory' {
        $parameter = (Get-Command Invoke-CloudGrangeSsh).Parameters['TimeoutSeconds']
        @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count | Should -Be 1
    }
}

Describe 'Invoke-CloudGrangeBoundedProcess' {
    It 'stops a process tree that runs past its timeout and throws' {
        $pidFile = Join-Path $TestDrive 'child.pid'
        $command = "`$PID | Set-Content '$pidFile'; Start-Sleep -Seconds 300"
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        { Invoke-CloudGrangeBoundedProcess -FilePath $script:pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $command) -TimeoutSeconds 8 -Description 'sleeper' } |
            Should -Throw '*CG-SSH-ERR-002: sleeper did not finish within 8 seconds*'
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 45
        Test-Path $pidFile | Should -BeTrue
        $childPid = [int](Get-Content $pidFile)
        Get-Process -Id $childPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'passes stdin bytes, captures stdout and sets LASTEXITCODE' {
        $command = '$text = [Console]::In.ReadToEnd(); "got:" + $text.Trim(); exit 3'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("hello`n")
        $out = Invoke-CloudGrangeBoundedProcess -FilePath $script:pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $command) -TimeoutSeconds 60 -StandardInput $bytes -CaptureOutput
        $out | Should -Be 'got:hello'
        $LASTEXITCODE | Should -Be 3
    }

    It 'gives the child a closed stdin pipe, never the console' {
        $command = '$text = [Console]::In.ReadToEnd(); "read:" + $text.Length'
        $out = Invoke-CloudGrangeBoundedProcess -FilePath $script:pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $command) -TimeoutSeconds 60 -CaptureOutput
        $out | Should -Be 'read:0'
        $LASTEXITCODE | Should -Be 0
    }
}
