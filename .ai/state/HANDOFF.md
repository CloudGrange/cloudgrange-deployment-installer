# HANDOFF — cloudgrange-deployment-installer

## 2026-09-20 — Release-artifact provenance (branch `feat/e9b-provenance`, AB#9171)

Nothing proved which source commit a released image came from. A stale label cost five rebuilds,
and the "retag an unchanged image" path once published a relay built BEFORE the fix it was supposed
to carry (preview.10) because the check compared the wrong base.

- `scripts/release/image-provenance.sh` (new) is the single stamp-and-check helper:
  `cg_provenance_labels <source checkout> <version>` builds the `--label` arguments
  (`org.opencontainers.image.revision` = full 40-hex HEAD of the SOURCE repo,
  `.version`, `.source`) and **refuses a dirty tree**;
  `cg_assert_image_provenance <ref> <revision> <version> [auto|local|remote]` reads the labels back
  (`docker image inspect` locally, `crane config --platform linux/amd64` from a registry) and hard-fails
  naming the image, the expected SHA and the found SHA.
- Stamped call sites (the only two `docker build`s in this repo's release tooling):
  `scripts/release/Build-PortalImage.sh` (source = the portal checkout) and
  `images/platform-updater/build.sh` (source = this repo). **api and relay images are built in their
  own repos** (`cloudgrange-platform-api`, `cloudgrange-runtime-relay`) — the assertion covers them,
  the stamping has to be added there.
- `scripts/release/New-PlatformRelease.sh` now takes `--source-sha <component>=<40-hex>`, **required
  for every component** with `--push`/`--already-pushed` (refused before anything is pulled or pushed),
  asserts a retag source image BEFORE it is tagged, asserts every published image by digest after the
  push, and records the proved revision in `manifest.json` as `components.<name>.revision`.
- Test: `test/appliance/test_release_provenance.py` (20 cases). It runs the real shell functions
  against a stubbed `crane`/`docker` on PATH and fails if any call site stops stamping or the release
  stops asserting.

**Already on main, no change needed (the task brief was stale):**
`Test-ReleaseVersionFree.sh` already checks GHCR packages + the chart package + GitHub Releases +
**git tags** (`repos/<repo>/git/matching-refs/tags/`) + R2 — added in `110637a`.
`Install-CloudGrange-Aca.zip` is already built and uploaded by `Publish-GitHubRelease.sh` (lines 73-78)
— added in `d7e8722`.

**Updated:** 2026-09-20


## 2026-09-18 — Foundation release builder (branch `feat/foundation-release-builder`, AB#9171)

- `scripts/release/New-FoundationRelease.sh` builds `cloudgrange-foundation-<F version>.zip`
  (cg-foundation-release-v1) from `release/pins.conf`: K3s binary and air-gap images checked against
  K3s's `sha256sum-amd64.txt`, `install.sh` against `K3S_INSTALL_SH_SHA256`, and the updater plus its
  unit as host files. `--version` must equal `FOUNDATION_VERSION` in pins.conf. Signing is optional
  (owner decision 2026-09-18: trust is HTTPS + SHA-256). The builder runs the updater's own
  extract/load_manifest over the result. Unsigned builds are byte-reproducible.
- `scripts/release/Publish-FoundationRelease.sh` runs as a dry run by default and uploads only with `--publish`. It writes
  `foundation/<v>/…zip(.sha256)` and adds `{version,bundleUrl,sha256,k3sVersion,…}` to
  `FOUNDATION_CHANNEL_URL`. **It has never been run with `--publish`.**
- Test: `test/appliance/test_foundation_release_builder.py` (run as root in WSL).
- Gotcha: r2.dev returns **HTTP 403 to Python-urllib's User-Agent**. The host updater's `https_open`
  used urllib's default User-Agent, so every real `foundation-check` and channel download failed. It now sends
  `cloudgrange-updater-k3s/2`, verified live against r2.dev (200 now; 403 before). The publisher
  reads with curl.

**Updated:** 2026-09-18
**Branch:** `feat/k3s-airgap-bundle-retire-compose` (16 commits, **UNPUSHED**, no PR)

## The plan this work comes from

`cloudgrange-internal/pmo/plans/2026-09-15-platform-restructure-helm-k8s.md` —
**read its "Live implementation status" section first.** That section is the authoritative
list of what is fixed, what is built but never run, and what is still open.

## Update trust: no signing key (2026-09-18, branch `feat/https-digest-update-trust`, AB#9171)

Owner decision: updates are trusted through HTTPS + digest pinning, signatures optional. The Platform
updater pins the manifest to the channel's `latest.manifestSha256` (channel URL from ConfigMap
`<release>-platform-updater-trust`); the Foundation updater accepts unsigned bundles whose sha256 matches.
`Publish-Release.sh` now publishes `manifestSha256` and accepts `--channel rc`. **Any release published
before this change has no `manifestSha256` in its channel and is refused by the new updater — republish
the channel with `Publish-Release.sh`.** Tests: `test/appliance/test_platform_updater_trust.py`,
`test_foundation_updater.py`, `test/e2e/platform-updater-kind.sh` (unsigned rc.90 → rc.91).
See `.ai/memory/DECISIONS.md`.

## Headline

**The VHDX appliance now passes its secret scan** — `findings=0`, 3.10 GB VHDX exported,
SHA-256'd and cosign-signed, at `C:\CloudGrangeApplianceK3sTest\cloudgrange-appliance-k3s.vhdx`.
Four previous builds were refused.

## What changed here

| Commit | Change |
|---|---|
| `32af461` | K3s bundle gained full offline parity (pinned K3s binary + airgap images + every image the rendered chart references), then the Compose bundle was retired. Found K3s was installed **completely unpinned** (`curl get.k3s.io \| sh`). |
| `34fab1b` | In-app updater ported to K3s, wire-compatible with the Compose one. Found its IPC was a **PVC the host updater could never read** — updates could never have started. |
| `33244a1` | AB#9182 interrupt/resume + uninstall-retention gates, driving the real installer. Mutation-tested. |
| `77156e3` `ad7a567` `b833d0f` `36a5851` `cb328b8` `87c9a92` `e1f3bac` | The VHDX secret-residue hunt — see below. |
| `13e585c` | The appliance builder uploads an explicit file list and the updater files were missing from it, so the build died *after* generalizing the VM. Gated. |
| `5e58d2e` | Namespace-scoped RBAC so the API can run installed modules. |
| `77d268d` | Updater refuses an update without 5 GB headroom. |
| `cb4ce71` | AB#9170 engine-parity gate: every Compose capability needs a K3s counterpart or a declared reason. |
| `9e969b5` | ACA IaC pointed at image tags that 404 (`main`, `v1.0.0`); every ACA deploy failed to pull. |
| `fd7a6ed` | Updater `hostPath` defaulted **on**, which only works when our installer put the host service there — a BYO-Kubernetes install got a hostPath with nothing behind it. Default now off; `values-single-node.yaml` turns it on. |

## The VHDX residue hunt — causes and dead ends

**Disproved with evidence, do not re-chase:** ext4 journal (inode 8 = blocks 262144–278527; hits
were ~34839/~38922), swap (none), anything outside the root filesystem, ext4 reserved blocks
(already 0%), VHDX-file stale sectors (raw-file count matched logical-disk count).

**Real causes:** journald reflushing sshd records after the wipe; SSH keys and cloud-init copies
being plain-deleted while logs were shredded (a plain delete releases blocks with contents
intact); a fill that could stop early silently; and finally `zerofree` on a read-only root, forced
with **sysrq-u** because `remount,ro` returns EBUSY over SSH.

Root is mounted with `discard`, so freed blocks are trimmed immediately — overwrite-before-unlink
is the only reliable treatment for live files.

## Verify before trusting

- `test/appliance/verify-delivery-paths.sh` — renders the chart per delivery path and reports how
  the updates directory is backed. Expected: BYO hostPath=0, single-node hostPath=1, AKS
  hostPath=0.
- Gate suites: `python3 -m unittest test_install_qualification test_engine_parity` in
  `test/appliance` (16 tests).

## Next steps

1. Boot a VM from the exported VHDX to confirm a customer-style import.
2. Push and open PRs when the owner says so.

## Gotchas

- Once generalize has run, that VM is spent — a retry needs a fresh install (generalize wipes the
  K3s cluster the build's secret-capture step reads first).
- **Never** pass a fake `-Version`; the default `latest` is the only published tag.
- `C:\CloudGrangeApplianceK3sTest\run-full-appliance-test.ps1` runs install→build→scan end to end.
