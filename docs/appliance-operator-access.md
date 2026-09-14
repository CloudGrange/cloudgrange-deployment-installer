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
| **Hyper-V KVP data exchange** (guest-to-host pool) | Hyper-V administrators on the host, through `root\virtualization\v2` | `CloudGrange.State`, `CloudGrange.Address`, `CloudGrange.SetupUrl`, `CloudGrange.SetupToken`, `CloudGrange.RealmAdminUser`, `CloudGrange.RealmAdminPassword`, `CloudGrange.SshUser`, `CloudGrange.SshPrivateKey` |
| **VM console login banner** (`/etc/issue.d/90-cloudgrange.issue`) | Anyone who can open the VM console (Hyper-V Manager or VMConnect, which also needs host access) | Setup URL, setup token, identity administrator and temporary password |

The banner is shown only on the local console gettys. It isn't shown over SSH.

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

## After setup completes

The service checks the setup status every 15 seconds. Once setup has completed, it:

- removes `CloudGrange.SetupToken`, `CloudGrange.RealmAdminPassword` and `CloudGrange.SshPrivateKey` from KVP, overwriting the pool file's previous contents
- sets `CloudGrange.State` to `setup-complete`
- deletes the console banner and reloads the gettys
- writes `/etc/cloudgrange/operator-access-cleared`, so nothing is published again after a reboot

The API itself deletes the setup token file when setup consumes the token.

Save the SSH private key (the import script does this for you) and record the temporary identity administrator password before you finish the setup wizard. Neither can be retrieved afterwards.

## Console and SSH access

- **SSH:** `ssh -i <saved key> cloudgrange@<address>`. The `cloudgrange` user has passwordless sudo. SSH password authentication is disabled.
- **Console:** the `cloudgrange` and `root` accounts have no password, so console login isn't possible by default. To enable it, set a password over SSH (`sudo passwd cloudgrange`).
- **Lost SSH key:** there is no other remote way in, by design. Recover through the Hyper-V host: attach the VHDX to a rescue VM, or use an operator-provided NoCloud seed with your own key.
