targetScope = 'resourceGroup'

@description('Location of the GitHub Actions deployment identity.')
param location string = resourceGroup().location

@description('Exact GitHub OIDC subject prefix, including immutable owner and repository IDs for this repository.')
param githubSubjectPrefix string = 'repo:pelithne@45140408/devday-infra@1408351006'

@description('Protected GitHub environment used by the deployment job.')
param githubEnvironment string = 'production'

@description('Name of the user-assigned deployment identity.')
param identityName string = 'id-azure-day-github-actions'

var contributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b24988ac-6180-42a0-ab88-20f7382dd24c'
)
var roleAdministratorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
)

resource deploymentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

resource githubFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: deploymentIdentity
  name: 'github-production'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    subject: '${githubSubjectPrefix}:environment:${githubEnvironment}'
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}

resource contributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, deploymentIdentity.id, contributorRoleId)
  properties: {
    roleDefinitionId: contributorRoleId
    principalId: deploymentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource roleAdministrator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, deploymentIdentity.id, roleAdministratorRoleId)
  properties: {
    roleDefinitionId: roleAdministratorRoleId
    principalId: deploymentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output clientId string = deploymentIdentity.properties.clientId
output tenantId string = deploymentIdentity.properties.tenantId
output subscriptionId string = subscription().subscriptionId
output resourceGroupName string = resourceGroup().name
