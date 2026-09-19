# Decisions

<!-- Architecture and design decisions WITH their reasoning, so a future session doesn't relitigate a settled choice. -->

## 2026-09-18 — Update trust is HTTPS + digest pinning; no signing key (owner decision, AB#9171)

- **Decision.** Updates must not require a signing key. Platform: the in-cluster updater
  (`images/platform-updater/entrypoint.sh`) accepts a release manifest only if it came over https from the
  update channel host (`api.updateChannel`, rendered into ConfigMap `<release>-platform-updater-trust`) or a
  host in `platformUpdater.trust.allowedHosts`, its SHA-256 equals the channel's `latest.manifestSha256`,
  and every image is `@sha256:`-pinned. Foundation (`scripts/cloudgrange-updater-k3s.py`): https from the
  Foundation channel host, bundle SHA-256 equal to the channel entry (or the admin's upload sha256), every
  file matching `foundation-release.json`.
- **Signatures are optional**: verified if a real key is configured, not required otherwise. The committed
  `cloudgrange-signing-key.pub` placeholder counts as "no key". Never reintroduce fail-closed-on-missing-key.
- **Still refused:** hash mismatch, unpinned image, http:// or other-host source, https→http redirect.
- **Why.** No release key exists; requiring one blocked every update. Accepted risk: a compromised channel
  host could publish a malicious release — signatures remain supported for when a key exists.
- **Record:** `cloudgrange-internal/pmo/decisions-2026-09-18/update-architecture.md` ("Update trust").
