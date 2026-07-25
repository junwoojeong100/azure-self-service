metadata description = '''
Per-business-user workload for the shared-platform isolation model.

Deployed into the business user's own resource group. The container app joins the
shared Container Apps environment by resource ID, and pushes and pulls images from
one repository inside the shared registry. The provisioning script creates the
required role assignments after this deployment.
'''

@description('Region for the resources in this business user resource group.')
param location string = resourceGroup().location

@description('Resource ID of the shared Container Apps environment to join.')
param containerAppsEnvironmentId string

@description('Login server of the shared container registry, for example "acrplatform.azurecr.io".')
param acrLoginServer string

@description('Repository inside the shared registry that this business user owns.')
param repositoryName string

@description('Name of this business user container app.')
param containerAppName string

@description('Name of the workload identity used only by GitHub Actions for this business user.')
param deploymentIdentityName string

@description('Maximum replica count. IT caps this because the consumption core quota is shared across the whole environment.')
@minValue(1)
@maxValue(10)
param maxReplicas int = 2

@description('Create the bootstrap container app. Set to false on repeat provisioning to preserve the current revision template.')
param createContainerApp bool = true

resource deploymentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: deploymentIdentityName
  location: location
}

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = if (createContainerApp) {
  name: containerAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: containerAppsEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      registries: [
        {
          server: acrLoginServer
          identity: 'system'
        }
      ]
      ingress: {
        external: true
        targetPort: 8000
      }
    }
    template: {
      containers: [
        {
          name: 'app'
          image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: maxReplicas
      }
    }
  }
}

output containerAppName string = containerAppName
output repositoryName string = repositoryName
output acrLoginServer string = acrLoginServer
output deploymentIdentityClientId string = deploymentIdentity.properties.clientId
output deploymentIdentityPrincipalId string = deploymentIdentity.properties.principalId
