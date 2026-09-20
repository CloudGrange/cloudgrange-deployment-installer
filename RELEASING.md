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

## Building the platform images (AB#9171)

`scripts/release/Build-PlatformImages.sh` is the **one supported way** to build the first-party
images for a release. It replaces the ad-hoc `build-images.sh` that release runs used to carry
around and that lived in no repository.

```bash
scripts/release/Build-PlatformImages.sh --version 2609.0.0-preview.28 \
    --api-source   <cloudgrange-platform-api checkout at the release commit> \
    --relay-source <cloudgrange-runtime-relay checkout at the release commit> \
    --portal-source <cloudgrange-portal checkout> --cli-dir <New-CliRelease.sh --out DIR> \
    --clean --push
```

It prints the `--source-sha <component>=<sha>` arguments `New-PlatformRelease.sh` requires.

### `--clean` is not `--no-cache`

`docker buildx build --no-cache` skips the **layer** cache and leaves BuildKit **cache mounts**
exactly as they were. Only `docker builder prune --filter type=exec.cachemount` clears those, and
`--clean` runs it. Without that step, "I rebuilt from scratch and it still fails" is not true.

This is not theoretical: the `preview.28` build failed with
`NETSDK1064: Package Microsoft.AspNetCore.OpenApi ... was not found` at `dotnet publish` and
survived every "clean" retry. Two causes, both now closed —

1. api and relay mounted the **same** cache id `cg-nuget` with the default `sharing=shared`, and
   the release builds every component in parallel;
2. a cache mount is reclaimable, so BuildKit's GC can drop it **between** the restore layer and the
   publish layer, after which `dotnet publish --no-restore` cannot recover.

The Dockerfiles now use per-component ids with `sharing=locked` and publish with an implicit
locked restore rather than `--no-restore`. `Build-PlatformImages.sh` **refuses to build** a source
tree that has regressed on any of those three points, before anything is built, and
`test/appliance/test_build_platform_images.py` plants each regression to prove the gate catches it.

### Build the release commit, not a branch

`New-PlatformRelease.sh` compares every published image's `org.opencontainers.image.revision`
against the `--source-sha` you give, and the retag path is checked against the source's **current**
HEAD. Merge everything first, then build each component from its repository's merged HEAD. Building
from a feature-branch commit and merging afterwards fails provenance.
