#Requires -Version 7.0
<#
.SYNOPSIS
    Deploy CloudSmith to Azure PaaS. Generates all secrets automatically.

.DESCRIPTION
    Deploys CloudSmith (API + Portal + PostgreSQL + Key Vault) to Azure Container
    Apps in your subscription. Auto-generates the master encryption key and
    database password — you never need to know about them.

.PARAMETER AdminPassword
    Password for the CloudSmith administrator account.
    Min 12 chars, requires uppercase + lowercase + digit + special char.

.PARAMETER OwnerEmail
    Email address of the team responsible for this deployment.
    Applied as Azure Policy required tag.

.PARAMETER Location
    Azure region. Default: centralus

.PARAMETER Environment
    Deployment tier. Default: prod. Options: dev, test, stage, prod.

.PARAMETER Instance
    Short suffix appended to resource names to keep them unique. Default: 001

.PARAMETER CostCenter
    Cost center tag for billing allocation. Default: Engineering

.PARAMETER ParamsFile
    Path to write the generated parameters JSON before deploying.
    Default: cloudsmith-deploy.json in the current directory.

.EXAMPLE
    .\Install-CloudSmith-PaaS.ps1 `
        -AdminPassword "YourPass1!" `
        -OwnerEmail "ops@contoso.com"

.EXAMPLE
    .\Install-CloudSmith-PaaS.ps1 `
        -AdminPassword "YourPass1!" `
        -OwnerEmail "ops@contoso.com" `
        -Environment dev `
        -Location eastus
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AdminPassword,
    [Parameter(Mandatory)][string]$OwnerEmail,
    [string]$Location      = "centralus",
    [ValidateSet("dev","test","stage","prod")]
    [string]$Environment   = "prod",
    [string]$Instance      = "001",
    [string]$CostCenter    = "Engineering",
    [string]$BusinessUnit  = "Engineering",
    [string]$ParamsFile    = "cloudsmith-deploy.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Check prerequisites ────────────────────────────────────────────────────────
Write-Host "Checking prerequisites..." -ForegroundColor Cyan
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') is required. Install from https://aka.ms/installazurecliwindows"
}

# ── Verify Azure login ─────────────────────────────────────────────────────────
Write-Host "Checking Azure login..." -ForegroundColor Cyan
try {
    $account = az account show 2>&1 | ConvertFrom-Json
} catch {
    Write-Host "Not logged in. Running: az login" -ForegroundColor Yellow
    az login
    $account = az account show 2>&1 | ConvertFrom-Json
}
Write-Host "  Using subscription: $($account.name) ($($account.id))" -ForegroundColor Green

# ── Auto-generate secrets ──────────────────────────────────────────────────────
Write-Host "Generating secrets..." -ForegroundColor Cyan

$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

$masterKeyBytes = New-Object byte[] 32
$rng.GetBytes($masterKeyBytes)
$masterKey = [Convert]::ToBase64String($masterKeyBytes)

$pgBytes = New-Object byte[] 12
$rng.GetBytes($pgBytes)
$pgPassword = [Convert]::ToBase64String($pgBytes).Replace("=","").Replace("/","x").Replace("+","y")
$pgPassword = "${pgPassword}Aa1!"   # ensure password complexity

$imageTag   = "v1.0.0"
$deployName = "cloudsmith-$(Get-Date -Format 'yyyyMMddHHmm')"

# ── Write parameters file ──────────────────────────────────────────────────────
Write-Host "Writing parameters to: $ParamsFile" -ForegroundColor Cyan

$params = [ordered]@{
    '$schema'       = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion  = "1.0.0.0"
    parameters      = [ordered]@{
        environment           = @{ value = $Environment }
        instance              = @{ value = $Instance }
        imageTag              = @{ value = $imageTag }
        postgresAdminUser     = @{ value = "cloudsmith" }
        postgresAdminPassword = @{ value = $pgPassword }
        masterKey             = @{ value = $masterKey }
        Owner                 = @{ value = $OwnerEmail }
        BusinessUnit          = @{ value = $BusinessUnit }
        DataClassification    = @{ value = "Internal" }
        Criticality           = @{ value = "High" }
        CostCenter            = @{ value = $CostCenter }
    }
}
$params | ConvertTo-Json -Depth 10 | Set-Content -Path $ParamsFile -Encoding UTF8

Write-Host ""
Write-Host "  Parameters written to $ParamsFile" -ForegroundColor Green
Write-Host "  Edit this file before deploying if you need custom values." -ForegroundColor Gray
Write-Host ""

# ── Download template ──────────────────────────────────────────────────────────
Write-Host "Downloading CloudSmith installer template..." -ForegroundColor Cyan
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $tmpDir | Out-Null

try {
    $bicepUrl = "https://raw.githubusercontent.com/cloudsmith-cloud/cloudsmith-installer/main/iac/main.bicep"
    $bicepFile = Join-Path $tmpDir "main.bicep"
    Invoke-WebRequest -Uri $bicepUrl -OutFile $bicepFile -UseBasicParsing

    # ── Deploy ─────────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "Deploying CloudSmith to Azure..." -ForegroundColor Cyan
    Write-Host "  Environment : $Environment"
    Write-Host "  Location    : $Location"
    Write-Host "  Image tag   : $imageTag"
    Write-Host "  Deploy name : $deployName"
    Write-Host ""

    az deployment sub create `
        --name $deployName `
        --location $Location `
        --template-file $bicepFile `
        --parameters "@$ParamsFile"

    # ── Show outputs ───────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "Getting deployment outputs..." -ForegroundColor Cyan
    $outputs = az deployment sub show `
        --name $deployName `
        --query "properties.outputs" -o json 2>/dev/null | ConvertFrom-Json

    $portalUrl = $outputs.portalUrl.value
    $apiUrl    = $outputs.apiUrl.value

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║  CloudSmith deployed successfully                    ║" -ForegroundColor Green
    Write-Host "╠══════════════════════════════════════════════════════╣" -ForegroundColor Green
    if ($portalUrl) {
    Write-Host "║  Portal : $portalUrl" -ForegroundColor Green
    }
    if ($apiUrl) {
    Write-Host "║  API    : $apiUrl" -ForegroundColor Green
    }
    Write-Host "╠══════════════════════════════════════════════════════╣" -ForegroundColor Green
    Write-Host "║  Next: open the Portal URL and complete setup        ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "Keep $ParamsFile — it contains your deployment configuration."
    Write-Host "The master key and passwords are stored in Azure Key Vault."

} finally {
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
}
