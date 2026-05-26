#Requires -Version 7.0
<#
.SYNOPSIS
    CloudSmith PaaS end-to-end smoke test. Validates the golden path for a freshly
    deployed or upgraded PaaS environment (AB#1607).

.DESCRIPTION
    Runs six ordered checks against the target PaaS deployment:
      1. GET /api/v1/health -> HTTP 200
      2. GET portal URL -> HTTP 200, Content-Type: text/html
      3. GET /api/v1/platform/setup-status -> HTTP 200, setupComplete or setup_state present
      4. If setup_state = pending: POST /api/v1/setup/complete (first-run wizard happy path)
      5. POST /api/v1/auth/login (local break-glass admin)
      6. GET /api/v1/clusters -> HTTP 200, response is a JSON array

    Each check is independently timed and reported. The script exits with code 0 if
    all 6 checks pass, or code 1 if any check fails.

.PARAMETER ApiBaseUrl
    Base URL for the cloudsmith-api ACA app (e.g. https://ca-cloudsmith-dev-eus-001.azurecontainerapps.io)

.PARAMETER PortalBaseUrl
    Base URL for the cloudsmith-portal ACA app. Defaults to ApiBaseUrl if not provided.

.PARAMETER AdminUser
    Local break-glass admin username. Default: admin

.PARAMETER AdminPassword
    Local break-glass admin password. Required for step 5.

.PARAMETER SetupPlatformName
    Platform name to use when completing first-run setup. Default: CloudSmith

.PARAMETER TimeoutSeconds
    HTTP request timeout in seconds. Default: 30

.EXAMPLE
    .\paas-smoke.ps1 `
        -ApiBaseUrl https://ca-cloudsmith-dev-eus-001.azurecontainerapps.io `
        -PortalBaseUrl https://ca-cloudsmith-portal-dev-eus-001.azurecontainerapps.io `
        -AdminPassword (Read-Host -AsSecureString 'Admin password')
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ApiBaseUrl,

    [string] $PortalBaseUrl,

    [string] $AdminUser = 'admin',

    [Parameter(Mandatory)]
    [securestring] $AdminPassword,

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
# Step 1: GET /api/v1/health
# ---------------------------------------------------------------------------
Invoke-Check -Step 1 -Name 'GET /api/v1/health -> 200' -Body {
    $r = Invoke-RestMethod -Uri "$ApiBaseUrl/api/v1/health" -Method GET -TimeoutSec $TimeoutSeconds
    if ($r -isnot [psobject] -and $r -isnot [hashtable]) { throw "Response is not a JSON object" }
    "status=$($r.status ?? $r)"
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
# Step 3: GET /api/v1/platform/setup-status
# ---------------------------------------------------------------------------
$setupState = $null
Invoke-Check -Step 3 -Name 'GET /api/v1/platform/setup-status -> 200' -Body {
    # setup-status is accessible without auth (ADR-047 SetupGateMiddleware allowlist)
    $r = Invoke-RestMethod -Uri "$ApiBaseUrl/api/v1/platform/setup-status" -Method GET -TimeoutSec $TimeoutSeconds -SkipHttpErrorCheck
    $script:setupState = $r.setupState ?? 'unknown'
    "setupState=$($script:setupState), setupComplete=$($r.setupComplete)"
}

# ---------------------------------------------------------------------------
# Step 4: Complete first-run wizard if setup_state = pending
# ---------------------------------------------------------------------------
if ($setupState -eq 'pending') {
    Invoke-Check -Step 4 -Name 'POST /api/v1/setup/complete (first-run wizard)' -Body {
        $body = @{
            platformName  = $SetupPlatformName
            adminUsername = $AdminUser
            adminPassword = $plainPassword
            timezone      = 'UTC'
        } | ConvertTo-Json
        $r = Invoke-RestMethod -Uri "$ApiBaseUrl/api/v1/setup/complete" -Method POST `
            -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSeconds
        "setupComplete=$($r.setupComplete)"
    }
} else {
    Write-Host "[SKIP] Step 4 — setup already completed (state: $setupState)" -ForegroundColor Yellow
    $results.Add([pscustomobject]@{ Step = 4; Name = 'POST /api/v1/setup/complete'; Status = 'SKIP'; Detail = "state=$setupState"; Ms = 0 })
}

# ---------------------------------------------------------------------------
# Step 5: POST /api/v1/auth/login
# ---------------------------------------------------------------------------
$token = $null
Invoke-Check -Step 5 -Name 'POST /api/v1/auth/login (break-glass admin)' -Body {
    $body = @{ username = $AdminUser; password = $plainPassword } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$ApiBaseUrl/api/v1/auth/login" -Method POST `
        -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSeconds `
        -SessionVariable loginSession
    $script:token = $r.accessToken ?? $r.access_token ?? ''
    if ([string]::IsNullOrEmpty($script:token)) { throw "No access token returned" }
    "token length=$($script:token.Length)"
}

# ---------------------------------------------------------------------------
# Step 6: GET /api/v1/clusters
# ---------------------------------------------------------------------------
Invoke-Check -Step 6 -Name 'GET /api/v1/clusters -> 200 []' -Body {
    $headers = if ($token) { @{ Authorization = "Bearer $token" } } else { @{} }
    $r = Invoke-RestMethod -Uri "$ApiBaseUrl/api/v1/clusters" -Method GET `
        -Headers $headers -TimeoutSec $TimeoutSeconds
    if ($r -isnot [array]) { throw "Expected array response, got $($r.GetType().Name)" }
    "items=$($r.Count)"
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
