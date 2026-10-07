using './main.bicep'

param location = 'northeurope'
param acrLocation = 'swedencentral'
param clusterName = 'aks-hsb-azure-day'
param nodeVmSize = 'Standard_D4s_v6'

// ACR uses a deterministic, globally unique name based on the resource group.
// Set apiServerAuthorizedIpRanges in main.bicep or override it at deployment time
// to restrict the public API to trusted CIDR ranges.
