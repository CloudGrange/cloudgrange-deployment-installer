# Reproducible release builds

A release has two customer artifacts built from one commit on `main`:

| Artifact | Built by | Reproducible |
|---|---|---|
| `Install-CloudGrange-K3s-Bundled.zip` | `scripts/New-ReleaseBundleK3s.sh`, run by the on-demand [Release Bundle](../../.github/workflows/release-bundle.yml) workflow on the `[self-hosted, linux, x64, hcs]` runner | Yes. The same commit and version rebuild to the same SHA-256 |
| `cloudgrange-appliance-k3s.vhdx` | `Install-CloudGrange.ps1 -Engine K3s` plus `Build-CloudGrangeApplianceK3s.ps1` on a Hyper-V host, as a documented host step | No. Its SHA-256 is recorded, not reproduced |

Neither workflow runs on a tag push or a schedule, and neither creates a tag or a GitHub release. Both upload workflow artifacts and write the SHA-256 to the run summary. Builds are unsigned.

## Bundle

### Inputs

Every input is fixed by the source tree:

| Input | Pinned by |
|---|---|
| Installer scripts, charts, docs | The commit, exported with `git archive` (never a working copy) |
| First-party images (api, portal, relay) | The `--version` tag, stamped into the bundled chart values as `global.image.tag` |
| Vendor images (postgres, keycloak, grafana, loki, promtail, prometheus, otel-collector, cert-manager, …) | The tags the chart itself renders. The image list is derived from `helm template`, never hand-maintained, so it cannot drift from the chart |
| K3s binary and K3s airgap images | `K3S_VERSION` in `release/pins.conf`, the single pins file, verified at build time against K3s's own published `sha256sum-amd64.txt` |
| Timestamps | `release/SOURCE_DATE_EPOCH` (a fixed release epoch, not the build or commit time) |

A first-party version tag is expected to be immutable once published. If a tag is re-pushed, the digest changes and so does the bundle hash. `release-record.json` records the resolved image references, so the difference is visible.

### What makes the zip deterministic

- `docker save` writes content-addressed blobs with fixed (epoch) timestamps and root ownership, but it lists the images in `manifest.json` and `index.json` in a random order that changes between runs. That alone made two otherwise identical builds differ. The build sorts the entry *list* inside both files (sorting keys alone is not enough — the list order is what varies) and repacks `airgap/cloudgrange-images-amd64.tar` with GNU tar: sorted names, owner 0/0, fixed modes, and `SOURCE_DATE_EPOCH` mtimes.
- Every file and directory in the bundle gets mode `u=rwX,go=rX` and mtime `SOURCE_DATE_EPOCH`, so the umask, checkout time and filesystem don't matter.
- `SHA256SUMS` and `images.txt` are sorted in the C locale.
- The zip is written with `TZ=UTC`, in sorted order, and with `zip -X -D`: no extra attributes (uid/gid, extended timestamps) and no directory entries.
- The commit SHA is recorded only in `release-record.json`, beside the zip, not inside it. A commit that changes nothing in the bundle (for example a docs-only change outside the bundled docs) rebuilds to the same hash.

### Rebuilding and checking

On the runner, dispatch Release Bundle with `commit_sha` (a full SHA on `main`) and `version`. To check a bundle by hand on any Linux host with Docker, zip, PyYAML and the pinned inputs:

```bash
git archive --format=tar <commit> | tar -x -C /tmp/src
bash /tmp/src/scripts/New-ReleaseBundleK3s.sh --source /tmp/src --version <version> \
  --images registry --out /tmp/out
sha256sum /tmp/out/Install-CloudGrange-K3s-Bundled.zip   # compare with the recorded SHA-256
```

`--images none` builds a smaller, network-install-only bundle with no offline image payload. `release-record-k3s.json` records which mode was used (`offlineCapable`).

### Offline install

With `--images registry` the bundle carries an `airgap/` directory: the pinned `k3s` binary, `k3s-airgap-images-amd64.tar`, K3s's install script, and `cloudgrange-images-amd64.tar` holding every image the rendered chart references. `scripts/Install-CloudGrangeK3s.sh` verifies each against its `.sha256`, installs K3s with `INSTALL_K3S_SKIP_DOWNLOAD=true`, and imports the service images into containerd, so a host with no internet access completes the install. The chart uses `imagePullPolicy: IfNotPresent` and no `:latest` vendor tags, so pods use the imported images instead of trying to pull.

### Known limits

- The zip hash depends on the zip implementation (Info-ZIP `zip` 3.0 on Ubuntu). Another zip tool or version can compress differently. The build records the hash from the pinned runner image. It doesn't claim the same bytes from any tool.
- Images and the K3s assets are downloaded when the bundle is built, then checked against the pins. If an upstream withdraws a pinned file, the build fails. It never substitutes a newer file.
- Vendor images are pinned by tag, not digest, because the chart references them by tag. A re-pushed vendor tag changes the bundle hash; `images.txt` inside the bundle records exactly what was packaged.

## Appliance VHDX

The VHDX needs Hyper-V (a VM is installed, generalized, exported and compacted), so it can't run on the Linux runner. It stays a documented host step. Its SHA-256 is recorded in the build output (`cloudgrange-appliance.vhdx.sha256`) and in the release baseline, and the secret scan must report zero findings.

Its hash isn't reproducible, and making it so isn't a goal, because:

- **VHDX metadata.** Hyper-V writes random GUIDs into each new VHDX (file identifier, data write GUID, log GUID, page 83 identifier), and the header's sequence number and log reflect the write history.
- **Filesystem state.** Installing and running the stack writes ext4 inode and superblock timestamps, journal contents, and a block layout that depend on timing. Examples are container image extraction order, PostgreSQL and Keycloak first-start writes, and log rotation.
- **Per-install random values.** The source VM gets random secrets and identifiers at install time. Generalization removes or resets them (the secret scan proves nothing is left), but the free blocks they used and the replacement state differ between builds.
- **Compaction.** `Optimize-VHD` and zero-filling reclaim blocks based on the layout above, so the compacted file size and block allocation table differ too.

The VHDX is traceable instead: it's built only from a bundle whose SHA-256 matches a reproducible Release Bundle run, and it records that bundle's SHA-256 and the source commit.
