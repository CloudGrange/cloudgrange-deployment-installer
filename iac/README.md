# CloudSmith — Azure PaaS (Model B) Deployment

Infrastructure-as-code for deploying CloudSmith to Azure PaaS using the Azure
Developer CLI (`azd`) + Bicep, per **ADR-043** (deployment mechanism),
**ADR-006** (Azure Container Apps hosting), and **ADR-044** (portal delivered as
an ACA container, not Static Web Apps).

## What gets deployed

| Resource | Purpose |
|---|---|
| Log Analytics workspace | Central logs for the ACA environment |
| Application Insights | API traces/metrics (Azure Monitor replaces Loki/Prometheus on PaaS) |
| User-assigned Managed Identity | Workload identity; granted Key Vault Secrets User |
| Key Vault | Secret storage (RBAC mode) |
| PostgreSQL Flexible Server (B1ms) | `cloudsmith` database |
| Container Apps Environment | Hosts the API and portal container apps |
| `cloudsmith-api` Container App | API host, external ingress :8080, image from ghcr.io |
| `cloudsmith-portal` Container App | Portal nginx image, external ingress :80, image from ghcr.io |

**Auth on PaaS is Entra ID** (per `design/sequence-diagrams/login-oidc-paas.md`),
not Keycloak. Keycloak is the standalone/Model A IdP only.

## Prerequisites

- Azure subscription + Contributor role
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) and [azd](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- An **Entra ID app registration** for the CloudSmith API (SPA + web), with a
  client secret and redirect URIs pointing at the portal/API FQDNs. (Entra app
  registration is a manual prerequisite — there is no first-class Bicep resource
  for it without the Microsoft Graph extension.)
- The container images published to `ghcr.io/cloudsmith-cloud/*`. While they
  remain **private**, supply `GHCR_USERNAME` + `GHCR_TOKEN` (a `read:packages`
  PAT). Once the images are **public** (ADR-046), leave both empty and the
  registry credential block is omitted automatically.

## Deploy

```bash
azd env new cloudsmith-mvp
azd env set ENTRA_TENANT_ID      <tenant-guid>
azd env set ENTRA_CLIENT_ID      <app-client-id>
azd env set ENTRA_CLIENT_SECRET  <secret> --secret
azd env set POSTGRES_ADMIN_PASSWORD <password> --secret
# only while images are private:
azd env set GHCR_USERNAME <github-user>
azd env set GHCR_TOKEN    <read-packages-pat> --secret

azd provision
```

Or with plain Azure CLI (no azd):

```bash
az deployment sub create \
  --location eastus \
  --template-file main.bicep \
  --parameters main.parameters.json \
  --parameters postgresAdminPassword=<pw> entraTenantId=<t> entraClientId=<c> entraClientSecret=<s>
```

The deployment outputs `PORTAL_URL` and `API_URL`.

## Known follow-ups (tracked in ADO)

- **Database migrations** run on API startup (FluentMigrator) against the
  PostgreSQL Flexible Server — AB#1605.
- **Entra ID app registration automation** — currently a manual prerequisite;
  AB#1602.
- **Custom domain + managed TLS** binding on the portal ACA — AB#1606.
- **Internal-only API ingress** behind the portal nginx proxy is the hardened
  posture (ADR-044 open question); MVP uses external ingress for simplicity.
- **Remove GHCR registry credentials** once images are public — AB#1566 / ADR-046.
