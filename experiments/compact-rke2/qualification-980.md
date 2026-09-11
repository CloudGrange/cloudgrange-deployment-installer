# Compact snapshot980 review

Infrastructure collection981 succeeded using source9ecb61d and installed owner8819c5f. It recovered the complete original980 node, pod, HelmChart and bootstrap files plus the matching host receipt. The five original files passed length, SHA256 and execution-identity checks after download from the exact private blob version. The duplicate upload was rejected with HTTP403. Original pipeline ZIP SHA256: `468b9abdc14623467e2e2ad4d98478b19e096c5ecc86485586fc5cab6a497d4c`.

Run `Measure-CompactRuntimeSnapshot.ps1` under PS7.4+ against the exact `runtime-source-980-collection-981` directory in the [collection981 artifact](https://dev.azure.com/hybridcloudsolutions/CloudGrange/_build/results?buildId=981). Keep its review output outside the original evidence directory. The artifact also includes synthetic guard-test fixtures; selecting every similarly named file recursively mixes fixtures with real observations and is invalid.

The actual980 observation at2026-09-11T00:13:17Z has one Ready management node running Ubuntu24.04.4 LTS, kernel6.8.0-138-generic, RKE2v1.36.4+rke2r1 and containerd2.3.4-k3s1.36. Memory, disk, PID and network pressure conditions are clear. All12 Running pods have ready containers and Ready=True; all8 Helm installer jobs completed successfully. All8 HelmCharts report Failed=False. These observations establish snapshot component health, not a current functional traffic or recovery test.

| Component | Embedded chart version | Observed main image tag |
| --- | --- | --- |
| Canal | v3.32.1-build2026082700 | hardened-calico:v3.32.1-build20260827; hardened-flannel:v0.28.9-build20260819 |
| CoreDNS | 1.47.003 | hardened-coredns:v1.14.7-build20260819 |
| Metrics server | 3.14.000 | hardened-k8s-metrics-server:v0.9.0-build20260819 |
| Runtime classes | 0.1.000 | No dedicated running pod |
| Snapshot controller and CRD | 5.2.003 | hardened-snapshot-controller:v8.6.0-build20260819 |
| Traefik and CRD | 40.1.010 | hardened-traefik:v3.7.11-build20260819 |

Canal and both Traefik chart versions match the pinned owner manifest. Versions came from each embedded chart archive's own Chart.yaml; spec.version is absent in these HelmCharts. Chart metadata appVersion is not the deployed image version: for example Traefik metadata saysv3.7.1 while its actual hardened image tag saysv3.7.11. The JSON review preserves both fields, embedded archive hashes and observed image digests.

Snapshot-controller and Traefik Helm installer jobs each restarted twice. Their retained last termination has exit1; their final termination has exit0. The reason for those earlier failures is not established by the generic termination message. Preserve and inspect available previous-container logs and job events before describing installation as free of transient failures. Running workload containers show zero restarts in this observation.

Remaining: functional DNS and ingress traffic, persistent workload data/storage, measured resource use and reboot/interrupted recovery, cached bootstrap with public egress denied, topology/trust/backup contract and full CloudGrange acceptance. Initial installation976 detailed snapshots remain lost after977 reused their directory;981 preserves980 observations and does not reconstruct976. No M0 task or HA profile is closed by this review.
