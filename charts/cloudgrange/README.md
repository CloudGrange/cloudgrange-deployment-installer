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
