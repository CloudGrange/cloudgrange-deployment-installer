#Requires -Version 7.0
<#
.SYNOPSIS
    CloudSmith PaaS end-to-end smoke test. Validates the golden path for a freshly
    deployed or upgraded PaaS environment (AB#1607, AB#2353).

.DESCRIPTION
    Runs eight ordered checks against the target PaaS deployment:
      1. GET /health/ready -> HTTP 200 (readiness probe — always accessible)
      2. GET portal URL -> HTTP 200, Content-Type: text/html
      3. GET /api/v1/setup/status -> HTTP 200, setupComplete field present
      4. If setupComplete = false: POST /api/v1/setup (first-run wizard happy path)
         Requires -InitialAdminToken (the one-time KV bootstrap token)
      5. POST /api/v1/auth/local-login (break-glass admin)
      6. GET /api/v1/clusters -> HTTP 200, response is a JSON array
      7. GET /openapi/v1.json -> HTTP 200 (OpenAPI spec served)
      8. GET /health/ready -> HTTP 200 (re-verify after setup)

    Each check is independently timed and reported. The script exits with code 0 if
    all checks pass, or code 1 if any check fails.

.PARAMETER ApiBaseUrl
    Base URL for the cloudsmith-api ACA app (e.g. https://ca-cloudsmith-api-dev-eus-001.azurecontainerapps.io)

.PARAMETER PortalBaseUrl
    Base URL for the cloudsmith-portal ACA app. Defaults to ApiBaseUrl if not provided.

.PARAMETER AdminUser
    Local break-glass admin username. Default: admin

.PARAMETER AdminPassword
    Local break-glass admin password. Required for step 5.

.PARAMETER InitialAdminToken
    One-time bootstrap token from KV secret 'cloudsmith-initial-admin-token'.
    Required only when setup has not been completed (setupComplete = false).

.PARAMETER SetupPlatformName
    Platform name to use when completing first-run setup. Default: CloudSmith

.PARAMETER TimeoutSeconds
    HTTP request timeout in seconds. Default: 30

.EXAMPLE
    .\paas-smoke.ps1 `
        -ApiBaseUrl https://ca-cloudsmith-api-test-cus-002.azurecontainerapps.io `
        -PortalBaseUrl https://ca-cloudsmith-portal-test-cus-002.azurecontainerapps.io `
        -InitialAdminToken (az keyvault secret show --vault-name kvXXX --name cloudsmith-initial-admin-token --query value -o tsv) `
        -AdminPassword (ConvertTo-SecureString 'MyPassword' -AsPlainText -Force)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ApiBaseUrl,

    [string] $PortalBaseUrl,

    [string] $AdminUser = 'admin',

    [Parameter(Mandatory)]
    [securestring] $AdminPassword,

    [string] $InitialAdminToken = '',

    [string] $SetupPlatformName = 'CloudSmith',

    [int] $TimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ApiBaseUrl  = $ApiBaseUrl.TrimEnd('/')
$PortalBaseUrl = if ($PortalBaseUrl) { $PortalBaseUrl.TrimEnd('/') } else { $ApiBaseUrl }

$passed  = 0
$failed  = 0
$results = [System.Collections.Generic.List[psobject]]::new()

function Invoke-Check {
    param(
        [int]    $Step,
        [string] $Name,
        [scriptblock] $Body
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $detail = & $Body
        $sw.Stop()
        $script:passed++
        $results.Add([pscustomobject]@{ Step = $Step; Name = $Name; Status = 'PASS'; Detail = $detail; Ms = $sw.ElapsedMilliseconds })
        Write-Host "[PASS] Step $Step — $Name ($($sw.ElapsedMilliseconds) ms)" -ForegroundColor Green
        return $true
    } catch {
        $sw.Stop()
        $script:failed++
        $results.Add([pscustomobject]@{ Step = $Step; Name = $Name; Status = 'FAIL'; Detail = $_.Exception.Message; Ms = $sw.ElapsedMilliseconds })
        Write-Host "[FAIL] Step $Step — $Name ($($sw.ElapsedMilliseconds) ms): $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

$plainPassword = [System.Net.NetworkCredential]::new('', $AdminPassword).Password

# ---------------------------------------------------------------------------
# Step 1: GET /health/ready — always accessible (bypasses SetupGateMiddleware)
# ---------------------------------------------------------------------------
Invoke-Check -Step 1 -Name 'GET /health/ready -> 200' -Body {
    $r = Invoke-WebRequest -Uri "$ApiBaseUrl/health/ready" -Method GET -TimeoutSec $TimeoutSeconds -UseBasicParsing
    if ($r.StatusCode -ne 200) { throw "Expected 200, got $($r.StatusCode)" }
    "HTTP $($r.StatusCode)"
}

# ---------------------------------------------------------------------------
# Step 2: GET portal URL -> HTML 200
# ---------------------------------------------------------------------------
Invoke-Check -Step 2 -Name 'GET portal -> HTTP 200 text/html' -Body {
    $r = Invoke-WebRequest -Uri "$PortalBaseUrl/" -Method GET -TimeoutSec $TimeoutSeconds -UseBasicParsing
    if ($r.StatusCode -ne 200) { throw "Expected 200, got $($r.StatusCode)" }
    $ct = $r.Headers['Content-Type']
    if ($ct -notmatch 'text/html') { throw "Expected text/html content type, got '$ct'" }
    "HTTP $($r.StatusCode)"
}

# ---------------------------------------------------------------------------
# Step 3: GET /api/v1/setup/status
# ---------------------------------------------------------------------------
$setupComplete = $true
Invoke-Check -Step 3 -Name 'GET /api/v1/setup/status -> 200' -Body {
    $r = Invoke-RestMethod -Uri "$ApiBaseUrl/api/v1/setup/status" -Method GET -TimeoutSec $TimeoutSeconds
    $script:setupComplete = [bool]$r.setupComplete
    "setupComplete=$($r.setupComplete), platformName=$($r.platformName)"
}

# ---------------------------------------------------------------------------
# Step 4: Complete first-run wizard if setupComplete = false
# ---------------------------------------------------------------------------
if (-not $setupComplete) {
    if ([string]::IsNullOrWhiteSpace($InitialAdminToken)) {
        Write-Host "[SKIP] Step 4 — setup required but -InitialAdminToken not provided. Retrieve from KV:" -ForegroundColor Yellow
        Write-Host "         az keyvault secret show --vault-name <kv-name> --name cloudsmith-initial-admin-token --query value -o tsv" -ForegroundColor Gray
        $results.Add([pscustomobject]@{ Step = 4; Name = 'POST /api/v1/setup (first-run wizard)'; Status = 'SKIP'; Detail = 'no InitialAdminToken'; Ms = 0 })
    } else {
        Invoke-Check -Step 4 -Name 'POST /api/v1/setup (first-run wizard)' -Body {
            $body = @{
                initialAdminToken = $InitialAdminToken
                platformName      = $SetupPlatformName
                adminUsername     = $AdminUser
                adminPassword     = $plainPassword
                timezone          = 'UTC'
            } | ConvertTo-Json
            $r = Invoke-RestMethod -Uri "$ApiBaseUrl/api/v1/setup" -Method POST `
                -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSeconds
            "setupComplete=$($r.setupComplete)"
        }
    }
} else {
    Write-Host "[SKIP] Step 4 — setup already completed" -ForegroundColor Yellow
    $results.Add([pscustomobject]@{ Step = 4; Name = 'POST /api/v1/setup (first-run wizard)'; Status = 'SKIP'; Detail = 'already complete'; Ms = 0 })
}

# ---------------------------------------------------------------------------
# Step 5: POST /api/v1/auth/local-login (cookie-based — uses .AspNetCore.Cookies)
# ---------------------------------------------------------------------------
$session = $null
Invoke-Check -Step 5 -Name 'POST /api/v1/auth/local-login (break-glass)' -Body {
    $body = @{ username = $AdminUser; password = $plainPassword } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$ApiBaseUrl/api/v1/auth/local-login" -Method POST `
        -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSeconds `
        -SessionVariable 'loginSession'
    $script:session = $loginSession
    if ($null -eq $r.sub) { throw "Expected user info with 'sub' in response" }
    "sub=$($r.sub), roles=$($r.roles -join ',')"
}

# ---------------------------------------------------------------------------
# Step 6: GET /api/v1/clusters (using cookie session)
# ---------------------------------------------------------------------------
Invoke-Check -Step 6 -Name 'GET /api/v1/clusters -> 200 []' -Body {
    $invokeArgs = @{ Uri = "$ApiBaseUrl/api/v1/clusters"; Method = 'GET'; TimeoutSec = $TimeoutSeconds }
    if ($session) { $invokeArgs['WebSession'] = $session }
    $r = Invoke-RestMethod @invokeArgs
    if ($r -isnot [array]) { throw "Expected array response, got $($r.GetType().Name)" }
    "items=$($r.Count)"
}

# ---------------------------------------------------------------------------
# Step 7: GET /openapi/v1.json (OpenAPI spec)
# ---------------------------------------------------------------------------
Invoke-Check -Step 7 -Name 'GET /openapi/v1.json -> 200' -Body {
    $r = Invoke-WebRequest -Uri "$ApiBaseUrl/openapi/v1.json" -Method GET -TimeoutSec $TimeoutSeconds -UseBasicParsing
    if ($r.StatusCode -ne 200) { throw "Expected 200, got $($r.StatusCode)" }
    $ct = $r.Headers['Content-Type']
    if ($ct -notmatch 'application/json') { throw "Expected application/json, got '$ct'" }
    "HTTP $($r.StatusCode)"
}

# ---------------------------------------------------------------------------
# Step 8: GET /health/ready (post-setup re-verify)
# ---------------------------------------------------------------------------
Invoke-Check -Step 8 -Name 'GET /health/ready -> 200 (post-setup)' -Body {
    $r = Invoke-WebRequest -Uri "$ApiBaseUrl/health/ready" -Method GET -TimeoutSec $TimeoutSeconds -UseBasicParsing
    if ($r.StatusCode -ne 200) { throw "Expected 200, got $($r.StatusCode)" }
    "HTTP $($r.StatusCode)"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "CloudSmith PaaS Smoke Test — Summary" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
$results | Format-Table -Property Step, Status, Name, Detail, Ms -AutoSize
Write-Host ""
Write-Host "Passed: $passed" -ForegroundColor Green
Write-Host "Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })

if ($failed -gt 0) {
    exit 1
}
exit 0
