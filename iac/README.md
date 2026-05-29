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

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) and [azd](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- The container images published to `ghcr.io/cloudsmith-cloud/*`. While they
  remain **private**, supply `GHCR_USERNAME` + `GHCR_TOKEN` (a `read:packages`
  PAT). Once the images are **public** (ADR-046), leave both empty and the
  registry credential block is omitted automatically.

## Deployment Authentication

Two deployment authentication methods are supported. Choose the one that fits
your environment.

### Option A — Interactive (personal Azure account)

The deploying user authenticates with their own Azure account. Recommended for
first-time setup and individual operator deploys.

```bash
az login
azd up
```

**Required permissions on the target Azure subscription:**

- **Contributor** — creates all resources (resource group, ACA, Key Vault,
  PostgreSQL, etc.)
- **Role Based Access Control Administrator** — assigns built-in roles to the
  CloudSmith workload managed identity (Key Vault Secrets Officer, Monitoring
  Metrics Publisher)
- **Owner** covers both; either combination works.

No Azure Active Directory / Entra ID directory roles are required. No service
principal or app registration is needed to deploy the platform.

### Option B — Pre-provisioned Managed Identity (enterprise / CI-CD)

A privileged administrator creates a User-Assigned Managed Identity (UAMI) once
and assigns it the required subscription roles. Operators then deploy from any
Azure resource that has the UAMI attached — no personal subscription-level
rights are needed at deploy time.

The deployment UAMI is **separate** from the workload UAMI that the ACA apps use
at runtime (API → Key Vault, API → PostgreSQL). The workload UAMI is always
created by the Bicep templates. The deployment UAMI is pre-created by an admin
and never modified by CloudSmith.

**One-time admin setup (run as Owner or User Access Admin):**

```bash
# Create the deployment identity
az identity create \
  --name id-cloudsmith-deploy \
  --resource-group rg-your-platform \
  --location eastus

MI_PRINCIPAL=$(az identity show \
  --name id-cloudsmith-deploy \
  --resource-group rg-your-platform \
  --query principalId -o tsv)

SUB_ID=$(az account show --query id -o tsv)

# Assign required roles on the target subscription
az role assignment create \
  --assignee "$MI_PRINCIPAL" \
  --role "Contributor" \
  --scope "/subscriptions/$SUB_ID"

az role assignment create \
  --assignee "$MI_PRINCIPAL" \
  --role "Role Based Access Control Administrator" \
  --scope "/subscriptions/$SUB_ID"
```

**Deploy (as any operator):**

Deploy from a resource that has the UAMI attached. `azd` picks up the identity
automatically via DefaultAzureCredential — no `az login` required.

| Deploy surface | How the UAMI is attached |
|---|---|
| Azure Cloud Shell | Attach the UAMI to your Cloud Shell storage account's identity |
| Azure VM / VMSS | Assign the UAMI to the VM at creation or via `az vm identity assign` |
| GitHub Actions | Workload Identity Federation — federate the UAMI to the GitHub Actions OIDC token |
| Azure DevOps | Workload Identity Federation — federate the UAMI to the ADO service connection OIDC token |

For GitHub Actions / Azure DevOps pipelines using Workload Identity Federation:

```bash
azd auth login --federated-credential-provider github   # GitHub Actions
azd auth login --federated-credential-provider azuredevops  # Azure DevOps
azd up
```

**Record the deployment identity in your parameters file:**

Uncomment and populate the `deploymentManagedIdentityId` field in
`main.parameters.json` to record which UAMI is authorised for this deployment.
This field has no effect on provisioned resources — it serves as operational
documentation and a reference for audit tooling.

```json
"deploymentManagedIdentityId": {
  "value": "/subscriptions/<sub-id>/resourceGroups/rg-your-platform/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-cloudsmith-deploy"
}
```

## Deploy

```bash
az login                   # or: azd auth login
azd env new cloudsmith-mvp
azd env set POSTGRES_ADMIN_PASSWORD <password> --secret
azd env set CLOUDSMITH_MASTER_KEY   <base64-aes256-key> --secret
# Only required while images are private (until ADR-046 public flip):
azd env set GHCR_USERNAME <github-user>
azd env set GHCR_TOKEN    <read-packages-pat> --secret

azd provision
```

No `ENTRA_TENANT_ID`, `ENTRA_CLIENT_ID`, or `ENTRA_CLIENT_SECRET` are required
for deployment. The platform starts in local-authentication mode and you
configure identity providers post-deploy through **Settings → Identity
Providers** (see identity model section below).

Or with plain Azure CLI (no azd):

```bash
az deployment sub create \
  --location eastus \
  --template-file iac/main.bicep \
  --parameters @iac/main.parameters.json \
  --parameters postgresAdminPassword=<pw> masterKey=<base64-key>
```

The deployment outputs `PORTAL_URL` and `API_URL`.

### Entra SSO (optional — post-deploy)

Configuring Entra SSO requires an **App Registration** in your Azure AD tenant
with redirect URIs pointing at the portal and API FQDNs. This is **only needed
if you want operators to log into the CloudSmith portal using their corporate
Entra credentials**. If you skip this, the portal uses local username/password
authentication (ADR-047 first-run wizard).

To pre-seed Entra at deploy time instead of post-deploy configuration, set the
optional parameters:

```bash
azd env set ENTRA_TENANT_ID     <tenant-guid>
azd env set ENTRA_CLIENT_ID     <app-client-id>
azd env set ENTRA_CLIENT_SECRET <secret> --secret
```

These parameters are optional and default to empty. The managed identity used
for Azure resource access (Key Vault, PostgreSQL, ACA self-management) is
separate from the Entra app registration used for end-user login — the former
is created automatically by Bicep and requires no manual steps.

## Known follow-ups (tracked in ADO)

- **Database migrations** run on API startup (FluentMigrator) against the
  PostgreSQL Flexible Server — AB#1605.
- **Entra ID app registration automation** — currently a manual prerequisite;
  AB#1602.
- **Custom domain + managed TLS** binding on the portal ACA — AB#1606.
- **Internal-only API ingress** behind the portal nginx proxy is the hardened
  posture (ADR-044 open question); MVP uses external ingress for simplicity.
- **Remove GHCR registry credentials** once images are public — AB#1566 / ADR-046.
