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
// Deploy:
//   az deployment sub create --location centralus --template-file iac/main.bicep \
//     --parameters iac/main.parameters.json

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

@description('Container image tag to deploy.')
param imageTag string = 'latest'

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

@description('PostgreSQL high availability mode.')
@allowed([ 'Disabled', 'SameZone', 'ZoneRedundant' ])
param postgresHighAvailabilityMode string = 'Disabled'

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

// ---- API container app sizing ----
@description('API container app CPU (cores).')
param apiAppCpu string = '0.5'

@description('API container app memory.')
param apiAppMemory string = '1Gi'

@description('API container app minimum replica count.')
@minValue(0)
param apiAppMinReplicas int = 1

@description('API container app maximum replica count.')
@minValue(1)
param apiAppMaxReplicas int = 3

@description('API container app external ingress target port.')
param apiAppTargetPort int = 8080

// ---- Portal container app sizing ----
@description('Portal container app CPU (cores).')
param portalAppCpu string = '0.25'

@description('Portal container app memory.')
param portalAppMemory string = '0.5Gi'

@description('Portal container app minimum replica count.')
@minValue(0)
param portalAppMinReplicas int = 1

@description('Portal container app maximum replica count.')
@minValue(1)
param portalAppMaxReplicas int = 2

@description('Portal container app external ingress target port.')
param portalAppTargetPort int = 80

@description('Optional Entra tenant ID for OIDC pre-seed. Empty = ADR-047 first-run wizard.')
param entraTenantId string = ''

@description('Optional Entra client ID for OIDC pre-seed.')
param entraClientId string = ''

@secure()
@description('Optional Entra client secret. Empty when first-run wizard is used.')
param entraClientSecret string = ''

@description('GHCR username for private image pull. Empty when images are public (ADR-046).')
param ghcrUsername string = ''

@secure()
@description('GHCR token for private image pull. Empty when images are public.')
param ghcrToken string = ''

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
    postgresAdminUser: postgresAdminUser
    postgresAdminPassword: postgresAdminPassword
    postgresSkuName: postgresSkuName
    postgresSkuTier: postgresSkuTier
    postgresStorageGB: postgresStorageGB
    postgresVersion: postgresVersion
    postgresBackupRetentionDays: postgresBackupRetentionDays
    postgresHighAvailabilityMode: postgresHighAvailabilityMode
    keyVaultSku: keyVaultSku
    keyVaultSoftDeleteRetentionDays: keyVaultSoftDeleteRetentionDays
    logAnalyticsSku: logAnalyticsSku
    logAnalyticsRetentionDays: logAnalyticsRetentionDays
    apiAppCpu: apiAppCpu
    apiAppMemory: apiAppMemory
    apiAppMinReplicas: apiAppMinReplicas
    apiAppMaxReplicas: apiAppMaxReplicas
    apiAppTargetPort: apiAppTargetPort
    portalAppCpu: portalAppCpu
    portalAppMemory: portalAppMemory
    portalAppMinReplicas: portalAppMinReplicas
    portalAppMaxReplicas: portalAppMaxReplicas
    portalAppTargetPort: portalAppTargetPort
    entraTenantId: entraTenantId
    entraClientId: entraClientId
    entraClientSecret: entraClientSecret
    ghcrUsername: ghcrUsername
    ghcrToken: ghcrToken
    logAnalyticsName: logAnalyticsName
    logAnalyticsTags: logAnalyticsTags
    applicationInsightsName: applicationInsightsName
    applicationInsightsTags: applicationInsightsTags
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
    bringYourOwn: bringYourOwn
  }
}

// =============================================================================
// Outputs
// =============================================================================

output PORTAL_URL string = resources.outputs.portalUrl
output API_URL string = resources.outputs.apiUrl
output POSTGRES_SERVER string = resources.outputs.postgresServer
output KEY_VAULT_NAME string = resources.outputs.keyVaultName
output RESOURCE_GROUP_NAME string = rgNameEffective
output REGION_CODE string = regionCode
