# CloudGrange — Azure PaaS (Model B) Deployment

The selected future Azure profile is owner-operated private AKS with managed PostgreSQL, Blob and Key Vault adapters. Existing ACA/Bicep walkthroughs remain historical implementation evidence; this page does not claim AKS scripts exist. Cold relocation needs data/identity/secret transforms and fencing; applying a template is not a state import.

**AB#9188 update (2026-09-16)**: the AKS path now has real code — `charts/cloudgrange` (the same Helm chart as the on-prem K3s path) with a `values-azure.yaml` overlay (AB#9187) using the Secrets Store CSI Driver for Azure Key Vault-backed secrets. See `charts/cloudgrange/values-azure.yaml`'s own header comment for what it assumes is already provisioned. This `iac/` directory (Bicep/ACA) stays supported — AB#9176 fixed its GHCR image-org bug — but is not receiving further feature investment; new Azure work goes into the AKS overlay.

See [current product and release status](https://github.com/CloudGrange/cloudgrange-deployment-installer/blob/main/PRODUCT-STATUS.md). No implementation, runtime test or deployment occurred in this documentation consolidation.

[Historical document at source revision 473b253b01430153557e2e9823aad88a34ad508a](https://github.com/CloudGrange/cloudgrange-deployment-installer/blob/a8e5827e1b955f43d9997aa52f1a60d48f86b6fd/archive/2026-09-07/iac/README.md) preserves earlier commands and rationale for that code revision. It is not current target architecture or release guidance.
