# CloudSmith Release Checklist

This document defines the mandatory steps for producing a CloudSmith release.
Complete **every** step in order. Do not publish a release if any step fails.

## Release artifacts

Every release must include the following files:

| Artifact | Required | Description |
|---|---|---|
| `cloudsmith-appliance.vhdx` | Yes | Pre-built appliance disk image |
| `cloudsmith-appliance.sha256` | **Mandatory** | SHA-256 manifest — `Import-CloudSmithAppliance.ps1` refuses to proceed without this |
| `cloudsmith-appliance.sig` | Yes | cosign detached signature over the VHDX |
| `Install-CloudSmith-Bundled.zip` | Yes | Offline bundle (compose stack + images) |
| `SHA256SUMS` | Yes | SHA-256 manifest for the bundled ZIP |
| `cloudsmith-installer.sha256` | Yes | SHA-256 of `Install-CloudSmith.ps1` (AB#1598 self-check) |

## Step-by-step release procedure

### 1. Build and tag

```powershell
# Tag the release commit
git tag -s "v<VERSION>" -m "CloudSmith v<VERSION>"
git push origin "v<VERSION>"
```

### 2. Build the appliance VHDX

The CI pipeline (`.github/workflows/release.yml`) builds the VHDX from the
official Ubuntu 24.04 cloud image and the Docker Compose stack baked in.

```bash
# CI variable — set in GitHub Actions secrets / kv-hcs-vault-01
CLOUDSMITH_VERSION=<VERSION>
```

### 3. Generate the SHA-256 manifest (mandatory for appliance)

```bash
sha256sum cloudsmith-appliance.vhdx > cloudsmith-appliance.sha256
# Verify the manifest round-trips correctly:
sha256sum --check cloudsmith-appliance.sha256
```

On Windows:

```powershell
$hash = (Get-FileHash -Path cloudsmith-appliance.vhdx -Algorithm SHA256).Hash.ToLower()
"$hash  cloudsmith-appliance.vhdx" | Set-Content cloudsmith-appliance.sha256 -Encoding ASCII
```

### 4. Sign the appliance with cosign (AB#1589)

The private signing key lives in `kv-hcs-vault-01` (secret:
`cloudsmith-appliance-signing-key`). Fetch it at signing time only — never
commit or persist it.

```bash
# Fetch private key from Key Vault (CI service principal must have Get permission)
az keyvault secret show --vault-name kv-hcs-vault-01 \
    --name cloudsmith-appliance-signing-key \
    --query value -o tsv > /tmp/cloudsmith-signing-key.key

# Sign the VHDX
cosign sign-blob \
    --key /tmp/cloudsmith-signing-key.key \
    --output-signature cloudsmith-appliance.sig \
    cloudsmith-appliance.vhdx

# Verify the signature before uploading
cosign verify-blob \
    --key cloudsmith-signing-key.pub \
    --signature cloudsmith-appliance.sig \
    cloudsmith-appliance.vhdx

# Shred the private key
shred -u /tmp/cloudsmith-signing-key.key
```

### 5. Generate the installer SHA-256 (AB#1598 self-check)

```powershell
$hash = (Get-FileHash -Path Install-CloudSmith.ps1 -Algorithm SHA256).Hash.ToLower()
"$hash  Install-CloudSmith.ps1" | Set-Content cloudsmith-installer.sha256 -Encoding ASCII
```

### 6. Bundle the offline installer

```powershell
# Include compose stack, signed images, and all scripts
Compress-Archive -Path @(
    'Install-CloudSmith.ps1',
    'cloudsmith-installer.sha256',
    'Update-CloudSmith.ps1',
    'Uninstall-CloudSmith.ps1',
    'scripts\',
    'compose\'
) -DestinationPath "Install-CloudSmith-Bundled-v<VERSION>.zip"

# Generate SHA256SUMS for the bundle
$hash = (Get-FileHash -Path "Install-CloudSmith-Bundled-v<VERSION>.zip" -Algorithm SHA256).Hash.ToLower()
"$hash  Install-CloudSmith-Bundled-v<VERSION>.zip" | Set-Content SHA256SUMS -Encoding ASCII
```

### 7. Publish the GitHub Release

Upload all artifacts from Step 2–6 as release assets. Verify that every
artifact listed in the **Release artifacts** table above is present before
publishing the release.

### 8. Post-release verification

Run the smoke test against the published release:

```powershell
# Download and verify
Invoke-WebRequest -Uri "https://github.com/cloudsmith-cloud/cloudsmith-installer/releases/download/v<VERSION>/cloudsmith-appliance.sha256" -OutFile cloudsmith-appliance.sha256
Invoke-WebRequest -Uri "https://github.com/cloudsmith-cloud/cloudsmith-installer/releases/download/v<VERSION>/cloudsmith-appliance.vhdx" -OutFile cloudsmith-appliance.vhdx

# Import and verify (runs full sha256 + cosign check)
.\Import-CloudSmithAppliance.ps1 -AppliancePath .\cloudsmith-appliance.vhdx
```

## Key Vault secrets used in release

| Secret name | Purpose |
|---|---|
| `cloudsmith-appliance-signing-key` | RSA private key for cosign (never committed) |
| `cloudsmith-appliance-signing-pubkey` | Public key (also committed as `cloudsmith-signing-key.pub`) |
| `cloudsmith-release-token` | GitHub token for publishing release assets |
