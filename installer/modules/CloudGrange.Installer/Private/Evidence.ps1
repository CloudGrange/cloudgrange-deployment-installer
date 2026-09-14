#Requires -Version 7.4
<#
.SYNOPSIS
    Redacted evidence writer (docs/future-profiles/rke2-bom-installer-design.md §3.5).
.DESCRIPTION
    Evidence lands under <state>/evidence/<installId>/<attempt>/<phase>/<name>. Every text is passed
    through a redactor before it is written; there is no unredacted path. In the installed product
    the redactor is the infrastructure SecretRef redactor (New-SecretRefRedactor +
    Protect-SecretRefText from management/SecretRef.psm1); ConvertTo-CgSecretRefRedactor adapts it.
.NOTES
    TaskReference: AB#8129 AB#9015
#>
Set-StrictMode -Version Latest

function ConvertTo-CgSecretRefRedactor {
    <# Adapts a SecretRef redactor object to the scriptblock shape used by the installer. #>
    param([Parameter(Mandatory)][psobject]$SecretRefRedactor)
    if (-not (Get-Command -Name Protect-SecretRefText -ErrorAction SilentlyContinue)) {
        throw (New-CgError 'management-scripts-missing' 'Protect-SecretRefText is not loaded; import management/SecretRef.psm1 first.')
    }
    $redactor = $SecretRefRedactor
    return { param([string]$Text) Protect-SecretRefText -Redactor $redactor -Text $Text }.GetNewClosure()
}

function Invoke-CgRedactor {
    param([Parameter(Mandatory)][scriptblock]$Redactor, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $redacted = & $Redactor $Text
    if ($redacted -isnot [string]) { throw (New-CgError 'evidence-redactor-invalid' 'The redactor must return a single string.') }
    return $redacted
}

function Write-CgEvidence {
    param(
        [Parameter(Mandatory)][string]$StateDirectory,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$InstallId,
        [Parameter(Mandatory)][ValidateRange(1, 1000000)][int]$Attempt,
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,63}$')][string]$Phase,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9._-]{0,127}$')][string]$Name,
        [Parameter(Mandatory)][AllowNull()]$Content,
        [Parameter(Mandatory)][scriptblock]$Redactor
    )
    $text = if ($Content -is [string]) { $Content } else { ConvertTo-Json -InputObject $Content -Depth 32 }
    $redacted = Invoke-CgRedactor -Redactor $Redactor -Text $text
    $path = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $StateDirectory 'evidence') $InstallId) ([string]$Attempt)) $Phase) $Name
    Write-CgAtomicFile -Path $path -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($redacted)) -Mode File0600
    return $path
}
