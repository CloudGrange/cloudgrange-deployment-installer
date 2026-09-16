# cloudgrange-deployment-installer

This component follows the single current product baseline. Existing implementation details remain available in the revision-bound historical document. Future development is selected by the canonical module and milestone plan, not the old phase numbers or availability language.

See [current product and release status](https://github.com/CloudGrange/cloudgrange-deployment-installer/blob/main/PRODUCT-STATUS.md). No implementation, runtime test or deployment occurred in this documentation consolidation.

## On-premises container stack (Docker Compose)

Owner decision 2026-09-14: CloudGrange on-premises runs on Docker Compose on one Ubuntu VM. HA comes later through Hyper-V failover clustering. [`compose/docker-compose.yml`](compose/docker-compose.yml) is the source of truth for this list.

Every image is pinned by `@sha256` digest, and a release bundle refuses to build otherwise (`scripts/Test-ComposeImagePins.sh`). The tags below are informational; the digests in compose are authoritative. First-party images are stamped as `<repo>:<release version>@sha256:<digest>` when the bundle is built (`scripts/Set-FirstPartyImagePins.sh`).

| Service | Image (tag) | Host ports | Role |
|---|---|---|---|
| `nginx` | `nginx:1.31.5-alpine` | **443** (TLS), **80** (redirect to 443), **8443** (TLS, agent API only) | The only published entry point. On 443: portal, API (`/api/`, `/health/`) and the `cloudgrange` Keycloak realm (`/realms/cloudgrange/`). On 8443: only the relay's agent routes (`/lan/v1/agents/`) |
| `cloudgrange-api` | `ghcr.io/cloudgrange/cloudgrange-api:<version>` | none | Platform API (built from cloudgrange-platform-api) |
| `cloudgrange-portal` | `ghcr.io/cloudgrange/cloudgrange-portal:<version>` | none | Web portal (built from cloudgrange-portal) |
| `cloudgrange-relay` | `ghcr.io/cloudgrange/cloudgrange-relay:<version>` | none (agents use nginx 8443) | Relay for host agents. Its own listener is plain HTTP and internal; agents reach `/lan/v1/agents/` through nginx TLS on 8443. Agent mTLS is planned, not implemented: enrollment uses the relay enrollment token |
| `postgres` | `postgres:17.11-alpine` | none | Platform database. The API stores identity-provider client secrets here, AES-256-GCM-encrypted with its master key (`/etc/cloudgrange/secrets.key`). The PostgresEncryptedSecretsProvider (ADR-009) is not implemented yet (story S-secrets) |
| `keycloak` | `quay.io/keycloak/keycloak:26.6.4` | none | Local identity provider (ADR-008). The master realm and admin console are not published |
| `otel-collector` | `otel/opentelemetry-collector-contrib:0.160.0` | none | Telemetry pipeline (ADR-016) |
| `prometheus` | `prom/prometheus:v3.14.0` | none | Metrics |
| `loki` | `grafana/loki:3.7.7` | none | Logs |
| `grafana` | `grafana/grafana:12.1.1` | none | Dashboards over Prometheus and Loki |

systemd supervises the stack (`compose/systemd/cloudgrange.service`, ADR-059). Stack credentials are generated per install into `/opt/cloudgrange/.env` (root 0600, root-owned directory) and passed to containers as environment variables. OpenBao and Entra ID are optional and not in the default stack. The runtime agent is a Windows host service, not a container, so it is not in this list.

The realm import creates no users. `compose/systemd/cloudgrange-realm-admin.service` creates `admin@cloudgrange.local` (PlatformAdmin) with a random, temporary password (`CLOUDGRANGE_REALM_ADMIN_PASSWORD` in `/opt/cloudgrange/.env`). The portal client accepts redirects only to `https://<CLOUDGRANGE_HOSTNAME>/*`.

Customer packages are the appliance VHDX, `Install-CloudGrange-Bundled.zip` and `Install-CloudGrange.ps1`. There is no signing yet, so current builds are unsigned test builds. `SHA256SUMS` checks integrity only, not authenticity.

## Standalone relay installer (additional sites) — AB#9196

The core install (VHDX or bundled ZIP) bundles one relay. To connect a second site — a branch
office, another datacenter, an edge location — install just the relay on a Linux or Windows
Docker host there and enroll it against the existing core, without reinstalling the rest of the
stack.

**Normal path:** in the portal, go to **Sites & Relays** (`/resources`), click **Add a site**,
then open the new site's page. It generates a one-hour enrollment token and a ready-to-run
install command — copy it and run it on the target host. The page polls and shows the relay as
connected once it enrolls.

**Manual path**, if you're not using the portal wizard: issue a token yourself
(`POST /api/v1/relays/enroll-token`, `platform:write`) and run the installer directly.

```bash
# Linux
curl -sSL https://raw.githubusercontent.com/CloudGrange/cloudgrange-deployment-installer/main/scripts/install-relay.sh \
  | bash -s -- --api-url https://your-core-host --api-key <TOKEN> --site-id <SITE-ID>
```

```powershell
# Windows (Docker Desktop)
irm https://raw.githubusercontent.com/CloudGrange/cloudgrange-deployment-installer/main/scripts/install-relay.ps1 -OutFile install-relay.ps1
.\install-relay.ps1 -ApiUrl https://your-core-host -ApiKey <TOKEN> -SiteId <SITE-ID>
```

Both scripts ([`scripts/install-relay.sh`](scripts/install-relay.sh), [`scripts/install-relay.ps1`](scripts/install-relay.ps1))
run only the relay container (`ghcr.io/cloudgrange/cloudgrange-relay`), point it at the core API,
and persist its enrolled identity in a `cloudgrange-relay-identity` Docker volume so a container
restart doesn't force re-enrollment. Uninstall with the matching `uninstall-relay.sh` /
`uninstall-relay.ps1`.

[Historical document at source revision 473b253b01430153557e2e9823aad88a34ad508a](https://github.com/CloudGrange/cloudgrange-deployment-installer/blob/a8e5827e1b955f43d9997aa52f1a60d48f86b6fd/archive/2026-09-07/README.md) preserves earlier commands and rationale for that code revision. It is not current target architecture or release guidance.
