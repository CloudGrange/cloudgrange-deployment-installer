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

## Backup / disaster recovery (AB#9192)

**HA is not DR.** `values-multi-node.yaml` (AB#9190) protects against a single node or
component failing — it does not protect against the whole site/VM/host being lost. That
needs backups that exist somewhere other than the primary install, which is what this
section covers. Two independent, complementary mechanisms, both off by default (no safe
generic backup-target default — this is a real customer-network decision, same as
`metallb.addressPool` above):

1. **Velero** (whole-namespace, cluster state + PVCs) — a SEPARATE Helm release, same
   CRD-ordering pattern as cert-manager/CNPG/MetalLB. It ships CRDs
   (`Backup`/`Restore`/`Schedule`/`BackupStorageLocation`) our own `Schedule` resource
   (`templates/velero-schedule.yaml`, gated by `backup.enabled`) depends on:

   ```bash
   # velero-credentials is an AWS-style credentials file (INI format, "default" profile) —
   # works for real AWS S3 or any S3-compatible target (MinIO, an on-prem NAS with an S3
   # gateway, Azure Blob via its S3-compatible API). No safe generic value; customer- or
   # install-time-supplied.
   kubectl create secret generic velero-credentials -n velero --create-namespace \
     --from-file=cloud=/path/to/credentials-file
   helm install velero charts/vendor/velero-12.2.0.tgz --namespace velero \
     --set-file credentials.secretContents.cloud=/path/to/credentials-file \
     --set configuration.backupStorageLocation[0].name=default \
     --set configuration.backupStorageLocation[0].provider=aws \
     --set configuration.backupStorageLocation[0].bucket=<bucket-name> \
     --set configuration.backupStorageLocation[0].config.region=<region-or-any-string-for-non-AWS> \
     --set configuration.backupStorageLocation[0].config.s3Url=<https://s3-endpoint-for-non-AWS> \
     --set deployNodeAgent=true \
     --wait
   helm install cloudgrange charts/cloudgrange -f charts/cloudgrange/values-single-node.yaml \
     --set backup.enabled=true \
     --wait
   ```

2. **Postgres WAL-archiving/backup** (multi-node/ha profile only, CloudNativePG's own
   built-in Barman Cloud integration — `spec.backup.barmanObjectStore` on the `Cluster` CR
   plus a `ScheduledBackup` CR, both in `charts/postgres/templates/cluster.yaml`, gated by
   `postgres.backup.enabled`). A second, *independent* recovery path per the plan: WAL-based
   point-in-time recovery is materially better than restoring a Velero volume snapshot for
   database-corruption scenarios. **Correction to the original plan doc**: it named
   pgBackRest as CNPG's mechanism — CNPG has never shipped that; its actual built-in
   integration is Barman Cloud, which is what this chart uses. Configure via
   `postgres.backup.{destinationPath,endpointURL,credentialsSecretName,schedule}` and a
   Secret (`ACCESS_KEY_ID`/`ACCESS_SECRET_KEY` keys) the customer's S3-compatible target
   requires — can point at the same target as Velero above, or a different one.

**Appliance/VHDX customers who don't set up a backup target**: fall back to documenting
Hyper-V-level VM export/checkpoint as the minimum viable DR story — protects against host
failure only, not data corruption or accidental in-app deletion. Do not promise RPO/RTO
numbers without a real, measured recovery drill (AB#9193) — restoring an untested backup
is not the same as having a working one.

### Recovery runbook (AB#9193 — real drill results)

A real recovery drill was run twice (fresh k3d cluster, MinIO standing in for the
customer's S3 target): `helm uninstall` to simulate loss, `velero restore create
--from-backup <name>`, confirmed reaching `phase: Completed` with all items restored,
confirmed the restored Postgres data is genuinely intact (a real `psql` query against the
restored database returned the correct row count both times, not just "the Restore object
says Completed").

**One real, reproducible gap found and its fix**: after the `Restore` reaches
`Completed`, `cg-postgres-0` (single-node profile only — not the multi-node/CNPG path,
which doesn't use Velero fs-backup for Postgres at all, see the "Postgres WAL-archiving"
section above) hangs at `Init:0/1` — Velero's restore-wait init container can't read its
own `.velero` completion marker (`permission denied`) under a non-root pod. The actual
PVC data restore itself is unaffected and already complete by this point. Fix:

```bash
kubectl delete pod <release>-postgres-0
```

The StatefulSet recreates the pod without the one-time restore-wait injection, mounting
the already-restored volume normally — comes up Ready within seconds. This is a known
class of Velero fs-backup limitation with non-root workloads, not specific to this chart;
`fsGroup` (the standard documented Velero fix) is set on the pod but did not resolve this
specific symptom in real testing — kept anyway as correct volume ownership practice.

**What this drill does and does not prove**: proves the whole mechanism — backup,
storage-target upload, restore, and real data integrity — works end to end on a real
cluster with a real (if disclosed as non-production) S3-compatible target. Does NOT
prove: recovery into a genuinely separate fresh cluster (this drill restored into the
same cluster after simulated loss, which validates the restore mechanism itself but not
cross-cluster portability), a real customer S3-compatible target (MinIO/NAS/cloud
bucket) instead of the in-cluster stand-in used here, or RTO/RPO numbers under real data
volumes — do not promise specific figures to customers without measuring against a
representative real dataset.

## Profiles

```
helm install cloudgrange . -f values-single-node.yaml
```

- `values-single-node.yaml` — one K3s node, Postgres as a single-Pod StatefulSet, no Redis.
- `values-multi-node.yaml` — real multi-replica/HA (AB#9190): 2x api/portal, Redis-backed
  relay dispatch, CloudNativePG-backed Postgres. See the CloudNativePG install-sequence
  note above.
- `values-azure.yaml` — real AKS overlay (AB#9187): Azure Disk/Files CSI, Key Vault CSI
  via Workload Identity. See "AKS overlay" below for the full cluster-side setup this
  profile assumes (it's more involved than the on-prem profiles' vendored-chart pattern,
  since Azure AD Workload Identity needs a federated credential tied to the specific
  AKS cluster's own OIDC issuer URL, which doesn't exist until the cluster does).

### AKS overlay (AB#9187)

Unlike cert-manager/CNPG/MetalLB/Velero, there's no chart-installable piece here — the
prerequisites are real Azure resources and cluster-level configuration this chart
deliberately does not provision (Azure resource creation is a confirm-first action, out
of scope for a Helm chart). Required, in order:

1. An AKS cluster created with `--enable-oidc-issuer --enable-workload-identity` (both
   required for Workload Identity; cannot be added to values-azure.yaml since it's a
   cluster-creation-time flag, not a chart concern) and the
   `azureKeyvaultSecretsProvider`/Secrets Store CSI Driver add-on enabled
   (`--enable-addons azure-keyvault-secrets-provider`).
2. A user-assigned managed identity (UAMI), granted `get`/`list` on Secrets in the target
   Key Vault (an access policy, or an RBAC role assignment if the vault uses
   `enableRbacAuthorization`).
3. A **federated identity credential** on that UAMI: subject
   `system:serviceaccount:<release-namespace>:<release-name>-workload-identity` (the
   exact ServiceAccount `templates/aks/serviceaccount.yaml` creates), issuer = the AKS
   cluster's own OIDC issuer URL (`az aks show --query oidcIssuerProfile.issuerUrl`),
   audience `api://AzureADTokenExchange`. **Found missing entirely via a real AKS test**:
   the chart's `SecretProviderClass` set a `clientID` but nothing on the pod side
   originally established a federated identity to use it with — fixed by adding the
   `azure.workload.identity/use: "true"` pod label (`charts/api/templates/deployment.yaml`)
   and the ServiceAccount above; this federated-credential step is the piece that still
   has to happen outside the chart, once, per cluster.
4. Install: `helm install cloudgrange charts/cloudgrange -f charts/cloudgrange/values-azure.yaml --set global.aks.keyVaultName=<vault> --set global.aks.tenantId=<tenant> --set global.aks.managedIdentityClientId=<uami-client-id> --wait`

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
