#Requires -Version 7.0
# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0
# ADR-029: Installs Docker CE inside the cloudsmith-docker VM via Hyper-V Direct connection

function Install-DockerCe {
    [CmdletBinding()]
    param(
        [string]$VmName  = 'cloudsmith-docker',
        [bool]$UseWsl2   = $false,
        [string]$Proxy   = ''
        # ProxyPassword is never passed to this function — it is written inside the VM only, never logged here
    )

    $script = {
        param([string]$Proxy)
        # Install Docker CE from official apt repository
        apt-get update -qq
        apt-get install -y -qq ca-certificates curl gnupg
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        $arch = (dpkg --print-architecture)
        $codename = (. /etc/os-release; echo $UBUNTU_CODENAME)
        $repo = "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable"
        echo $repo | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        systemctl enable docker
        systemctl start docker

        if ($Proxy -ne '') {
            mkdir -p /etc/systemd/system/docker.service.d
            # Credentials are written only if provided; they are never echoed to stdout
            $proxyConf = "[Service]`nEnvironment=HTTP_PROXY=$Proxy`nEnvironment=HTTPS_PROXY=$Proxy`nEnvironment=NO_PROXY=localhost,127.0.0.1"
            echo $proxyConf | tee /etc/systemd/system/docker.service.d/proxy.conf > /dev/null
            systemctl daemon-reload
            systemctl restart docker
        }

        # Smoke test
        docker run --rm hello-world
    }

    if ($UseWsl2) {
        wsl -d Ubuntu -u root -- pwsh -Command $script.ToString() -Args $Proxy
    } else {
        Invoke-Command -VMName $VmName -Credential (Get-Credential -UserName 'cloudsmith' -Message 'VM credential') `
            -ScriptBlock $script -ArgumentList $Proxy
    }
}
