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

@description('Entra ID tenant ID for PaaS OIDC auth.')
param entraTenantId string

@description('Entra ID application (client) ID for the CloudSmith API.')
param entraClientId string

@secure()
@description('Entra ID client secret for the CloudSmith API app registration.')
param entraClientSecret string

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
var entraAuthority = 'https://login.microsoftonline.com/${entraTenantId}/v2.0'

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
  name: '${namePrefix}-kv-${uniqueString(resourceGroup().id)}'
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
        [
          { name: 'db-connection', value: dbConnString }
          { name: 'entra-client-secret', value: entraClientSecret }
        ],
        imagesArePrivate ? [ { name: 'ghcr-token', value: ghcrToken } ] : []
      )
    }
    template: {
      containers: [
        {
          name: 'cloudsmith-api'
          image: apiImage
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'ASPNETCORE_ENVIRONMENT', value: 'Production' }
            { name: 'ConnectionStrings__Default', secretRef: 'db-connection' }
            { name: 'Keycloak__Authority', value: entraAuthority }
            { name: 'Keycloak__ClientId', value: entraClientId }
            { name: 'Keycloak__ClientSecret', secretRef: 'entra-client-secret' }
            { name: 'Keycloak__RequireHttpsMetadata', value: 'true' }
            { name: 'ApplicationInsights__ConnectionString', value: appInsights.properties.ConnectionString }
            { name: 'AZURE_CLIENT_ID', value: uami.properties.clientId }
          ]
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
            // Browser-facing API base (external API FQDN) — entrypoint.sh injects window.__CLOUDSMITH_CONFIG__
            { name: 'CLOUDSMITH_API_URL', value: 'https://${apiApp.properties.configuration.ingress.fqdn}' }
            // Entra ID authority for the browser OIDC flow
            { name: 'CLOUDSMITH_AUTH_URL', value: entraAuthority }
            // Container-to-container proxy target for nginx /api/ (separate from browser URL, per ADR-044)
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
