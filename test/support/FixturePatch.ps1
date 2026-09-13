#Requires -Version 7.0
<#
.SYNOPSIS
    JSON-pointer patching for release BOM fixture cases (shared by Test-ReleaseBomSchema.ps1 and Pester).
.NOTES
    TaskReference: AB#8129 AB#9016
#>
Set-StrictMode -Version Latest

function Edit-FixtureNode {
    # Minimal JSON-pointer patching over ConvertFrom-Json -AsHashtable output. Object keys and
    # array indexes are supported for "set"; "remove" applies to object keys only.
    param([Parameter(Mandatory)][hashtable]$Root, [Parameter(Mandatory)][string]$Pointer, $Value, [switch]$Remove)
    $parts = @($Pointer.TrimStart('/') -split '/')
    $node = $Root
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $part = $parts[$i]
        if ($node -is [Collections.IList]) { $node = $node[[int]$part] } else { $node = $node[$part] }
        if ($null -eq $node) { throw ('Fixture path does not resolve: ' + $Pointer) }
    }
    $leaf = $parts[-1]
    if ($node -is [Collections.IList]) {
        if ($Remove) { throw 'Array element removal is not supported by this fixture format.' }
        $node[[int]$leaf] = $Value
    } elseif ($Remove) {
        if (-not $node.ContainsKey($leaf)) { throw ('Fixture path does not exist for removal: ' + $Pointer) }
        $node.Remove($leaf)
    } else {
        $node[$leaf] = $Value
    }
}

function Get-PatchedFixtureJson {
    param([Parameter(Mandatory)][string]$ValidText, [Parameter(Mandatory)][Collections.IDictionary]$Case)
    $bom = ConvertFrom-Json $ValidText -AsHashtable -Depth 32
    foreach ($patch in @($Case['patches'])) {
        if ($patch['op'] -eq 'set') { Edit-FixtureNode -Root $bom -Pointer $patch['path'] -Value $patch['value'] }
        elseif ($patch['op'] -eq 'remove') { Edit-FixtureNode -Root $bom -Pointer $patch['path'] -Remove }
        else { throw ('Unknown patch op in case ' + $Case['id']) }
    }
    return (ConvertTo-Json -InputObject $bom -Depth 32)
}
