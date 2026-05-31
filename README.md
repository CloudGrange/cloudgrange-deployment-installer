# cloudsmith-installer

CloudSmith installer — Hyper-V Ubuntu VM + Docker Compose stack provisioning (Online / Bundled / Appliance modes), plus one-click Azure PaaS deployment.

## Deploy to Azure (PaaS — fastest path)

Click the button below to deploy CloudSmith to Azure Container Apps in your subscription. A friendly wizard guides you through the required settings — no ARM template knowledge needed.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fcloudsmith-cloud%2Fcloudsmith-installer%2Fmain%2Fiac%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fcloudsmith-cloud%2Fcloudsmith-installer%2Fmain%2Fiac%2FcreateUiDefinition.json)

### What the wizard asks for

| Step | Fields |
|---|---|
| **Basics** (Azure standard) | Subscription, Resource Group (new or existing), Region |
| **CloudSmith Settings** | Administrator Password, Environment (dev/test/stage/prod), Container Image Tag, Database Admin Username, Cost Center, Owner Email |
| **Review + Create** | Summary of resources to be created |

### What gets deployed (approx. 15–20 minutes)

| Resource | Purpose |
|---|---|
| Log Analytics Workspace | Central logs for the Container Apps environment |
| Application Insights | API traces and metrics |
| User-Assigned Managed Identity | Workload identity for Key Vault and PostgreSQL access |
| Key Vault | Stores the master encryption key and database password |
| PostgreSQL Flexible Server (B1ms) | `cloudsmith` database |
| Container Apps Environment | Hosts the API and portal |
| CloudSmith API Container App | REST API, external HTTPS ingress |
| CloudSmith Portal Container App | Web portal, external HTTPS ingress |

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
.\Install-CloudSmith.ps1 -Mode Online

# Bundled mode (uses a local bundle directory)
.\Install-CloudSmith.ps1 -Mode Bundled -BundlePath D:\cloudsmith-bundle

# Appliance mode (imports a pre-built VHDX)
.\Install-CloudSmith.ps1 -Mode Appliance -VhdxPath D:\cloudsmith-appliance.vhdx
```

### Update and uninstall

```powershell
# Pull latest images and restart
.\Update-CloudSmith.ps1

# Stop containers, remove VM and VHDX, clean up
.\Uninstall-CloudSmith.ps1
```

---

## PaaS deployment — advanced (azd CLI)

For CI/CD pipelines or operators who prefer the Azure Developer CLI:

```bash
az login
azd env new cloudsmith-prod
azd env set POSTGRES_ADMIN_PASSWORD <password> --secret
azd env set CLOUDSMITH_MASTER_KEY   <base64-aes256-key> --secret
azd provision
```

See [iac/README.md](iac/README.md) for full parameter reference, bring-your-own resource options, and Managed Identity deployment.

---

## Repository structure

```
cloudsmith-installer/
├── Install-CloudSmith.ps1      — main entry point (mode selector)
├── Update-CloudSmith.ps1       — pull images, rolling restart, run migrations
├── Uninstall-CloudSmith.ps1    — stop containers, delete VM/VHDX, cleanup
├── modules/
│   ├── New-CloudSmithVM.ps1    — Hyper-V VM provisioning
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
