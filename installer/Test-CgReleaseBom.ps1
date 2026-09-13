#Requires -Version 7.4
<#
.SYNOPSIS
    Validates a cg-release-bom-v1 file and prints the result as JSON.
.DESCRIPTION
    Strict JSON parse, closed schema (schemas/release-bom.schema.json) and the semantic rules in
    CloudGrange.Installer (Get-CgReleaseBomRuleCatalog lists every code). Exit code 0 when the BOM
    passes, 1 when it is rejected.
.PARAMETER Path
    The release-bom.json to validate.
.PARAMETER ConfigurationSchemaPath
    Optional site-config-v1 schema file whose bytes must match configurationSchema.sha256.
.EXAMPLE
    pwsh ./installer/Test-CgReleaseBom.ps1 -Path release/release-bom.json -ConfigurationSchemaPath schemas/site-config-v1.schema.json
.NOTES
    TaskReference: AB#8129 AB#9016
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$ConfigurationSchemaPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'modules/CloudGrange.Installer/CloudGrange.Installer.psd1') -Force
$arguments = @{ Path = $Path }
if ($ConfigurationSchemaPath) { $arguments.ConfigurationSchemaPath = $ConfigurationSchemaPath }
$result = Test-CgReleaseBom @arguments
$result | ConvertTo-Json -Depth 6
exit $(if ($result.passed) { 0 } else { 1 })
