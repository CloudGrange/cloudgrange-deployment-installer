# Compact experiment teardown and Online promotion

Owner: AB#8915. Reviewed2026-09-11 against the installed experiment source
`8819c5fd808ad5bca9dbeddc70cc6d36773dd5a3` and the canonical
[F12-1 work packages](https://github.com/CloudGrange/cloudgrange-internal/blob/main/pmo/decisions-2026-09-07/m0-task-register.md#f12-1).
This is a recovery/transition procedure; no teardown has been executed.

## Current retention decision

Keep cglab-mgmt01 running as the management fixture for the requested lab.
Its Hyper-V identity is `2e3208da-fd6d-4ab4-8f5b-f0384b08351e` on cg-hv01;
its declared independent data volume is mounted at /var/lib/rancher. The two
Hyper-V clusters and product installation still need this management environment.
The disposable qualification label does not authorize removing it during delivery.

Retain original source/config/manifest, vendor archives and their digests,
checkpoint, runtime configuration, installed binary hash, node/boot/volume
identities and per-execution evidence. Keep kubeconfig, join tokens and SSH keys
in protected storage; evidence records references and hashes, not their contents.
Preserve failed and corrected runs separately. A new Verify run needs a fresh
evidence directory because the installed prototype writes fixed observation names.

## Controlled retirement procedure

1. Identify the exact VM by immutable ID and its disks/adapters from current
   Hyper-V state; reconcile them with the deployment and runtime receipts.
   An unexpected host, VM ID, disk parent, active job or foreign attachment stops
   retirement. Do not select resources by an old prefix or wildcard.
2. Verify all pipeline, managed-command and guest operations are terminal.
   Observation timeouts do not establish termination. Preserve the final result,
   source and operation identity before retiring any command record. Verify
   temporary recovery tasks, ACLs and SSH credentials are cleaned up without
   altering unrelated host state.
3. Export the required evidence and original packages to their retained ADO/private
   versioned stores; read back exact versions and verify hashes. Retain the
   authoritative owner checkpoint and source bindings. A VM export alone does not
   establish application-consistent PostgreSQL, identity, vault or product recovery.
4. Agree on retention and the specific fixture being retired. Preserve the OS and
   data disks for inspection/recovery unless disposal of those exact disks is
   explicitly included. Gracefully stop the selected VM, observe Off, and remove
   its registration only after confirming its consumers have moved or completed.
   Do not force power off a running data-bearing fixture as routine cleanup.
5. Before any filesystem removal, resolve every selected path and prove it lies
   inside that VM's designated directory, is not a parent/shared location and has
   no remaining VM/checkpoint reference. Use native PowerShell LiteralPath handling.
   Stop on ambiguity; do not turn a failed removal into a broader recursive delete.
6. Preserve domain controllers, witnesses, cluster disks, shared management
   networking, other nested VMs and evidence storage while any lab work uses them.
   Retiring the experiment does not authorize deleting the Azure resource group
   or revoking credentials shared with other hosts.
7. Record the final VM/disk/adapter state and retained recovery locations. If
   anything remains running or registered, report it explicitly. F12 uninstall
   must separately define product data retention, secret revocation and restoration.

The current experiment intentionally does not automate destructive teardown.
Legacy installer/uninstaller entry points must be reviewed against their actual
target architecture before use; the Compact experiment does not qualify them.

## Promotion into F12-1

Promote reviewed behavior and verified artifacts through the owning work packages;
do not adopt an installed prototype by changing its checkpoint or source hash.

| F12-1 work | Inputs reusable from this experiment | Required implementation and evidence |
| --- | --- | --- |
| AB#9015 state machine and guide | Pinned artifacts, explicit identity/source binding, preflight predicates, attributed failures and unique evidence paths | Versioned installation states with atomic checkpoint persistence; trust/network/storage prerequisites; safe failure and recovery transitions |
| AB#9016 resumable Online installation | Hash validation before extraction, cached artifact use, bounded service/node observation | One signed BOM/configuration schema, authenticated retrieval, schema/version migration, protected one-use setup and bootstrap-to-production identity transition |
| AB#9017 reference composition | Actual selected RKE2/Canal/Traefik startup and runtime measurements | PostgreSQL, identity, vault, API/Core, portal, Gateway, Agent and reference module installed through their owner contracts without manual container changes |
| AB#9018 acceptance and uninstall | Original reboot/network/egress observations and retained failure examples | Fresh clean install; interruption at every declared checkpoint; preserved data and no duplicate identities; explicit uninstall/retention behavior; versioned operator instructions |

F12-1 prerequisites AB#8130, AB#8894 and AB#8118 remain governed by the
canonical dependency graph. Full Compact restore is a separate assembled
composition acceptance gate. Existing-node cached resume is not fresh offline
installation, product recovery, HA or disconnected-distribution certification.

Before changing the installed prototype source, define a transition that verifies
the old request identity and preserved data, records the new signed inputs and
can stop safely. Deleting the old checkpoint to make a different request appear
fresh is not a migration. The remaining interrupted/partial-bootstrap experiment
must retain its first failure and prove the actual resume or safe-failure state.
