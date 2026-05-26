// Copyright 2026 CloudSmith Contributors
// SPDX-License-Identifier: Apache-2.0
//
// CloudSmith PaaS (Model B) resource module — ADR-043 / ADR-044 / ADR-046 / ADR-047 / ADR-048.
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

@description('Container image tag for API + portal.')
param imageTag string = 'latest'

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

@allowed([ 'standard', 'premium' ])
param keyVaultSku string = 'standard'
@minValue(7)
@maxValue(90)
param keyVaultSoftDeleteRetentionDays int = 7

param logAnalyticsSku string = 'PerGB2018'
@minValue(30)
@maxValue(730)
param logAnalyticsRetentionDays int = 30

param apiAppCpu string = '0.5'
param apiAppMemory string = '1Gi'
@minValue(0)
param apiAppMinReplicas int = 1
@minValue(1)
param apiAppMaxReplicas int = 3
param apiAppTargetPort int = 8080

param portalAppCpu string = '0.25'
param portalAppMemory string = '0.5Gi'
@minValue(0)
param portalAppMinReplicas int = 1
@minValue(1)
param portalAppMaxReplicas int = 2
param portalAppTargetPort int = 80

@description('Entra tenant ID — empty = ADR-047 first-run wizard.')
param entraTenantId string = ''

@description('Entra client ID — empty = first-run wizard.')
param entraClientId string = ''

@secure()
param entraClientSecret string = ''

@description('GHCR username. Empty = images public (ADR-046).')
param ghcrUsername string = ''

@secure()
param ghcrToken string = ''

// Per-resource overrides (ADR-048)
param logAnalyticsName string = ''
param logAnalyticsTags object = {}
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
var applicationInsightsNameEffective = empty(applicationInsightsName) ? cafName(typeAbbr.applicationInsights, workload, environment, regionCode, instance) : applicationInsightsName
var managedIdentityNameEffective = empty(managedIdentityName) ? cafName(typeAbbr.userAssignedManagedIdentity, workload, environment, regionCode, instance) : managedIdentityName
var keyVaultNameEffective = empty(keyVaultName) ? cafNameLengthConstrained(typeAbbr.keyVault, workloadShort, environment, regionCode, instance, rgHash) : keyVaultName
var postgresServerNameEffective = empty(postgresServerName) ? cafName(typeAbbr.postgresqlFlexibleServer, workload, environment, regionCode, instance) : postgresServerName
var containerAppsEnvironmentNameEffective = empty(containerAppsEnvironmentName) ? cafName(typeAbbr.containerAppsEnvironment, workload, environment, regionCode, instance) : containerAppsEnvironmentName
var apiAppNameEffective = empty(apiAppName) ? cafNameWithRole(typeAbbr.containerApp, workload, 'api', environment, regionCode, instance) : apiAppName
var portalAppNameEffective = empty(portalAppName) ? cafNameWithRole(typeAbbr.containerApp, workload, 'portal', environment, regionCode, instance) : portalAppName

// Tag composition helper — every resource gets commonTags + autoTags + own.
// Length-constrained types also get a DisplayName tag with the readable CAF form.
var allTagsBase = union(commonTags, autoTags)
var keyVaultDisplayName = cafName(typeAbbr.keyVault, workload, environment, regionCode, instance)
var kvDisplayTag = { DisplayName: keyVaultDisplayName }

// =============================================================================
// Image / connection-string composition
// =============================================================================
var imagesArePrivate = !empty(ghcrToken)
var apiImage = 'ghcr.io/cloudsmith-cloud/cloudsmith-api:${imageTag}'
var portalImage = 'ghcr.io/cloudsmith-cloud/cloudsmith-portal:${imageTag}'
var pgFqdn = '${postgresServerNameEffective}.postgres.database.azure.com'
var dbConnString = 'Host=${pgFqdn};Database=${postgresDatabaseName};Username=${postgresAdminUser};Password=${postgresAdminPassword};Ssl Mode=Require;'
var oidcPreseed = !empty(entraClientId)
var entraAuthority = empty(entraTenantId) ? '' : 'https://login.microsoftonline.com/${entraTenantId}/v2.0'
var oidcApiEnv = oidcPreseed ? [
  { name: 'Keycloak__Authority', value: entraAuthority }
  { name: 'Keycloak__ClientId', value: entraClientId }
  { name: 'Keycloak__ClientSecret', secretRef: 'entra-client-secret' }
  { name: 'Keycloak__RequireHttpsMetadata', value: 'true' }
] : []

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
  }
}

resource existingKv 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (!empty(byoKvId)) {
  name: byoKvParts[8]
  scope: resourceGroup(byoKvParts[2], byoKvParts[4])
}

// Key Vault Secrets User role assignment for the managed identity — applied to
// whichever KV we ended up using.
var kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
resource kvRoleAssignNew 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (empty(byoKvId)) {
  name: guid(newKv.id, miId, kvSecretsUserRoleId)
  scope: newKv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: miPrincipalId
    principalType: 'ServicePrincipal'
  }
}
// When BYO KV is used the role assignment is the customer's responsibility — we
// do not modify access on existing shared resources.

// =============================================================================
// PostgreSQL Flexible Server (always created — workload-specific)
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
    backup: { backupRetentionDays: postgresBackupRetentionDays, geoRedundantBackup: 'Disabled' }
    highAvailability: { mode: postgresHighAvailabilityMode }
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Enabled'
      tenantId: subscription().tenantId
    }
  }
}

resource pgDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-12-01-preview' = {
  parent: pg
  name: postgresDatabaseName
}

resource pgFwAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-12-01-preview' = {
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

var caeId = empty(byoCaeId) ? newCae.id : existingCae.id

var registries = imagesArePrivate ? [
  {
    server: 'ghcr.io'
    username: ghcrUsername
    passwordSecretRef: 'ghcr-token'
  }
] : []

// =============================================================================
// API Container App (external ingress on 8080)
// =============================================================================

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
      activeRevisionsMode: 'Single'
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
      }
      registries: registries
      secrets: concat(
        [ { name: 'db-connection', value: dbConnString } ],
        oidcPreseed ? [ { name: 'entra-client-secret', value: entraClientSecret } ] : [],
        imagesArePrivate ? [ { name: 'ghcr-token', value: ghcrToken } ] : []
      )
    }
    template: {
      containers: [
        {
          name: 'cloudsmith-api'
          image: apiImage
          resources: { cpu: json(apiAppCpu), memory: apiAppMemory }
          env: union([
            { name: 'ASPNETCORE_ENVIRONMENT', value: 'Production' }
            { name: 'ConnectionStrings__Default', secretRef: 'db-connection' }
            { name: 'ApplicationInsights__ConnectionString', value: appiConnectionString }
            { name: 'AZURE_CLIENT_ID', value: miClientId }
          ], oidcApiEnv)
        }
      ]
      scale: { minReplicas: apiAppMinReplicas, maxReplicas: apiAppMaxReplicas }
    }
  }
}

// =============================================================================
// Portal Container App (external ingress on 80, same-origin nginx proxy)
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
        }
      ]
      scale: { minReplicas: portalAppMinReplicas, maxReplicas: portalAppMaxReplicas }
    }
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
output appInsightsConnectionString string = appiConnectionString
output managedIdentityClientId string = miClientId
