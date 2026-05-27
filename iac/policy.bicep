// Copyright 2026 CloudSmith Contributors
// SPDX-License-Identifier: Apache-2.0
//
// Azure Policy assignment module (AB#1668 — governance finding).
// Deployed at resource group scope from the subscription-scoped main.bicep via module.
//
// Policy definitions referenced:
//   5ff38825-c5d8-47c5-b70e-069a21955146 — KV keys should have expiry date
//                                         (requires parameter: minimumDaysBeforeExpiration)
//   55615ac9-af46-4a59-874e-391cc3dfb490 — KV should have firewall enabled
//   c9299215-ae47-4f50-9c54-8a392f68a052 — PG public network access should be disabled
//   871b6d14-10aa-478d-b590-94f262ecfa99 — Require tag on resources (applied per mandatory tag key)
//
// NOTE: The PG infrastructure encryption policy (24fde369-...) was removed — that
// definition ID does not exist in the built-in policy catalog (fresh-deploy failure
// 2026-05-27). PostgreSQL Flexible Server has Microsoft-managed key encryption on
// by default; CMK encryption is a Phase V enhancement.

@description('Environment name — used to disambiguate assignment names across envs.')
@allowed([ 'dev', 'test', 'stage', 'prod' ])
param environment string

@description('Azure region — required for policy assignment location property.')
param location string

// =============================================================================
// Key Vault policy assignments
// =============================================================================

resource policyKvKeyExpiry 'Microsoft.Authorization/policyAssignments@2022-06-01' = {
  name: 'cs-kv-key-expiry-${environment}'
  location: location
  properties: {
    displayName: 'CloudSmith — KV keys should have expiration date'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/5ff38825-c5d8-47c5-b70e-069a21955146'
    parameters: {
      // Required by the built-in policy (Phase IV fresh-deploy fix 2026-05-27).
      // Operators can override per-environment to enforce stricter rotation.
      minimumDaysBeforeExpiration: { value: 90 }
    }
  }
}

resource policyKvFirewall 'Microsoft.Authorization/policyAssignments@2022-06-01' = {
  name: 'cs-kv-firewall-${environment}'
  location: location
  properties: {
    displayName: 'CloudSmith — KV should have firewall enabled (Audit; Deny post-Phase-V)'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/55615ac9-af46-4a59-874e-391cc3dfb490'
    parameters: {}
  }
}

// =============================================================================
// PostgreSQL policy assignments
// =============================================================================

resource policyPgPublicAccess 'Microsoft.Authorization/policyAssignments@2022-06-01' = {
  name: 'cs-pg-public-${environment}'
  location: location
  properties: {
    displayName: 'CloudSmith — PG public network access should be disabled (Audit; Deny post-Phase-V)'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/c9299215-ae47-4f50-9c54-8a392f68a052'
    parameters: {}
  }
}

// policyPgEncryption was assigned policy definition 24fde369-2374-4b4c-a418-b4d97d0b0cef
// which does not exist in the built-in catalog (fresh-deploy failure 2026-05-27).
// PG Flexible Server uses Microsoft-managed key encryption by default; CMK is Phase V.
// Removed until a valid policy ID is identified or the requirement is reformulated.

// =============================================================================
// Required tag enforcement (ADR-048 mandatory tag set — 7 keys)
// Each assignment enforces one tag key at the RG scope.
// Deny effect prevents untagged resources from being created in this RG.
// =============================================================================

var requiredTags = [
  'Environment'
  'Workload'
  'CostCenter'
  'Owner'
  'BusinessUnit'
  'DataClassification'
  'Criticality'
]

resource policyRequireTags 'Microsoft.Authorization/policyAssignments@2022-06-01' = [for tagKey in requiredTags: {
  name: 'cs-tag-${toLower(tagKey)}-${environment}'
  location: location
  properties: {
    displayName: 'CloudSmith — require tag ${tagKey}'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/871b6d14-10aa-478d-b590-94f262ecfa99'
    parameters: {
      tagName: { value: tagKey }
    }
  }
}]
