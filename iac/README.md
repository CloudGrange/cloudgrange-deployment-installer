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

### Identity model — Managed Identity first, secret-less target

Two distinct auth planes:

| Plane | Mechanism |
|---|---|
| API → Key Vault | **User-assigned Managed Identity** (Key Vault Secrets User role) — no secret |
| API → PostgreSQL | **User-assigned Managed Identity** — the MI is an Entra administrator of the Flexible Server; the API connects with an MI access token, no DB password (Npgsql password provider fetches an `https://ossrdbms-aad.database.windows.net` token) |
| API → Application Insights | Connection string (instrumentation key is not a secret) |
| **End-user browser sign-in** | Configured **POST-DEPLOY** in platform identity settings (`/identity/v1/idp`), stored in the Config Registry. The platform is **IdP-agnostic** at deploy time. |

### Identity provider is a post-deploy SETTING, not a deploy parameter

The identity provider — **Entra ID, on-premises Active Directory, Keycloak, or
generic OIDC** — is **not** configured by this Bicep. It is configured *inside
the running platform* via the identity settings (`/identity/v1/idp` API + UI),
exactly like any other platform setting, and persisted in the Config Registry.

Deploy flow:
1. `azd provision` stands up the platform (no IdP required).
2. The API issues a **bootstrap admin token** on first run (printed to logs).
3. The admin logs in with the bootstrap token and configures their identity
   provider(s) in **Settings → Identity Providers**.
4. Subsequent logins use the configured IdP.

The `entra*` parameters below are an **optional** convenience to pre-seed an
Entra OIDC provider at deploy time; leave them empty for the normal
configure-in-settings flow. When pre-seeding, prefer a **federated credential
to the Managed Identity** over a client secret.

> **Note:** end-user sign-in always requires *some* IdP that can authenticate
> humans (Entra ID, AD, Keycloak, OIDC). Managed Identity authenticates
> *services* (API→Key Vault, API→PostgreSQL), never interactive human logins —
> those are two different planes.

Net target: **zero stored secrets** — Key Vault and PostgreSQL via MI, and the
app registration credential via workload identity federation. The PostgreSQL
admin password remains only as break-glass; set `passwordAuth: 'Disabled'` on
the server for Entra-only once the API's MI DB connection is verified
(API code follow-up — AB#1605).

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
