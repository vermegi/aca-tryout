param vnetName string = 'vnet-aca'
param location string = resourceGroup().location
param vnetAddressPrefixes array = [
  '10.1.0.0/22'
]

param subnetName string = 'snet-aca'
param subnetAddressPrefix string = '10.1.0.0/23'
param privateEndpointsSubnetName string = 'snet-pep'
param privateEndpointsSubnetAddressPrefix string = '10.1.2.0/27'

param acrName string = 'acraca'
param acrSku string = 'Premium'
param networkRuleBypassOptions string = 'AzureServices'

@description('The name of the private endpoint to be created for Azure Container Registry.')
param containerRegistryPrivateEndpointName string = 'acr-aca-pep'

@description('The name of the user assigned identity to be created to pull image from Azure Container Registry.')
param containerRegistryUserAssignedIdentityName string = 'acr-aca-identity'

@description('Required. Name of your Azure Container Apps Environment. ')
param acaName string = 'aca-env-tryout'

@description('If true, the endpoint is an internal load balancer. If false the hosted apps are exposed on an internet-accessible IP address ')
param vnetEndpointInternal bool = false

@description('Optional, the workload profiles required by the end user. The default is "Consumption", and is automatically added whether workload profiles are specified or not.')
param workloadProfiles array = [
  {
    workloadProfileType: 'D4'
    name: 'D4'
    minimumCount: 1
    maximumCount: 3
  }
]
// Example of a workload profile below:
// [ {
//     workloadProfileType: 'D4'  // available types can be found here: https://learn.microsoft.com/en-us/azure/container-apps/workload-profiles-overview#profile-types
//     name: '<name of the workload profile>'
//     minimumCount: 1
//     maximumCount: 3
//   }
// ]

// VNet with a subnet that has a delegation to the Microsoft.App/environments service
var defaultSubnets = [
  {
    name: subnetName
    properties: {
      addressPrefix: subnetAddressPrefix
      delegations: [
        {
          name: 'envdelegation'
          properties: {
            serviceName: 'Microsoft.App/environments'
          }
        }
      ]
    }
  }
  {
    name:privateEndpointsSubnetName
    properties: {
      addressPrefix: privateEndpointsSubnetAddressPrefix
    }
  }
]

var identity =  {
  type: 'SystemAssigned'
  userAssignedIdentities: null
}

var privateDnsZoneNamesACR = 'privatelink.azurecr.io'
var containerRegistryResourceName = 'registry'
var containerRegistryPullRoleGuid='7f951dda-4ed3-4680-a7ca-43fe172d538d'

var defaultWorkloadProfile = [
  {
    workloadProfileType: 'Consumption'
    name: 'Consumption'
  }
]

var effectiveWorkloadProfiles = workloadProfiles != [] ? concat(defaultWorkloadProfile, workloadProfiles) : defaultWorkloadProfile

var vNetLinks = [
  {
    vnetName: vnetName
    vnetId: vnet.id
    registrationEnabled: false
  }
]

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: vnetAddressPrefixes
    }
    subnets: defaultSubnets
  }
}

// ACR
resource registry 'Microsoft.ContainerRegistry/registries@2022-02-01-preview' = {
  name: acrName
  location: location
  identity: identity
  sku: {
    name: acrSku
  }
  properties: {
    anonymousPullEnabled: false
    adminUserEnabled: false
    encryption: null
    dataEndpointEnabled: false
    publicNetworkAccess: 'Disabled'
    networkRuleBypassOptions: networkRuleBypassOptions
    networkRuleSet: null
  }
}

module containerRegistryNetwork './shared/network/private-networking.bicep' = {
  name:take('containerRegistryNetworkDeployment-${deployment().name}', 64)
  params: {
    location: location
    azServicePrivateDnsZoneName: privateDnsZoneNamesACR
    azServiceId: registry.id
    privateEndpointName: containerRegistryPrivateEndpointName
    privateEndpointSubResourceName: containerRegistryResourceName
    virtualNetworkLinks: vNetLinks
    subnetId: vnet.properties.subnets[1].id
  }
}

resource containerRegistryUserAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: containerRegistryUserAssignedIdentityName
  location: location
}


module containerRegistryPullRoleAssignment './shared/role-assignments/role-assignment.bicep' = {
  name: take('containerRegistryPullRoleAssignmentDeployment-${deployment().name}', 64)
  params: {
    name: 'ra-containerRegistryPullRoleAssignment'
    principalId: containerRegistryUserAssignedIdentity.properties.principalId
    resourceId: registry.id
    roleDefinitionId: containerRegistryPullRoleGuid
  }
}

resource acaEnvironment 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: acaName
  location: location
  properties: {
    zoneRedundant: false
    vnetConfiguration: {
      internal: vnetEndpointInternal
    }
    workloadProfiles: effectiveWorkloadProfiles
    appLogsConfiguration:  {
      destination: 'azure-monitor'
    }
  }
}

@description('The Private DNS zone containing the ACA load balancer IP')
module containerAppsEnvironmentPrivateDnsZone './shared/network/private-dns-zone.bicep' = {
  name: 'containerAppsEnvironmentPrivateDnsZone-${uniqueString(resourceGroup().id)}'
  params: {
    name: acaEnvironment.properties.defaultDomain
    virtualNetworkLinks: [
      {
        vnetName: vnetName  /* Link to spoke */
        vnetId: vnet.id
        registrationEnabled: false
      }
    ]
    aRecords: [
      {
        name: '*'
        ipv4Address: acaEnvironment.properties.staticIp
      }
    ]
  }
}

@description('The "Hello World" Container App.')
resource containerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'helloworld-app'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${containerRegistryUserAssignedIdentity.id}' : {}
    }
  }
  properties: {
    configuration: {
      activeRevisionsMode: 'single'
      ingress: {
        allowInsecure: false
        external: true
        targetPort: 80
        transport: 'auto'
      }
      registries: [
        {
          identity: containerRegistryUserAssignedIdentity.id
          username: containerRegistryUserAssignedIdentity.id
          server: registry.properties.loginServer
        }
      ]
      secrets: []
    }
    environmentId: acaEnvironment.id
    workloadProfileName: 'Consumption'
    template: {
      containers: [
        {
          name: 'inspectorgadget'
          // Production readiness change
          // All workloads should be pulled from your private container registry and not public registries.
          image: 'acraca.azurecr.io/inspectorgadget:latest'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 10
      }
      volumes: []
    }
  }
}

@description('The "Hello World" Container App.')
resource containerAppDed 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'helloworld-app-dedicated'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${containerRegistryUserAssignedIdentity.id}' : {}
    }
  }
  properties: {
    configuration: {
      activeRevisionsMode: 'single'
      ingress: {
        allowInsecure: false
        external: true
        targetPort: 80
        transport: 'auto'
      }
      registries: [
        {
          identity: containerRegistryUserAssignedIdentity.id
          username: containerRegistryUserAssignedIdentity.id
          server: registry.properties.loginServer
        }
      ]
      secrets: []
    }
    environmentId: acaEnvironment.id
    workloadProfileName: 'D4'
    template: {
      containers: [
        {
          name: 'inspectorgadget'
          // Production readiness change
          // All workloads should be pulled from your private container registry and not public registries.
          image: 'acraca.azurecr.io/inspectorgadget:latest'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 10
      }
      volumes: []
    }
  }
}

output RegistryFQDN string = registry.properties.loginServer
