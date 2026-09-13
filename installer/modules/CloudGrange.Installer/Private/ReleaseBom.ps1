#Requires -Version 7.4
<#
.SYNOPSIS
    cg-release-bom-v1 validator: strict parse, closed schema, and semantic rules with stable codes.
.DESCRIPTION
    Test-CgReleaseBom validates BOM bytes in three layers:
      1. strict JSON (UTF-8, no BOM, no duplicate or case-colliding keys, 1 MiB bound);
      2. schemas/release-bom.schema.json (closed structural schema);
      3. Get-CgReleaseBomViolation: rules JSON Schema cannot express, plus independent re-checks of
         the security-relevant structural rules (digest pinning, floating locators, per-kind
         retrieval, vendor exclusivity, SBOM obligations, site-config binding) so a schema engine
         defect cannot silently admit them.
    Rule codes are listed by Get-CgReleaseBomRuleCatalog; every code is exercised by
    schemas/fixtures/release-bom.semantic-cases.json or test/unit/ReleaseBom.Tests.ps1.
    Member/catalog set equality and provenance/candidate equality need authenticated envelopes and
    remain with cg-trust integration (not in this validator).
.NOTES
    TaskReference: AB#8129 AB#9016
#>
Set-StrictMode -Version Latest

$script:CgSiteConfigSchemaUri = 'https://cloudgrange.cloud/schemas/cg-site-config-v1.schema.json'
$script:CgBomPhaseOrder = @('preflight', 'retrieve', 'runtime', 'storage', 'postgres', 'vault', 'identity', 'migrate', 'api', 'portal', 'gateway', 'module', 'handoff')
$script:CgOciReferencePattern = '^(?<repository>[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:[0-9]{1,5})?(/[a-z0-9]+([._-][a-z0-9]+)*)+)@sha256:(?<digest>[0-9a-f]{64})$'
$script:CgHttpsUriPattern = '^https://(?<host>[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:[0-9]{1,5})?)(?<path>/[A-Za-z0-9._~%/+-]*)$'
$script:CgReleaseTagPattern = '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9a-z]+(\.[0-9a-z]+)*)?$'
$script:CgKindRetrieval = @{
    'oci-image' = @('oci'); 'vendor-oci-image' = @('oci')
    'helm-chart' = @('bundled'); 'vendor-helm-chart' = @('bundled')
    'vendor-archive' = @('https', 'bundled')
    'installer-archive' = @('github-release-asset', 'bundled'); 'verifier' = @('github-release-asset', 'bundled')
    'agent-package' = @('github-release-asset', 'bundled'); 'module-package' = @('github-release-asset', 'bundled')
    'script-archive' = @('github-release-asset', 'bundled')
}
# Design §2.3 / G10. script-archive is first-party but is not in the design's SBOM list.
$script:CgSbomKinds = @('oci-image', 'helm-chart', 'agent-package', 'module-package', 'installer-archive', 'verifier')

$script:CgBomRuleCatalog = [ordered]@{
    'bom-unreadable' = 'The BOM file is missing or unreadable.'
    'invalid-json' = 'The BOM is not UTF-8 JSON without a byte order mark.'
    'json-duplicate-key' = 'An object repeats a property name (compared case-insensitively).'
    'bom-too-large' = 'The BOM exceeds 1 MiB.'
    'bom-shape-invalid' = 'The BOM root or a member is not the expected JSON type.'
    'schema-violation' = 'The BOM does not satisfy schemas/release-bom.schema.json.'
    'release-tag-version-mismatch' = 'product.releaseTag is not v<product.version>.'
    'installer-version-mismatch' = 'compatibility.installer.version differs from product.version.'
    'assembly-repository-mismatch' = 'assembly.repository differs from product.releaseRepository.'
    'reader-version-newer-than-product' = 'database.minCompatibleReaderVersion is newer than the product.'
    'configuration-schema-binding-invalid' = 'configurationSchema is not schemaId cg-site-config-v1, kind CloudGrangeSiteConfig, schemaVersion 1 at schemas/site-config-v1.schema.json with a sha256.'
    'configuration-schema-unreadable' = 'The configuration schema file supplied for binding is missing.'
    'configuration-schema-digest-mismatch' = 'The supplied configuration schema bytes do not hash to configurationSchema.sha256.'
    'configuration-schema-identity-mismatch' = 'The supplied configuration schema is not cg-site-config-v1 (kind CloudGrangeSiteConfig, schema_version 1).'
    'image-inventory-missing' = 'compatibility.kubernetes.imageInventorySha256 is absent or not a digest.'
    'image-inventory-member-missing' = 'No rke2-images member carries the curator image inventory.'
    'image-inventory-mismatch' = 'The rke2-images curator evidence digest differs from imageInventorySha256.'
    'kubernetes-runtime-member-missing' = 'No rke2-runtime member exists.'
    'kubernetes-version-mismatch' = 'The rke2-runtime member version differs from compatibility.kubernetes.version.'
    'composition-ref-not-older' = 'An upgradeFrom or rollbackTo entry is not older than the product version.'
    'composition-ref-duplicate-version' = 'An upgradeFrom or rollbackTo list names the same version twice.'
    'members-missing' = 'members is absent or not an array.'
    'kind-unknown' = 'A member kind is not a cg-release-bom-v1 kind.'
    'duplicate-member-id' = 'Two members share an id.'
    'duplicate-artifact-digest' = 'Two members share an artifact digest.'
    'duplicate-retrieval-location' = 'Two members are retrieved from the same location.'
    'retrieval-type-not-allowed-for-kind' = 'The retrieval type is not permitted for the member kind.'
    'vendor-block-required' = 'A vendor-* member has no vendor block.'
    'vendor-block-forbidden' = 'A first-party member carries a vendor block.'
    'sbom-required' = 'A first-party member kind that requires an SBOM has no evidence.sbomSha256.'
    'kind-constraint-violated' = 'The member os, architecture or phase is not permitted for its kind.'
    'oci-reference-not-digest-pinned' = 'An OCI reference is tagged, registry-less, tag+digest or otherwise not <dotted-host>/<path>@sha256:<hex>.'
    'oci-reference-digest-mismatch' = 'retrieval.reference digest differs from sha256.'
    'mirror-digest-mismatch' = 'retrieval.mirrorOf digest differs from sha256.'
    'oci-name-reference-mismatch' = 'An OCI member name differs from its reference repository.'
    'vendor-image-not-mirrored' = 'A vendor-oci-image has no mirrorOf upstream reference.'
    'vendor-image-outside-mirror-namespace' = 'A vendor-oci-image is not retrieved from ghcr.io/cloudgrange/vendor/.'
    'first-party-image-outside-namespace' = 'An oci-image is not retrieved from ghcr.io/cloudgrange/ (outside vendor/).'
    'https-uri-invalid' = 'An https locator has a non-https scheme, userinfo, query, fragment or an undotted host.'
    'floating-locator' = 'A locator contains a floating "latest" path segment.'
    'release-asset-tag-invalid' = 'A release-asset tag is not an exact release tag.'
    'release-asset-foreign-release' = 'A release asset is not attached to this composition release (product.releaseRepository at product.releaseTag).'
    'chart-bundle-path-mismatch' = 'A chart is not bundled at charts/<name>-<version>.tgz.'
    'chart-version-not-product-version' = 'A first-party helm-chart version differs from product.version.'
    'upstream-source-invalid' = 'vendor.upstreamSource is neither a valid https locator nor a digest-pinned OCI reference.'
    'dangling-depends-on' = 'dependsOn names a member that does not exist.'
    'self-dependency' = 'A member depends on itself.'
    'dependency-cycle' = 'dependsOn contains a cycle.'
    'depends-on-later-phase' = 'A member depends on a member consumed in a later phase.'
}

function Get-CgReleaseBomRuleCatalog {
    $copy = [ordered]@{}
    foreach ($key in $script:CgBomRuleCatalog.Keys) { $copy[$key] = $script:CgBomRuleCatalog[$key] }
    return $copy
}

function Get-CgMapValue {
    param([AllowNull()]$Map, [Parameter(Mandatory)][string[]]$Path)
    $node = $Map
    foreach ($segment in $Path) {
        if ($node -isnot [Collections.IDictionary] -or -not $node.Contains($segment)) { return $null }
        $node = $node[$segment]
    }
    if ($node -is [Collections.IList]) { return , $node }
    return $node
}

function Test-CgStringMatch {
    param([AllowNull()]$Value, [Parameter(Mandatory)][string]$Pattern)
    return ($Value -is [string] -and [regex]::IsMatch($Value, $Pattern))
}

function Get-CgOciReferenceParts {
    param([AllowNull()]$Reference)
    if ($Reference -isnot [string]) { return $null }
    $match = [regex]::Match($Reference, $script:CgOciReferencePattern)
    if (-not $match.Success) { return $null }
    return [pscustomobject]@{ Repository = $match.Groups['repository'].Value; Digest = $match.Groups['digest'].Value }
}

function Test-CgHttpsLocator {
    <# Returns 'ok', 'https-uri-invalid' or 'floating-locator'. #>
    param([AllowNull()]$Uri)
    if ($Uri -isnot [string] -or $Uri.Length -gt 1024) { return 'https-uri-invalid' }
    $match = [regex]::Match($Uri, $script:CgHttpsUriPattern)
    if (-not $match.Success) { return 'https-uri-invalid' }
    foreach ($segment in $match.Groups['path'].Value.Split('/')) {
        $decoded = $segment
        try { $decoded = [Uri]::UnescapeDataString($segment) } catch { return 'https-uri-invalid' }
        if ($decoded.Trim() -ieq 'latest') { return 'floating-locator' }
    }
    return 'ok'
}

function Get-CgReleaseBomViolation {
    <#
    .SYNOPSIS
        Returns @{code; path} objects for every semantic rule the BOM violates (empty when none).
    #>
    param([Parameter(Mandatory)][Collections.IDictionary]$Bom, [AllowNull()][byte[]]$ConfigurationSchemaBytes)
    $violations = [Collections.Generic.List[object]]::new()
    $add = { param([string]$Code, [string]$Path) $violations.Add([pscustomobject]@{ code = $Code; path = $Path }) }
    $isVersion = { param($Value) Test-CgStringMatch -Value $Value -Pattern $script:CgProductVersionPattern }

    # Product, assembly and compatibility coherence.
    try {
        $version = Get-CgMapValue $Bom @('product', 'version')
        $releaseTag = Get-CgMapValue $Bom @('product', 'releaseTag')
        $releaseRepository = Get-CgMapValue $Bom @('product', 'releaseRepository')
        if ($version -is [string] -and $releaseTag -is [string] -and $releaseTag -cne ('v' + $version)) { & $add 'release-tag-version-mismatch' '/product/releaseTag' }
        $installerVersion = Get-CgMapValue $Bom @('compatibility', 'installer', 'version')
        if ($version -is [string] -and $installerVersion -is [string] -and $installerVersion -cne $version) { & $add 'installer-version-mismatch' '/compatibility/installer/version' }
        $assemblyRepository = Get-CgMapValue $Bom @('assembly', 'repository')
        if ($assemblyRepository -is [string] -and $releaseRepository -is [string] -and $assemblyRepository -cne $releaseRepository) { & $add 'assembly-repository-mismatch' '/assembly/repository' }
        $minReader = Get-CgMapValue $Bom @('compatibility', 'database', 'minCompatibleReaderVersion')
        if ((& $isVersion $version) -and (& $isVersion $minReader) -and (Compare-CgProductVersion -Left $minReader -Right $version) -gt 0) {
            & $add 'reader-version-newer-than-product' '/compatibility/database/minCompatibleReaderVersion'
        }
        foreach ($listName in @('upgradeFrom', 'rollbackTo')) {
            $list = Get-CgMapValue $Bom @('compatibility', $listName)
            if ($list -isnot [Collections.IList]) { continue }
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            for ($i = 0; $i -lt $list.Count; $i++) {
                $refVersion = Get-CgMapValue $list[$i] @('version')
                if (-not (& $isVersion $refVersion)) { continue }
                if ((& $isVersion $version) -and (Compare-CgProductVersion -Left $refVersion -Right $version) -ge 0) { & $add 'composition-ref-not-older' ('/compatibility/' + $listName + '/' + $i + '/version') }
                if (-not $seen.Add($refVersion)) { & $add 'composition-ref-duplicate-version' ('/compatibility/' + $listName + '/' + $i + '/version') }
            }
        }
    } catch { & $add 'bom-shape-invalid' '/product' }

    # Site configuration schema binding.
    try {
        $binding = Get-CgMapValue $Bom @('configurationSchema')
        if ($binding -isnot [Collections.IDictionary]) {
            & $add 'configuration-schema-binding-invalid' '/configurationSchema'
        } else {
            if ((Get-CgMapValue $binding @('schemaId')) -cne 'cg-site-config-v1') { & $add 'configuration-schema-binding-invalid' '/configurationSchema/schemaId' }
            if ((Get-CgMapValue $binding @('kind')) -cne 'CloudGrangeSiteConfig') { & $add 'configuration-schema-binding-invalid' '/configurationSchema/kind' }
            $schemaVersion = Get-CgMapValue $binding @('schemaVersion')
            if (-not (($schemaVersion -is [long] -or $schemaVersion -is [int]) -and $schemaVersion -eq 1)) { & $add 'configuration-schema-binding-invalid' '/configurationSchema/schemaVersion' }
            if ((Get-CgMapValue $binding @('path')) -cne 'schemas/site-config-v1.schema.json') { & $add 'configuration-schema-binding-invalid' '/configurationSchema/path' }
            $bindingSha = Get-CgMapValue $binding @('sha256')
            if (-not (Test-CgStringMatch -Value $bindingSha -Pattern $script:CgSha256Pattern)) { & $add 'configuration-schema-binding-invalid' '/configurationSchema/sha256' }
            if ($null -ne $ConfigurationSchemaBytes) {
                if ((Get-CgSha256Hex -Bytes $ConfigurationSchemaBytes) -cne $bindingSha) { & $add 'configuration-schema-digest-mismatch' '/configurationSchema/sha256' }
                $identityOk = $false
                try {
                    $schemaDocument = (ConvertFrom-CgStrictJson -Bytes $ConfigurationSchemaBytes -MaxBytes 4194304).Value
                    $kindConst = Get-CgMapValue $schemaDocument @('properties', 'kind', 'const')
                    $versionConst = Get-CgMapValue $schemaDocument @('properties', 'schema_version', 'const')
                    $identityOk = ((Get-CgMapValue $schemaDocument @('$id')) -ceq $script:CgSiteConfigSchemaUri) -and ($kindConst -ceq 'CloudGrangeSiteConfig') -and ($versionConst -is [long] -and $versionConst -eq 1)
                } catch { $identityOk = $false }
                if (-not $identityOk) { & $add 'configuration-schema-identity-mismatch' '/configurationSchema' }
            }
        }
    } catch { & $add 'bom-shape-invalid' '/configurationSchema' }

    $members = Get-CgMapValue $Bom @('members')
    if ($members -isnot [Collections.IList]) {
        & $add 'members-missing' '/members'
        return , $violations.ToArray()
    }

    # Kubernetes runtime and image inventory.
    try {
        $inventory = Get-CgMapValue $Bom @('compatibility', 'kubernetes', 'imageInventorySha256')
        if (-not (Test-CgStringMatch -Value $inventory -Pattern $script:CgSha256Pattern)) { & $add 'image-inventory-missing' '/compatibility/kubernetes/imageInventorySha256' }
        $imagesMember = @($members | Where-Object { (Get-CgMapValue $_ @('id')) -ceq 'rke2-images' })
        if ($imagesMember.Count -eq 0) {
            & $add 'image-inventory-member-missing' '/members'
        } elseif ((Test-CgStringMatch -Value $inventory -Pattern $script:CgSha256Pattern) -and (Get-CgMapValue $imagesMember[0] @('vendor', 'curatorEvidenceSha256')) -cne $inventory) {
            & $add 'image-inventory-mismatch' '/compatibility/kubernetes/imageInventorySha256'
        }
        $runtimeMember = @($members | Where-Object { (Get-CgMapValue $_ @('id')) -ceq 'rke2-runtime' })
        if ($runtimeMember.Count -eq 0) {
            & $add 'kubernetes-runtime-member-missing' '/members'
        } elseif ((Get-CgMapValue $runtimeMember[0] @('version')) -cne (Get-CgMapValue $Bom @('compatibility', 'kubernetes', 'version'))) {
            & $add 'kubernetes-version-mismatch' '/compatibility/kubernetes/version'
        }
    } catch { & $add 'bom-shape-invalid' '/compatibility/kubernetes' }

    $ids = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $digests = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $locations = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $productVersion = Get-CgMapValue $Bom @('product', 'version')
    $productTag = Get-CgMapValue $Bom @('product', 'releaseTag')
    $productRepository = Get-CgMapValue $Bom @('product', 'releaseRepository')

    for ($i = 0; $i -lt $members.Count; $i++) {
        $member = $members[$i]
        $p = '/members/' + $i
        if ($member -isnot [Collections.IDictionary]) { & $add 'bom-shape-invalid' $p; continue }
        try {
            $id = Get-CgMapValue $member @('id')
            $kind = Get-CgMapValue $member @('kind')
            $phase = Get-CgMapValue $member @('phase')
            $sha = Get-CgMapValue $member @('sha256')
            $name = Get-CgMapValue $member @('name')
            $memberVersion = Get-CgMapValue $member @('version')
            if ($id -is [string]) { if ($ids.ContainsKey($id)) { & $add 'duplicate-member-id' ($p + '/id') } else { $ids[$id] = $member } }
            if ($sha -is [string] -and -not $digests.Add($sha)) { & $add 'duplicate-artifact-digest' ($p + '/sha256') }

            $knownKind = $kind -is [string] -and $script:CgKindRetrieval.ContainsKey($kind) -and ($script:CgKindRetrieval.Keys -ccontains $kind)
            if (-not $knownKind) { & $add 'kind-unknown' ($p + '/kind') }
            $retrieval = Get-CgMapValue $member @('retrieval')
            $type = Get-CgMapValue $retrieval @('type')
            if ($knownKind -and -not ($script:CgKindRetrieval[$kind] -ccontains $type)) { & $add 'retrieval-type-not-allowed-for-kind' ($p + '/retrieval/type') }

            $isVendorKind = $kind -is [string] -and $kind.StartsWith('vendor-', [StringComparison]::Ordinal)
            $hasVendor = $member.Contains('vendor')
            if ($isVendorKind -and -not $hasVendor) { & $add 'vendor-block-required' ($p + '/vendor') }
            if ($knownKind -and -not $isVendorKind -and $hasVendor) { & $add 'vendor-block-forbidden' ($p + '/vendor') }
            if ($script:CgSbomKinds -ccontains $kind -and -not (Test-CgStringMatch -Value (Get-CgMapValue $member @('evidence', 'sbomSha256')) -Pattern $script:CgSha256Pattern)) {
                & $add 'sbom-required' ($p + '/evidence/sbomSha256')
            }

            $os = Get-CgMapValue $member @('os')
            $architecture = Get-CgMapValue $member @('architecture')
            $kindOk = $true
            if (@('oci-image', 'vendor-oci-image') -ccontains $kind) { $kindOk = ($os -ceq 'linux' -and $architecture -ceq 'amd64') }
            elseif (@('helm-chart', 'vendor-helm-chart') -ccontains $kind) { $kindOk = ($os -ceq 'any' -and $architecture -ceq 'any') }
            elseif ($kind -ceq 'agent-package') { $kindOk = ($os -ceq 'windows' -and $architecture -ceq 'amd64' -and $phase -ceq 'handoff') }
            elseif ($kind -ceq 'verifier') { $kindOk = ($phase -ceq 'preflight') }
            if (-not $kindOk) { & $add 'kind-constraint-violated' $p }

            switch -CaseSensitive ($type) {
                'oci' {
                    $reference = Get-CgOciReferenceParts (Get-CgMapValue $retrieval @('reference'))
                    if ($null -eq $reference) {
                        & $add 'oci-reference-not-digest-pinned' ($p + '/retrieval/reference')
                    } else {
                        if ($reference.Digest -cne $sha) { & $add 'oci-reference-digest-mismatch' ($p + '/retrieval/reference') }
                        if ($reference.Repository -cne $name) { & $add 'oci-name-reference-mismatch' ($p + '/name') }
                        if (-not $locations.Add('oci:' + $reference.Repository + '@' + $reference.Digest)) { & $add 'duplicate-retrieval-location' ($p + '/retrieval/reference') }
                        if ($kind -ceq 'vendor-oci-image' -and -not $reference.Repository.StartsWith('ghcr.io/cloudgrange/vendor/', [StringComparison]::Ordinal)) {
                            & $add 'vendor-image-outside-mirror-namespace' ($p + '/retrieval/reference')
                        }
                        if ($kind -ceq 'oci-image' -and (-not $reference.Repository.StartsWith('ghcr.io/cloudgrange/', [StringComparison]::Ordinal) -or $reference.Repository.StartsWith('ghcr.io/cloudgrange/vendor/', [StringComparison]::Ordinal))) {
                            & $add 'first-party-image-outside-namespace' ($p + '/retrieval/reference')
                        }
                    }
                    if ($retrieval.Contains('mirrorOf')) {
                        $mirror = Get-CgOciReferenceParts (Get-CgMapValue $retrieval @('mirrorOf'))
                        if ($null -eq $mirror) { & $add 'oci-reference-not-digest-pinned' ($p + '/retrieval/mirrorOf') }
                        elseif ($mirror.Digest -cne $sha) { & $add 'mirror-digest-mismatch' ($p + '/retrieval/mirrorOf') }
                    } elseif ($kind -ceq 'vendor-oci-image') {
                        & $add 'vendor-image-not-mirrored' ($p + '/retrieval/mirrorOf')
                    }
                }
                'https' {
                    $uri = Get-CgMapValue $retrieval @('uri')
                    $status = Test-CgHttpsLocator $uri
                    if ($status -cne 'ok') { & $add $status ($p + '/retrieval/uri') }
                    elseif (-not $locations.Add('https:' + $uri)) { & $add 'duplicate-retrieval-location' ($p + '/retrieval/uri') }
                }
                'github-release-asset' {
                    $tag = Get-CgMapValue $retrieval @('tag')
                    $repository = Get-CgMapValue $retrieval @('repository')
                    if (-not (Test-CgStringMatch -Value $tag -Pattern $script:CgReleaseTagPattern)) { & $add 'release-asset-tag-invalid' ($p + '/retrieval/tag') }
                    elseif ($tag -cne $productTag -or $repository -cne $productRepository) { & $add 'release-asset-foreign-release' ($p + '/retrieval') }
                    if (-not $locations.Add('asset:' + $repository + '/' + $tag + '/' + (Get-CgMapValue $retrieval @('assetName')))) { & $add 'duplicate-retrieval-location' ($p + '/retrieval/assetName') }
                }
                'bundled' {
                    $bundlePath = Get-CgMapValue $retrieval @('path')
                    if (-not $locations.Add('bundled:' + $bundlePath)) { & $add 'duplicate-retrieval-location' ($p + '/retrieval/path') }
                    if (@('helm-chart', 'vendor-helm-chart') -ccontains $kind -and $bundlePath -cne ('charts/' + $name + '-' + $memberVersion + '.tgz')) {
                        & $add 'chart-bundle-path-mismatch' ($p + '/retrieval/path')
                    }
                }
            }
            if ($kind -ceq 'helm-chart' -and $productVersion -is [string] -and $memberVersion -cne $productVersion) { & $add 'chart-version-not-product-version' ($p + '/version') }

            if ($hasVendor) {
                $upstream = Get-CgMapValue $member @('vendor', 'upstreamSource')
                if ($upstream -is [string] -and $upstream.StartsWith('https://', [StringComparison]::Ordinal)) {
                    $status = Test-CgHttpsLocator $upstream
                    if ($status -ceq 'floating-locator') { & $add 'floating-locator' ($p + '/vendor/upstreamSource') }
                    elseif ($status -cne 'ok') { & $add 'upstream-source-invalid' ($p + '/vendor/upstreamSource') }
                } elseif ($null -eq (Get-CgOciReferenceParts $upstream)) {
                    & $add 'upstream-source-invalid' ($p + '/vendor/upstreamSource')
                }
            }
        } catch {
            & $add 'bom-shape-invalid' $p
        }
    }

    # Dependency graph: resolvable, no self edges, no later-phase edges, acyclic.
    for ($i = 0; $i -lt $members.Count; $i++) {
        $member = $members[$i]
        if ($member -isnot [Collections.IDictionary]) { continue }
        $dependsOn = Get-CgMapValue $member @('dependsOn')
        if ($dependsOn -isnot [Collections.IList]) { continue }
        foreach ($dependency in $dependsOn) {
            $path = '/members/' + $i + '/dependsOn'
            if ($dependency -isnot [string] -or -not $ids.ContainsKey($dependency)) { & $add 'dangling-depends-on' $path; continue }
            if ($dependency -ceq (Get-CgMapValue $member @('id'))) { & $add 'self-dependency' $path; continue }
            $fromPhase = [Array]::IndexOf($script:CgBomPhaseOrder, [string](Get-CgMapValue $member @('phase')))
            $toPhase = [Array]::IndexOf($script:CgBomPhaseOrder, [string](Get-CgMapValue $ids[$dependency] @('phase')))
            if ($fromPhase -ge 0 -and $toPhase -gt $fromPhase) { & $add 'depends-on-later-phase' $path }
        }
    }
    $visit = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $cycle = $false
    foreach ($start in @($ids.Keys)) {
        if ($cycle -or $visit.ContainsKey($start)) { continue }
        # Iterative depth-first search with an explicit stack of (id, next-edge-index).
        $stack = [Collections.Generic.Stack[object]]::new()
        $stack.Push([pscustomobject]@{ Id = $start; Index = 0 })
        $visit[$start] = 'active'
        while ($stack.Count -gt 0 -and -not $cycle) {
            $frame = $stack.Peek()
            # Assign before enumerating: Get-CgMapValue returns the list wrapped, so piping it directly
            # would hand Where-Object the whole list as a single object and hide every edge.
            $declared = Get-CgMapValue $ids[$frame.Id] @('dependsOn')
            $edges = @(foreach ($edge in @($declared)) { if ($edge -is [string] -and $ids.ContainsKey($edge)) { $edge } })
            if ($frame.Index -ge $edges.Count) {
                $visit[$frame.Id] = 'done'
                $null = $stack.Pop()
                continue
            }
            $next = $edges[$frame.Index]
            $frame.Index++
            if ($visit.ContainsKey($next)) {
                if ($visit[$next] -ceq 'active') { $cycle = $true }
                continue
            }
            $visit[$next] = 'active'
            $stack.Push([pscustomobject]@{ Id = $next; Index = 0 })
        }
    }
    if ($cycle) { & $add 'dependency-cycle' '/members' }
    return , $violations.ToArray()
}

function Test-CgReleaseBom {
    <#
    .SYNOPSIS
        Validates cg-release-bom-v1 bytes. Returns passed, schemaAccepted, sha256, errors[] {code, path} and codes[].
    .PARAMETER ConfigurationSchemaPath
        Optional site-config schema file; when given its bytes must hash to configurationSchema.sha256
        and declare the cg-site-config-v1 identity.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Bytes')][AllowEmptyCollection()][byte[]]$Bytes,
        [string]$ConfigurationSchemaPath,
        [string]$SchemaPath
    )
    $errors = [Collections.Generic.List[object]]::new()
    $finish = {
        param($SchemaAccepted, $Sha)
        [pscustomobject]@{
            passed = ($errors.Count -eq 0); schemaAccepted = $SchemaAccepted; sha256 = $Sha
            errors = @($errors.ToArray()); codes = @($errors | ForEach-Object code | Select-Object -Unique)
        }
    }
    if ($PSCmdlet.ParameterSetName -ceq 'Path') {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $errors.Add([pscustomobject]@{ code = 'bom-unreadable'; path = '' })
            return (& $finish $false $null)
        }
        $Bytes = [IO.File]::ReadAllBytes($Path)
    }
    $sha = Get-CgSha256Hex -Bytes $Bytes
    try {
        $parsed = ConvertFrom-CgStrictJson -Bytes $Bytes -MaxBytes 1048576
    } catch {
        $reason = Get-CgErrorReason $_
        $code = switch ($reason) { 'json-duplicate-key' { 'json-duplicate-key' } 'document-too-large' { 'bom-too-large' } default { 'invalid-json' } }
        $errors.Add([pscustomobject]@{ code = $code; path = '' })
        return (& $finish $false $sha)
    }
    if ($parsed.Value -isnot [Collections.IDictionary]) {
        $errors.Add([pscustomobject]@{ code = 'bom-shape-invalid'; path = '' })
        return (& $finish $false $sha)
    }
    if (-not $SchemaPath) { $SchemaPath = Get-CgSchemaPath -FileName 'release-bom.schema.json' }
    $schemaAccepted = Test-CgJsonSchema -Json $parsed.Text -SchemaPath $SchemaPath
    if (-not $schemaAccepted) { $errors.Add([pscustomobject]@{ code = 'schema-violation'; path = '' }) }
    $configurationBytes = $null
    if ($ConfigurationSchemaPath) {
        if (Test-Path -LiteralPath $ConfigurationSchemaPath -PathType Leaf) { $configurationBytes = [IO.File]::ReadAllBytes($ConfigurationSchemaPath) }
        else { $errors.Add([pscustomobject]@{ code = 'configuration-schema-unreadable'; path = '/configurationSchema' }) }
    }
    foreach ($violation in (Get-CgReleaseBomViolation -Bom $parsed.Value -ConfigurationSchemaBytes $configurationBytes)) { $errors.Add($violation) }
    return (& $finish $schemaAccepted $sha)
}
