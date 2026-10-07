targetScope = 'resourceGroup'

@description('Azure region for the AKS cluster.')
param location string = 'northeurope'

@description('Azure region for the container registry. Keep this unchanged for an existing registry.')
param acrLocation string = 'swedencentral'

@description('Name of the AKS cluster. Also used as the public API DNS prefix.')
@minLength(1)
@maxLength(63)
param clusterName string = 'aks-azure-day'

@description('Globally unique ACR name, containing only alphanumeric characters.')
@minLength(5)
@maxLength(50)
param acrName string = 'acr${uniqueString(resourceGroup().id)}'

@description('VM size for both node pools. Standard_D4s_v6 has 4 vCPUs and 16 GiB RAM.')
param nodeVmSize string = 'Standard_D4s_v6'

@description('Optional CIDR ranges allowed to reach the public API server. Empty allows access from any IP, with authentication still required.')
param apiServerAuthorizedIpRanges string[] = []

var acrPullRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '7f951dda-4ed3-4680-a7ca-43fe172d538d'
)

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: acrLocation
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource aks 'Microsoft.ContainerService/managedClusters@2025-01-01' = {
  name: clusterName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  properties: {
    dnsPrefix: clusterName
    enableRBAC: true
    apiServerAccessProfile: {
      enablePrivateCluster: false
      authorizedIPRanges: apiServerAuthorizedIpRanges
    }
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        count: 2
        vmSize: nodeVmSize
        osType: 'Linux'
        osSKU: 'Ubuntu'
        type: 'VirtualMachineScaleSets'
        enableAutoScaling: false
        upgradeSettings: {
          maxSurge: '1'
        }
      }
      {
        name: 'user'
        mode: 'User'
        count: 1
        vmSize: nodeVmSize
        osType: 'Linux'
        osSKU: 'Ubuntu'
        type: 'VirtualMachineScaleSets'
        enableAutoScaling: false
        upgradeSettings: {
          maxSurge: '1'
        }
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'cilium'
      podCidr: '10.244.0.0/16'
      serviceCidr: '10.0.0.0/16'
      dnsServiceIP: '10.0.0.10'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
    }
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
  }
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, aks.id, acrPullRoleDefinitionId)
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleDefinitionId
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

resource flux 'Microsoft.KubernetesConfiguration/extensions@2024-11-01' = {
  name: 'flux'
  scope: aks
  properties: {
    extensionType: 'microsoft.flux'
    releaseTrain: 'Stable'
    autoUpgradeMinorVersion: true
    scope: {
      cluster: {
        releaseNamespace: 'flux-system'
      }
    }
  }
}

module demoappGitops './demoapp-gitops.bicep' = {
  name: 'demoapp-gitops'
  params: {
    clusterName: aks.name
  }
  dependsOn: [
    flux
  ]
}

output clusterName string = aks.name
output clusterResourceId string = aks.id
output apiServerFqdn string = aks.properties.fqdn
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output kubeletIdentityObjectId string = aks.properties.identityProfile.kubeletidentity.objectId
output oidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
output fluxExtensionResourceId string = flux.id
output demoappGitopsConfigurationId string = demoappGitops.outputs.configurationId
