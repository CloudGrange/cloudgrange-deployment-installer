// Copyright 2026 CloudSmith Contributors
// SPDX-License-Identifier: Apache-2.0
//
// CloudSmith PaaS (Model B) entry point — subscription-scoped.
// Follows ADR-048 (Azure resource naming and tagging standard):
//   - Default names: <type-abbr>-<workload>-<env>-<region>-<instance>
//   - CAF mandatory tag set, applied via commonTags
//   - Per-resource <resource>Name and <resource>Tags overrides
//   - bringYourOwn parameter set for shared LAW/KV/UAMI/ACA env / App Insights
//
// Wave 3 additions (AB#1599, AB#1600, AB#1667, AB#1668, AB#1669):
//   - Passes new WAF-CAF security/reliability/cost parameters to resources module
//   - Defender for Cloud Standard tier (AB#1668, LOW security finding)
//   - Azure Policy assignments for governance (AB#1668)
//   - Azure Budget alert (AB#1668, MEDIUM cost finding)
//
// Deploy:
//   az deployment sub create --location centralus --template-file iac/main.bicep \
//     --parameters @iac/main.parameters.json

targetScope = 'subscription'

// =============================================================================
// Naming + tagging parameters (ADR-048)
// =============================================================================

@description('Azure region for the deployment.')
param location string = 'eastus'

@description('Workload identifier. Used in CAF-pattern names. Lowercase alphanumeric.')
@minLength(2)
@maxLength(12)
param workload string = 'cloudsmith'

@description('Environment. One of dev, test, stage, prod.')
@allowed([ 'dev', 'test', 'stage', 'prod' ])
param environment string

@description('Three-digit zero-padded instance number.')
@minLength(3)
@maxLength(3)
param instance string = '001'

@description('CAF mandatory tag set + operator additions. Merged into every resource.')
param commonTags object

@description('Override the resource group name. Empty = derive from CAF pattern.')
param resourceGroupName string = ''

@description('Additional tags merged with commonTags for the resource group only.')
param resourceGroupTags object = {}

@description('Deployment timestamp recorded in the DeployedAt tag. Defaults to UTC now.')
param deploymentTime string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

// =============================================================================
// Application parameters (Phase IV)
// =============================================================================

// AB#1669 — imageTag default changed from 'latest' to 'v1.0.0'.
// Never use 'latest' in stage or prod. CI must always pass an explicit SHA or semver tag.
// GHCR tags: v1.0.0, 1.0.0-preview1, 1.0.0-preview2, SHA digests. 'main' tag does NOT exist.
@description('Default container image tag. Used for both API and portal unless overridden.')
param imageTag string = 'v1.0.0'

@description('Optional override for the API image tag. Empty = use imageTag. Use when the API repo has shipped a fix that the portal repo has not.')
param apiImageTag string = ''

@description('Optional override for the portal image tag. Empty = use imageTag. Portal repo has its own commit history; pin independently when SHAs diverge.')
param portalImageTag string = ''

// ---- PostgreSQL Flexible Server SKU + sizing (ADR-048 parameter surface) ----
@description('PostgreSQL administrator login.')
param postgresAdminUser string = 'cloudsmith'

@secure()
param postgresAdminPassword string

@description('PostgreSQL Flexible Server SKU name.')
param postgresSkuName string = 'Standard_B1ms'

@description('PostgreSQL Flexible Server SKU tier.')
@allowed([ 'Burstable', 'GeneralPurpose', 'MemoryOptimized' ])
param postgresSkuTier string = 'Burstable'

@description('PostgreSQL storage size in GB.')
@minValue(32)
param postgresStorageGB int = 32

@description('PostgreSQL major version.')
param postgresVersion string = '16'

@description('PostgreSQL backup retention in days.')
@minValue(7)
@maxValue(35)
param postgresBackupRetentionDays int = 7

@description('PostgreSQL high availability mode. ZoneRedundant requires postgresSkuTier=GeneralPurpose or MemoryOptimized. Incompatible with Burstable.')
@allowed([ 'Disabled', 'SameZone', 'ZoneRedundant' ])
param postgresHighAvailabilityMode string = 'Disabled'

// AB#1599
@description('PostgreSQL geo-redundant backup. Enable for prod workloads. Disabled for dev to save cost.')
@allowed([ 'Enabled', 'Disabled' ])
param postgresGeoRedundantBackup string = 'Disabled'

// AB#1599
@description('PostgreSQL public network access. Enabled (default) allows ACA containers via the AllowAllAzureServices firewall rule. Disabled requires private endpoint — only set when VNet integration is in place (Phase V+).')
@allowed([ 'Enabled', 'Disabled' ])
param postgresPublicNetworkAccess string = 'Enabled'

// ---- Key Vault SKU + retention ----
@description('Key Vault SKU.')
@allowed([ 'standard', 'premium' ])
param keyVaultSku string = 'standard'

@description('Key Vault soft-delete retention in days.')
@minValue(7)
@maxValue(90)
param keyVaultSoftDeleteRetentionDays int = 7

// ---- Log Analytics workspace SKU + retention ----
@description('Log Analytics workspace SKU.')
param logAnalyticsSku string = 'PerGB2018'

@description('Log Analytics retention in days.')
@minValue(30)
@maxValue(730)
param logAnalyticsRetentionDays int = 30

// AB#1599
@description('Log Analytics daily data cap in GB. 0 = unlimited (not recommended for non-prod). Recommended: dev=1, stage=5, prod=-1 (unlimited + alert).')
@minValue(0)
param logAnalyticsDailyCapGB int = 1

// ---- API container app sizing ----
@description('API container app CPU (cores).')
param apiAppCpu string = '0.5'

@description('API container app memory.')
param apiAppMemory string = '1Gi'

// AB#1599 — default changed to 0 for scale-to-zero in dev (HIGH reliability/cost finding)
// Recommended per-environment: dev=0, test=0, stage=1, prod=1
@description('API container app minimum replica count. Set to 0 for dev (scale-to-zero), 1 for prod.')
@minValue(0)
param apiAppMinReplicas int = 0

@description('API container app maximum replica count.')
@minValue(1)
param apiAppMaxReplicas int = 3

@description('API container app external ingress target port.')
param apiAppTargetPort int = 8080

// AB#1599
@description('API ACA HTTP scale-out threshold (concurrent requests per replica).')
param apiAppScaleThreshold int = 100

// AB#1669
@description('ACA active revisions mode for API. Multiple enables weighted traffic split for zero-downtime deploys.')
@allowed([ 'Single', 'Multiple' ])
param apiAppRevisionsMode string = 'Single'

// ---- Portal container app sizing ----
@description('Portal container app CPU (cores).')
param portalAppCpu string = '0.25'

@description('Portal container app memory.')
param portalAppMemory string = '0.5Gi'

// AB#1599 — default changed to 0 for scale-to-zero in dev
@description('Portal container app minimum replica count. Set to 0 for dev (scale-to-zero), 1 for prod.')
@minValue(0)
param portalAppMinReplicas int = 0

@description('Portal container app maximum replica count.')
@minValue(1)
param portalAppMaxReplicas int = 2

@description('Portal container app external ingress target port.')
param portalAppTargetPort int = 80

@description('Portal ACA HTTP scale-out threshold (concurrent requests per replica).')
param portalAppScaleThreshold int = 50

@description('Optional Entra tenant ID for OIDC pre-seed. Empty = ADR-047 first-run wizard.')
param entraTenantId string = ''

@description('Optional Entra client ID for OIDC pre-seed.')
param entraClientId string = ''

@secure()
@description('Optional Entra client secret. Empty when first-run wizard is used.')
param entraClientSecret string = ''

// AB#2379 — authority base URL parameter so operators targeting sovereign clouds
// (Azure Government, Azure China) can override the public cloud default.
// Default: https://login.microsoftonline.com (Azure Public Cloud)
// GovCloud: https://login.microsoftonline.us
// China:    https://login.partner.microsoftonline.cn
@description('Entra authority base URL. Override for sovereign clouds. Default = https://login.microsoftonline.com.')
param entraAuthorityBase string = 'https://login.microsoftonline.com'

@description('GHCR username for private image pull. Empty when images are public (ADR-046).')
param ghcrUsername string = ''

@secure()
@description('GHCR token for private image pull. Empty when images are public.')
param ghcrToken string = ''

// H1 security remediation — AES-256 master key for envelope encryption.
// Passed @secure() so the value is never written to ARM deployment logs.
// Stored in Key Vault (secret name: cloudsmith-master-key) at deploy time;
// injected into ACA via KV secret reference — never a plaintext env var.
@secure()
@description('256-bit AES master key (base64-encoded). Must be supplied at deploy time via environment variable CLOUDSMITH_MASTER_KEY or azd env set. Written to Key Vault; ACA reads it via KV secret reference.')
param masterKey string

// AB#1600
@description('Enable PgBouncer connection pooling sidecar on the API container app.')
param enablePgBouncer bool = true

// AB#1668 — governance parameters
@description('Enable Defender for Cloud Standard tier for Containers and OpenSource Relational Databases.')
param enableDefenderForCloud bool = true

@description('Enable Azure Policy assignments for required tags and PG/KV audit policies.')
param enablePolicyAssignments bool = true

@description('Enable Azure Monitor metric alert rules for ACA availability, PG CPU/storage, KV throttling.')
param enableAlertRules bool = true

@description('Monthly budget alert threshold in USD. 0 = no alert.')
param monthlyBudgetUSD int = 0

// =============================================================================
// Per-resource name and tag overrides (ADR-048)
// =============================================================================

@description('Override Log Analytics workspace name. Empty = CAF pattern.')
param logAnalyticsName string = ''

@description('Additional tags for the Log Analytics workspace.')
param logAnalyticsTags object = {}

@description('Override Application Insights name. Empty = CAF pattern.')
param applicationInsightsName string = ''

@description('Additional tags for Application Insights.')
param applicationInsightsTags object = {}

@description('Override Azure Monitor Workspace name. Empty = CAF pattern.')
param azureMonitorWorkspaceName string = ''

@description('Additional tags for the Azure Monitor Workspace.')
param azureMonitorWorkspaceTags object = {}

@description('Override managed identity name. Empty = CAF pattern.')
param managedIdentityName string = ''

@description('Additional tags for the managed identity.')
param managedIdentityTags object = {}

@description('Override Key Vault name. Empty = CAF pattern.')
param keyVaultName string = ''

@description('Additional tags for the Key Vault.')
param keyVaultTags object = {}

@description('Override PostgreSQL flexible server name. Empty = CAF pattern.')
param postgresServerName string = ''

@description('Additional tags for the PostgreSQL server.')
param postgresServerTags object = {}

@description('Override PostgreSQL database name.')
param postgresDatabaseName string = 'cloudsmith'

@description('Override Container Apps Environment name. Empty = CAF pattern.')
param containerAppsEnvironmentName string = ''

@description('Additional tags for the Container Apps Environment.')
param containerAppsEnvironmentTags object = {}

@description('Override API container app name. Empty = CAF pattern.')
param apiAppName string = ''

@description('Additional tags for the API container app.')
param apiAppTags object = {}

@description('Override portal container app name. Empty = CAF pattern.')
param portalAppName string = ''

@description('Additional tags for the portal container app.')
param portalAppTags object = {}

// AB#1606 — optional custom domain + managed TLS for ACA apps
@description('Optional custom domain for the portal (e.g. app.contoso.com). Empty = use default *.azurecontainerapps.io HTTPS endpoint.')
param portalCustomDomain string = ''

@description('Optional custom domain for the API (e.g. api.contoso.com). Empty = use default *.azurecontainerapps.io HTTPS endpoint.')
param apiCustomDomain string = ''

// =============================================================================
// Deployment authentication (AB#2412)
// =============================================================================

// Option A: Interactive deploy — the deploying user authenticates with az login.
//   Requires Contributor + Role Based Access Control Administrator (or Owner) on
//   the target subscription. No extra parameters needed.
//
// Option B: Pre-created User-Assigned Managed Identity (enterprise / CI-CD).
//   A privileged administrator creates the UAMI once and assigns it the required
//   roles. Operators deploy from a resource (Cloud Shell, VM, GitHub Actions /
//   Azure DevOps with Workload Identity Federation) that has the UAMI attached.
//   azd picks up the identity automatically via DefaultAzureCredential.
//   Supply the resource ID here as a record of which identity is authorised.
//
// This parameter is SEPARATE from the runtime UAMI created for the ACA apps
// (API → Key Vault, API → PostgreSQL). That identity is always provisioned by
// the resources module and is referenced via managedIdentityName / bringYourOwn.
@description('Optional resource ID of a pre-existing User-Assigned Managed Identity used to authenticate this deployment (Method B). Empty = interactive az login (Method A). This identity must hold Contributor + Role Based Access Control Administrator on the target subscription. It is not used at runtime — runtime identity is the workload UAMI created by the resources module.')
param deploymentManagedIdentityId string = ''

// =============================================================================
// Bring-your-own (ADR-048) — supply resource IDs to skip creation and reuse
// =============================================================================

@description('Existing resource IDs to reuse instead of creating new resources. Empty string = create new.')
param bringYourOwn object = {
  logAnalyticsWorkspaceId: ''
  applicationInsightsId: ''
  managedIdentityId: ''
  keyVaultId: ''
  containerAppsEnvironmentId: ''
}

// =============================================================================
// Region code lookup (CAF abbreviation)
// =============================================================================

var regionCodes = {
  eastus: 'eus'
  eastus2: 'eus2'
  westus: 'wus'
  westus2: 'wus2'
  westus3: 'wus3'
  centralus: 'cus'
  northcentralus: 'ncus'
  southcentralus: 'scus'
  westcentralus: 'wcus'
  northeurope: 'neu'
  westeurope: 'weu'
  uksouth: 'uks'
  ukwest: 'ukw'
  francecentral: 'frc'
  germanywestcentral: 'gwc'
  switzerlandnorth: 'chn'
  swedencentral: 'sec'
  australiaeast: 'aue'
  australiasoutheast: 'ause'
  southeastasia: 'sea'
  eastasia: 'ea'
  japaneast: 'jpe'
  japanwest: 'jpw'
  koreacentral: 'krc'
  centralindia: 'cin'
  southindia: 'sin'
  canadacentral: 'cac'
  canadaeast: 'cae'
  brazilsouth: 'brs'
  uaenorth: 'uaen'
  southafricanorth: 'san'
}
var regionCode = contains(regionCodes, location) ? regionCodes[location] : substring(replace(location, ' ', ''), 0, 4)

// =============================================================================
// Resource group name (CAF default unless overridden)
// =============================================================================

var rgNameDefault = 'rg-${workload}-${environment}-${regionCode}-${instance}'
var rgNameEffective = empty(resourceGroupName) ? rgNameDefault : resourceGroupName

// Auto-injected tags applied across the deploy (ADR-048).
// deploymentTime comes from the parameter (utcNow is only valid as a parameter default).
var autoTags = {
  ManagedBy: 'bicep'
  DeployedAt: deploymentTime
}

var rgTagsEffective = union(commonTags, autoTags, resourceGroupTags)

// =============================================================================
// Resource group (workload + environment + region + instance)
// =============================================================================

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgNameEffective
  location: location
  tags: rgTagsEffective
}

// =============================================================================
// AB#1668 — Defender for Cloud Standard tier (LOW security finding)
// Enables Defender for Containers and OpenSourceRelationalDatabases at the subscription level.
// Gate behind enableDefenderForCloud to allow cost-conscious operators to opt out in non-prod.
// =============================================================================

resource defenderContainers 'Microsoft.Security/pricings@2024-01-01' = if (enableDefenderForCloud) {
  name: 'Containers'
  properties: { pricingTier: 'Standard' }
}

resource defenderDatabases 'Microsoft.Security/pricings@2024-01-01' = if (enableDefenderForCloud) {
  name: 'OpenSourceRelationalDatabases'
  properties: { pricingTier: 'Standard' }
}

// =============================================================================
// Resources module
// =============================================================================

module resources 'resources.bicep' = {
  name: 'cloudsmith-resources'
  scope: rg
  params: {
    location: location
    workload: workload
    environment: environment
    instance: instance
    regionCode: regionCode
    commonTags: commonTags
    autoTags: autoTags
    imageTag: imageTag
    apiImageTag: apiImageTag
    portalImageTag: portalImageTag
    postgresAdminUser: postgresAdminUser
    postgresAdminPassword: postgresAdminPassword
    postgresSkuName: postgresSkuName
    postgresSkuTier: postgresSkuTier
    postgresStorageGB: postgresStorageGB
    postgresVersion: postgresVersion
    postgresBackupRetentionDays: postgresBackupRetentionDays
    postgresHighAvailabilityMode: postgresHighAvailabilityMode
    postgresGeoRedundantBackup: postgresGeoRedundantBackup
    postgresPublicNetworkAccess: postgresPublicNetworkAccess
    keyVaultSku: keyVaultSku
    keyVaultSoftDeleteRetentionDays: keyVaultSoftDeleteRetentionDays
    logAnalyticsSku: logAnalyticsSku
    logAnalyticsRetentionDays: logAnalyticsRetentionDays
    logAnalyticsDailyCapGB: logAnalyticsDailyCapGB
    apiAppCpu: apiAppCpu
    apiAppMemory: apiAppMemory
    apiAppMinReplicas: apiAppMinReplicas
    apiAppMaxReplicas: apiAppMaxReplicas
    apiAppTargetPort: apiAppTargetPort
    apiAppScaleThreshold: apiAppScaleThreshold
    apiAppRevisionsMode: apiAppRevisionsMode
    portalAppCpu: portalAppCpu
    portalAppMemory: portalAppMemory
    portalAppMinReplicas: portalAppMinReplicas
    portalAppMaxReplicas: portalAppMaxReplicas
    portalAppTargetPort: portalAppTargetPort
    portalAppScaleThreshold: portalAppScaleThreshold
    entraTenantId: entraTenantId
    entraClientId: entraClientId
    entraClientSecret: entraClientSecret
    entraAuthorityBase: entraAuthorityBase
    ghcrUsername: ghcrUsername
    ghcrToken: ghcrToken
    masterKey: masterKey
    enablePgBouncer: enablePgBouncer
    enableAlertRules: enableAlertRules
    logAnalyticsName: logAnalyticsName
    logAnalyticsTags: logAnalyticsTags
    applicationInsightsName: applicationInsightsName
    applicationInsightsTags: applicationInsightsTags
    azureMonitorWorkspaceName: azureMonitorWorkspaceName
    azureMonitorWorkspaceTags: azureMonitorWorkspaceTags
    managedIdentityName: managedIdentityName
    managedIdentityTags: managedIdentityTags
    keyVaultName: keyVaultName
    keyVaultTags: keyVaultTags
    postgresServerName: postgresServerName
    postgresServerTags: postgresServerTags
    postgresDatabaseName: postgresDatabaseName
    containerAppsEnvironmentName: containerAppsEnvironmentName
    containerAppsEnvironmentTags: containerAppsEnvironmentTags
    apiAppName: apiAppName
    apiAppTags: apiAppTags
    portalAppName: portalAppName
    portalAppTags: portalAppTags
    portalCustomDomain: portalCustomDomain
    apiCustomDomain: apiCustomDomain
    bringYourOwn: bringYourOwn
  }
}

// =============================================================================
// AB#1668 — Azure Policy assignments (governance finding)
// Deployed as a module at resource group scope (policy.bicep).
// Policy assignments must be RG-scoped; deploying inline at subscription scope
// requires the BCP139 workaround of a nested module.
// enablePolicyAssignments = false to skip in environments without policy permissions
// (e.g. a dev subscription where the deployer lacks Policy Contributor).
// =============================================================================

module policyAssignments 'policy.bicep' = if (enablePolicyAssignments) {
  name: 'cloudsmith-policy'
  scope: rg
  params: {
    environment: environment
    location: location
  }
}

// =============================================================================
// AB#1668 — Azure Budget alert (MEDIUM cost finding)
// monthlyBudgetUSD = 0 → no budget resource created (default — operator opt-in).
// Set to expected monthly spend to receive notifications at 80% and 100% of threshold.
// =============================================================================

// Budget alert email: prefer commonTags.Owner only if it looks like an email
// (contains '@'); otherwise fall back to the placeholder. Fresh-deploy failure
// 2026-05-27 — operators frequently put a person name in Owner; Azure rejects
// the budget create with "Notification cannot have invalid email addresses".
var ownerLooksLikeEmail = contains(commonTags, 'Owner') && contains(string(commonTags.Owner), '@')
var budgetContactEmail  = ownerLooksLikeEmail ? string(commonTags.Owner) : 'cloudsmith-alerts@example.com'

// Budget startDate must be the first day of the current month for monthly time
// grain — Azure rejects past start dates. Derive from deploymentTime.
var _budgetStartDate = '${substring(deploymentTime, 0, 7)}-01'

resource budget 'Microsoft.Consumption/budgets@2021-10-01' = if (monthlyBudgetUSD > 0) {
  name: 'budget-${workload}-${environment}'
  properties: {
    timePeriod: { startDate: _budgetStartDate }
    timeGrain: 'Monthly'
    amount: monthlyBudgetUSD
    category: 'Cost'
    filter: {
      dimensions: {
        name: 'ResourceGroupName'
        operator: 'In'
        values: [ rgNameEffective ]
      }
    }
    notifications: {
      actual80: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 80
        contactEmails: [ budgetContactEmail ]
      }
      actual100: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        contactEmails: [ budgetContactEmail ]
      }
    }
  }
}

// =============================================================================
// Outputs
// =============================================================================

output PORTAL_URL string = resources.outputs.portalUrl
output API_URL string = resources.outputs.apiUrl
output AZURE_MONITOR_WORKSPACE_ID string = resources.outputs.azureMonitorWorkspaceId
output AZURE_MONITOR_QUERY_ENDPOINT string = resources.outputs.azureMonitorQueryEndpoint
output AZURE_MONITOR_METRICS_INGESTION_ENDPOINT string = resources.outputs.azureMonitorMetricsIngestionEndpoint
output AZURE_MONITOR_DCR_IMMUTABLE_ID string = resources.outputs.azureMonitorDcrImmutableId
// AB#1605 — used by the postprovision hook to restart the API ACA for migration
output API_APP_NAME string = resources.outputs.apiAppName
output PORTAL_APP_NAME string = resources.outputs.portalAppName
output POSTGRES_SERVER string = resources.outputs.postgresServer
output KEY_VAULT_NAME string = resources.outputs.keyVaultName
output RESOURCE_GROUP_NAME string = rgNameEffective
output REGION_CODE string = regionCode
