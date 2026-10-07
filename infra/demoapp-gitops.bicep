targetScope = 'resourceGroup'

@description('Existing AKS cluster with the Flux extension installed.')
param clusterName string = 'aks-azure-day'

@description('Public application repository containing Kubernetes manifests.')
param repositoryUrl string = 'https://github.com/pelithne/devday-demoapp'

resource aks 'Microsoft.ContainerService/managedClusters@2025-01-01' existing = {
  name: clusterName
}

resource configuration 'Microsoft.KubernetesConfiguration/fluxConfigurations@2024-11-01' = {
  name: 'devday-demoapp'
  scope: aks
  properties: {
    namespace: 'flux-system'
    scope: 'cluster'
    sourceKind: 'GitRepository'
    suspend: false
    gitRepository: {
      url: repositoryUrl
      repositoryRef: {
        branch: 'main'
      }
      syncIntervalInSeconds: 60
      timeoutInSeconds: 60
    }
    kustomizations: {
      app: {
        path: './deploy'
        prune: true
        force: false
        wait: true
        syncIntervalInSeconds: 60
        retryIntervalInSeconds: 30
        timeoutInSeconds: 600
      }
    }
  }
}

output configurationId string = configuration.id
