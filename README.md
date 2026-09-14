# cloudgrange-deployment-installer

This component follows the single current product baseline. Existing implementation details remain available in the revision-bound historical document. Future development is selected by the canonical module and milestone plan, not the old phase numbers or availability language.

See [current product and release status](https://github.com/CloudGrange/cloudgrange-deployment-installer/blob/main/PRODUCT-STATUS.md). No implementation, runtime test or deployment occurred in this documentation consolidation.

## On-premises container stack (Docker Compose)

Owner decision 2026-09-14: CloudGrange on-premises runs on Docker Compose on one Ubuntu VM. HA comes later through Hyper-V failover clustering. [`compose/docker-compose.yml`](compose/docker-compose.yml) is the source of truth for this list.

| Service | Image | Role |
|---|---|---|
| `cloudgrange-api` | `ghcr.io/cloudgrange/cloudgrange-api` | Platform API (built from cloudgrange-platform-api) |
| `cloudgrange-portal` | `ghcr.io/cloudgrange/cloudgrange-portal` | Web portal (built from cloudgrange-portal) |
| `cloudgrange-relay` | `ghcr.io/cloudgrange/cloudgrange-relay` | Relay for host agents, mTLS (built from cloudgrange-runtime-relay) |
| `nginx` | `nginx:alpine` | TLS ingress on 443 |
| `postgres` | `postgres:17-alpine` | Database and the default PostgreSQL-encrypted secrets provider (ADR-009) |
| `keycloak` | `quay.io/keycloak/keycloak:26.6` | Local identity provider (ADR-008) |
| `otel-collector` | `otel/opentelemetry-collector-contrib` | Telemetry pipeline (ADR-016) |
| `prometheus` | `prom/prometheus` | Metrics |
| `loki` | `grafana/loki` | Logs |
| `grafana` | `grafana/grafana:12.1.1` | Dashboards over Prometheus and Loki |

systemd supervises the stack (`compose/systemd/cloudgrange.service`, ADR-059). OpenBao and Entra ID are optional and not in the default stack. The runtime agent is a Windows host service, not a container, so it is not in this list.

Customer packages are the appliance VHDX, `Install-CloudGrange-Bundled.zip` and `Install-CloudGrange.ps1`. There is no signing yet, so current builds are unsigned test builds. `SHA256SUMS` checks integrity only, not authenticity.

[Historical document at source revision 473b253b01430153557e2e9823aad88a34ad508a](https://github.com/CloudGrange/cloudgrange-deployment-installer/blob/a8e5827e1b955f43d9997aa52f1a60d48f86b6fd/archive/2026-09-07/README.md) preserves earlier commands and rationale for that code revision. It is not current target architecture or release guidance.
