#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# Get-TestKvSecrets.ps1 — List all secrets whose names start with "test-" in kv-hcs-vault-01.
#                          Read-only. Does not modify any secrets.
#
# Usage:
#   .\Get-TestKvSecrets.ps1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$VaultName = 'kv-hcs-vault-01'
$Prefix    = 'test-'

# ----------------------------------------------------------------------------
# Verify az CLI is available and authenticated
# ----------------------------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI (az) is not installed or not on PATH."
    exit 1
}

$account = az account show 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Not authenticated. Run 'az login' first."
    exit 1
}

# ----------------------------------------------------------------------------
# List secrets
# ----------------------------------------------------------------------------
Write-Host "Listing secrets with prefix '$Prefix' in vault '$VaultName' ..."
Write-Host ""

$allSecrets = az keyvault secret list --vault-name $VaultName --output json 2>&1 | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to list secrets from vault $VaultName."
    exit 1
}

$testSecrets = $allSecrets | Where-Object { $_.name -like "$Prefix*" }

if (-not $testSecrets -or $testSecrets.Count -eq 0) {
    Write-Host "No secrets found with prefix '$Prefix'."
    exit 0
}

# ----------------------------------------------------------------------------
# Display table
# ----------------------------------------------------------------------------
$rows = $testSecrets | ForEach-Object {
    [PSCustomObject]@{
        Name    = $_.name
        Created = if ($_.attributes.created) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$_.attributes.created).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'unknown' }
        Expires = if ($_.attributes.expires) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$_.attributes.expires).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'none' }
        Enabled = $_.attributes.enabled
    }
}

$rows | Format-Table -AutoSize

Write-Host "Total: $($testSecrets.Count) secret(s) with prefix '$Prefix'."
Write-Host ""
Write-Host "To delete these secrets, run:  .\Remove-TestKvSecrets.ps1"
