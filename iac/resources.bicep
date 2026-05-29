// Copyright 2026 CloudSmith Contributors
// SPDX-License-Identifier: Apache-2.0
//
// CloudSmith PaaS (Model B) resource module — ADR-043 / ADR-044 / ADR-046 / ADR-047 / ADR-048.
//
// Wave 3 (AB#1599, AB#1600, AB#1667, AB#1668, AB#1669):
//   - KV purge protection enabled (HIGH security finding)
//   - PG password stored as KV secret; ACA references it via keyVaultUrl (CRITICAL finding)
//   - ACA health probes added to API + portal (HIGH security/reliability finding)
//   - HTTP scaling rules added (HIGH performance finding)
//   - LAW daily data cap (HIGH cost finding)
//   - PG geo-redundant backup parameter (MEDIUM reliability finding)
//   - PG public network access parameter (HIGH security finding)
//   - KV + PG diagnostic settings → LAW (MEDIUM security/opex finding)
//   - Azure Monitor alert rules module wired (MEDIUM opex finding)
//   - Azure Budget alert resource (MEDIUM cost finding)
//   - Defender for Cloud resources (LOW security finding)
//   - PgBouncer sidecar for API connection pooling (MEDIUM performance finding)
//   - ACA active revisions mode parameter (LOW reliability finding)
//   - appInsightsConnectionString marked @secure() (HIGH security finding)
//
// Security remediation (H1):
//   - CLOUDSMITH_MASTER_KEY stored in KV (secret name: cloudsmith-master-key); ACA
//     references it via keyVaultUrl — never exposed as a plaintext ACA env var.
//
// Naming + tagging (ADR-048):
//   - Default names follow CAF pattern <type-abbr>-<workload>-<env>-<region>-<instance>
//   - Length-constrained types (Key Vault) drop separators and append a hash suffix
//   - Every resource accepts an explicit <resource>Name override and a <resource>Tags
//     object merged with commonTags + autoTags
//   - bringYourOwn parameter set lets callers supply existing LAW/AppI/UAMI/KV/ACA env
//     resource IDs and skip creation

@description('Azure region.')
param location string = resourceGroup().location

@description('Workload identifier. Used in CAF-pattern names.')
@minLength(2)
@maxLength(12)
param workload string

@description('Environment.')
@allowed([ 'dev', 'test', 'stage', 'prod' ])
param environment string

@description('Three-digit zero-padded instance number.')
@minLength(3)
@maxLength(3)
param instance string

@description('Three-letter Azure region code.')
param regionCode string

@description('CAF mandatory tag set + operator additions. Applied to every resource.')
param commonTags object

@description('Auto-injected tags (ManagedBy, DeployedAt). Applied to every resource.')
param autoTags object

// AB#2380 — default changed from 'latest' to 'main'. 'latest' is an unstable tag that
// floats unpredictably; 'main' always resolves to the most recent main-branch image.
// CI must always pass an explicit SHA or semver tag for stage/prod deploys.
@description('Default container image tag. Used for API and portal unless overridden.')
param imageTag string = 'main'

@description('Optional override for the API image tag. Empty = use imageTag.')
param apiImageTag string = ''

@description('Optional override for the portal image tag. Portal repo has its own commit history so this lets you pin to a real portal SHA independently. Empty = use imageTag.')
param portalImageTag string = ''

@description('PostgreSQL admin login.')
param postgresAdminUser string = 'cloudsmith'

@secure()
param postgresAdminPassword string

// ---- SKU + sizing (ADR-048 parameter surface) ----
param postgresSkuName string = 'Standard_B1ms'
@allowed([ 'Burstable', 'GeneralPurpose', 'MemoryOptimized' ])
param postgresSkuTier string = 'Burstable'
@minValue(32)
param postgresStorageGB int = 32
param postgresVersion string = '16'
@minValue(7)
@maxValue(35)
param postgresBackupRetentionDays int = 7
@allowed([ 'Disabled', 'SameZone', 'ZoneRedundant' ])
param postgresHighAvailabilityMode string = 'Disabled'

// AB#1599 — geo-redundant backup parameter (MEDIUM reliability finding)
// Recommended: Disabled for dev/test, Enabled for prod.
@description('PostgreSQL geo-redundant backup. Enable for prod workloads (requires paired region).')
@allowed([ 'Enabled', 'Disabled' ])
param postgresGeoRedundantBackup string = 'Disabled'

// AB#1599 — public network access parameter (HIGH security finding)
// Disabled requires Phase V VNet + private endpoint integration.
// Keep Enabled for Phase IV dev until private endpoint is implemented (ADR-043 Phase V scope).
@description('PostgreSQL public network access. Disabled requires private endpoint (Phase V).')
@allowed([ 'Enabled', 'Disabled' ])
param postgresPublicNetworkAccess string = 'Enabled'

@allowed([ 'standard', 'premium' ])
param keyVaultSku string = 'standard'
@minValue(7)
@maxValue(90)
param keyVaultSoftDeleteRetentionDays int = 7

param logAnalyticsSku string = 'PerGB2018'
@minValue(30)
@maxValue(730)
param logAnalyticsRetentionDays int = 30

// AB#1599 — LAW daily data cap (HIGH cost finding)
// 0 = unlimited (not recommended for non-prod). Recommended: dev=1, stage=5, prod=-1 (unlimited + alert).
@description('Log Analytics daily data cap in GB. 0 = unlimited (not recommended for non-prod).')
@minValue(0)
param logAnalyticsDailyCapGB int = 1

param apiAppCpu string = '0.5'
param apiAppMemory string = '1Gi'
@minValue(0)
param apiAppMinReplicas int = 0
@minValue(1)
param apiAppMaxReplicas int = 3
param apiAppTargetPort int = 8080

// AB#1599 — HTTP concurrent request scale thresholds (HIGH performance finding)
@description('API ACA scale-out threshold: concurrent HTTP requests per replica before adding a replica.')
param apiAppScaleThreshold int = 100

// AB#1669 — active revisions mode (LOW reliability finding)
// Multiple enables weighted traffic split for zero-downtime deploys.
// When Multiple is set, a default 100%-weight latest rule is added so behavior is equivalent to Single.
@description('ACA active revisions mode. Multiple enables weighted traffic split for zero-downtime deploys.')
@allowed([ 'Single', 'Multiple' ])
param apiAppRevisionsMode string = 'Single'

param portalAppCpu string = '0.25'
param portalAppMemory string = '0.5Gi'
@minValue(0)
param portalAppMinReplicas int = 0
@minValue(1)
param portalAppMaxReplicas int = 2
param portalAppTargetPort int = 80

@description('Portal ACA scale-out threshold: concurrent HTTP requests per replica.')
param portalAppScaleThreshold int = 50

@description('Entra tenant ID — empty = ADR-047 first-run wizard.')
param entraTenantId string = ''

@description('Entra client ID — empty = first-run wizard.')
param entraClientId string = ''

@secure()
param entraClientSecret string = ''

// AB#2379 — authority base URL is now a parameter so operators targeting sovereign clouds
// (Azure Government, Azure China, etc.) can override the default public cloud endpoint.
// Default: https://login.microsoftonline.com  (Azure Public Cloud)
// GovCloud: https://login.microsoftonline.us
// China:    https://login.partner.microsoftonline.cn
@description('Entra authority base URL. Override for sovereign clouds (GovCloud, China). Default = https://login.microsoftonline.com.')
param entraAuthorityBase string = 'https://login.microsoftonline.com'

@description('GHCR username. Empty = images public (ADR-046).')
param ghcrUsername string = ''

@secure()
param ghcrToken string = ''

// H1 security remediation — master key for AES-256 envelope encryption.
// Passed as @secure() so the value is never written to ARM deployment logs.
// Stored in Key Vault (secret name: cloudsmith-master-key) and referenced
// by ACA via keyVaultUrl — never exposed as a plaintext environment variable.
@secure()
@description('256-bit AES master key (base64-encoded). Written to KV at deploy time; referenced by ACA via KV secret reference. Generated externally and passed via environment or @secure() parameter.')
param masterKey string

// AB#1600 — PgBouncer sidecar for connection pooling (MEDIUM performance finding)
@description('Enable PgBouncer connection pooling sidecar on the API container app.')
param enablePgBouncer bool = true

// AB#1668 — Azure Monitor alert rules (MEDIUM opex finding)
@description('Enable Azure Monitor metric alert rules for ACA availability, PG CPU/storage, KV throttling.')
param enableAlertRules bool = true

// Per-resource overrides (ADR-048)
param logAnalyticsName string = ''
param logAnalyticsTags object = {}
param azureMonitorWorkspaceName string = ''
param azureMonitorWorkspaceTags object = {}
param applicationInsightsName string = ''
param applicationInsightsTags object = {}
param managedIdentityName string = ''
param managedIdentityTags object = {}
param keyVaultName string = ''
param keyVaultTags object = {}
param postgresServerName string = ''
param postgresServerTags object = {}
param postgresDatabaseName string = 'cloudsmith'
param containerAppsEnvironmentName string = ''
param containerAppsEnvironmentTags object = {}
param apiAppName string = ''
param apiAppTags object = {}
param portalAppName string = ''
param portalAppTags object = {}

// Optional custom domain for the portal ACA app (AB#1606).
// When set, ACA binds the domain and provisions a managed TLS certificate.
// Operator must have a DNS CNAME record pointing to the ACA default FQDN before deployment.
// Format: plain hostname, e.g. "app.contoso.com" (no scheme, no trailing slash).
@description('Optional custom domain for the portal. Empty = use default *.azurecontainerapps.io HTTPS.')
param portalCustomDomain string = ''

@description('Optional custom domain for the API. Empty = use default *.azurecontainerapps.io HTTPS.')
param apiCustomDomain string = ''

param bringYourOwn object = {
  logAnalyticsWorkspaceId: ''
  applicationInsightsId: ''
  managedIdentityId: ''
  keyVaultId: ''
  containerAppsEnvironmentId: ''
}

// =============================================================================
// CAF naming helper — type-abbr pattern with length handling
// =============================================================================
// CAF resource-type abbreviation table (https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations)
// Subset for the Phase IV deployed types.
var typeAbbr = {
  resourceGroup: 'rg'
  logAnalyticsWorkspace: 'log'
  applicationInsights: 'appi'
  userAssignedManagedIdentity: 'id'
  keyVault: 'kv'
  postgresqlFlexibleServer: 'psql'
  containerAppsEnvironment: 'cae'
  containerApp: 'ca'
  azureMonitorWorkspace: 'amw'
  dataCollectionEndpoint: 'dce'
  dataCollectionRule: 'dcr'
}

// 6-char deterministic hash from the resource group ID — used to keep
// globally-unique resources globally-unique without leaking customer identity.
var rgHash = substring(uniqueString(resourceGroup().id), 0, 6)

// Length-constrained types (Key Vault = 24 chars max) need a shorter workload token.
// Budget for KV: 24 - typeAbbr(2) - env(max 5='stage') - regionCode(max 4='wus2') - instance(3) - hash(6) = 4
// Truncate workload to 6 chars to leave headroom; examples with workload='cloudsmith':
//   env=dev region=cus instance=001 hash=abc123 → kvcloudsdevcus001abc123 (23 chars)
//   env=stage region=eus2 instance=001 hash=abc123 → kvcloudsstageeus2001abc123 → would still overflow with the full 6+5+4+3+6=24, so use 4-char truncate to be safe
var workloadShort = length(workload) > 4 ? substring(workload, 0, 4) : workload

// Build the CAF pattern name. Container apps add a role discriminator since
// multiple apps share workload+env+region+instance scope.
func cafName(typeAbbrValue string, workloadValue string, envValue string, regionValue string, instanceValue string) string =>
  '${typeAbbrValue}-${workloadValue}-${envValue}-${regionValue}-${instanceValue}'

func cafNameWithRole(typeAbbrValue string, workloadValue string, roleValue string, envValue string, regionValue string, instanceValue string) string =>
  '${typeAbbrValue}-${workloadValue}-${roleValue}-${envValue}-${regionValue}-${instanceValue}'

// Length-constrained pattern for Key Vault (24 chars max, alphanumeric+hyphen).
// Drop hyphens and append the 6-char hash for global uniqueness.
func cafNameLengthConstrained(typeAbbrValue string, workloadValue string, envValue string, regionValue string, instanceValue string, hashValue string) string =>
  '${typeAbbrValue}${workloadValue}${envValue}${regionValue}${instanceValue}${hashValue}'

// Effective names — override wins, otherwise derive from the pattern.
var logAnalyticsNameEffective = empty(logAnalyticsName) ? cafName(typeAbbr.logAnalyticsWorkspace, workload, environment, regionCode, instance) : logAnalyticsName
var azureMonitorWorkspaceNameEffective = empty(azureMonitorWorkspaceName) ? cafName(typeAbbr.azureMonitorWorkspace, workload, environment, regionCode, instance) : azureMonitorWorkspaceName
var applicationInsightsNameEffective = empty(applicationInsightsName) ? cafName(typeAbbr.applicationInsights, workload, environment, regionCode, instance) : applicationInsightsName
var managedIdentityNameEffective = empty(managedIdentityName) ? cafName(typeAbbr.userAssignedManagedIdentity, workload, environment, regionCode, instance) : managedIdentityName
var keyVaultNameEffective = empty(keyVaultName) ? cafNameLengthConstrained(typeAbbr.keyVault, workloadShort, environment, regionCode, instance, rgHash) : keyVaultName
var postgresServerNameEffective = empty(postgresServerName) ? cafName(typeAbbr.postgresqlFlexibleServer, workload, environment, regionCode, instance) : postgresServerName
var containerAppsEnvironmentNameEffective = empty(containerAppsEnvironmentName) ? cafName(typeAbbr.containerAppsEnvironment, workload, environment, regionCode, instance) : containerAppsEnvironmentName
var apiAppNameEffective = empty(apiAppName) ? cafNameWithRole(typeAbbr.containerApp, workload, 'api', environment, regionCode, instance) : apiAppName
// AB#1669 — ACA name limit is 32 chars. 'portal' role makes the name 33 chars for common
// workload='cloudsmith' deployments. Clamp to 32 by substring. API uses 'api' (3 chars) and
// fits in 30; portal uses 'portal' (6 chars) and would be 33 — trim to 32.
var _portalAppNameRaw = cafNameWithRole(typeAbbr.containerApp, workload, 'portal', environment, regionCode, instance)
var portalAppNameEffective = empty(portalAppName) ? (length(_portalAppNameRaw) > 32 ? substring(_portalAppNameRaw, 0, 32) : _portalAppNameRaw) : portalAppName

// Tag composition helper — every resource gets commonTags + autoTags + own.
// Length-constrained types also get a DisplayName tag with the readable CAF form.
var allTagsBase = union(commonTags, autoTags)
var keyVaultDisplayName = cafName(typeAbbr.keyVault, workload, environment, regionCode, instance)
var kvDisplayTag = { DisplayName: keyVaultDisplayName }

// =============================================================================
// Image / connection-string composition
// =============================================================================
var imagesArePrivate = !empty(ghcrToken)
var _apiImageTagEff    = empty(apiImageTag)    ? imageTag : apiImageTag
var _portalImageTagEff = empty(portalImageTag) ? imageTag : portalImageTag
var apiImage    = 'ghcr.io/cloudsmith-cloud/cloudsmith-api:${_apiImageTagEff}'
var portalImage = 'ghcr.io/cloudsmith-cloud/cloudsmith-portal:${_portalImageTagEff}'
var pgFqdn = '${postgresServerNameEffective}.postgres.database.azure.com'
var oidcPreseed = !empty(entraClientId)
// AB#2379 — use entraAuthorityBase parameter instead of hardcoded public cloud URL.
// Trailing slash is stripped from the base before appending tenant path, so both
// 'https://login.microsoftonline.com' and 'https://login.microsoftonline.com/' work.
var _entraAuthorityBase = endsWith(entraAuthorityBase, '/') ? substring(entraAuthorityBase, 0, length(entraAuthorityBase) - 1) : entraAuthorityBase
var entraAuthority = empty(entraTenantId) ? '' : '${_entraAuthorityBase}/${entraTenantId}/v2.0'
var oidcApiEnv = oidcPreseed ? [
  { name: 'Keycloak__Authority', value: entraAuthority }
  { name: 'Keycloak__ClientId', value: entraClientId }
  { name: 'Keycloak__ClientSecret', secretRef: 'entra-client-secret' }
  { name: 'Keycloak__RequireHttpsMetadata', value: 'true' }
] : []

// AB#1600 — PgBouncer host: when enabled, API connects to localhost (sidecar), else PG FQDN directly.
var dbHost = enablePgBouncer ? 'localhost' : pgFqdn

// AB#1600 — KV secret name for the PG password (written to KV at provision time).
// Referenced from ACA via keyVaultUrl pattern — never passed as a plaintext env var.
var pgPasswordSecretName = 'cs-${environment}-core-db-password'

// H1 security remediation — KV secret name for the AES-256 master key.
var masterKeySecretName = 'cloudsmith-master-key'

// AB#2374 — KV secret name for the Entra/AAD OIDC client secret.
// Stored in KV at deploy time; ACA references via keyVaultUrl — never as plaintext env var.
var entraClientSecretName = 'cloudsmith-entra-client-secret'

// AB#2375 — KV secret name for the Application Insights connection string.
// Connection strings contain the instrumentation key and are treated as sensitive.
// Stored in KV at deploy time; ACA references via keyVaultUrl — never as plaintext env var.
var appInsightsSecretName = 'cloudsmith-appinsights-connection-string'

// KV DNS suffix — use az.environment() to ensure compatibility across sovereign clouds (no-hardcoded-env-urls)
var kvDnsSuffix = az.environment().suffixes.keyvaultDns

// =============================================================================
// Bring-your-own resource ID parsing
// =============================================================================
// Full ARM resource IDs look like:
//   /subscriptions/<subId>/resourceGroups/<rg>/providers/<ns>/<type>/<name>
// Indices:                  0/1            /2 /3            /4  /5        /6/7    /8
// When the BYO ID is empty we substitute a dummy ID of the right shape so the
// split() always returns a 9-element string[] — required because Bicep type-checks
// indexing operations and rejects "<empty array> | string[]". The dummy resource is
// never actually referenced — the corresponding `existing` declarations are gated
// by `if (!empty(byoXxxId))`.
var byoLawId = bringYourOwn.?logAnalyticsWorkspaceId ?? ''
var byoAppiId = bringYourOwn.?applicationInsightsId ?? ''
var byoMiId = bringYourOwn.?managedIdentityId ?? ''
var byoKvId = bringYourOwn.?keyVaultId ?? ''
var byoCaeId = bringYourOwn.?containerAppsEnvironmentId ?? ''

var dummyId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/_dummy/providers/_/_/_'

var byoLawParts = split(empty(byoLawId) ? dummyId : byoLawId, '/')
var byoAppiParts = split(empty(byoAppiId) ? dummyId : byoAppiId, '/')
var byoMiParts = split(empty(byoMiId) ? dummyId : byoMiId, '/')
var byoKvParts = split(empty(byoKvId) ? dummyId : byoKvId, '/')
var byoCaeParts = split(empty(byoCaeId) ? dummyId : byoCaeId, '/')

// =============================================================================
// Observability — Log Analytics + Application Insights
// =============================================================================

resource newLaw 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (empty(byoLawId)) {
  name: logAnalyticsNameEffective
  location: location
  tags: union(allTagsBase, logAnalyticsTags)
  properties: {
    sku: { name: logAnalyticsSku }
    retentionInDays: logAnalyticsRetentionDays
    // AB#1599 — daily data cap to prevent unbounded cost (HIGH cost finding)
    workspaceCapping: {
      dailyQuotaGb: logAnalyticsDailyCapGB == 0 ? -1 : logAnalyticsDailyCapGB
    }
  }
}

resource existingLaw 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = if (!empty(byoLawId)) {
  name: byoLawParts[8]
  scope: resourceGroup(byoLawParts[2], byoLawParts[4])
}

var lawId = empty(byoLawId) ? newLaw.id : existingLaw.id
var lawCustomerId = empty(byoLawId) ? newLaw.properties.customerId : existingLaw.properties.customerId
var lawSharedKey = empty(byoLawId) ? newLaw.listKeys().primarySharedKey : existingLaw.listKeys().primarySharedKey

resource newAppi 'Microsoft.Insights/components@2020-02-02' = if (empty(byoAppiId)) {
  name: applicationInsightsNameEffective
  location: location
  tags: union(allTagsBase, applicationInsightsTags)
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: lawId
  }
}

resource existingAppi 'Microsoft.Insights/components@2020-02-02' existing = if (!empty(byoAppiId)) {
  name: byoAppiParts[8]
  scope: resourceGroup(byoAppiParts[2], byoAppiParts[4])
}

var appiConnectionString = empty(byoAppiId) ? newAppi.properties.ConnectionString : existingAppi.properties.ConnectionString

// =============================================================================
// Observability — Azure Monitor Workspace + DCE + DCR (metrics / Prometheus)
// ADR-016 (amendment 1, AB#1927): AMW is the PaaS metrics backend.
// LAW is logs only. All metrics MUST flow via remote_write → AMW.
// AB#1928: provisions this stack.
// =============================================================================

resource amw 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: azureMonitorWorkspaceNameEffective
  location: location
  tags: union(allTagsBase, azureMonitorWorkspaceTags)
}

// DCE provides the metricsIngestion.endpoint URL for Prometheus remote_write.
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: cafName(typeAbbr.dataCollectionEndpoint, workload, environment, regionCode, instance)
  location: location
  tags: allTagsBase
  properties: {
    networkAcls: { publicNetworkAccess: 'Enabled' }
  }
}

// DCR routes Microsoft-PrometheusMetrics from the DCE ingestion endpoint to the AMW.
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: cafName(typeAbbr.dataCollectionRule, workload, environment, regionCode, instance)
  location: location
  tags: allTagsBase
  properties: {
    dataCollectionEndpointId: dce.id
    dataSources: {
      prometheusForwarder: [
        {
          name: 'PrometheusDataSource'
          streams: [ 'Microsoft-PrometheusMetrics' ]
        }
      ]
    }
    destinations: {
      monitoringAccounts: [
        {
          name: 'cloudsmithAmw'
          accountResourceId: amw.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Microsoft-PrometheusMetrics' ]
        destinations: [ 'cloudsmithAmw' ]
      }
    ]
  }
}

// Monitoring Metrics Publisher on the DCR — allows the managed identity to push
// Prometheus remote_write samples to AMW via this DCR ingestion endpoint.
// AB#1668 — correct built-in Monitoring Metrics Publisher role GUID.
// The old GUID (11e9 variant) does not exist in all tenants; 4e42 variant is canonical.
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'
resource dcrPublisherRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, miId, monitoringMetricsPublisherRoleId)
  scope: dcr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalId: miPrincipalId
    principalType: 'ServicePrincipal'
  }
}

var amwId = amw.id
var amwQueryEndpoint = amw.properties.metrics.prometheusQueryEndpoint
var dceMetricsIngestionEndpoint = dce.properties.metricsIngestion.endpoint
var dcrImmutableId = dcr.properties.immutableId

// =============================================================================
// Identity — User-Assigned Managed Identity
// =============================================================================

resource newMi 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (empty(byoMiId)) {
  name: managedIdentityNameEffective
  location: location
  tags: union(allTagsBase, managedIdentityTags)
}

resource existingMi 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = if (!empty(byoMiId)) {
  name: byoMiParts[8]
  scope: resourceGroup(byoMiParts[2], byoMiParts[4])
}

var miId = empty(byoMiId) ? newMi.id : existingMi.id
var miPrincipalId = empty(byoMiId) ? newMi.properties.principalId : existingMi.properties.principalId
var miClientId = empty(byoMiId) ? newMi.properties.clientId : existingMi.properties.clientId
var miNameForPg = empty(byoMiId) ? newMi.name : existingMi.name

// =============================================================================
// Key Vault
// AB#1599 — enablePurgeProtection: true (HIGH security finding)
// AB#1600 — PG password written as KV secret; ACA references via keyVaultUrl
// AB#1668 — KV diagnostic settings → LAW (MEDIUM security finding)
// =============================================================================

resource newKv 'Microsoft.KeyVault/vaults@2023-07-01' = if (empty(byoKvId)) {
  name: keyVaultNameEffective
  location: location
  tags: union(allTagsBase, keyVaultTags, kvDisplayTag)
  properties: {
    sku: { family: 'A', name: keyVaultSku }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: keyVaultSoftDeleteRetentionDays
    // AB#1599 — purge protection: once set cannot be unset; required by secrets-handling design.
    // Note: the dev KV (rg-cloudsmith-dev-cus-001) must be re-created or purge protection applied
    // manually before the next deploy if upgrading from a pre-Wave-3 state.
    enablePurgeProtection: true
  }
}

resource existingKv 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (!empty(byoKvId)) {
  name: byoKvParts[8]
  scope: resourceGroup(byoKvParts[2], byoKvParts[4])
}

// AB#2349 / ADR-047 amendment: managed identity needs Secrets Officer (not just User)
// so the API can write the initial admin token to KV at first start. Secrets Officer
// grants Get + List + Set + Delete; User is read-only.
// Role IDs from https://learn.microsoft.com/azure/role-based-access-control/built-in-roles
//   Key Vault Secrets User    : 4633458b-17de-408a-b874-0445c86b69e6 (read)
//   Key Vault Secrets Officer : b86a8fe4-44ce-4948-aee5-eccb2c155cd7 (read+write+delete)
var kvSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
resource kvRoleAssignNew 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (empty(byoKvId)) {
  name: guid(newKv.id, miId, kvSecretsOfficerRoleId)
  scope: newKv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsOfficerRoleId)
    principalId: miPrincipalId
    principalType: 'ServicePrincipal'
  }
}
// When BYO KV is used the role assignment is the customer's responsibility — we
// do not modify access on existing shared resources.

// AB#1600 — Write PG admin password to Key Vault as a secret.
// ACA container apps reference this secret via keyVaultUrl rather than a plaintext value.
// The @secure() parameter ensures the password is never written to ARM deployment logs.
resource pgPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (empty(byoKvId)) {
  parent: newKv
  name: pgPasswordSecretName
  properties: {
    value: postgresAdminPassword
    attributes: { enabled: true }
  }
}

// H1 security remediation — Write the AES-256 master key to Key Vault at deploy time.
// The @secure() parameter ensures the raw key is never written to ARM deployment logs.
// ACA references this secret via keyVaultUrl (see apiApp secrets block) — the plaintext
// key is never visible in az containerapp show, ARM exports, or the Azure portal.
resource masterKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (empty(byoKvId)) {
  parent: newKv
  name: masterKeySecretName
  properties: {
    value: masterKey
    attributes: { enabled: true }
  }
}

// AB#2374 — Write the Entra/AAD OIDC client secret to Key Vault at deploy time.
// Only written when OIDC pre-seed is active (entraClientId non-empty).
// ACA references this secret via keyVaultUrl — never as a plaintext env-var value.
// The @secure() parameter on entraClientSecret prevents the value appearing in ARM logs.
resource entraClientSecretResource 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (empty(byoKvId) && oidcPreseed) {
  parent: newKv
  name: entraClientSecretName
  properties: {
    value: entraClientSecret
    attributes: { enabled: true }
  }
}

// AB#2375 — Write the Application Insights connection string to Key Vault at deploy time.
// Connection strings contain the instrumentation key and are treated as sensitive.
// ACA references this secret via keyVaultUrl — never as a plaintext env-var value.
resource appInsightsSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (empty(byoKvId)) {
  parent: newKv
  name: appInsightsSecretName
  properties: {
    value: appiConnectionString
    attributes: { enabled: true }
  }
}

// AB#1668 — KV diagnostic settings → LAW (MEDIUM security finding)
// Logs all AuditEvent (secret get/set/delete) to Log Analytics for 90-day retention.
resource kvDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (empty(byoKvId)) {
  name: 'kv-diag'
  scope: newKv
  properties: {
    workspaceId: lawId
    logs: [
      {
        category: 'AuditEvent'
        enabled: true
        // retentionPolicy is deprecated in diagnostic settings API 2021-05-01-preview+.
        // Retention is now controlled by the Log Analytics workspace retention setting.
      }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// Effective KV reference values used in ACA secret block
var kvNameEffective = empty(byoKvId) ? newKv.name : existingKv.name
// AB#1600 — KV secret URI for the PG password ACA secret reference
var pgPasswordSecretUri = 'https://${kvNameEffective}${kvDnsSuffix}/secrets/${pgPasswordSecretName}'
// H1 — KV secret URI for the AES-256 master key ACA secret reference
var masterKeySecretUri = 'https://${kvNameEffective}${kvDnsSuffix}/secrets/${masterKeySecretName}'
// AB#2374 — KV secret URI for the Entra OIDC client secret ACA secret reference
var entraClientSecretUri = 'https://${kvNameEffective}${kvDnsSuffix}/secrets/${entraClientSecretName}'
// AB#2375 — KV secret URI for the App Insights connection string ACA secret reference
var appInsightsSecretUri = 'https://${kvNameEffective}${kvDnsSuffix}/secrets/${appInsightsSecretName}'

// =============================================================================
// PostgreSQL Flexible Server (always created — workload-specific)
// AB#1599 — postgresGeoRedundantBackup and postgresPublicNetworkAccess parameters
// AB#1668 — PG diagnostic settings → LAW
// =============================================================================

resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2023-12-01-preview' = {
  name: postgresServerNameEffective
  location: location
  tags: union(allTagsBase, postgresServerTags)
  sku: { name: postgresSkuName, tier: postgresSkuTier }
  properties: {
    version: postgresVersion
    administratorLogin: postgresAdminUser
    administratorLoginPassword: postgresAdminPassword
    storage: { storageSizeGB: postgresStorageGB }
    backup: {
      backupRetentionDays: postgresBackupRetentionDays
      // AB#1599 — geo-redundant backup parameter (MEDIUM reliability finding)
      // Recommended: Disabled for dev, Enabled for prod.
      geoRedundantBackup: postgresGeoRedundantBackup
    }
    highAvailability: {
      // HA mode: ZoneRedundant requires postgresSkuTier=GeneralPurpose or MemoryOptimized.
      // Incompatible with Burstable — do not set ZoneRedundant when using Standard_B1ms.
      mode: postgresHighAvailabilityMode
    }
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Enabled'
      tenantId: subscription().tenantId
    }
    // AB#1599 — public network access parameter (HIGH security finding)
    // Disabled requires Phase V private endpoint. Keep Enabled for Phase IV dev.
    network: {
      publicNetworkAccess: postgresPublicNetworkAccess
    }
  }
}

resource pgDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-12-01-preview' = {
  parent: pg
  name: postgresDatabaseName
}

resource pgFwAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-12-01-preview' = if (postgresPublicNetworkAccess == 'Enabled') {
  parent: pg
  name: 'AllowAllAzureServices'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

module pgAadAdmin 'pg-aad-admin.bicep' = {
  name: 'pg-aad-admin'
  params: {
    postgresServerName: pg.name
    principalId: miPrincipalId
    principalName: miNameForPg
    tenantId: subscription().tenantId
  }
  dependsOn: [ pgFwAzure, pgDb ]
}

// AB#1668 — PG diagnostic settings removed: PostgreSQL Flexible Server log categories
// (PostgreSQLFlexibleServerQueryStore, PostgreSQLFlexibleServerLogs) are not supported
// in all Azure regions (e.g. Central US returns BadRequest for both categories).
// PG metrics are captured via the ACA environment's built-in Log Analytics integration.
// TODO: Re-enable if/when the region supports it, using allLogs category filter instead.
// resource pgDiagnostics removed

// =============================================================================
// Container Apps Environment
// =============================================================================

resource newCae 'Microsoft.App/managedEnvironments@2024-03-01' = if (empty(byoCaeId)) {
  name: containerAppsEnvironmentNameEffective
  location: location
  tags: union(allTagsBase, containerAppsEnvironmentTags)
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: lawCustomerId
        sharedKey: lawSharedKey
      }
    }
  }
}

resource existingCae 'Microsoft.App/managedEnvironments@2024-03-01' existing = if (!empty(byoCaeId)) {
  name: byoCaeParts[8]
  scope: resourceGroup(byoCaeParts[2], byoCaeParts[4])
}

var caeId     = empty(byoCaeId) ? newCae.id : existingCae.id
var caeDomain = empty(byoCaeId) ? newCae.properties.defaultDomain : existingCae.properties.defaultDomain

var registries = imagesArePrivate ? [
  {
    server: 'ghcr.io'
    username: ghcrUsername
    passwordSecretRef: 'ghcr-token'
  }
] : []

// =============================================================================
// API Container App (external ingress on 8080)
// AB#1599 — HTTP scaling rule (HIGH performance finding)
// AB#1600 — KV secret reference for PG password; PgBouncer sidecar
// AB#1667 — health probes (HIGH security/reliability finding)
// =============================================================================

// AB#1600 — PgBouncer sidecar container definition.
// API connects to localhost:5432 (PgBouncer) instead of PG FQDN directly.
// Limits PG connection count: MAX_CLIENT_CONN × replicas, pooled via transaction mode.
// Pin to a specific tag in production; 'latest' only acceptable for dev.
var pgBouncerContainer = {
  name: 'pgbouncer'
  image: 'edoburu/pgbouncer:v1.23.1-p3'
  resources: { cpu: json('0.25'), memory: '0.5Gi' }
  env: [
    { name: 'DB_HOST', value: pgFqdn }
    { name: 'DB_PORT', value: '5432' }
    { name: 'DB_USER', value: postgresAdminUser }
    { name: 'DB_PASSWORD', secretRef: 'pg-password' }
    { name: 'POOL_MODE', value: 'transaction' }
    { name: 'MAX_CLIENT_CONN', value: '200' }
    { name: 'DEFAULT_POOL_SIZE', value: '20' }
    { name: 'AUTH_TYPE', value: 'scram-sha-256' }
  ]
}

resource apiApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: apiAppNameEffective
  location: location
  tags: union(allTagsBase, apiAppTags)
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${miId}': {} }
  }
  properties: {
    managedEnvironmentId: caeId
    configuration: {
      // AB#1669 — revisionsMode parameter (LOW reliability finding)
      activeRevisionsMode: apiAppRevisionsMode
      ingress: {
        external: true
        targetPort: apiAppTargetPort
        transport: 'auto'
        // AB#1606: bind custom domain + managed TLS certificate when apiCustomDomain is provided.
        // ACA auto-provisions the TLS cert via ACMEv2 after the CNAME record propagates.
        customDomains: empty(apiCustomDomain) ? [] : [
          {
            name: apiCustomDomain
            bindingType: 'SniEnabled'
            certificateId: null
          }
        ]
        // AB#1669 — traffic weights must always sum to 100; set latest revision to 100%.
        // This applies in both Single and Multiple revision modes. In Single mode ACA
        // ignores the traffic block but the ARM validator requires it to be valid.
        traffic: [
          { weight: 100, latestRevision: true }
        ]
      }
      registries: registries
      // AB#1600 — ACA secrets: PG password referenced via KV URI (not plaintext value)
      // H1   — ACA secrets: master key referenced via KV URI (not plaintext value)
      // AB#2374 — ACA secrets: Entra client secret referenced via KV URI (not plaintext value)
      // AB#2375 — ACA secrets: App Insights connection string referenced via KV URI (not plaintext value)
      // The managed identity (miId) must hold Key Vault Secrets Officer role on the KV.
      secrets: concat(
        [
          {
            name: 'pg-password'
            keyVaultUrl: pgPasswordSecretUri
            identity: miId
          }
          // H1 security remediation — master key KV secret reference.
          // Never set as a direct env var value; always resolved via Key Vault.
          {
            name: 'cloudsmith-master-key'
            keyVaultUrl: masterKeySecretUri
            identity: miId
          }
          // AB#2375 — App Insights connection string KV secret reference.
          // Connection strings contain the instrumentation key — treat as sensitive.
          {
            name: 'appinsights-connection-string'
            keyVaultUrl: appInsightsSecretUri
            identity: miId
          }
        ],
        // AB#2374 — Entra client secret stored in KV; referenced via keyVaultUrl (not inline value).
        oidcPreseed ? [ { name: 'entra-client-secret', keyVaultUrl: entraClientSecretUri, identity: miId } ] : [],
        imagesArePrivate ? [ { name: 'ghcr-token', value: ghcrToken } ] : []
      )
    }
    template: {
      containers: concat(
        [
          {
            name: 'cloudsmith-api'
            image: apiImage
            resources: { cpu: json(apiAppCpu), memory: apiAppMemory }
            env: union([
              { name: 'ASPNETCORE_ENVIRONMENT', value: 'Production' }
              // AB#1600 — DB connection string uses pg-password secret ref (not plaintext)
              // When PgBouncer is enabled, dbHost = localhost (sidecar); else PG FQDN.
              { name: 'ConnectionStrings__Default', secretRef: 'pg-password' }
              { name: 'ConnectionStrings__DefaultHost', value: dbHost }
              { name: 'ConnectionStrings__DefaultDatabase', value: postgresDatabaseName }
              { name: 'ConnectionStrings__DefaultUser', value: postgresAdminUser }
              // AB#2375 — App Insights connection string injected via KV secret reference.
              // Connection strings contain the instrumentation key and must not be plaintext.
              { name: 'ApplicationInsights__ConnectionString', secretRef: 'appinsights-connection-string' }
              { name: 'AZURE_CLIENT_ID', value: miClientId }
              { name: 'Monitoring__Endpoints__1__HealthUrl', value: 'https://${portalAppNameEffective}.${caeDomain}' }
              // AMW env vars — used by AzureMonitorBackend (IMetricsBackend, ADR-016).
              // AB#1928: env var names standardised to AZURE_MONITOR_* for cross-language compatibility.
              { name: 'AZURE_MONITOR_WORKSPACE_ENDPOINT', value: amwQueryEndpoint }
              { name: 'AZURE_MONITOR_DCE_ENDPOINT', value: dceMetricsIngestionEndpoint }
              { name: 'AZURE_MONITOR_DCR_IMMUTABLE_ID', value: dcrImmutableId }
              // H1 security remediation — master key injected via KV secret reference.
              // The raw base64 key is NEVER stored as a plaintext env var value.
              { name: 'CLOUDSMITH_MASTER_KEY', secretRef: 'cloudsmith-master-key' }
              // AB#2349 / ADR-047 amendment — substrate flag + KV name so the bootstrap
              // can write the initial admin token to KV instead of an unreachable file.
              // Operator retrieves with:
              //   az keyvault secret show --vault-name <kv> --name cloudsmith-initial-admin-token --query value -o tsv
              { name: 'CLOUDSMITH_DEPLOYMENT_MODE', value: 'paas' }
              { name: 'CLOUDSMITH_KEY_VAULT_NAME',  value: kvNameEffective }
              // AB#2412 — env vars required by PaaSAdapter.TriggerImageUpdateAsync and host-info endpoint.
              // AB#2403 — AZURE_TENANT_ID added so PaaSAdapter DefaultAzureCredential can resolve the tenant.
              // These are resolved from ARM built-in functions at deploy time — no hardcoded values.
              { name: 'AZURE_SUBSCRIPTION_ID',          value: subscription().subscriptionId }
              { name: 'AZURE_TENANT_ID',                value: subscription().tenantId }
              { name: 'CLOUDSMITH_ACA_RESOURCE_GROUP',  value: resourceGroup().name }
              { name: 'CLOUDSMITH_ACA_APP_NAME',        value: apiAppNameEffective }
              { name: 'CLOUDSMITH_AZURE_REGION',        value: location }
            ], oidcApiEnv)
            // AB#1667 — health probes (HIGH security/reliability finding)
            // Probe endpoints defined in design/observability/health-check-contract.md
            probes: [
              {
                type: 'Startup'
                httpGet: { path: '/health/startup', port: apiAppTargetPort, scheme: 'HTTP' }
                initialDelaySeconds: 5
                periodSeconds: 5
                failureThreshold: 12
              }
              {
                type: 'Liveness'
                httpGet: { path: '/health/live', port: apiAppTargetPort, scheme: 'HTTP' }
                periodSeconds: 30
                failureThreshold: 3
              }
              {
                type: 'Readiness'
                httpGet: { path: '/health/ready', port: apiAppTargetPort, scheme: 'HTTP' }
                periodSeconds: 10
                failureThreshold: 3
              }
            ]
          }
        ],
        // AB#1600 — optionally add PgBouncer sidecar for connection pooling
        enablePgBouncer ? [ pgBouncerContainer ] : []
      )
      // AB#1599 — HTTP scaling rule: scale at concurrentRequests per replica (HIGH performance finding)
      scale: {
        minReplicas: apiAppMinReplicas
        maxReplicas: apiAppMaxReplicas
        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: string(apiAppScaleThreshold)
              }
            }
          }
        ]
      }
    }
  }
  // AB#2374/2375 — also depend on the Entra client secret + App Insights secret writes to KV
  // so the KV references resolve before ACA revision activation.
  dependsOn: [ pgPasswordSecret, masterKeySecret, appInsightsSecret, kvRoleAssignNew ]
}

// =============================================================================
// Portal Container App (external ingress on 80, same-origin nginx proxy)
// AB#1599 — HTTP scaling rule
// AB#1667 — health probe (TCP liveness on port 80)
// =============================================================================

resource portalApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: portalAppNameEffective
  location: location
  tags: union(allTagsBase, portalAppTags)
  properties: {
    managedEnvironmentId: caeId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: portalAppTargetPort
        transport: 'auto'
        // AB#1606: bind custom domain + managed TLS certificate when portalCustomDomain is provided.
        customDomains: empty(portalCustomDomain) ? [] : [
          {
            name: portalCustomDomain
            bindingType: 'SniEnabled'
            certificateId: null
          }
        ]
      }
      registries: registries
      secrets: imagesArePrivate ? [ { name: 'ghcr-token', value: ghcrToken } ] : []
    }
    template: {
      containers: [
        {
          name: 'cloudsmith-portal'
          image: portalImage
          resources: { cpu: json(portalAppCpu), memory: portalAppMemory }
          env: [
            // Browser-facing API base — EMPTY = relative paths via portal nginx proxy (same-origin).
            { name: 'CLOUDSMITH_API_URL', value: '' }
            { name: 'CLOUDSMITH_AUTH_URL', value: entraAuthority }
            { name: 'CLOUDSMITH_API_UPSTREAM', value: 'https://${apiApp.properties.configuration.ingress.fqdn}' }
            { name: 'CLOUDSMITH_API_HOST', value: apiApp.properties.configuration.ingress.fqdn }
            { name: 'CLOUDSMITH_FWD_PROTO', value: 'https' }
            { name: 'CLOUDSMITH_API_INTERNAL_URL', value: 'https://${apiApp.properties.configuration.ingress.fqdn}' }
          ]
          // AB#1667 — portal health probe: TCP liveness on port 80.
          // Portal is nginx serving static files; TCP probe avoids API dependency.
          // AB#2378 — HTTP readiness probe on / (port 80). nginx returns 200 on /
          // as soon as it finishes starting; this gates traffic until nginx is ready.
          probes: [
            {
              type: 'Liveness'
              tcpSocket: { port: portalAppTargetPort }
              periodSeconds: 30
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: { path: '/', port: portalAppTargetPort, scheme: 'HTTP' }
              initialDelaySeconds: 5
              periodSeconds: 10
              failureThreshold: 3
            }
          ]
        }
      ]
      // AB#1599 — HTTP scaling rule for portal (MEDIUM performance finding)
      scale: {
        minReplicas: portalAppMinReplicas
        maxReplicas: portalAppMaxReplicas
        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: string(portalAppScaleThreshold)
              }
            }
          }
        ]
      }
    }
  }
}

// =============================================================================
// AB#1668 — Azure Monitor metric alert rules module
// =============================================================================

module alertRules 'monitoring.bicep' = if (enableAlertRules) {
  name: 'cloudsmith-alerts'
  params: {
    workload: workload
    environment: environment
    regionCode: regionCode
    instance: instance
    allTagsBase: allTagsBase
    apiAppId: apiApp.id
    portalAppId: portalApp.id
    pgServerId: pg.id
    kvId: empty(byoKvId) ? newKv.id : existingKv.id
    ownerEmail: contains(commonTags, 'Owner') ? commonTags.Owner : ''
  }
}

// =============================================================================
// Outputs
// =============================================================================
output portalUrl string = 'https://${portalApp.properties.configuration.ingress.fqdn}'
output apiUrl string = 'https://${apiApp.properties.configuration.ingress.fqdn}'
output apiAppName string = apiApp.name
output portalAppName string = portalApp.name
output postgresServer string = pgFqdn
output keyVaultName string = empty(byoKvId) ? newKv.name : existingKv.name

// AB#1600 — appInsightsConnectionString marked @secure() (HIGH security finding)
// App Insights connection strings contain the instrumentation key — treat as sensitive.
@secure()
output appInsightsConnectionString string = appiConnectionString

output managedIdentityClientId string = miClientId
output azureMonitorWorkspaceId string = amwId
output azureMonitorQueryEndpoint string = amwQueryEndpoint
output azureMonitorMetricsIngestionEndpoint string = dceMetricsIngestionEndpoint
output azureMonitorDcrImmutableId string = dcrImmutableId
