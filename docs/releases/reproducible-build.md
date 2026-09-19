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

- The image export writes content-addressed blobs, but the order of the images in `manifest.json` and `index.json` isn't fixed between runs. That alone made two otherwise identical builds differ. The build sorts the entry *list* inside both files (sorting keys alone is not enough — the list order is what varies) and repacks `airgap/cloudgrange-images-amd64.tar` with GNU tar: sorted names, owner 0/0, fixed modes, and `SOURCE_DATE_EPOCH` mtimes.
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

With `--images registry` the bundle carries an `airgap/` directory: the pinned `k3s` binary, `k3s-airgap-images-amd64.tar`, K3s's install script, and `cloudgrange-images-amd64.tar` holding every image the rendered chart references. `scripts/Install-CloudGrangeK3s.sh` verifies each against its `.sha256`, installs K3s with `INSTALL_K3S_SKIP_DOWNLOAD=true`, and imports the service images into containerd, so a host with no internet access completes the install. The chart uses `imagePullPolicy: IfNotPresent` and no `:latest` vendor tags, so pods use the imported images instead of trying to pull. The installer imports with `ctr -n k8s.io images import --platform linux/amd64`. It then resolves every `images.txt` reference through CRI (`crictl inspecti`) and fails at that point if any image is missing, so a bad payload never ends in an `ImagePullBackOff`.

### Image payload gates

The build host's Docker image store isn't used for the payload. A Docker daemon that uses the containerd image store can keep an image record whose layer blobs are gone. `docker pull` doesn't restore them, because the unpacked snapshots still exist, and plain `docker save` exports the image anyway without the missing content and exits 0. That's how 2609.0.0-preview.10 shipped cert-manager images with no config or layers.

Instead, the build starts the containerd from `rancher/k3s:<K3S_VERSION>` in a new throwaway container. It runs `ctr content fetch --platform linux/amd64` for every chart image, fully qualified, and tags each digest-pinned image as both `repo:tag` and `repo@sha256:<digest>`. It then runs `ctr images export --platform linux/amd64`. That export keeps each vendor image's multi-arch index as the top-level digest, so the chart's `@sha256` pins still resolve. It carries only linux/amd64 content, and it can't write an image it doesn't fully have. Every image has to be pullable from its registry. A local-only image can't be bundled. Docker is used only to run the `rancher/k3s` image.

Two checks then run, and either one fails the build:

1. **`scripts/release/Test-ImageTarComplete.py`** runs on the extracted layout before it's packed. It follows every named image down its linux/amd64 branch and requires the manifest, the config and every layer to be present at their recorded size. It also requires every chart image to be named, as `repo:tag` and, for a digest-pinned image, as `repo@sha256:<digest>`. Other platforms and attestation manifests are left out on purpose, because the import never reads them.
2. **`scripts/release/Test-AirgapImageImport.sh`** runs on the finished tar, mounted read-only, so the bundle bytes don't change. It starts the containerd from `rancher/k3s:<K3S_VERSION>` in a throwaway container with `--network none` and runs the installer's import. `ctr images check` must report every image complete, and `crictl inspecti` must resolve every `images.txt` reference offline. The gate itself never touches the network.

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
