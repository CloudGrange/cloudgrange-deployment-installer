# CloudGrange product status

Product planning authority: [canonical CloudGrange package](https://github.com/CloudGrange/cloudgrange-internal/blob/main/pmo/decisions-2026-09-07/README.md) (internal maintainer planning). The public summary below is derived from that baseline; it is not a second roadmap. Public source/build documentation remains usable without private planning or ADO access.

CloudGrange is one open-source infrastructure management product. The first planned product release installs a local control plane, discovers existing clusters/VMs and safely manages existing workloads through the portal, CLI and PowerShell. The selected first writable qualification target is Windows Server2025 Hyper-V on WSFC. No passing qualification or new release is claimed by this documentation change.

Foundation work is an internal checkpoint. VM creation from verified local images and basic health/evidence collection follow the first release. Production HA and disconnected packaging, specialist lifecycle modules, owner-operated Azure hosting and read-only federation are later separately qualified outcomes. No calendar delivery promise is made by one maintainer assisted by AI.

Selected target (2026-09-14 reset, [`runtime-and-platform-reset.md`](https://github.com/CloudGrange/cloudgrange-internal/blob/main/pmo/decisions-2026-09-14/runtime-and-platform-reset.md)): Docker Compose on a single Ubuntu VM on premises, PostgreSQL17, local Keycloak and PostgresEncryptedSecretsProvider (a target, not implemented yet: story S-secrets; OpenBao optional hardening); trusted signed modules with controlled host restart and compatible portal bundles. HA is the appliance VM run as a Hyper-V failover-cluster role (WSFC+CSV), no app change. Azure hosting targets Azure Container Apps and managed service adapters, deferred past M0/M1. Federation preserves each instance's local execution and secret authority. RKE2/AKS remain a future optional profile if the two-VM Compose HA option also proves insufficient.

Public first-party code follows Apache2 with DCO contributions; public documentation follows CC BY4. Private planning is excluded. Exact source/license/provenance and release artifacts must be verified before distribution. No present paid service, billing, license server, mandatory cloud telemetry, LTS or response-time SLA is promised.

Supported releases are identified by a tested signed composition and published limits. Maintain the current minor's latest patch; the previous minor receives critical security/data-loss fixes on a best-effort basis for90days after its successor, or upstream support end if earlier. Older releases are historical/unsupported. No current artifact is certified merely because an older README says it is.

Use version-specific release notes and build instructions for actual existing code. Historical documents are preserved under archive/2026-09-07 and cannot override the current planning baseline.
