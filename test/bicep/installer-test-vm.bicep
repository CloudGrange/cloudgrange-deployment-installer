// installer-test-vm.bicep
// Provisions a clean Hyper-V-capable Windows Server 2025 Azure Edition VM
// for CloudSmith installer testing (Online / Bundled / Appliance modes).
// Deploy: az deployment group create -g <rg> --template-file installer-test-vm.bicep --parameters @installer-test-vm.params.json

@description('VM name')
param vmName string = 'cs-install-test'

@description('Azure region')
param location string = resourceGroup().location

@description('VM size — must support nested virtualisation (D4s_v5 or similar)')
param vmSize string = 'Standard_D4s_v5'

@description('Local administrator username')
param adminUsername string = 'csadmin'

@description('Local administrator password')
@secure()
param adminPassword string

// NIC + public IP so we can see it from run-command and optionally RDP
resource pip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${vmName}-pip'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${vmName}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-rdp'
        properties: {
          priority: 1000
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${vmName}-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.0.0.0/16'] }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.0.0.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: '${vnet.id}/subnets/default' }
          publicIPAddress: { id: pip.id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: false
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2025-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
        diskSizeGB: 256
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id }]
    }
    securityProfile: {
      // Disable Trusted Launch / VBS — required for nested Hyper-V on Azure
      securityType: 'Standard'
    }
  }
}

// Custom Script Extension: disable VBS/Credential Guard + install Hyper-V + reboot
resource vmSetup 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vm
  name: 'HyperVSetup'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      commandToExecute: 'powershell -ExecutionPolicy Bypass -Command "& { reg add HKLM\\SYSTEM\\CurrentControlSet\\Control\\DeviceGuard /v EnableVirtualizationBasedSecurity /t REG_DWORD /d 0 /f; reg add HKLM\\SYSTEM\\CurrentControlSet\\Control\\DeviceGuard /v RequirePlatformSecurityFeatures /t REG_DWORD /d 0 /f; Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart -ErrorAction SilentlyContinue; Install-WindowsFeature -Name Hyper-V,Hyper-V-PowerShell -IncludeManagementTools -ErrorAction SilentlyContinue; shutdown /r /t 10 }"'
    }
  }
}

output vmName string = vm.name
output publicIp string = pip.properties.ipAddress
output adminUser string = adminUsername
