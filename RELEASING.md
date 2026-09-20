# CloudGrange Release Checklist

Release only the selected, tested composition. M1 is Compact Online; HA, Bundled and Appliance are later profile qualifications. Require signed digests/BOM, source/license provenance, install/upgrade/restore and owner-acceptance evidence. Existing Compose packaging is historical code and does not implement the selected RKE2 release.

See [current product and release status](https://github.com/CloudGrange/cloudgrange-deployment-installer/blob/main/PRODUCT-STATUS.md). No implementation, runtime test or deployment occurred in this documentation consolidation.

[Historical document at source revision 473b253b01430153557e2e9823aad88a34ad508a](https://github.com/CloudGrange/cloudgrange-deployment-installer/blob/a8e5827e1b955f43d9997aa52f1a60d48f86b6fd/archive/2026-09-07/RELEASING.md) preserves earlier commands and rationale for that code revision. It is not current target architecture or release guidance.

## Platform release artifacts for air-gapped installs (AB#9171, E7)

- `scripts/release/New-PlatformRelease.sh` needs `crane` on `PATH` (pinned: `CRANE_VERSION` and `CRANE_LINUX_AMD64_SHA256` in `release/pins.conf`). It also needs read access to ghcr.io through `docker login`, because the module package `cloudgrange-modules` is private. It resolves the digests for `images.txt` with crane.
- Run it with `--already-pushed --offline-bundle --modules-catalog "$R2_PUBLIC_BASE/modules/catalog.json"`. It writes `images.txt` (what bring-your-own-Kubernetes customers mirror, module images included) and `cloudgrange-platform-<version>.zip` with its `.sha256` (the offline bundle that air-gapped managed installs upload).
- `Publish-Release.sh --platform-release-dir <dir>` puts both on R2 under `releases/<version>/`. The zip is over GitHub's 2 GiB asset limit, so it is not attached to the GitHub release.
- A module-only bundle between Platform releases: `scripts/release/New-ModuleBundle.sh --out <dir>`.

## Release-artifact provenance (AB#9171)

Every image a release publishes must prove which source commit it came from. `scripts/release/image-provenance.sh` is the one place that stamps it and the one place that checks it.

- Each image the release tooling builds carries `org.opencontainers.image.revision` (the full 40-hex HEAD of its **source** repository), `org.opencontainers.image.version` (the version it is built as) and `org.opencontainers.image.source`. A dirty source checkout is refused: a revision label naming `HEAD` while the tree differs from it is exactly the lie this prevents.
- `New-PlatformRelease.sh` now requires `--source-sha <component>=<40-hex sha>` for **every** component (`api`, `portal`, `relay`, `platform-updater`) with `--push` or `--already-pushed`, and refuses before anything is pulled, tagged or pushed if one is missing. Give the **current** source HEAD of each component's repository.
- After the push it reads each published image back by digest (`crane config`) and refuses the release unless the stamped revision equals the `--source-sha` given and the stamped version equals the version the image was built as. The proved revision is recorded in `manifest.json` under `components.<name>.revision`.
- The retag paths are covered, because they are the ones that burned us. `--push --source-tag <older tag>` asserts the pulled image **before** it is retagged, so a stale image never reaches the registry under the new tag. `--already-pushed` publishes images it did not build, so the same assertion runs on the published bytes; an image hand-retagged from an older digest also fails the version check (it was built as the older version) and the operator is told to rebuild or use `--push --source-tag`.
- The gate is covered by `test/appliance/test_release_provenance.py`, which runs the real shell functions against a stubbed registry and fails if any `docker build` call site in `scripts/release/` or `images/` stops stamping, or if `New-PlatformRelease.sh` stops asserting.
