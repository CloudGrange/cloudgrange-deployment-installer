#Requires -Version 5.1
# Invoke-InstallerTest.ps1 — Repeatable CloudGrange installer test runner
# Deploys a fresh test VM (or reuses existing), runs Install-CloudGrange.ps1
# as the local admin (not SYSTEM), streams the log, reports pass/fail.
#
# Usage:
#   .\Invoke-InstallerTest.ps1 -Mode Online
#   .\Invoke-InstallerTest.ps1 -Mode Online -Fresh          # delete + redeploy VM first
#   .\Invoke-InstallerTest.ps1 -Mode Bundled -Fresh
#   .\Invoke-InstallerTest.ps1 -Mode Appliance -Fresh

param(
    [ValidateSet('Online','Bundled','Appliance')]
    [string]$Mode = 'Online',

    [string]$ResourceGroup = 'rg-cg-online-001',
    [string]$VmName        = 'vmonline001',
    [string]$Location      = 'eastus2',

    # Redeploy the VM from scratch before testing
    [switch]$Fresh,

    # KV secret names
    [string]$KvName          = 'kv-hcs-vault-01',
    [string]$AdminPwSecret   = 'cs-hvhost-online-2025-admin-pw',
    [string]$AdminUser       = 'csadmin'
)

$ErrorActionPreference = 'Stop'

# ── 1. Fetch admin password from KV ──────────────────────────────────────────
Write-Host "Fetching VM admin credentials from KV..." -ForegroundColor Cyan
$adminPassword = az keyvault secret show --vault-name $KvName --name $AdminPwSecret --query value -o tsv
if (-not $adminPassword) { throw "Could not retrieve admin password from KV secret '$AdminPwSecret'." }

# ── 2. Optionally redeploy the VM ────────────────────────────────────────────
if ($Fresh) {
    Write-Host "[-Fresh] Deleting and redeploying $VmName in $ResourceGroup..." -ForegroundColor Yellow

    # Delete any existing VM and its resources
    az group delete --name $ResourceGroup --yes --no-wait 2>$null
    Write-Host "  Waiting for RG deletion..."
    az group wait --name $ResourceGroup --deleted --timeout 300 2>$null

    az group create --name $ResourceGroup --location $Location | Out-Null
    Write-Host "  Deploying fresh VM from Bicep..."

    $paramFile = Join-Path $env:TEMP "installer-test-vm-params-$(Get-Random).json"
    @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{
            vmName        = @{ value = $VmName }
            location      = @{ value = $Location }
            adminUsername = @{ value = $AdminUser }
            adminPassword = @{ value = $adminPassword }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content $paramFile -Encoding UTF8

    $bicepPath = Join-Path $PSScriptRoot "bicep\installer-test-vm.bicep"
    az bicep build --file $bicepPath --stdout | Out-Null
    az deployment group create `
        --resource-group $ResourceGroup `
        --template-file $bicepPath `
        --parameters "@$paramFile" `
        --output none
    Remove-Item $paramFile -Force

    # Wait for VM to come up after the Hyper-V setup reboot
    Write-Host "  Waiting for VM agent to become ready (post-reboot)..."
    az vm wait --resource-group $ResourceGroup --name $VmName --custom "instanceView.statuses[?code=='PowerState/running']" --timeout 300
    Start-Sleep -Seconds 60  # let WinRM/agent settle after reboot
    Write-Host "  VM ready." -ForegroundColor Green
}

# ── 3. Build the installer run-command script ─────────────────────────────────
Write-Host "Preparing installer run-command (Mode=$Mode, running as $AdminUser)..." -ForegroundColor Cyan

$logPath = 'C:\CloudGrangeInstall\install.log'
$installDir = 'C:\CloudGrangeInstall'
$raw = 'https://raw.githubusercontent.com/cloudgrange-cloud/cloudgrange-installer/main'

$scripts = @('CloudGrange-Common.ps1','CloudGrange-Prereqs.ps1','New-CloudGrangeVm.ps1',
             'Install-DockerCe.ps1','Initialize-CloudGrange.ps1','Deploy-DockerCompose.ps1',
             'Register-EntraApp.ps1')

# Root-level support scripts referenced by the scripts/ directory (relative path ..\)
$rootScripts = @('New-SelfSignedCert.ps1')

# Compose directory files (scp'd to the Docker VM by Deploy-DockerCompose.ps1)
# Note: compose/.env is gitignored (contains secrets) — POSTGRES_PASSWORD is injected
# by Deploy-DockerCompose.ps1 via environment variable export, not via .env file.
$composeFiles = @(
    'compose/.env.example',
    'compose/docker-compose.yml',
    'compose/loki-config.yml',
    'compose/otel-collector.yml',
    'compose/prometheus.yml',
    'compose/keycloak/cloudgrange-realm.json',
    'compose/nginx/nginx.conf'
)

# Script runs as SYSTEM (run-command constraint) but immediately hands off
# to a scheduled task that runs as the real local admin ($AdminUser).
# The admin password is passed via Azure protectedParameters — never in the script body.
$runScript = @"
param([string]`$AdminPassword)
`$ErrorActionPreference = 'Stop'
`$pwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
if (-not (Test-Path `$pwshPath)) {
    Invoke-Expression "& { `$(Invoke-RestMethod -Uri 'https://aka.ms/install-powershell.ps1' -UseBasicParsing) } -UseMSI -Quiet"
}

# Fresh download of all installer scripts
if (Test-Path '$installDir') { Remove-Item '$installDir' -Recurse -Force }
New-Item -ItemType Directory -Force '$installDir' | Out-Null
New-Item -ItemType Directory -Force '$installDir\scripts' | Out-Null
New-Item -ItemType Directory -Force '$installDir\compose\keycloak' | Out-Null
New-Item -ItemType Directory -Force '$installDir\compose\nginx' | Out-Null
foreach (`$f in @('Install-CloudGrange.ps1','cloudgrange-installer.sha256')) {
    Invoke-WebRequest -Uri '$raw/`$f' -OutFile '$installDir\`$f' -UseBasicParsing
}
foreach (`$f in @('$($scripts -join "','")')) {
    Invoke-WebRequest -Uri '$raw/scripts/`$f' -OutFile '$installDir\scripts\`$f' -UseBasicParsing
}
foreach (`$f in @('$($rootScripts -join "','")')) {
    Invoke-WebRequest -Uri '$raw/`$f' -OutFile '$installDir\`$f' -UseBasicParsing
}
foreach (`$f in @('$($composeFiles -join "','")')) {
    `$dest = '$installDir\' + (`$f -replace '/', '\')
    Invoke-WebRequest -Uri '$raw/`$f' -OutFile `$dest -UseBasicParsing
}
Write-Host "Scripts downloaded."

# Register scheduled task to run installer as $AdminUser (not SYSTEM)
`$taskArg = "-NonInteractive -ExecutionPolicy Bypass -Command & '$installDir\Install-CloudGrange.ps1' -Mode $Mode -VmIp 192.168.100.10 -AcceptDefaults *> '$logPath'"
`$action    = New-ScheduledTaskAction -Execute `$pwshPath -Argument `$taskArg
`$principal = New-ScheduledTaskPrincipal -UserId ".\$AdminUser" -LogonType Password -RunLevel Highest
Register-ScheduledTask -TaskName 'CloudGrangeInstall' -Action `$action -Principal `$principal -Password `$AdminPassword -Force | Out-Null
Write-Host "Starting installer as $AdminUser..."
Start-ScheduledTask -TaskName 'CloudGrangeInstall'

# Poll until the task finishes (up to 50 minutes)
`$timeout = 3000; `$elapsed = 0
while (`$elapsed -lt `$timeout) {
    `$state = (Get-ScheduledTask -TaskName 'CloudGrangeInstall' -ErrorAction SilentlyContinue).State
    if (`$state -ne 'Running') { break }
    Start-Sleep -Seconds 15; `$elapsed += 15
    Write-Host "  ...still running (`${elapsed}s elapsed)"
}
`$exitCode = (Get-ScheduledTaskInfo -TaskName 'CloudGrangeInstall').LastTaskResult
Unregister-ScheduledTask -TaskName 'CloudGrangeInstall' -Confirm:`$false -ErrorAction SilentlyContinue

Write-Host "=== INSTALLER LOG ==="
if (Test-Path '$logPath') { Get-Content '$logPath' } else { Write-Host "(no log file)" }
Write-Host "=== EXIT CODE: `$exitCode ==="
if (`$exitCode -ne 0) { exit 1 }
"@

# ── 4. Submit via Azure Run Command v2 with protected password ────────────────
$subId = az account show --query id -o tsv
$rcName = "InstallerTest-$Mode-$(Get-Date -Format 'HHmmss')"
$token  = az account get-access-token --query accessToken -o tsv
$hdrs   = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
$url    = "https://management.azure.com/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/virtualMachines/$VmName/runCommands/${rcName}?api-version=2023-03-01"

$body = @{
    location   = $Location
    properties = @{
        source               = @{ script = $runScript }
        protectedParameters  = @( @{ name = 'AdminPassword'; value = $adminPassword } )
        asyncExecution       = $true
        timeoutInSeconds     = 3600
    }
} | ConvertTo-Json -Depth 6

Invoke-RestMethod -Uri $url -Method PUT -Headers $hdrs -Body $body | Out-Null
Write-Host "Run command '$rcName' submitted." -ForegroundColor Green

# ── 5. Poll for completion ────────────────────────────────────────────────────
Write-Host "Polling every 30 seconds..." -ForegroundColor Cyan
$pollUrl = "$url?`$expand=instanceView"
$maxWait = 3600; $waited = 0
while ($waited -lt $maxWait) {
    Start-Sleep -Seconds 30; $waited += 30
    $r  = Invoke-RestMethod -Uri $pollUrl -Headers @{ Authorization = "Bearer $(az account get-access-token --query accessToken -o tsv)" }
    $iv = $r.properties.instanceView
    if ($iv.executionState -notin @('Running','Pending','Creating','',$null)) {
        Write-Host "`nFinal state: $($iv.executionState) (exit $($iv.exitCode))"
        Write-Host "=== STDOUT ===" ; Write-Host $iv.output
        Write-Host "=== STDERR ===" ; Write-Host $iv.error
        if ($iv.exitCode -eq 0) {
            Write-Host "`nINSTALL PASSED" -ForegroundColor Green
        } else {
            Write-Host "`nINSTALL FAILED" -ForegroundColor Red
            exit 1
        }
        break
    }
    Write-Host "  ${waited}s — still $($iv.executionState)..."
}
