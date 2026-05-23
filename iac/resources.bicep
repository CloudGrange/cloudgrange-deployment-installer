// Copyright 2026 CloudSmith Contributors
// SPDX-License-Identifier: Apache-2.0
//
// CloudSmith MVP — Azure PaaS (Model B) resource module.
// Deploys the minimal Phase IV PaaS stack per ADR-043 (azd + Bicep),
// ADR-006 (Azure Container Apps), ADR-044 (portal as ACA container).
// Auth on PaaS uses Entra ID (per design/sequence-diagrams/login-oidc-paas.md),
// not Keycloak (which is the standalone/Model A IdP).

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short prefix for resource names (3-12 lowercase alphanumeric).')
@minLength(3)
@maxLength(12)
param namePrefix string = 'cloudsmith'

@description('Container image tag to deploy for api and portal.')
param imageTag string = 'latest'

@description('PostgreSQL administrator login name.')
param postgresAdminUser string = 'cloudsmith'

@secure()
@description('PostgreSQL administrator password.')
param postgresAdminPassword string

// OPTIONAL deploy-time IdP pre-seed. The identity provider (Entra ID, on-prem
// Active Directory, Keycloak, generic OIDC) is normally configured POST-DEPLOY
// in the platform identity settings (/identity/v1/idp) and stored in the Config
// Registry — see README "Identity model". Leave these empty to deploy
// IdP-agnostic; the API issues a bootstrap admin token on first run for the
// first login, after which the operator configures their IdP in settings.
@description('Optional: Entra tenant ID to PRE-SEED OIDC at deploy time. Empty = configure IdP post-deploy in settings.')
param entraTenantId string = ''

@description('Optional: Entra app (client) ID to pre-seed. Empty = configure post-deploy.')
param entraClientId string = ''

@secure()
@description('Optional: Entra client secret to pre-seed. Prefer a federated credential to the Managed Identity (no secret). Empty = configure post-deploy.')
param entraClientSecret string = ''

@description('GHCR username for pulling container images while they remain private. Leave empty once images are public (ADR-046).')
param ghcrUsername string = ''

@secure()
@description('GHCR token (read:packages) for private image pull. Leave empty once images are public.')
param ghcrToken string = ''

var imagesArePrivate = !empty(ghcrToken)
var apiImage = 'ghcr.io/cloudsmith-cloud/cloudsmith-api:${imageTag}'
var portalImage = 'ghcr.io/cloudsmith-cloud/cloudsmith-portal:${imageTag}'
var pgFqdn = '${pg.name}.postgres.database.azure.com'
var dbConnString = 'Host=${pgFqdn};Database=cloudsmith;Username=${postgresAdminUser};Password=${postgresAdminPassword};Ssl Mode=Require;'
var oidcPreseed = !empty(entraClientId)
var entraAuthority = empty(entraTenantId) ? '' : 'https://login.microsoftonline.com/${entraTenantId}/v2.0'
// Optional OIDC pre-seed env — normally EMPTY; IdP is configured post-deploy in settings.
var oidcApiEnv = oidcPreseed ? [
  { name: 'Keycloak__Authority', value: entraAuthority }
  { name: 'Keycloak__ClientId', value: entraClientId }
  { name: 'Keycloak__ClientSecret', secretRef: 'entra-client-secret' }
  { name: 'Keycloak__RequireHttpsMetadata', value: 'true' }
] : []

// ---------------------------------------------------------------------------
// Observability — Log Analytics + Application Insights
// ---------------------------------------------------------------------------
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-logs'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-appi'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logs.id
  }
}

// ---------------------------------------------------------------------------
// Identity + Key Vault
// ---------------------------------------------------------------------------
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-id'
  location: location
}

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  // KV names are limited to 24 chars; use a short fixed prefix + 13-char uniqueString (= 19).
  name: 'cs-kv-${uniqueString(resourceGroup().id)}'
  location: location
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

// Key Vault Secrets User role for the workload identity
var kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
resource kvRoleAssign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, uami.id, kvSecretsUserRoleId)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// PostgreSQL Flexible Server
// ---------------------------------------------------------------------------
resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2023-12-01-preview' = {
  name: '${namePrefix}-pg-${uniqueString(resourceGroup().id)}'
  location: location
  sku: { name: 'Standard_B1ms', tier: 'Burstable' }
  properties: {
    version: '16'
    administratorLogin: postgresAdminUser
    administratorLoginPassword: postgresAdminPassword
    storage: { storageSizeGB: 32 }
    backup: { backupRetentionDays: 7, geoRedundantBackup: 'Disabled' }
    highAvailability: { mode: 'Disabled' }
    // Entra auth ENABLED so the API connects to PostgreSQL with its Managed
    // Identity (no password). Password auth kept enabled only as break-glass /
    // migration transition; target is Entra-only (set passwordAuth: 'Disabled').
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Enabled'
      tenantId: subscription().tenantId
    }
  }
}

resource pgDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-12-01-preview' = {
  parent: pg
  name: 'cloudsmith'
}

// Allow other Azure services (incl. Container Apps) to reach the server.
resource pgFwAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-12-01-preview' = {
  parent: pg
  name: 'AllowAllAzureServices'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

// Make the workload Managed Identity an Entra administrator of PostgreSQL,
// so the API authenticates to the database passwordless via its MI token
// (Npgsql password provider fetches an https://ossrdbms-aad.database.windows.net token).
// Done via module to satisfy the runtime-name (BCP120) constraint.
module pgAadAdmin 'pg-aad-admin.bicep' = {
  name: 'pg-aad-admin'
  params: {
    postgresServerName: pg.name
    principalId: uami.properties.principalId
    principalName: uami.name
    tenantId: subscription().tenantId
  }
  dependsOn: [ pgFwAzure, pgDb ]
}

// ---------------------------------------------------------------------------
// Container Apps Environment
// ---------------------------------------------------------------------------
resource acaEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${namePrefix}-aca-env'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

// Shared registry config for private GHCR pull (removable once images public).
var registries = imagesArePrivate ? [
  {
    server: 'ghcr.io'
    username: ghcrUsername
    passwordSecretRef: 'ghcr-token'
  }
] : []

// ---------------------------------------------------------------------------
// API Container App (external ingress on 8080)
// ---------------------------------------------------------------------------
resource apiApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${namePrefix}-api'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uami.id}': {} }
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
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
          resources: { cpu: json('0.5'), memory: '1Gi' }
          // Base env only. IdP/OIDC is configured POST-DEPLOY via /identity/v1/idp
          // (Config Registry); oidcApiEnv is empty unless an operator pre-seeds Entra.
          env: union([
            { name: 'ASPNETCORE_ENVIRONMENT', value: 'Production' }
            { name: 'ConnectionStrings__Default', secretRef: 'db-connection' }
            { name: 'ApplicationInsights__ConnectionString', value: appInsights.properties.ConnectionString }
            { name: 'AZURE_CLIENT_ID', value: uami.properties.clientId }
          ], oidcApiEnv)
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 3 }
    }
  }
}

// ---------------------------------------------------------------------------
// Portal Container App (external ingress on 80) — same nginx image as Model A (ADR-044)
// ---------------------------------------------------------------------------
resource portalApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${namePrefix}-portal'
  location: location
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
      }
      registries: registries
      secrets: imagesArePrivate ? [ { name: 'ghcr-token', value: ghcrToken } ] : []
    }
    template: {
      containers: [
        {
          name: 'cloudsmith-portal'
          image: portalImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            // Browser-facing API base — EMPTY = relative paths via portal nginx proxy (same-origin).
            // Setting an absolute URL here makes the SPA fetch cross-origin, which breaks the cookie/setup flow on ACA.
            { name: 'CLOUDSMITH_API_URL', value: '' }
            // Entra ID authority for the browser OIDC flow
            { name: 'CLOUDSMITH_AUTH_URL', value: entraAuthority }
            // nginx upstream — portal proxies /api/ and /signin-oidc to the API's external ACA FQDN over HTTPS.
            // Required because compose DNS (cloudsmith-api:8080) does not resolve in ACA.
            { name: 'CLOUDSMITH_API_UPSTREAM', value: 'https://${apiApp.properties.configuration.ingress.fqdn}' }
            { name: 'CLOUDSMITH_API_HOST', value: apiApp.properties.configuration.ingress.fqdn }
            { name: 'CLOUDSMITH_FWD_PROTO', value: 'https' }
            // Legacy compatibility — kept until removed from portal image (not used when CLOUDSMITH_API_UPSTREAM is set)
            { name: 'CLOUDSMITH_API_INTERNAL_URL', value: 'https://${apiApp.properties.configuration.ingress.fqdn}' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 2 }
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output portalUrl string = 'https://${portalApp.properties.configuration.ingress.fqdn}'
output apiUrl string = 'https://${apiApp.properties.configuration.ingress.fqdn}'
output postgresServer string = pgFqdn
output keyVaultName string = kv.name
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output managedIdentityClientId string = uami.properties.clientId
