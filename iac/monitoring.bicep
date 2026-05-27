// Copyright 2026 CloudSmith Contributors
// SPDX-License-Identifier: Apache-2.0
//
// Azure Monitor metric alert rules module (AB#1668 — MEDIUM operational excellence finding).
//
// Provisions Azure Monitor metric alert rules for:
//   - ACA API availability (< 99% over 5 min) — Severity 1
//   - ACA Portal availability (< 99% over 5 min) — Severity 2
//   - PG CPU (> 80% for 10 min) — Severity 2
//   - PG storage (> 80%) — Severity 1
//   - KV throttling (any 429 over 5 min) — Severity 2
//
// Also provisions an Action Group emailing the Owner tag value.

@description('Workload identifier used in CAF-pattern resource names.')
param workload string

@description('Environment name (dev/test/stage/prod).')
@allowed([ 'dev', 'test', 'stage', 'prod' ])
param environment string

@description('Three-letter Azure region code.')
param regionCode string

@description('Three-digit zero-padded instance number.')
param instance string

@description('Base tags (commonTags merged with autoTags) applied to all alert resources.')
param allTagsBase object

@description('Resource ID of the API container app.')
param apiAppId string

@description('Resource ID of the portal container app.')
param portalAppId string

@description('Resource ID of the PostgreSQL Flexible Server.')
param pgServerId string

@description('Resource ID of the Key Vault.')
param kvId string

@description('Email address for alert notifications (from commonTags.Owner).')
param ownerEmail string

// =============================================================================
// Action Group — email to Owner tag
// =============================================================================

var actionGroupName = 'ag-${workload}-${environment}-${regionCode}-${instance}'

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'Global'
  tags: allTagsBase
  properties: {
    groupShortName: 'csalerts'
    enabled: true
    emailReceivers: empty(ownerEmail) ? [] : [
      {
        name: 'owner-email'
        emailAddress: ownerEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// =============================================================================
// Helper: CAF alert name prefix
// =============================================================================

var alertPrefix = 'cs-alert'

// =============================================================================
// ACA API restart alert (Severity 1 — Error)
// Container Apps does not expose an "Availability" metric (fresh-deploy fix
// 2026-05-27); RestartCount > 3 over 15 min is a useful proxy for crash loops.
// =============================================================================

resource alertApiAvailability 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${alertPrefix}-api-restarts'
  location: 'Global'
  tags: allTagsBase
  properties: {
    description: 'CloudSmith API container app restarted more than 3 times in 15 minutes (crash loop).'
    severity: 1
    enabled: true
    scopes: [ apiAppId ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'api-restarts'
          metricName: 'RestartCount'
          metricNamespace: 'Microsoft.App/containerApps'
          operator: 'GreaterThan'
          threshold: 3
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      { actionGroupId: actionGroup.id }
    ]
  }
}

// =============================================================================
// ACA Portal restart alert (Severity 2 — Warning)
// =============================================================================

resource alertPortalAvailability 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${alertPrefix}-portal-restarts'
  location: 'Global'
  tags: allTagsBase
  properties: {
    description: 'CloudSmith Portal container app restarted more than 3 times in 15 minutes (crash loop).'
    severity: 2
    enabled: true
    scopes: [ portalAppId ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'portal-restarts'
          metricName: 'RestartCount'
          metricNamespace: 'Microsoft.App/containerApps'
          operator: 'GreaterThan'
          threshold: 3
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      { actionGroupId: actionGroup.id }
    ]
  }
}

// =============================================================================
// PostgreSQL CPU alert (Severity 2 — Warning)
// =============================================================================

resource alertPgCpu 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${alertPrefix}-pg-cpu'
  location: 'Global'
  tags: allTagsBase
  properties: {
    description: 'CloudSmith PostgreSQL CPU > 80% for 10 minutes.'
    severity: 2
    enabled: true
    scopes: [ pgServerId ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'pg-cpu'
          metricName: 'cpu_percent'
          metricNamespace: 'Microsoft.DBforPostgreSQL/flexibleServers'
          operator: 'GreaterThan'
          threshold: 80
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      { actionGroupId: actionGroup.id }
    ]
  }
}

// =============================================================================
// PostgreSQL storage alert (Severity 1 — Error)
// =============================================================================

resource alertPgStorage 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${alertPrefix}-pg-storage'
  location: 'Global'
  tags: allTagsBase
  properties: {
    description: 'CloudSmith PostgreSQL storage > 80%.'
    severity: 1
    enabled: true
    scopes: [ pgServerId ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'pg-storage'
          metricName: 'storage_percent'
          metricNamespace: 'Microsoft.DBforPostgreSQL/flexibleServers'
          operator: 'GreaterThan'
          threshold: 80
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      { actionGroupId: actionGroup.id }
    ]
  }
}

// =============================================================================
// Key Vault throttling alert (Severity 2 — Warning)
// =============================================================================

resource alertKvThrottle 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${alertPrefix}-kv-throttle'
  location: 'Global'
  tags: allTagsBase
  properties: {
    description: 'CloudSmith Key Vault is receiving throttled requests (HTTP 429).'
    severity: 2
    enabled: true
    scopes: [ kvId ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'kv-throttle'
          metricName: 'ServiceApiResult'
          metricNamespace: 'Microsoft.KeyVault/vaults'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Count'
          criterionType: 'StaticThresholdCriterion'
          dimensions: [
            {
              name: 'StatusCode'
              operator: 'Include'
              values: [ '429' ]
            }
          ]
        }
      ]
    }
    actions: [
      { actionGroupId: actionGroup.id }
    ]
  }
}

// =============================================================================
// Outputs
// =============================================================================

output actionGroupId string = actionGroup.id
