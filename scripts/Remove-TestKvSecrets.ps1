#Requires -Version 7.0
# Copyright 2026 CloudSmith Contributors
# SPDX-License-Identifier: Apache-2.0
#
# Remove-TestKvSecrets.ps1 — Delete all secrets whose names start with "test-" from kv-hcs-vault-01.
#
# Usage:
#   .\Remove-TestKvSecrets.ps1 [-Force]
#
# Parameters:
#   -Force   Skip interactive confirmation and delete immediately.
#
# Audit log:
#   Written to $env:TEMP\cloudsmith-kv-cleanup-<timestamp>.log

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$VaultName  = 'kv-hcs-vault-01'
$Prefix     = 'test-'
$Timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogPath    = Join-Path $env:TEMP "cloudsmith-kv-cleanup-$Timestamp.log"

function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $LogPath -Value $line
    Write-Host $line
}

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

Write-Log "Starting KV test-secret cleanup run against vault: $VaultName"
Write-Log "Log file: $LogPath"

# ----------------------------------------------------------------------------
# List secrets with test- prefix
# ----------------------------------------------------------------------------
Write-Log "Listing secrets with prefix '$Prefix' ..."
$allSecrets = az keyvault secret list --vault-name $VaultName --output json 2>&1 | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: Failed to list secrets from vault $VaultName."
    exit 1
}

$testSecrets = $allSecrets | Where-Object { $_.name -like "$Prefix*" }

if (-not $testSecrets -or $testSecrets.Count -eq 0) {
    Write-Log "No secrets found with prefix '$Prefix'. Nothing to delete."
    exit 0
}

# ----------------------------------------------------------------------------
# Display the list
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "The following secrets will be DELETED from $VaultName :"
Write-Host ""
$testSecrets | ForEach-Object {
    $created = if ($_.attributes.created) { $_.attributes.created } else { 'unknown' }
    $expires = if ($_.attributes.expires) { $_.attributes.expires } else { 'none' }
    Write-Host ("  {0,-55} created: {1,-25} expires: {2}" -f $_.name, $created, $expires)
}
Write-Host ""
Write-Log "Found $($testSecrets.Count) secret(s) with prefix '$Prefix'."

# ----------------------------------------------------------------------------
# Confirm
# ----------------------------------------------------------------------------
if (-not $Force) {
    $answer = Read-Host "Type 'yes' to confirm deletion of $($testSecrets.Count) secret(s), or anything else to abort"
    if ($answer -ne 'yes') {
        Write-Log "Deletion aborted by operator."
        Write-Host "Aborted. No secrets were deleted."
        exit 0
    }
}

# ----------------------------------------------------------------------------
# Delete
# ----------------------------------------------------------------------------
$deleted  = 0
$failed   = 0

foreach ($secret in $testSecrets) {
    Write-Log "Deleting: $($secret.name) ..."
    az keyvault secret delete --vault-name $VaultName --name $secret.name 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  Deleted: $($secret.name)"
        $deleted++
    } else {
        Write-Log "  ERROR: Failed to delete $($secret.name)."
        $failed++
    }
}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
Write-Log "Cleanup complete. Deleted: $deleted  Failed: $failed"
Write-Host ""
Write-Host "Audit log written to: $LogPath"

if ($failed -gt 0) {
    Write-Warning "$failed secret(s) could not be deleted. Review the log for details."
    exit 1
}
