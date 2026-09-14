# Installer host prerequisites

These apply to `Install-CloudGrange.ps1` on the Windows Hyper-V host. The installer checks them and **fails closed**. It never silently downloads or installs software on the host.

| Prerequisite | Why | How to satisfy |
|---|---|---|
| Windows Server 2022/2025 (or Windows 10/11) with the Hyper-V role | Runs the `cloudgrange-docker` Ubuntu VM | `Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart` |
| PowerShell 7 (`pwsh`) | Installer runtime | Install PowerShell 7 from Microsoft |
| OpenSSH client (`ssh.exe`, `scp.exe`, `ssh-keygen.exe`) | Guest configuration over SSH | Built into Windows Server 2019+ (`Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0`) |
| **`qemu-img` on `PATH`** | Converts the Ubuntu cloud image to VHDX | See below |
| 64 GB free disk at the VHDX path | VM disk | — |

## qemu-img

If `qemu-img` is not on `PATH`, the installer stops with `CG-INST-ERR-004` and installs nothing.

Supported build: **QEMU for Windows `qemu-w64-setup-20260811.exe`** from <https://qemu.weilnetz.de/w64/> (the upstream Windows build feed referenced by qemu.org).

SHA-512:

```
5bcf9eed634e8575a37b74f445af41a2fe4106da512d0c30c368301d4c105037fdfab40a5287367a28a957624cddebbc8c07e16c88ab6634f554cdf3d16bf543
```

You have two options:

1. **Install it yourself (recommended).** Verify the hash, then install and add the install directory to `PATH`:

   ```powershell
   (Get-FileHash .\qemu-w64-setup-20260811.exe -Algorithm SHA512).Hash
   ```

2. **Explicit opt-in.** Run the installer with `-InstallPinnedQemu`. It downloads only that pinned file and verifies the SHA-512 before running it. On a mismatch it deletes the file and aborts (`CG-INST-ERR-005`). It then installs to `C:\Program Files\qemu` and adds that directory to the machine `PATH`.

Bundled (`-Mode Bundled`) installs need no internet in the guest VM: the Ubuntu image, Docker CE packages and every container image ship in `Install-CloudGrange-Bundled.zip`. QEMU is still a host prerequisite, and the host must already have it.
