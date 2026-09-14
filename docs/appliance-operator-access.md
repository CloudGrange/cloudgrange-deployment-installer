# Appliance operator access

This page explains how an operator who imports the CloudGrange appliance VHDX gets into it. It covers the one-use setup token, the temporary identity administrator password, and console and SSH access. The appliance ships no default credential and opens no extra network port for this.

## What the appliance creates at first boot

The first boot re-keys the VM (`cloudgrange-firstboot.service`). Among other things it generates:

- the platform's one-use **setup token**, written by the API into its secrets volume
- a random, temporary password for the identity administrator `admin@cloudgrange.local` (Keycloak realm `cloudgrange`, role PlatformAdmin), which must be changed at first sign-in
- an **operator SSH key pair** for the `cloudgrange` user. The public key goes into `authorized_keys`, and the private key never touches the VM's disk except inside the KVP pool described below.

## How the operator gets them

`cloudgrange-operator-access.service` publishes the credentials over two local channels. Neither one is reachable over the network.

| Channel | Who can read it | What it shows |
|---|---|---|
| **Hyper-V KVP data exchange** (guest-to-host pool) | Hyper-V administrators on the host, through `root\virtualization\v2`. Inside the guest, only root: `/var/lib/hyperv` is 0700 and the pool files are 0600 | `CloudGrange.State`, `CloudGrange.Address`, `CloudGrange.SetupUrl`, `CloudGrange.SetupToken`, `CloudGrange.RealmAdminUser`, `CloudGrange.RealmAdminPassword`, `CloudGrange.SshUser`, `CloudGrange.SshPrivateKey` |
| **VM console login banner** (`/etc/issue.d/90-cloudgrange.issue`, root 0600) | Anyone who can see a console getty of the VM: Hyper-V Administrators, users granted VMConnect access (`Grant-VMConnectAccess`), and anyone with access to a named pipe mapped to COM1 (the image boots with `console=ttyS0` too) | Setup URL, setup token, identity administrator and temporary password |

The banner is shown only on console gettys (the VM console and the serial port). It isn't shown over SSH. Treat VMConnect access and COM port pipes to an appliance that hasn't finished setup as privileged.

**Guest-side permissions.** `hv_kvp_daemon` would create its pool files world-readable under the default umask. The appliance therefore:

- runs the daemon with `UMask=0077` (drop-in `/etc/systemd/system/hv-kvp-daemon.service.d/10-cloudgrange-umask.conf`);
- has `cloudgrange-kvp.py` set the directory to 0700 and every pool file to 0600, verify mode and root ownership, and refuse to write any value otherwise.

### Recommended: Import-CloudGrangeAppliance.ps1

Run the import script as an administrator on the Hyper-V host:

```powershell
.\Import-CloudGrangeAppliance.ps1 -AppliancePath .\cloudgrange-appliance.vhdx -VmName cloudgrange `
    -SwitchName <existing-switch> [-VmIp 10.0.0.50 -PrefixLength 24 -Gateway 10.0.0.1 -DnsServers 10.0.0.2]
```

- Leave out `-VmIp` on a network with DHCP. Use it on a network without DHCP: the script then attaches a NoCloud seed that carries only the network configuration, with no users and no keys.
- The script creates the VM, turns on the Key-Value Pair Exchange integration service, starts the VM, and waits for `CloudGrange.State`. It then shows the setup URL, setup token and temporary identity administrator password **once** on the console.
- It saves the operator SSH private key to `%USERPROFILE%\.ssh\cloudgrange-<VmName>-operator_ed25519`, readable only by the current user, and prints the `ssh` command to use.

### Without the import script

As a Hyper-V administrator you can read the KVP items directly, before setup completes:

```powershell
$vm  = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='<VmName>'"
$kvp = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_KvpExchangeComponent
$kvp.GuestExchangeItems | ForEach-Object {
    $x = [xml]$_
    $n = ($x.INSTANCE.PROPERTY | Where-Object NAME -eq 'Name').VALUE
    if ($n -like 'CloudGrange.*') { '{0} = {1}' -f $n, ($x.INSTANCE.PROPERTY | Where-Object NAME -eq 'Data').VALUE }
}
```

Or open the VM console, where the login banner shows the setup token and the temporary password.

## While setup is pending: re-publication and rotation

- **New token.** If the API issues a new setup token (the API's token lasts 24 hours and a new one is issued at the next API start), the service publishes the new token to KVP and the banner within one poll (15 seconds).
- **72-hour window.** If setup has not completed within 72 hours of first publication, the service rotates both credentials and publishes them again; `Import-CloudGrangeAppliance.ps1` or the KVP query shows the current values.
  - It restarts the API once the setup token has expired, so the API issues a new one.
  - It resets the identity administrator's password to a new random temporary value, but only while that password is still the temporary one. A password the operator already chose is never overwritten; the temporary password is then just removed from KVP and the banner.
- **Settings.** Override the window with `CLOUDGRANGE_SETUP_WINDOW_SECONDS` in a drop-in for `cloudgrange-operator-access.service`. The window start is kept in `/etc/cloudgrange/operator-access-window-start`, so it survives reboots.

## After setup completes

The service checks the setup status every 15 seconds. Once setup has completed, it:

- removes `CloudGrange.SetupToken`, `CloudGrange.RealmAdminPassword` and `CloudGrange.SshPrivateKey` from KVP, overwriting the pool file's previous contents
- sets `CloudGrange.State` to `setup-complete`
- shreds the console banner and reloads the gettys
- removes the in-memory operator key directory
- deletes the API's setup token file if it is still present (the API normally deletes it when setup consumes the token)
- writes `/etc/cloudgrange/operator-access-cleared`, so nothing is published again after a reboot

These steps are covered by `test/appliance/test_operator_access.py` and `test/appliance/test_kvp_writer.py`.

Save the SSH private key (the import script does this for you) and record the temporary identity administrator password before you finish the setup wizard. Neither can be retrieved afterwards.

## Console and SSH access

- **SSH:** `ssh -i <saved key> cloudgrange@<address>`. The `cloudgrange` user has passwordless sudo. SSH password authentication is disabled.
- **Console:** the `cloudgrange` and `root` accounts have no password, so console login isn't possible by default. To enable it, set a password over SSH (`sudo passwd cloudgrange`).
- **Lost SSH key:** there is no other remote way in, by design. Recover through the Hyper-V host: attach the VHDX to a rescue VM, or use an operator-provided NoCloud seed with your own key.
