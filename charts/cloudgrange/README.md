# cloudgrange (umbrella Helm chart)

AB#9171/9177. Replaces the Compose stack's `docker compose up` with `helm install`/`helm
upgrade` — same services, same images (`ghcr.io/cloudgrange/*`), different runtime (K3s
instead of Docker Compose).

## Subcharts

`api`, `portal`, `relay`, `postgres`, `keycloak`, `observability` (OTel collector +
Prometheus + Loki + Grafana, ADR-016) — plain subdirectories under `charts/`, no
`helm dependency build` step needed.

## Install sequence

cert-manager (AB#9179) must be installed as its OWN, separate Helm release, BEFORE this
chart — a real k3d install proved Helm can't validate our own `ClusterIssuer`/`Certificate`
resources in the same install as a subchart that introduces those CRDs ("ensure CRDs are
installed first"), which is cert-manager's own standard documented pattern regardless.
The chart is vendored at `charts/vendor/cert-manager-v1.21.2.tgz` — no internet access
needed at install time.

```bash
helm install cert-manager charts/vendor/cert-manager-v1.21.2.tgz \
  --set crds.enabled=true --namespace cert-manager --create-namespace --wait
helm install cloudgrange charts/cloudgrange -f charts/cloudgrange/values-single-node.yaml --wait
```

**On `values-multi-node.yaml` (AB#9190)**: CloudNativePG (the HA Postgres operator) needs
the same separate-release-first treatment, for the same CRD-validation reason:

```bash
helm install cnpg charts/vendor/cloudnative-pg-0.29.0.tgz --namespace cnpg-system --create-namespace --wait
helm install cert-manager charts/vendor/cert-manager-v1.21.2.tgz \
  --set crds.enabled=true --namespace cert-manager --create-namespace --wait
helm install cloudgrange charts/cloudgrange -f charts/cloudgrange/values-multi-node.yaml --wait
```

**MetalLB (AB#9191, bare-metal on-prem only — skip entirely on AKS, which has its own
native LoadBalancer)**: needed once there's more than one node for the relay's
`LoadBalancer` Service (`charts/relay/values.yaml`) to resolve to a real routable address
instead of staying `Pending`. Same separate-release-first pattern as cert-manager/CNPG —
MetalLB ships its own CRDs (`IPAddressPool`, `L2Advertisement`) that this chart's own
`templates/metallb.yaml` config depends on:

```bash
helm install metallb charts/vendor/metallb-0.16.1.tgz --namespace metallb-system --create-namespace --wait
helm install cloudgrange charts/cloudgrange -f charts/cloudgrange/values-multi-node.yaml \
  --set metallb.enabled=true \
  --set metallb.addressPool='{192.168.1.240-192.168.1.250}' \
  --wait
```

`metallb.addressPool` is a customer-specific LAN address range with no safe generic
default (it must be free/unused addresses on the customer's own network) — leave
`metallb.enabled=false` (the default in every profile) until the customer's network team
supplies a real range. Without it the relay's Service simply stays `Pending`, which is
the existing documented single-node behavior — nothing breaks, the relay is still
reachable from inside the cluster.

## Profiles

```
helm install cloudgrange . -f values-single-node.yaml
```

- `values-single-node.yaml` — the only currently fully-deployable profile. One K3s node,
  Postgres as a single-Pod StatefulSet, no Redis.
- `values-multi-node.yaml` — skeleton only. Real multi-replica/HA support (Redis dispatch
  bus, CloudNativePG-backed Postgres) is AB#9190.
- `values-azure.yaml` — skeleton only. Real AKS overlay (Azure Disk/Files CSI, Key Vault
  CSI) is AB#9187.

## Secrets

`templates/secrets.yaml` is a **temporary** placeholder Secret populated from
`--set`/values at install time. AB#9178 replaces it with an idempotent pre-install hook
Job that generates these server-side if they don't already exist — do not commit real
secret values into any values file in the meantime.

## Migrations

Each API pod runs FluentMigrator at its own startup, serialized by a Postgres session
advisory lock (`RunMigrationsWithAdvisoryLock` in `Program.cs`, AB#9175) — **not** a
pre-install/pre-upgrade hook Job. A real k3d install proved a hook Job doesn't work here:
Helm runs every pre-install hook before any normal chart resource, so a hook Job would
race against both the shared Secret and the Postgres StatefulSet not existing yet on a
fresh install. The advisory lock is what actually makes concurrent-pod migrations
race-safe; see the comment at the top of `charts/api/templates/deployment.yaml`.

## Install qualification (AB#9182)

`scripts/Install-CloudGrangeK3s.sh` is the qualification-gate installer: it wraps the
two-step sequence above in a resumable, checkpointed process. Each named stage
(`prereqs-checked` → `k3s-installed` → `certmanager-installed` → `chart-installed` →
`ready`) is recorded to a JSON state file (`$CLOUDGRANGE_INSTALL_STATE`, default
`/opt/cloudgrange/.install-state.json`) only AFTER it actually succeeds — an
interrupted run (Ctrl-C, crash, network drop) simply re-runs from the first incomplete
stage on the next invocation, never redoing completed work or trusting a partial write.
Real interrupt-and-resume testing (kill the process mid-`k3s-installed`, confirm resume
correctly skips the completed stages and retries only the interrupted one) is how two
real bugs were caught before this ever ships: a `stage_done` check that never matched
Python's indented JSON output, and a `helm install` that left a failed release blocking
every subsequent retry with "name already in use" — fixed by using
`helm upgrade --install` everywhere, which is idempotent regardless of prior state.

`scripts/New-ArtifactManifest.sh` produces a plain SHA-256 digest manifest
(`charts/manifest.json`) for the vendored artifacts and the chart's own tracked
contents — a hash-verified bundle, not a cryptographically signed one (signing needs
key-management infrastructure this product doesn't have; a hash check answers "did the
right bytes arrive" without that cost). Confirmed reproducible: re-running it twice on
an unchanged tree produces identical digests.

## Uninstall / retention

`helm uninstall cloudgrange` removes the release's Deployments/Services/Secret/etc. but
**leaves PersistentVolumeClaims behind** — this is Kubernetes' own default behavior
(PVCs are never owned by a Helm release's garbage collection), matching how Postgres,
Keycloak, Grafana, Prometheus and Loki data already survives a Compose `docker compose
down` today. This is intentional, not an oversight — it means an accidental
`helm uninstall` doesn't silently destroy customer data.

For a full purge (e.g. decommissioning an appliance for good), delete the PVCs
explicitly and separately:

```bash
kubectl delete pvc -l app.kubernetes.io/part-of=cloudgrange
```

## Not yet wired up (separate ADO items)

- Ingress routing via Traefik (AB#9180) — `cg-tls` (the cert-manager-issued Secret) is ready for an Ingress to reference once this lands
- MetalLB for the relay's on-prem `LoadBalancer` Service (AB#9191)
- Local verification gate script (`helm lint`/`template`/real K3s smoke install) — AB#9181

## Verifying locally

```bash
helm lint cloudgrange -f cloudgrange/values-single-node.yaml
helm template cloudgrange cloudgrange -f cloudgrange/values-single-node.yaml --set secrets.postgresPassword=x
# Real cluster (k3d, K3s-in-Docker):
k3d cluster create cgtest --wait
helm install cg cloudgrange -f cloudgrange/values-single-node.yaml --set secrets.postgresPassword=x --set secrets.relayEnrollmentToken=x
kubectl get pods -w
```
