# CloudGrange Release Checklist

This document defines the mandatory steps for producing a CloudGrange release.
Complete **every** step in order. Do not publish a release if any step fails.

## Release artifacts

Every release must include the following files:

| Artifact | Required | Description |
|---|---|---|
| `cloudgrange-appliance.vhdx` | Yes | Pre-built appliance disk image |
| `cloudgrange-appliance.sha256` | **Mandatory** | SHA-256 manifest — `Import-CloudGrangeAppliance.ps1` refuses to proceed without this |
| `cloudgrange-appliance.sig` | Yes | cosign detached signature over the VHDX |
| `Install-CloudGrange-Bundled.zip` | Yes | Offline bundle (compose stack + images) |
| `SHA256SUMS` | Yes | SHA-256 manifest for the bundled ZIP |
| `cloudgrange-installer.sha256` | Yes | SHA-256 of `Install-CloudGrange.ps1` (AB#1598 self-check) |

## Step-by-step release procedure

### 1. Build and tag

```powershell
# Tag the release commit
git tag -s "v<VERSION>" -m "CloudGrange v<VERSION>"
git push origin "v<VERSION>"
```

### 2. Build the appliance VHDX

The CI pipeline (`.github/workflows/release.yml`) builds the VHDX from the
official Ubuntu 24.04 cloud image and the Docker Compose stack baked in.

```bash
# CI variable — set in GitHub Actions secrets / kv-hcs-vault-01
CLOUDGRANGE_VERSION=<VERSION>
```

### 3. Generate the SHA-256 manifest (mandatory for appliance)

```bash
sha256sum cloudgrange-appliance.vhdx > cloudgrange-appliance.sha256
# Verify the manifest round-trips correctly:
sha256sum --check cloudgrange-appliance.sha256
```

On Windows:

```powershell
$hash = (Get-FileHash -Path cloudgrange-appliance.vhdx -Algorithm SHA256).Hash.ToLower()
"$hash  cloudgrange-appliance.vhdx" | Set-Content cloudgrange-appliance.sha256 -Encoding ASCII
```

### 4. Sign the appliance with cosign (AB#1589)

The private signing key lives in `kv-hcs-vault-01` (secret:
`cloudgrange-appliance-signing-key`). Fetch it at signing time only — never
commit or persist it.

```bash
# Fetch private key from Key Vault (CI service principal must have Get permission)
az keyvault secret show --vault-name kv-hcs-vault-01 \
    --name cloudgrange-appliance-signing-key \
    --query value -o tsv > /tmp/cloudgrange-signing-key.key

# Sign the VHDX
cosign sign-blob \
    --key /tmp/cloudgrange-signing-key.key \
    --output-signature cloudgrange-appliance.sig \
    cloudgrange-appliance.vhdx

# Verify the signature before uploading
cosign verify-blob \
    --key cloudgrange-signing-key.pub \
    --signature cloudgrange-appliance.sig \
    cloudgrange-appliance.vhdx

# Shred the private key
shred -u /tmp/cloudgrange-signing-key.key
```

### 5. Generate the installer SHA-256 (AB#1598 self-check)

```powershell
$hash = (Get-FileHash -Path Install-CloudGrange.ps1 -Algorithm SHA256).Hash.ToLower()
"$hash  Install-CloudGrange.ps1" | Set-Content cloudgrange-installer.sha256 -Encoding ASCII
```

### 6. Bundle the offline installer

```powershell
# Include compose stack, signed images, and all scripts
Compress-Archive -Path @(
    'Install-CloudGrange.ps1',
    'cloudgrange-installer.sha256',
    'Update-CloudGrange.ps1',
    'Uninstall-CloudGrange.ps1',
    'scripts\',
    'compose\'
) -DestinationPath "Install-CloudGrange-Bundled-v<VERSION>.zip"

# Generate SHA256SUMS for the bundle
$hash = (Get-FileHash -Path "Install-CloudGrange-Bundled-v<VERSION>.zip" -Algorithm SHA256).Hash.ToLower()
"$hash  Install-CloudGrange-Bundled-v<VERSION>.zip" | Set-Content SHA256SUMS -Encoding ASCII
```

### 7. Publish the GitHub Release

Upload all artifacts from Step 2–6 as release assets. Verify that every
artifact listed in the **Release artifacts** table above is present before
publishing the release.

### 8. Post-release verification

Run the smoke test against the published release:

```powershell
# Download and verify
Invoke-WebRequest -Uri "https://github.com/cloudgrange-cloud/cloudgrange-installer/releases/download/v<VERSION>/cloudgrange-appliance.sha256" -OutFile cloudgrange-appliance.sha256
Invoke-WebRequest -Uri "https://github.com/cloudgrange-cloud/cloudgrange-installer/releases/download/v<VERSION>/cloudgrange-appliance.vhdx" -OutFile cloudgrange-appliance.vhdx

# Import and verify (runs full sha256 + cosign check)
.\Import-CloudGrangeAppliance.ps1 -AppliancePath .\cloudgrange-appliance.vhdx
```

## Key Vault secrets used in release

| Secret name | Purpose |
|---|---|
| `cloudgrange-appliance-signing-key` | RSA private key for cosign (never committed) |
| `cloudgrange-appliance-signing-pubkey` | Public key (also committed as `cloudgrange-signing-key.pub`) |
| `cloudgrange-release-token` | GitHub token for publishing release assets |
