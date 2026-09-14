#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — Post-export release gate: scan the raw bytes of an appliance VHDX for install-time
# secrets. Two independent checks:
#   1. exact values captured from the source VM before generalization (in memory only), e.g. the
#      .env secrets, the API master key and setup token, the TLS private key and the installer's
#      SSH public key blob (authorized_keys residue);
#   2. generation-independent patterns: any <NAME>(PASSWORD|TOKEN|SECRET)=<48 hex> assignment, the
#      shape the installer and first boot generate.
# Output never contains a value: only labels, a short SHA-256 prefix and occurrence counts.
# Returns a result object; Passed is $false when anything is found.

function Test-ApplianceVhdxSecrets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        # label -> literal value
        [hashtable]$Values = @{}
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $literals = @($Values.GetEnumerator() | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Value) -and ([string]$_.Value).Length -ge 16 } |
        ForEach-Object { [pscustomobject]@{ Label = [string]$_.Key; Value = [string]$_.Value; Count = [long]0 } })
    $pattern = [regex]::new('[A-Z_]*(?:PASSWORD|TOKEN|SECRET)=[0-9a-f]{48}(?![0-9a-f])', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    $patternCount = [long]0

    $maxLen = [Math]::Max(80, (@($literals | ForEach-Object { $_.Value.Length }) + 0 | Measure-Object -Maximum).Maximum)
    $chunk = 16MB
    $buf = [byte[]]::new($chunk + $maxLen)
    $latin1 = [System.Text.Encoding]::Latin1
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $carry = 0
        while (($read = $fs.Read($buf, $carry, $chunk)) -gt 0) {
            $len = $carry + $read
            $text = $latin1.GetString($buf, 0, $len)
            $last = $read -lt $chunk
            # A match that starts inside the carried tail is counted in the next chunk instead.
            $limit = if ($last) { $len } else { $len - $maxLen + 1 }
            foreach ($l in $literals) {
                $pos = 0
                while (($pos = $text.IndexOf($l.Value, $pos, [StringComparison]::Ordinal)) -ge 0) {
                    if ($pos -lt $limit) { $l.Count++ }
                    $pos++
                }
            }
            foreach ($m in $pattern.Matches($text)) {
                if ($m.Index -lt $limit) { $patternCount++ }
            }
            $carry = [Math]::Min($maxLen - 1, $len)
            [Array]::Copy($buf, $len - $carry, $buf, 0, $carry)
        }
    } finally {
        $fs.Dispose()
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $literals) {
        $h = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($l.Value))).Substring(0, 16).ToLowerInvariant()
        $lines.Add(('{0} (sha256 {1}): {2}' -f $l.Label, $h, $l.Count))
    }
    $lines.Add("pattern <NAME>(PASSWORD|TOKEN|SECRET)=<48 hex>: $patternCount")
    $total = $patternCount + (@($literals | ForEach-Object { $_.Count }) + 0 | Measure-Object -Sum).Sum
    [pscustomobject]@{
        Path          = $Path
        LiteralsCount = $literals.Count
        Findings      = [long]$total
        Passed        = ($total -eq 0)
        Report        = $lines
    }
}
