metadata description = '''
Shared platform resources for the fixed shared-platform architecture.

IT deploys this once into a platform resource group that business users have no
role on. Each business user keeps their own resource group for their container
app; that app joins the environment created here by resource ID.
'''

@description('Region for every shared platform resource.')
param location string = resourceGroup().location

@description('Name of the shared Container Apps environment that every business user joins.')
param containerAppsEnvironmentName string

@description('Globally unique ACR name, using lower-case alphanumeric characters only.')
param acrName string

@description('SKU of the shared container registry. Repository isolation uses ABAC, so Basic is enough.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param acrSku string = 'Basic'

@description('Retention in days for the shared Log Analytics workspace.')
@minValue(30)
@maxValue(730)
param logRetentionInDays int = 30

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${containerAppsEnvironmentName}-logs'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logRetentionInDays
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2025-11-01' = {
  name: acrName
  location: location
  sku: {
    name: acrSku
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
    // ABAC mode lets one registry hold every user's repository while each identity
    // is restricted to its own repository through a role assignment condition.
    roleAssignmentMode: 'AbacRepositoryPermissions'
  }
}

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerAppsEnvironmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    // Apps from different business users share this environment's network, so
    // encrypt traffic between replicas.
    peerTrafficConfiguration: {
      encryption: {
        enabled: true
      }
    }
  }
}

output platformResourceGroupName string = resourceGroup().name
output containerAppsEnvironmentId string = containerAppsEnvironment.id
output containerAppsEnvironmentName string = containerAppsEnvironment.name
output containerAppsEnvironmentDefaultDomain string = containerAppsEnvironment.properties.defaultDomain
output logAnalyticsWorkspaceId string = logAnalytics.id
output acrName string = acr.name
output acrId string = acr.id
output acrLoginServer string = acr.properties.loginServer
