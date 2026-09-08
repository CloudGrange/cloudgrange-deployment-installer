# CAF Naming Migration Runbook

**AB#1670 — CAF naming migration guidance**  
**Standard:** ADR-048 (Azure resource naming and tagging standard)  
**Scope:** CloudGrange PaaS resources managed by `iac/main.bicep`

---

## 1. Pre-migration inventory

Before renaming any resource, generate a full inventory of the current resource group. This table drives the mapping from old names to CAF-pattern names.

```powershell
# Replace <old-rg-name> with the actual resource group name
az resource list \
  --resource-group <old-rg-name> \
  --output table \
  --query "[].{Name:name, Type:type, Location:location}"
```

Populate the mapping table below with your results:

| Current name | Resource type | CAF target name | Override param in `main.parameters.json` |
|---|---|---|---|
| `cloudgrange-logs` | `Microsoft.OperationalInsights/workspaces` | `log-cloudgrange-dev-cus-001` | `logAnalyticsName` |
| `cloudgrange-appi` | `Microsoft.Insights/components` | `appi-cloudgrange-dev-cus-001` | `applicationInsightsName` |
| `cs-kv-abc123` | `Microsoft.KeyVault/vaults` | `kvclouddevcus001abc123` | `keyVaultName` |
| `cloudgrange-pg` | `Microsoft.DBforPostgreSQL/flexibleServers` | `psql-cloudgrange-dev-cus-001` | `postgresServerName` |
| `cloudgrange-cae` | `Microsoft.App/managedEnvironments` | `cae-cloudgrange-dev-cus-001` | `containerAppsEnvironmentName` |
| `cloudgrange-api` | `Microsoft.App/containerApps` | `ca-cloudgrange-api-dev-cus-001` | `apiAppName` |
| `cloudgrange-portal` | `Microsoft.App/containerApps` | `ca-cloudgrange-portal-dev-cus-001` | `portalAppName` |
| `cloudgrange-mi` | `Microsoft.ManagedIdentity/userAssignedIdentities` | `id-cloudgrange-dev-cus-001` | `managedIdentityName` |

**CAF name pattern (ADR-048):** `{abbr}-{workload}-{env}-{regionCode}-{instance}`  
**Key Vault pattern (length-constrained):** `{abbr}{workloadShort}{env}{regionCode}{instance}{rgHash}` (24 chars max, no separators, 6-char hash for uniqueness)

---

## 2. Bicep parameter override syntax

Any operator who wants to **preserve existing resource names** (avoiding resource recreation) can supply the `<resource>Name` override parameters. This is the correct path for in-place renames that Bicep can reconcile via ARM incremental mode.

Add overrides to `main.parameters.json`:

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "keyVaultName":               { "value": "cs-kv-abc123def456" },
    "logAnalyticsName":           { "value": "cloudgrange-logs" },
    "applicationInsightsName":    { "value": "cloudgrange-appi" },
    "postgresServerName":         { "value": "cloudgrange-pg" },
    "containerAppsEnvironmentName": { "value": "cloudgrange-cae" },
    "apiAppName":                 { "value": "cloudgrange-api" },
    "portalAppName":              { "value": "cloudgrange-portal" },
    "managedIdentityName":        { "value": "cloudgrange-mi" }
  }
}
```

When these overrides are present, `azd provision` re-deploys against the existing resources using their current names. ARM incremental mode updates only the changed properties; the resources are not deleted and recreated.

**When overrides are not provided:** Bicep derives the name from the CAF pattern. If the Bicep-derived name differs from an existing resource's name, ARM creates a **new** resource alongside the old one — it does not rename in place. The old resource must then be deleted manually after the new one is verified.

---

## 3. Note on Terraform

CloudGrange IaC is Bicep-only per ADR-043. Terraform is not used. If an operator has existing Terraform state managing CloudGrange resources, they must import those resources into Bicep management via `az deployment group create --mode Incremental` against the existing RG. Terraform import procedures are outside the scope of this runbook.

---

## 4. Rollback procedure

If a naming migration produces unexpected behavior (wrong names, failed role assignments, broken application configuration):

### 4.1 Verify a backup exists before any destructive action

```powershell
# Confirm an automated PG backup exists before proceeding
az postgres flexible-server backup list \
  --resource-group <rg> \
  --name <pg-server-name> \
  --query "[0].{BackupType:backupType, CompletedTime:completedTime}" \
  --output table
```

Only proceed after confirming a recent backup.

### 4.2 Rollback via parameter revert

```powershell
# Restore the pre-migration parameter file from git
git checkout HEAD~1 -- iac/main.parameters.json

# Re-run provision with the old names
azd provision
```

This re-deploys using the previous parameter values. ARM incremental mode reverts name overrides to the old values.

### 4.3 Full teardown rollback (non-prod only)

For non-production environments where data loss is acceptable:

```powershell
# NEVER run azd down on rg-cloudgrange-dev-cus-001 (live dev) without explicit approval
# Only use on named test RGs: rg-cg-test-*, rg-cloudgrange-onprem-*
azd down --purge --resource-group <test-rg-name>
```

Then re-provision from a clean state using the pre-ADR-048 parameter set.

### 4.4 PG data recovery

If data loss occurred in PostgreSQL, restore from the most recent automated backup:

```
Azure Portal > PostgreSQL Flexible Server > Backups > Restore to point in time
```

Select a restore time before the migration began. The restore creates a new server — after verification, update the `postgresServerName` override in `main.parameters.json` to the restored server's name.

**Always perform a point-in-time backup before any destructive PG operation:**

```powershell
# Trigger a manual on-demand backup before migration
az postgres flexible-server backup create \
  --resource-group <rg> \
  --name <pg-server-name> \
  --backup-name "pre-migration-$(Get-Date -Format 'yyyyMMdd-HHmm')"
```

---

## 5. Zero-downtime migration path for production

Renaming production resources in place is high-risk. The recommended path is blue/green provisioning.

### 5.1 Provision new resources alongside existing (different RG)

```powershell
# Create a parallel prod environment in a new RG with the CAF name
az deployment sub create \
  --location centralus \
  --template-file iac/main.bicep \
  --parameters @iac/main.parameters.json \
               resourceGroupName=rg-cloudgrange-prod-cus-002 \
               instance=002
```

This creates all resources with CAF-pattern names in `rg-cloudgrange-prod-cus-002` alongside the existing `rg-cloudgrange-prod-cus-001`.

### 5.2 Sync PostgreSQL data

Option A — logical replication (minimal downtime, requires PG superuser):

```sql
-- On source server: create a publication
CREATE PUBLICATION cloudgrange_pub FOR ALL TABLES;

-- On target server: create a subscription
CREATE SUBSCRIPTION cloudgrange_sub
  CONNECTION 'host=<old-pg-fqdn> dbname=cloudgrange user=cloudgrange password=<pw>'
  PUBLICATION cloudgrange_pub;
```

Wait for the subscription to reach `consistent snapshot` state. Validate row counts:

```sql
-- On both servers
SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY relname;
```

Option B — pg_dump/restore (downtime required):

```bash
# On a machine with network access to both servers
pg_dump -h <old-pg-fqdn> -U cloudgrange -d cloudgrange -F c -f cloudgrange.dump
pg_restore -h <new-pg-fqdn> -U cloudgrange -d cloudgrange -F c cloudgrange.dump
```

### 5.3 Switch ACA traffic

Update DNS CNAME records (or Azure Traffic Manager if configured) to point to the new ACA environment's default domain:

```powershell
# Get the new portal FQDN
az containerapp show \
  --name ca-cloudgrange-portal-prod-cus-002 \
  --resource-group rg-cloudgrange-prod-cus-002 \
  --query 'properties.configuration.ingress.fqdn' \
  --output tsv
```

Update your DNS provider's CNAME for your custom domain to the new FQDN.

### 5.4 Verify

Run smoke tests against the new environment before decommissioning the old one:

```bash
# Health check
curl -f https://<new-portal-fqdn>/
curl -f https://<new-api-fqdn>/health/ready

# Authenticated smoke test (adjust to your test suite)
# Run: cloudgrange-api integration tests against new environment
```

### 5.5 Decommission old RG

After 24 hours of clean operation with the new environment:

```powershell
# Confirm KV soft-delete is enabled (7-day fallback window for secret recovery)
az keyvault show \
  --name <old-kv-name> \
  --resource-group rg-cloudgrange-prod-cus-001 \
  --query 'properties.enableSoftDelete'

# Delete the old RG (30-second confirmation window)
az group delete \
  --name rg-cloudgrange-prod-cus-001 \
  --yes --no-wait
```

---

## 6. Post-migration verification

Run these checks after any naming migration completes:

```bash
# 1. Bicep lint — must exit 0
az bicep build --stdout iac/main.bicep

# 2. CAF naming lint (runs as part of bicep-lint.yml CI gate)
# Trigger the workflow manually if not on a PR:
gh workflow run bicep-lint.yml

# 3. azd deploy health check
azd deploy
# The postprovision hook polls /health/ready and reports pass/fail.

# 4. Verify alert rules are active
az monitor metrics alert list \
  --resource-group <new-rg-name> \
  --query "[].{Name:name, Enabled:properties.enabled}" \
  --output table

# 5. Verify KV purge protection
az keyvault show \
  --name <new-kv-name> \
  --resource-group <new-rg-name> \
  --query 'properties.enablePurgeProtection'
# Expected: true
```
