# cloudgrange-installer

CloudGrange installer — Hyper-V Ubuntu VM + Docker Compose stack provisioning (Online / Bundled / Appliance modes), plus one-click Azure PaaS deployment.

## Deploy to Azure (PaaS — fastest path)

Click the button below to deploy CloudGrange to Azure Container Apps in your subscription. A friendly wizard guides you through the required settings — no ARM template knowledge needed.

[![Deploy to Azure](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg?sanitize=true)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fcloudgrange-cloud%2Fcloudgrange-installer%2Fmain%2Fiac%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fcloudgrange-cloud%2Fcloudgrange-installer%2Fmain%2Fiac%2FcreateUiDefinition.json)

### What the wizard asks for

| Step | Fields |
|---|---|
| **Basics** (Azure standard) | Subscription, Resource Group (new or existing), Region |
| **CloudGrange Settings** | Administrator Password, Environment (dev/test/stage/prod), Container Image Tag, Database Admin Username, Cost Center, Owner Email |
| **Review + Create** | Summary of resources to be created |

### What gets deployed (approx. 15–20 minutes)

| Resource | Purpose |
|---|---|
| Log Analytics Workspace | Central logs for the Container Apps environment |
| Application Insights | API traces and metrics |
| User-Assigned Managed Identity | Workload identity for Key Vault and PostgreSQL access |
| Key Vault | Stores the master encryption key and database password |
| PostgreSQL Flexible Server (B1ms) | `cloudgrange` database |
| Container Apps Environment | Hosts the API and portal |
| CloudGrange API Container App | REST API, external HTTPS ingress |
| CloudGrange Portal Container App | Web portal, external HTTPS ingress |

### After deployment

1. Open the **Outputs** tab of the deployment in the Azure portal — it shows:
   - **portalUrl** — open this in your browser
   - **apiUrl** — REST API base URL
   - **adminUsername** — the administrator username to use at first login
2. Navigate to `portalUrl` and complete the first-run setup wizard.
3. Sign in with `adminUsername` and the password you set during deployment.

---

## On-premises deployment (Hyper-V)

Three modes — choose based on your environment:

| Mode | How | When to use |
|---|---|---|
| **Appliance** | Pre-built VHDX imported to Hyper-V host | Fastest — portal live in ~3 minutes |
| **Compose** | Docker Compose stack inside a new Hyper-V VM | Full installer; standard on-prem path |
| **WSL2** | Docker Compose inside WSL2 | Dev/lab only — no Hyper-V required |

### Prerequisites

- Windows Server 2022/2025 or Windows 11 with Hyper-V enabled
- PowerShell 7 (`pwsh`)
- Internet access (Online mode) or pre-downloaded bundle (Bundled/Appliance mode)

### Quick start

```powershell
# Online mode (downloads images at install time)
.\Install-CloudGrange.ps1 -Mode Online

# Bundled mode (uses a local bundle directory)
.\Install-CloudGrange.ps1 -Mode Bundled -BundlePath D:\cloudgrange-bundle

# Appliance mode (imports a pre-built VHDX)
.\Install-CloudGrange.ps1 -Mode Appliance -VhdxPath D:\cloudgrange-appliance.vhdx
```

### Update and uninstall

```powershell
# Pull latest images and restart
.\Update-CloudGrange.ps1

# Stop containers, remove VM and VHDX, clean up
.\Uninstall-CloudGrange.ps1
```

---

## Relay agent

The CloudGrange relay agent runs as a Docker container on any Linux or Windows host and connects your on-premises infrastructure to the CloudGrange portal.

### Linux (one-liner)

```bash
curl -sSL https://raw.githubusercontent.com/cloudgrange-cloud/cloudgrange-installer/main/scripts/install-relay.sh \
  | bash -s -- --api-url <URL> --api-key <KEY> --site-id <SITE-ID>
```

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/cloudgrange-cloud/cloudgrange-installer/main/scripts/install-relay.ps1 `
  | iex  # then supply parameters interactively, or:

.\scripts\install-relay.ps1 -ApiUrl <URL> -ApiKey <KEY> -SiteId <SITE-ID>
```

### Parameters

| Parameter | Description |
|---|---|
| `--api-url` / `-ApiUrl` | CloudGrange API base URL (from the portal Settings page) |
| `--api-key` / `-ApiKey` | Site API key (from the portal Settings page) |
| `--site-id` / `-SiteId` | Site identifier shown in the portal |
| `--version` / `-Version` | Container image tag (optional — defaults to latest release) |

### Uninstall

```bash
# Linux
curl -sSL https://raw.githubusercontent.com/cloudgrange-cloud/cloudgrange-installer/main/scripts/uninstall-relay.sh | bash

# Windows
.\scripts\uninstall-relay.ps1
```

---

## PaaS deployment — advanced (azd CLI)

For CI/CD pipelines or operators who prefer the Azure Developer CLI:

```bash
az login
azd env new cloudgrange-prod
azd env set POSTGRES_ADMIN_PASSWORD <password> --secret
azd env set CLOUDGRANGE_MASTER_KEY   <base64-aes256-key> --secret
azd provision
```

See [iac/README.md](iac/README.md) for full parameter reference, bring-your-own resource options, and Managed Identity deployment.

---

## Repository structure

```
cloudgrange-installer/
├── Install-CloudGrange.ps1      — main entry point (mode selector)
├── Update-CloudGrange.ps1       — pull images, rolling restart, run migrations
├── Uninstall-CloudGrange.ps1    — stop containers, delete VM/VHDX, cleanup
├── modules/
│   ├── New-CloudGrangeVM.ps1    — Hyper-V VM provisioning
│   ├── Install-DockerCe.ps1    — Docker CE install inside VM
│   ├── Install-Appliance.ps1   — VHDX import + start (appliance mode)
│   └── Install-WSL2.ps1        — WSL2 fallback path
├── docker-compose.yml          — services: api, portal, postgres, keycloak, nginx, loki, grafana
└── iac/                        — Bicep + ARM templates for PaaS (Model B) deployment
    ├── azuredeploy.json        — Deploy to Azure ARM template (resource group scoped)
    ├── createUiDefinition.json — Deploy to Azure wizard definition
    ├── main.bicep              — Full subscription-scoped Bicep (azd / az CLI path)
    └── README.md               — Full PaaS parameter reference
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
