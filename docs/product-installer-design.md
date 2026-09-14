# CloudGrange product installer design (current path)

**Status:** current, authoritative design for the M0/M1 product installer, per the 2026-09-14
owner/design-lead decision recorded in
[`runtime-and-platform-reset.md`](https://github.com/CloudGrange/cloudgrange-internal/blob/main/pmo/decisions-2026-09-14/runtime-and-platform-reset.md)
(cloudgrange-internal; this link 404s until that PR merges to `main` — expected). For the retained,
not-currently-scheduled RKE2/Kubernetes profile, see
[`docs/future-profiles/rke2-bom-installer-design.md`](future-profiles/rke2-bom-installer-design.md).

## Runtime and HA

On-premises runtime is **Docker Compose on a single Ubuntu VM** (ADR-029). HA is the same appliance
VM run as a **Hyper-V failover-cluster role** (Windows Server Failover Clustering, WSFC, with a
Cluster Shared Volume) — the Compose composition is the clustered resource; Hyper-V handles
live-migration/failover of the whole VM. There is no application-level HA logic, no multi-node
database topology and no orchestrator HA in this profile. Later options, only if this proves
insufficient: a two-VM active/standby Compose option (PostgreSQL streaming replication +
`keepalived`), then the RKE2/Kubernetes future-optional profile above.

## Entry point

The product installer is the root `Install-CloudGrange.ps1` script (built from the legacy
compose-era `Install-/Update-/Uninstall-CloudGrange.ps1` scripts, promoted to the product path by
the 2026-09-14 reset), run on the management Ubuntu VM:

```
sudo pwsh ./Install-CloudGrange.ps1 -Mode Install -SiteConfig /etc/cloudgrange/site-config.json
```

It shares the generic phase/checkpoint/envelope/evidence engine under `installer/` with the
future-optional RKE2 profile — see that document's §3 for the mechanics (on-node layout,
checkpoint chain, atomic writes, resume/refusal rules). The phases it runs bring up the Docker
Compose composition (PostgreSQL 17, local Keycloak, API/Core, portal, gateway) rather than an RKE2/Helm
bring-up. Secrets today: per-install credentials in `/opt/cloudgrange/.env` (root 0600) passed as container
environment, and the API's AES-256-GCM master-key encryption of the identity-provider secrets it stores in
PostgreSQL. The PostgresEncryptedSecretsProvider is the selected target but is not implemented yet (story
S-secrets).

## The three customer packages

All three run the same Compose composition on the target Ubuntu VM:

| Package | Delivery | Mode |
|---|---|---|
| VHDX appliance | A pre-built Hyper-V VHDX with the composition baked in | `Appliance` |
| `Install-CloudGrange-Bundled.zip` | Installed onto an existing Ubuntu VM, offline-capable | `Bundled` |
| `Install-CloudGrange.ps1` (Online) | Installer script that retrieves exact digests over the network | `Online` |

## Signing status

Signing custody (CG-015) is not yet built. Until it exists, release builds are **unsigned test
builds** — the installer's trust-verification step (`cg-trust verify-tree`) is exercised against
test/dev keys only, and no candidate composition should be represented as signed or production-
ready. Signed releases are a future acceptance gate (F01, F12), not the current state.

## What this document does not cover

Detailed phase-by-phase mechanics, the BOM/checkpoint schema, and the retained per-component Helm
chart design are in
[`docs/future-profiles/rke2-bom-installer-design.md`](future-profiles/rke2-bom-installer-design.md).
This document stays short and factual; expand it in place as the Compose-specific phase design is
written, rather than growing the future-profile document further.
