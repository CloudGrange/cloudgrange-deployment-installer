# Reproducible release builds

A release has two customer artifacts built from one commit on `main`:

| Artifact | Built by | Reproducible |
|---|---|---|
| `Install-CloudGrange-Bundled.zip` | `scripts/New-ReleaseBundle.sh`, run by the on-demand [Release Bundle](../../.github/workflows/release-bundle.yml) workflow on the `[self-hosted, linux, x64, hcs]` runner | Yes. The same commit and version rebuild to the same SHA-256 |
| `cloudgrange-appliance.vhdx` | `Install-CloudGrange.ps1 -Mode Bundled` plus `Build-CloudGrangeAppliance.ps1` on a Hyper-V host, as a documented host step (the on-demand [Release Appliance](../../.github/workflows/release-appliance.yml) workflow or by hand) | No. Its SHA-256 is recorded, not reproduced |

Neither workflow runs on a tag push or a schedule, and neither creates a tag or a GitHub release. Both upload workflow artifacts and write the SHA-256 to the run summary. Builds are unsigned.

## Bundle

### Inputs

Every input is fixed by the source tree:

| Input | Pinned by |
|---|---|
| Installer scripts, compose files, docs | The commit, exported with `git archive` (never a working copy) |
| First-party images (api, portal, relay) | The version tag, resolved to a digest when the bundle is built and stamped into the bundle compose as `repo:<version>@sha256:<digest>` by `scripts/Set-FirstPartyImagePins.sh` |
| Vendor images | `@sha256` digests in `compose/docker-compose.yml` and `compose/helper-images.txt`. `scripts/Test-ComposeImagePins.sh` fails the build on any image without a digest |
| Ubuntu cloud image | `release/ubuntu-noble-cloudimg-amd64.sha256` (serial 20260911) |
| Offline Docker CE and Hyper-V KVP packages | `release/docker-debs/SHA256SUMS` (the exact file set) and `release/docker-debs/versions.txt` |
| Timestamps | `release/SOURCE_DATE_EPOCH` (a fixed release epoch, not the build or commit time) |

A first-party version tag is expected to be immutable once published. If a tag is re-pushed, the digest changes and so does the bundle hash. `release-record.json` records the resolved image references, so the difference is visible.

### What makes the zip deterministic

- `docker save` writes content-addressed blobs with fixed (epoch) timestamps and root ownership. Saving the same images by name in sorted order gives the same tar.
- Every file and directory in the bundle gets mode `u=rwX,go=rX` and mtime `SOURCE_DATE_EPOCH`, so the umask, checkout time and filesystem don't matter.
- `SHA256SUMS` and `images.txt` are sorted in the C locale.
- The zip is written with `TZ=UTC`, in sorted order, and with `zip -X -D`: no extra attributes (uid/gid, extended timestamps) and no directory entries.
- The commit SHA is recorded only in `release-record.json`, beside the zip, not inside it. A commit that changes nothing in the bundle (for example a docs-only change outside the bundled docs) rebuilds to the same hash.

### Rebuilding and checking

On the runner, dispatch Release Bundle with `commit_sha` (a full SHA on `main`) and `version`. To check a bundle by hand on any Linux host with Docker, zip, PyYAML and the pinned inputs:

```bash
git archive --format=tar <commit> | tar -x -C /tmp/src
bash /tmp/src/scripts/New-ReleaseBundle.sh --source /tmp/src --version <version> --images registry \
  --ubuntu-image noble-server-cloudimg-amd64.img --debs-dir debs/ --out /tmp/out --source-commit <commit>
sha256sum /tmp/out/Install-CloudGrange-Bundled.zip   # compare with the recorded SHA-256
```

`--images local` builds from images already in the local image store (for example a locally built test version) and fails if an image isn't present with the pinned digest.

### Known limits

- The zip hash depends on the zip implementation (Info-ZIP `zip` 3.0 on Ubuntu). Another zip tool or version can compress differently. The build records the hash from the pinned runner image. It doesn't claim the same bytes from any tool.
- The Ubuntu cloud image and packages are downloaded when the bundle is built, then checked against the pins. If Canonical or Docker withdraws a pinned file, the build fails. It never substitutes a newer file.

## Appliance VHDX

The VHDX needs Hyper-V (a VM is installed, generalized, exported and compacted), so it can't run on the Linux runner. It stays a documented host step. Its SHA-256 is recorded in the build output (`cloudgrange-appliance.vhdx.sha256`) and in the release baseline, and the secret scan must report zero findings.

Its hash isn't reproducible, and making it so isn't a goal, because:

- **VHDX metadata.** Hyper-V writes random GUIDs into each new VHDX (file identifier, data write GUID, log GUID, page 83 identifier), and the header's sequence number and log reflect the write history.
- **Filesystem state.** Installing and running the stack writes ext4 inode and superblock timestamps, journal contents, and a block layout that depend on timing. Examples are container image extraction order, PostgreSQL and Keycloak first-start writes, and log rotation.
- **Per-install random values.** The source VM gets random secrets and identifiers at install time. Generalization removes or resets them (the secret scan proves nothing is left), but the free blocks they used and the replacement state differ between builds.
- **Compaction.** `Optimize-VHD` and zero-filling reclaim blocks based on the layout above, so the compacted file size and block allocation table differ too.

The VHDX is traceable instead: it's built only from a bundle whose SHA-256 matches a reproducible Release Bundle run, and it records that bundle's SHA-256 and the source commit.
