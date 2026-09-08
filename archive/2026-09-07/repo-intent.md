# Repo intent — cloudgrange-deployment-installer

**CloudGrange installer — Hyper-V Ubuntu VM + Docker Compose stack provisioning (Online / Bundled / Appliance modes), plus one-click Azure PaaS deployment.**

## What this repo is

The installer for standalone CloudGrange deployments: provisions a Hyper-V
Ubuntu VM running a Docker Compose stack, in three modes (Online / Bundled /
Appliance), plus a one-click "Deploy to Azure" path straight to Azure Container
Apps via an ARM template wizard (no ARM knowledge required — Administrator
Password, Environment dev/test/stage/prod, Container Image Tag, etc.).

## Shape

- `Install-CloudGrange.ps1`, `Install-CloudGrange-WSL2.ps1`,
  `Uninstall-CloudGrange.ps1`, `Update-CloudGrange.ps1` — the operator-facing
  lifecycle scripts
- `Build-CloudGrangeAppliance.ps1`, `Import-CloudGrangeAppliance.ps1`,
  `New-CloudGrangeBundle.ps1` — appliance/bundle build tooling
- `iac/azuredeploy*.json` — the ARM templates behind the "Deploy to Azure" button
- `compose/` — the Docker Compose stack definition
- `cloudgrange-signing-key.pub`, `New-InstallerHash.ps1`, `verify-bundle.ps1` —
  installer integrity verification

## How it relates to other repos

- Deploys **`cloudgrange-platform-api`**, **`cloudgrange-portal`**, and their
  dependencies as a packaged stack — this repo doesn't contain that application
  code itself

## Status

Active — the primary installer for standalone/appliance deployments.
