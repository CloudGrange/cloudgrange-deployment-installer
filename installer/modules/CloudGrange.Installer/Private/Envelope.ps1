#Requires -Version 7.4
<#
.SYNOPSIS
    Node key and node-local envelopes (docs/future-profiles/rke2-bom-installer-design.md §3.1).
.DESCRIPTION
    state/keys/node.key is 32 random bytes generated once at the first Install (never in Plan),
    root-only (0400). Envelopes are AES-256-GCM under that key with AAD "installId|purpose".
    They enable crash recovery without the custodian's key; they are never part of a backup set.
    Envelope contents are callers' secrets and are never logged or returned as strings.
.NOTES
    TaskReference: AB#8129 AB#9015
#>
Set-StrictMode -Version Latest

$script:CgInstallIdPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$script:CgPurposePattern = '^[a-z][a-z0-9-]{0,63}$'

function Get-CgNodeKeyPath {
    param([Parameter(Mandatory)][string]$StateDirectory)
    return Join-Path (Join-Path $StateDirectory 'keys') 'node.key'
}

function Initialize-CgNodeKey {
    <# Creates state/keys/node.key when absent; an existing key is validated and never regenerated. #>
    param([Parameter(Mandatory)][string]$StateDirectory)
    $path = Get-CgNodeKeyPath -StateDirectory $StateDirectory
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $null = Read-CgNodeKey -StateDirectory $StateDirectory
        return [pscustomobject]@{ Path = $path; Created = $false }
    }
    $key = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    try {
        Write-CgAtomicFile -Path $path -Bytes $key -Mode File0400
    } finally {
        [Array]::Clear($key, 0, $key.Length)
    }
    return [pscustomobject]@{ Path = $path; Created = $true }
}

function Read-CgNodeKey {
    param([Parameter(Mandatory)][string]$StateDirectory)
    $path = Get-CgNodeKeyPath -StateDirectory $StateDirectory
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw (New-CgError 'node-key-missing' 'state/keys/node.key is missing.') }
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ne 32) { throw (New-CgError 'node-key-invalid' 'state/keys/node.key is not 32 bytes.') }
    return , $bytes
}

function Get-CgEnvelopeAad {
    param([string]$InstallId, [string]$Purpose)
    if ($InstallId -notmatch $script:CgInstallIdPattern) { throw (New-CgError 'envelope-binding-invalid' 'installId is not a lowercase UUID.') }
    if ($Purpose -notmatch $script:CgPurposePattern) { throw (New-CgError 'envelope-binding-invalid' 'purpose is not a valid identifier.') }
    return [Text.Encoding]::UTF8.GetBytes($InstallId + '|' + $Purpose)
}

function Protect-CgEnvelope {
    param(
        [Parameter(Mandatory)][byte[]]$Key,
        [Parameter(Mandatory)][string]$InstallId,
        [Parameter(Mandatory)][string]$Purpose,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Plaintext
    )
    if ($Key.Length -ne 32) { throw (New-CgError 'node-key-invalid' 'Envelope key must be 32 bytes.') }
    $aad = Get-CgEnvelopeAad -InstallId $InstallId -Purpose $Purpose
    $nonce = [Security.Cryptography.RandomNumberGenerator]::GetBytes(12)
    $ciphertext = [byte[]]::new($Plaintext.Length)
    $tag = [byte[]]::new(16)
    $aes = [Security.Cryptography.AesGcm]::new($Key, 16)
    try { $aes.Encrypt($nonce, $Plaintext, $ciphertext, $tag, $aad) } finally { $aes.Dispose() }
    $document = [ordered]@{
        schema = 'cg-node-envelope-v1'
        installId = $InstallId
        purpose = $Purpose
        algorithm = 'AES-256-GCM'
        nonce = [Convert]::ToBase64String($nonce)
        ciphertext = [Convert]::ToBase64String($ciphertext)
        tag = [Convert]::ToBase64String($tag)
    }
    return , (ConvertTo-CgJsonBytes -InputObject $document)
}

function Unprotect-CgEnvelope {
    param(
        [Parameter(Mandatory)][byte[]]$Key,
        [Parameter(Mandatory)][string]$InstallId,
        [Parameter(Mandatory)][string]$Purpose,
        [Parameter(Mandatory)][byte[]]$EnvelopeBytes
    )
    if ($Key.Length -ne 32) { throw (New-CgError 'node-key-invalid' 'Envelope key must be 32 bytes.') }
    $aad = Get-CgEnvelopeAad -InstallId $InstallId -Purpose $Purpose
    try { $document = (ConvertFrom-CgStrictJson -Bytes $EnvelopeBytes -MaxBytes 16777216).Value }
    catch { throw (New-CgError 'envelope-undecryptable' 'Envelope does not parse.') }
    if ($document -isnot [Collections.IDictionary] -or $document['schema'] -ne 'cg-node-envelope-v1' -or $document['algorithm'] -ne 'AES-256-GCM') {
        throw (New-CgError 'envelope-undecryptable' 'Envelope has an unknown format.')
    }
    if ($document['installId'] -ne $InstallId -or $document['purpose'] -ne $Purpose) {
        throw (New-CgError 'envelope-binding-mismatch' 'Envelope belongs to a different installation or purpose.')
    }
    try {
        $nonce = [Convert]::FromBase64String([string]$document['nonce'])
        $ciphertext = [Convert]::FromBase64String([string]$document['ciphertext'])
        $tag = [Convert]::FromBase64String([string]$document['tag'])
    } catch {
        throw (New-CgError 'envelope-undecryptable' 'Envelope fields are not base64.')
    }
    if ($nonce.Length -ne 12 -or $tag.Length -ne 16) { throw (New-CgError 'envelope-undecryptable' 'Envelope nonce or tag has the wrong length.') }
    $plaintext = [byte[]]::new($ciphertext.Length)
    $aes = [Security.Cryptography.AesGcm]::new($Key, 16)
    try {
        $aes.Decrypt($nonce, $ciphertext, $tag, $plaintext, $aad)
    } catch [Security.Cryptography.CryptographicException] {
        throw (New-CgError 'envelope-undecryptable' 'Envelope authentication failed.')
    } finally {
        $aes.Dispose()
    }
    return , $plaintext
}

function Write-CgEnvelopeFile {
    <# Encrypts and writes an envelope with the temp/fsync/rename discipline (0600). #>
    param(
        [Parameter(Mandatory)][string]$StateDirectory,
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,31}/[a-z][a-z0-9.-]{0,63}\.envelope$')][string]$RelativePath,
        [Parameter(Mandatory)][string]$InstallId,
        [Parameter(Mandatory)][string]$Purpose,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Plaintext
    )
    $key = Read-CgNodeKey -StateDirectory $StateDirectory
    try {
        $bytes = Protect-CgEnvelope -Key $key -InstallId $InstallId -Purpose $Purpose -Plaintext $Plaintext
    } finally {
        [Array]::Clear($key, 0, $key.Length)
    }
    $path = Join-Path $StateDirectory $RelativePath
    Write-CgAtomicFile -Path $path -Bytes $bytes -Mode File0600
    return [pscustomobject]@{ Path = $path; Sha256 = Get-CgSha256Hex -Bytes $bytes }
}
