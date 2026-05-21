// Copyright 2026 CloudSmith Contributors
// SPDX-License-Identifier: Apache-2.0
//
// Module boundary for the PostgreSQL Flexible Server Entra administrator.
// Required because the administrators resource `name` must be the principal's
// object ID, which for a same-deployment Managed Identity is a runtime value;
// passing it as a module parameter satisfies Bicep's BCP120 name constraint.

param postgresServerName string
param principalId string
param principalName string
param tenantId string

resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2023-12-01-preview' existing = {
  name: postgresServerName
}

resource admin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2023-12-01-preview' = {
  parent: pg
  name: principalId
  properties: {
    principalType: 'ServicePrincipal'
    principalName: principalName
    tenantId: tenantId
  }
}
