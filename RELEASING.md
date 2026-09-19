# CloudGrange Release Checklist

Release only the selected, tested composition. M1 is Compact Online; HA, Bundled and Appliance are later profile qualifications. Require signed digests/BOM, source/license provenance, install/upgrade/restore and owner-acceptance evidence. Existing Compose packaging is historical code and does not implement the selected RKE2 release.

See [current product and release status](https://github.com/CloudGrange/cloudgrange-deployment-installer/blob/main/PRODUCT-STATUS.md). No implementation, runtime test or deployment occurred in this documentation consolidation.

[Historical document at source revision 473b253b01430153557e2e9823aad88a34ad508a](https://github.com/CloudGrange/cloudgrange-deployment-installer/blob/a8e5827e1b955f43d9997aa52f1a60d48f86b6fd/archive/2026-09-07/RELEASING.md) preserves earlier commands and rationale for that code revision. It is not current target architecture or release guidance.

## Platform release artifacts for air-gapped installs (AB#9171, E7)

- `scripts/release/New-PlatformRelease.sh` needs `crane` on `PATH` (pinned: `CRANE_VERSION` and `CRANE_LINUX_AMD64_SHA256` in `release/pins.conf`). It also needs read access to ghcr.io through `docker login`, because the module package `cloudgrange-modules` is private. It resolves the digests for `images.txt` with crane.
- Run it with `--already-pushed --offline-bundle --modules-catalog "$R2_PUBLIC_BASE/modules/catalog.json"`. It writes `images.txt` (what bring-your-own-Kubernetes customers mirror, module images included) and `cloudgrange-platform-<version>.zip` with its `.sha256` (the offline bundle that air-gapped managed installs upload).
- `Publish-Release.sh --platform-release-dir <dir>` puts both on R2 under `releases/<version>/`. The zip is over GitHub's 2 GiB asset limit, so it is not attached to the GitHub release.
- A module-only bundle between Platform releases: `scripts/release/New-ModuleBundle.sh --out <dir>`.
