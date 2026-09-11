# Compact RKE2 bootstrap experiment

This implements the initial Compact experiment for AB#8913/AB#8914 in the canonical M0 runtime workstream. Owner revision `8819c5fd808ad5bca9dbeddc70cc6d36773dd5a3` ran successfully on Linux: infrastructure pipeline975 passed preparation,976 installed RKE2 and977/980 verified the existing API and node readiness. Component, recovery and integrated CloudGrange qualification remain open; no M0 task is closed by startup alone.

The initial fixture is the separate tppoc management VM: Ubuntu24.04, eight virtual processors,32GiB memory,200GiB system disk and a separate256GiB ext4 volume at `/var/lib/rancher`. Infrastructure run968 independently verified its actual boot, authenticated SSH, cloud-init, disks, DNS and HTTPS. Its operating-system kernel is `6.8.0-138-generic`. That evidence does not prove RKE2 startup or reboot persistence.

## Immutable inputs

`artifacts.json` pins RKE2 `v1.36.4+rke2r1`, Canal `v3.32.1-build2026082700` and Traefik/CRD `40.1.010`. The [exact vendor chart manifest](https://github.com/rancher/rke2/blob/v1.36.4%2Brke2r1/charts/chart_versions.yaml) and [release component table](https://github.com/rancher/rke2/releases/tag/v1.36.4%2Brke2r1) agree on those versions. [SUSE's support matrix](https://www.suse.com/suse-rke2/support-matrix/all-supported-versions/rke2-v1-36/) includes Ubuntu24.04. Evidence date:2026-09-10.

Both the original binary archive and801412840-byte image archive were acquired and checked against GitHub release asset digests and the vendor checksum manifest. The executable was extracted and hashed independently. Artifacts remain in the lab scratch directory and are not committed. Pipeline975 verified source/config/artifact delivery and actual PowerShell7.4.19 on the original Linux guest before976 installed RKE2. The installation reached API and node readiness in53.12seconds;977 and980 each observed20pods without reinstalling.

The [vendor-supported manual/tarball layout](https://docs.rke2.io/install/methods) supplies the executable and systemd units. The experiment preserves that layout and invokes native tools from PowerShell7. It does not generate a shell installer or execute the vendor uninstall/killall scripts. The original systemd units contain vendor shell hooks. First-party orchestration remains PowerShell7.

## Execution contract

On the dedicated Linux guest, after secure delivery of these sources and the original archives, run under root PowerShell7:

```powershell
./Invoke-CompactRke2Experiment.ps1 -ConfigPath ./tppoc.example.json -ManifestPath ./artifacts.json -ArtifactDirectory /var/lib/cloudgrange/artifacts -EvidenceDirectory /var/lib/cloudgrange/evidence/rke2 -Mode Plan
./Invoke-CompactRke2Experiment.ps1 -ConfigPath ./tppoc.example.json -ManifestPath ./artifacts.json -ArtifactDirectory /var/lib/cloudgrange/artifacts -EvidenceDirectory /var/lib/cloudgrange/evidence/rke2 -Mode Install
```

Plan hashes both archives and inspects the actual OS, CPU/memory, hostname/address, independent disks, iptables, time synchronization and100GiB data headroom. These are experiment thresholds, not certified minimum requirements. Artifact tampering is rejected before installation state is created. Missing or incompatible prerequisites stop the run.

Install preserves a checkpoint bound to configuration, manifest and source bytes. An existing runtime without that checkpoint, a different request, a changed runtime configuration, or an altered installed executable is preserved and rejected. No disk is formatted. A matching retry uses the original files and systemd service. Interrupted checkpoint writes fail safely for inspection; do not delete existing state or rerun with new inputs to bypass a mismatch.

The Kubernetes API and exact single node must become Ready within20minutes. A timeout preserves state and is a blocking experiment finding until diagnosed or superseded explicitly. Node, pod and HelmChart observations are saved under the requested root-only evidence directory. Kubeconfig and join-token contents are never returned. `node_ready` is distinct from addon/ingress qualification, restart/recovery, blocked-egress operation, HA and product acceptance; those fields remain false.

## Remaining acceptance

The [source980 snapshot review](qualification-980.md) records complete original evidence recovered by infrastructure collection981:12 ready running pods,8 completed installer jobs and the actual8 embedded chart versions. Two installer jobs had historical retries. `Measure-CompactRuntimeSnapshot.ps1` reproduces the review without changing the frozen installer inputs. Subsequent [runtime qualification](qualification-986.md) records successful reboot persistence983, post-reboot functional DNS/HTTP984 and cached resume with public egress denied986. These results do not establish application backup/recovery or full product acceptance.

The upstream management topology/preflight contract (AB#8084), dated qualification record and trust/budget/abort design (AB#8907/8908) still need reconciliation in their owning repositories. This fixture does not supply the full proxy/PKI/backup/recovery contract or claim those dependencies closed.

Remaining work includes sustained footprint measurements, interrupted/partial bootstrap and safe recovery, documented teardown/promotion into F12-1, full storage/TLS/PKI contracts and assembled product testing. Public-egress denial has been tested for cached resume of the existing node; a fresh disconnected installation is not qualified. Production recovery or HA claims are not proved by this single-node experiment. All original M0/M1 acceptance remains required.

Local validation:

```powershell
./Test-ArtifactGuards.ps1 -EvidenceDirectory D:/tmp/cloudgrange-artifact-guard-tests
./Test-PreflightParsing.ps1 -EvidenceDirectory D:/tmp/cloudgrange-preflight-tests
```

This executes the actual artifact validator with changed bytes, truncation, missing files, a path escape and a wrong runtime. It does not substitute for the Linux execution tests above.

The preflight regression executes the actual disk-space expression and minimum-space predicate with native-output fixtures. It reproduced the Linux974 failure before the fix: PowerShell bound `-split` as a native-wrapper parameter. Parenthesizing the command result preserves the operator boundary; LF/CRLF output and the100GiB acceptance threshold are tested.

Evidence directory contract: use a fresh directory for every Install or Verify execution. The pinned bootstrap writes fixed node/pod/chart/result filenames inside the supplied directory. Reusing that directory replaces those detailed observations. The original lab976 installation receipt and timing survive, but Verify977 replaced its initial detailed Linux snapshots. Infrastructurec9ffc10 now passes a unique pipeline execution directory, rejects pre-existing host/Linux evidence paths and leaves the legacy977 snapshots intact. Do not describe the lost initial detail as retained. The installed bootstrap source/config/manifest remain frozen because they define its request identity; add qualification logic separately or design an explicit source transition before changing those bytes.
