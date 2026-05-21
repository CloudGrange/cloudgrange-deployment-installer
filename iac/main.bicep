// Copyright 2026 CloudSmith Contributors
// SPDX-License-Identifier: Apache-2.0
//
// CloudSmith MVP — Azure PaaS (Model B) entry point.
// Subscription-scoped: creates the resource group and deploys the resource module.
// Deploy with azd (`azd up`) or directly:
//   az deployment sub create --location eastus \
//     --template-file iac/main.bicep --parameters iac/main.parameters.json

targetScope = 'subscription'

@description('Azure region for the deployment.')
param location string = 'eastus'

@description('Environment name (azd-provided) — used in the resource group name.')
param environmentName string = 'cloudsmith-mvp'

@description('Short prefix for resource names.')
param namePrefix string = 'cloudsmith'

@description('Container image tag to deploy.')
param imageTag string = 'latest'

param postgresAdminUser string = 'cloudsmith'

@secure()
param postgresAdminPassword string

param entraTenantId string
param entraClientId string

@secure()
param entraClientSecret string

param ghcrUsername string = ''

@secure()
param ghcrToken string = ''

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
}

module resources 'resources.bicep' = {
  name: 'cloudsmith-resources'
  scope: rg
  params: {
    location: location
    namePrefix: namePrefix
    imageTag: imageTag
    postgresAdminUser: postgresAdminUser
    postgresAdminPassword: postgresAdminPassword
    entraTenantId: entraTenantId
    entraClientId: entraClientId
    entraClientSecret: entraClientSecret
    ghcrUsername: ghcrUsername
    ghcrToken: ghcrToken
  }
}

output PORTAL_URL string = resources.outputs.portalUrl
output API_URL string = resources.outputs.apiUrl
output POSTGRES_SERVER string = resources.outputs.postgresServer
output KEY_VAULT_NAME string = resources.outputs.keyVaultName
