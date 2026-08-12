#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# uninstall-relay.ps1 — Stop and remove the CloudGrange relay agent container.
#
# Usage:
#   .\uninstall-relay.ps1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ContainerName = 'cloudgrange-relay'

$dockerExe = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerExe) {
    Write-Error "Docker is not installed or not on PATH."
    exit 1
}

$existing = docker inspect $ContainerName 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Container '$ContainerName' not found — nothing to remove."
    exit 0
}

Write-Host "Stopping container '$ContainerName' ..."
docker stop $ContainerName 2>$null

Write-Host "Removing container '$ContainerName' ..."
docker rm $ContainerName

Write-Host ""
Write-Host "Relay agent removed. The container image is still cached locally."
Write-Host "To also remove the image, run:  docker rmi ghcr.io/cloudgrange-cloud/cloudgrange-relay"
