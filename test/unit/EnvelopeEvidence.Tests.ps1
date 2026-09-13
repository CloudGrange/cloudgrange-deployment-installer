#Requires -Version 7.4
<#
.SYNOPSIS
    Node key, AES-256-GCM envelopes (AAD installId|purpose) and the redacting evidence writer.
.NOTES
    TaskReference: AB#8129 AB#9015
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../support/TestHelpers.ps1')
    Import-Module $ModuleManifest -Force
    $installId = [guid]::NewGuid().ToString()
    $plaintext = [Text.Encoding]::UTF8.GetBytes('unseal-share canary-3f9a')
}

Describe 'Node key' {
    It 'creates a 32-byte owner-read-only key once and never regenerates it' {
        $state = New-TestDirectory -Prefix 'cg-key'
        $first = Initialize-CgNodeKey -StateDirectory $state
        $first.Created | Should -BeTrue
        $key = Read-CgNodeKey -StateDirectory $state
        $key.Length | Should -Be 32
        $second = Initialize-CgNodeKey -StateDirectory $state
        $second.Created | Should -BeFalse
        [Convert]::ToHexString((Read-CgNodeKey -StateDirectory $state)) | Should -Be ([Convert]::ToHexString($key))
        if ($IsLinux) { [IO.File]::GetUnixFileMode($first.Path) | Should -Be ([IO.UnixFileMode]::UserRead) }
    }

    It 'refuses a key file of the wrong length' {
        $state = New-TestDirectory -Prefix 'cg-key'
        $null = New-Item -ItemType Directory -Path (Join-Path $state 'keys')
        [IO.File]::WriteAllBytes((Join-Path $state 'keys/node.key'), [byte[]]::new(16))
        { Read-CgNodeKey -StateDirectory $state } | Should -Throw '*node-key-invalid*'
        { Initialize-CgNodeKey -StateDirectory $state } | Should -Throw '*node-key-invalid*'
    }
}

Describe 'Envelopes' {
    BeforeAll {
        $key = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    }

    It 'round-trips and never contains the plaintext' {
        $envelope = Protect-CgEnvelope -Key $key -InstallId $installId -Purpose 'vault-recovery' -Plaintext $plaintext
        [Text.Encoding]::UTF8.GetString($envelope) | Should -Not -Match 'canary-3f9a'
        $decrypted = Unprotect-CgEnvelope -Key $key -InstallId $installId -Purpose 'vault-recovery' -EnvelopeBytes $envelope
        [Text.Encoding]::UTF8.GetString($decrypted) | Should -BeExactly 'unseal-share canary-3f9a'
    }

    It 'fails authentication when the AAD purpose differs, even if the document is relabelled' {
        $envelope = Protect-CgEnvelope -Key $key -InstallId $installId -Purpose 'vault-recovery' -Plaintext $plaintext
        $document = (ConvertFrom-CgStrictJson -Bytes $envelope).Value
        $document['purpose'] = 'setup-token'
        $relabelled = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $document))
        { Unprotect-CgEnvelope -Key $key -InstallId $installId -Purpose 'setup-token' -EnvelopeBytes $relabelled } | Should -Throw '*envelope-undecryptable*'
    }

    It 'fails authentication when the AAD installId differs, even if the document is relabelled' {
        $envelope = Protect-CgEnvelope -Key $key -InstallId $installId -Purpose 'vault-recovery' -Plaintext $plaintext
        $other = [guid]::NewGuid().ToString()
        $document = (ConvertFrom-CgStrictJson -Bytes $envelope).Value
        $document['installId'] = $other
        $relabelled = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $document))
        { Unprotect-CgEnvelope -Key $key -InstallId $other -Purpose 'vault-recovery' -EnvelopeBytes $relabelled } | Should -Throw '*envelope-undecryptable*'
    }

    It 'refuses an envelope bound to another installation or purpose' {
        $envelope = Protect-CgEnvelope -Key $key -InstallId $installId -Purpose 'vault-recovery' -Plaintext $plaintext
        { Unprotect-CgEnvelope -Key $key -InstallId ([guid]::NewGuid().ToString()) -Purpose 'vault-recovery' -EnvelopeBytes $envelope } | Should -Throw '*envelope-binding-mismatch*'
        { Unprotect-CgEnvelope -Key $key -InstallId $installId -Purpose 'setup-token' -EnvelopeBytes $envelope } | Should -Throw '*envelope-binding-mismatch*'
    }

    It 'detects ciphertext and tag tampering' -ForEach @('ciphertext', 'tag', 'nonce') {
        $envelope = Protect-CgEnvelope -Key $key -InstallId $installId -Purpose 'vault-recovery' -Plaintext $plaintext
        $document = (ConvertFrom-CgStrictJson -Bytes $envelope).Value
        $bytes = [Convert]::FromBase64String($document[$_])
        $bytes[0] = $bytes[0] -bxor 0x01
        $document[$_] = [Convert]::ToBase64String($bytes)
        $tampered = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $document))
        { Unprotect-CgEnvelope -Key $key -InstallId $installId -Purpose 'vault-recovery' -EnvelopeBytes $tampered } | Should -Throw '*envelope-undecryptable*'
    }

    It 'detects a wrong key' {
        $envelope = Protect-CgEnvelope -Key $key -InstallId $installId -Purpose 'vault-recovery' -Plaintext $plaintext
        $wrong = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
        { Unprotect-CgEnvelope -Key $wrong -InstallId $installId -Purpose 'vault-recovery' -EnvelopeBytes $envelope } | Should -Throw '*envelope-undecryptable*'
    }

    It 'rejects malformed bindings' {
        { Protect-CgEnvelope -Key $key -InstallId 'not-a-uuid' -Purpose 'vault-recovery' -Plaintext $plaintext } | Should -Throw '*envelope-binding-invalid*'
        { Protect-CgEnvelope -Key $key -InstallId $installId -Purpose 'Vault Recovery' -Plaintext $plaintext } | Should -Throw '*envelope-binding-invalid*'
    }

    It 'writes envelope files atomically under the node key with owner-only mode' {
        $state = New-TestDirectory -Prefix 'cg-env'
        $null = Initialize-CgNodeKey -StateDirectory $state
        $written = Write-CgEnvelopeFile -StateDirectory $state -RelativePath 'vault/recovery.envelope' -InstallId $installId -Purpose 'vault-recovery' -Plaintext $plaintext
        Test-Path -LiteralPath ($written.Path + '.tmp') | Should -BeFalse
        $written.Sha256 | Should -Be (Get-TestFileSha256 $written.Path)
        $decrypted = Unprotect-CgEnvelope -Key (Read-CgNodeKey -StateDirectory $state) -InstallId $installId -Purpose 'vault-recovery' -EnvelopeBytes ([IO.File]::ReadAllBytes($written.Path))
        [Text.Encoding]::UTF8.GetString($decrypted) | Should -BeExactly 'unseal-share canary-3f9a'
        if ($IsLinux) { [IO.File]::GetUnixFileMode($written.Path) | Should -Be ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) }
    }
}

Describe 'Write-CgEvidence' {
    It 'writes redacted evidence under evidence/installId/attempt/phase/name' {
        $state = New-TestDirectory -Prefix 'cg-evidence'
        $redactor = { param([string]$Text) $Text.Replace('canary-3f9a', '[REDACTED]') }
        $path = Write-CgEvidence -StateDirectory $state -InstallId $installId -Attempt 2 -Phase 'vault' -Name 'health.json' -Redactor $redactor -Content ([ordered]@{ note = 'token canary-3f9a' })
        $path | Should -Be (Join-Path $state ('evidence/' + $installId + '/2/vault/health.json'))
        $text = [IO.File]::ReadAllText($path)
        $text | Should -Not -Match 'canary-3f9a'
        $text | Should -Match '\[REDACTED\]'
    }

    It 'refuses a redactor that does not return a single string' {
        $state = New-TestDirectory -Prefix 'cg-evidence'
        { Write-CgEvidence -StateDirectory $state -InstallId $installId -Attempt 1 -Phase 'vault' -Name 'x.json' -Redactor { param($t) 1, 2 } -Content 'text' } | Should -Throw '*evidence-redactor-invalid*'
        Test-Path -LiteralPath (Join-Path $state 'evidence') | Should -BeFalse
    }

    It 'requires the SecretRef redactor to be loaded before adapting it' {
        Get-Module -Name SecretRef | Remove-Module -Force
        { ConvertTo-CgSecretRefRedactor -SecretRefRedactor ([pscustomobject]@{}) } | Should -Throw '*management-scripts-missing*'
    }

    It 'adapts a SecretRef redactor (Protect-SecretRefText) to the evidence writer' {
        Get-Module -Name SecretRef | Remove-Module -Force
        $null = New-Module -Name SecretRef -ScriptBlock {
            function Protect-SecretRefText { param([Parameter(Mandatory)][psobject]$Redactor, [Parameter(Mandatory)][AllowEmptyString()][string]$Text) $Text.Replace($Redactor.Value, '[REDACTED]') }
            Export-ModuleMember -Function Protect-SecretRefText
        } | Import-Module -Global -PassThru
        try {
            $redactor = ConvertTo-CgSecretRefRedactor -SecretRefRedactor ([pscustomobject]@{ Value = 'canary-3f9a' })
            & $redactor 'a canary-3f9a b' | Should -BeExactly 'a [REDACTED] b'
        } finally {
            Get-Module -Name SecretRef | Remove-Module -Force
        }
    }
}
