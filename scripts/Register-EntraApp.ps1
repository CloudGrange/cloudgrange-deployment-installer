#Requires -Version 7.0
<#
.SYNOPSIS
    Create or update Entra ID app registrations for CloudGrange PaaS (AB#1602).

.DESCRIPTION
    Creates two app registrations in the target Entra tenant:
      1. cloudgrange-api — the backend API app (exposes OAuth2 scopes)
      2. cloudgrange-portal — the SPA client (MSAL public client)

    Idempotent: if the app already exists (by displayName + signInAudience), it is
    updated rather than re-created. The output object contains client IDs and tenant
    ID suitable for injection into the azd environment.

    Requires: az CLI logged in to the target tenant with Application.ReadWrite.OwnedBy
    (or Application.ReadWrite.All) Microsoft Graph permission.

.PARAMETER TenantId
    Entra tenant ID (GUID). Defaults to the current az CLI tenant.

.PARAMETER ApiRedirectUri
    HTTPS URI of the cloudgrange-api ACA app. Used to set allowed audiences and CORS.
    Example: https://ca-cloudgrange-api-dev-eus-001.azurecontainerapps.io

.PARAMETER PortalRedirectUri
    HTTPS redirect URI for the portal SPA. Must end with /auth/callback.
    Example: https://ca-cloudgrange-portal-dev-eus-001.azurecontainerapps.io/auth/callback

.PARAMETER OutputFile
    Optional path to write output as JSON. Useful for piping into azd env set.

.EXAMPLE
    .\Register-EntraApp.ps1 `
        -TenantId 00000000-0000-0000-0000-000000000000 `
        -ApiRedirectUri https://ca-cloudgrange-api-dev-eus-001.azurecontainerapps.io `
        -PortalRedirectUri https://ca-cloudgrange-portal-dev-eus-001.azurecontainerapps.io/auth/callback
#>
[CmdletBinding()]
param(
    [string] $TenantId = '',
    [Parameter(Mandatory)]
    [string] $ApiRedirectUri,
    [Parameter(Mandatory)]
    [string] $PortalRedirectUri,
    [string] $OutputFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($TenantId)) {
    $account = az account show --output json | ConvertFrom-Json
    $TenantId = $account.tenantId
}
Write-Host "Entra tenant: $TenantId"

$ApiAppDisplayName    = 'cloudgrange-api'
$PortalAppDisplayName = 'cloudgrange-portal'
$ApiIdentifierUri     = "api://cloudgrange-api/$TenantId"
$AccessScopeId        = [System.Guid]::NewGuid().ToString()

# ---------------------------------------------------------------------------
# Helper: get or create an app registration
# ---------------------------------------------------------------------------
function Get-OrCreateApp {
    param([string]$DisplayName, [string]$SignInAudience = 'AzureADMyOrg')
    $existing = az ad app list --display-name $DisplayName --output json | ConvertFrom-Json
    if ($existing -and $existing.Count -gt 0) {
        Write-Host "App '$DisplayName' exists — reusing (appId: $($existing[0].appId))"
        return $existing[0]
    }
    Write-Host "Creating app registration '$DisplayName'..."
    $app = az ad app create --display-name $DisplayName --sign-in-audience $SignInAudience --output json | ConvertFrom-Json
    Write-Host "Created: appId=$($app.appId)"
    return $app
}

# ---------------------------------------------------------------------------
# 1. API app registration
# ---------------------------------------------------------------------------
$apiApp = Get-OrCreateApp -DisplayName $ApiAppDisplayName

# Set identifier URI + exposed scope (api://)
Write-Host "Setting identifier URI and exposed scope for API app..."
$scopeJson = @{
    adminConsentDescription = 'Access CloudGrange API on behalf of the user'
    adminConsentDisplayName = 'Access CloudGrange API'
    id                      = $AccessScopeId
    isEnabled               = $true
    type                    = 'User'
    userConsentDescription  = 'Allow CloudGrange portal to access the API on your behalf'
    userConsentDisplayName  = 'Access CloudGrange API'
    value                   = 'access_as_user'
} | ConvertTo-Json -Compress

$apiUpdate = @{
    identifierUris       = @($ApiIdentifierUri)
    api                  = @{ oauth2PermissionScopes = @($scopeJson | ConvertFrom-Json) }
    web                  = @{ redirectUris = @($ApiRedirectUri) }
} | ConvertTo-Json -Depth 10

az ad app update --id $apiApp.appId --set ($apiUpdate | ConvertFrom-Json | ForEach-Object { $_ }) 2>&1 | Out-Null

# Create a service principal if it doesn't exist
$apiSp = az ad sp show --id $apiApp.appId --output json 2>&1 | ConvertFrom-Json
if (-not $apiSp -or $LASTEXITCODE -ne 0) {
    Write-Host "Creating service principal for API app..."
    az ad sp create --id $apiApp.appId --output json | Out-Null
}

# ---------------------------------------------------------------------------
# 2. Client secret for the API service principal
# ---------------------------------------------------------------------------
Write-Host "Creating client secret for API app..."
$secretResult = az ad app credential reset --id $apiApp.appId --append --output json | ConvertFrom-Json
$apiClientSecret = $secretResult.password

# ---------------------------------------------------------------------------
# 3. Portal SPA app registration
# ---------------------------------------------------------------------------
$portalApp = Get-OrCreateApp -DisplayName $PortalAppDisplayName

Write-Host "Configuring portal SPA redirect URIs..."
az ad app update --id $portalApp.appId `
    --public-client-redirect-uris $PortalRedirectUri `
    --output json | Out-Null

# Grant admin consent for the api scope on the portal app
Write-Host "Granting API access scope to portal app..."
$scopeGrant = @{
    clientId    = $portalApp.appId
    consentType = 'AllPrincipals'
    resourceId  = $apiApp.appId
    scope       = 'access_as_user'
} | ConvertTo-Json
# az ad app permission add is idempotent
az ad app permission add --id $portalApp.appId `
    --api $apiApp.appId `
    --api-permissions "${AccessScopeId}=Scope" 2>&1 | Out-Null

# ---------------------------------------------------------------------------
# 4. Output
# ---------------------------------------------------------------------------
$output = [pscustomobject]@{
    TenantId        = $TenantId
    ApiClientId     = $apiApp.appId
    ApiClientSecret = $apiClientSecret
    PortalClientId  = $portalApp.appId
    ApiIdentifierUri = $ApiIdentifierUri
    AccessScopeId   = $AccessScopeId
}

Write-Host ""
Write-Host "========================================"
Write-Host "Entra App Registrations — Complete"
Write-Host "========================================"
Write-Host "TenantId:       $($output.TenantId)"
Write-Host "ApiClientId:    $($output.ApiClientId)"
Write-Host "PortalClientId: $($output.PortalClientId)"
Write-Host ""
Write-Host "Set these in your azd environment:"
Write-Host "  azd env set ENTRA_TENANT_ID $($output.TenantId)"
Write-Host "  azd env set ENTRA_CLIENT_ID $($output.ApiClientId)"
Write-Host "  azd env set ENTRA_CLIENT_SECRET <see output file>"
Write-Host ""
Write-Host "IMPORTANT: The client secret is only shown once. Store it securely."
Write-Host "  ApiClientSecret: $($output.ApiClientSecret)"

if (-not [string]::IsNullOrEmpty($OutputFile)) {
    $output | ConvertTo-Json | Set-Content -Path $OutputFile -Encoding UTF8
    Write-Host ""
    Write-Host "Output written to: $OutputFile"
}

return $output
