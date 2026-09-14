# rc.2 baseline

Release candidate 2 of the on-premises installer. This is a recorded baseline, not a release: no tag, no GitHub release and no upload. Builds are unsigned test builds.

How to rebuild and check it: [reproducible-build.md](reproducible-build.md).

## Source

| Item | Value |
|---|---|
| Installer repo | `CloudGrange/cloudgrange-deployment-installer`, PR #10 (`fix/installer-hardening-followups`) |
| Installer source commit (bundle content) | `439fe69ab77111cf056210c79b94e9ecb89c96a9` (tree `b6b8c0d9adc53ebe48027f8ee54845722fc713fa`) |
| Test version string | `0.0.0-unsigned-test` |
| `SOURCE_DATE_EPOCH` | `1789430400` (`release/SOURCE_DATE_EPOCH`) |

The commit that adds this file changes only `docs/releases/`, which is not in the bundle, so it rebuilds to the same bundle SHA-256. PR #10 isn't merged yet. After merge, rebuild from the merge commit on `main` with the on-demand Release Bundle workflow and record that commit here; the bundle SHA-256 must match.

## Images

Every image is pinned by digest in the bundle's `compose/docker-compose.yml`.

| Image | Digest | Source |
|---|---|---|
| `ghcr.io/cloudgrange/cloudgrange-api:0.0.0-unsigned-test` | `sha256:e056f53a77997198c87e07e8458637fa14857d56065b2f8da3fedfb169b9901a` | `cloudgrange-platform-api` `9702e188652cee2023f0c9b7a9c22d5d200e1bc4` (on `main`) |
| `ghcr.io/cloudgrange/cloudgrange-portal:0.0.0-unsigned-test` | `sha256:2f7bd46f5cc5a433be1f492f3c303d4e92d429d3795a723c5d148c7b8a587449` | `cloudgrange-portal` `a624af67b309ce7fa106e44e69cede401c78fc34` (on `main`) |
| `ghcr.io/cloudgrange/cloudgrange-relay:0.0.0-unsigned-test` | `sha256:232839b1f6e84604e8965bae362cf02ac9b1220ffe98881b14ea21848e9b282a` | `cloudgrange-relay` `ea157c027335e39b22e6254f7222cb1c5dfabcab` (on `main`) |
| `nginx:1.31.5-alpine` | `sha256:72ba65eb42c10344912a84ff42408db7d34f2feb642204570ab8fc5ffd29f1d3` | vendor |
| `postgres:17.11-alpine` | `sha256:18cfe3ef5e6815560c98237d6216d1e5119702fb0f3894c8785dd58b8bbe5d73` | vendor |
| `quay.io/keycloak/keycloak:26.6.4` | `sha256:0aae0de7fca85525f727d3354df17896092de8bb26ae4c12d89c77e5df8cbce4` | vendor |
| `otel/opentelemetry-collector-contrib:0.160.0` | `sha256:799dc6cf12c96192af37b5bdba804da8c10b3bc563b43cb90c3f3c58d9572ad6` | vendor |
| `prom/prometheus:v3.14.0` | `sha256:5ce7540c3c00ef4ab0c9d2c995c6a5b9c421f44b4a115d97a2c7af3b1c21cbb0` | vendor |
| `grafana/loki:3.7.7` | `sha256:d70e4659623f3e109af669cae76fe2a5dd5be54e2298fe8aed380d982fbc2500` | vendor |
| `grafana/grafana:12.1.1` | `sha256:a1701c2180249361737a99a01bc770db39381640e4d631825d38ff4535efa47d` | vendor |
| `alpine:3.24.1` (healthcheck tools helper) | `sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b` | vendor |

The first-party images were built locally from those commits for this baseline. They are not the GHCR-published images. A GHCR release of the same commits must be recorded with the registry digests.

## Other pinned inputs

| Input | SHA-256 |
|---|---|
| Ubuntu noble cloud image, serial 20260911 (kernel 6.8.0-139-generic) | `612b2c0cc1bc413a6cb8c38fd611794caf0f2b436c50013d8b3794db12ad7354` |
| Offline Docker CE and KVP packages | 25 files, listed in `release/docker-debs/SHA256SUMS` (versions in `release/docker-debs/versions.txt`) |

## Artifacts

| Artifact | SHA-256 | Size (bytes) | Reproducible |
|---|---|---|---|
| `Install-CloudGrange-Bundled.zip` | `194726c9fe9b21f27f1a2e4e94b0261ddc2abc2139b89ee19a7feb79faeeb421` | 1748432010 | Yes. Built twice in WSL from `git archive` of `439fe69` (different directory, umask 022 and 077, different time), byte-identical. `verify-bundle.ps1`: 71/71 |
| `cloudgrange-appliance.vhdx` | `3f626c296ffae31a05f38a71deab6a288da924ffc594eab609548a7846843674` | 6853492736 | No, recorded only (see [reproducible-build.md](reproducible-build.md#appliance-vhdx)). Built on the Hyper-V host from a fresh air-gapped Bundled install of the bundle above (installer `439fe69`). Secret scan: 12 install-time values plus the pattern check, 0 findings |

The stage 8 VHDX (`90e5e606…`, built from an earlier non-reproducible bundle) is not rc.2.

## Known gaps

- **Agent certificate trust, no mTLS.** Host agents reach the relay through nginx on 8443 (TLS, `/lan/v1/agents/` only). Agents must trust the appliance certificate: CA-signed, or the install-time self-signed certificate imported on each host. The relay doesn't authenticate agents with client certificates yet. Enrollment relies on the relay enrollment token.
- **Grafana first-start SQLite race: mitigated, watch.** On a fresh volume Grafana could exit once with `Failed to provision data sources: database is locked` (one restart, stage 8 install). rc.2 disables Grafana's offline background database writers, enables SQLite WAL, raises transaction retries to 40, and starts Grafana after Prometheus and Loki are healthy. Proof: three fresh WSL starts of the hardened stack, plus one fresh air-gapped VM install of this bundle. All four had 0 Grafana restarts, 0 provisioning failures and a healthy database, and every other container also had 0 restarts. WSL didn't reproduce the original failure even on a throttled disk, so the single VM install is the closest check. Watch the next installs. A PostgreSQL backend for Grafana would remove the race entirely and isn't done.
- **dev-web doesn't yet document 8443.** Docs PR CloudGrange/cloudgrange-dev-web#5 adds the agent endpoint and certificate trust. It isn't merged.
- **Secrets provider.** Stack secrets are in the root-only `.env` on the appliance, and the API encrypts stored secrets with its master key. The real PostgreSQL encrypted secrets provider is pending as S27.
- **Unsigned builds.** No code signing, image signing or VHDX signature. `SHA256SUMS` and the recorded SHA-256 values are integrity checks, not authenticity.
- **Installer SSH calls can hang.** `scripts/Deploy-DockerCompose.ps1`, `scripts/Install-DockerCe.ps1` and `New-SelfSignedCert.ps1` call `ssh` without `BatchMode=yes` or `ConnectTimeout`. During the rc.2 VM install, one call hung for about 40 minutes until the stuck `ssh.exe` was stopped, after which the installer continued and succeeded. Not fixed here.
- **Zip tool dependence.** The bundle hash is reproducible with Info-ZIP `zip` 3.0 and GNU tar on Ubuntu. Other tools may produce different bytes.
