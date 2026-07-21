@description('Object ID of the Microsoft Entra business user who owns this resource group.')
param businessOwnerPrincipalId string

// Owner is intentionally scoped to the current resource group, never the subscription.
var ownerRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
)

resource businessOwnerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, businessOwnerPrincipalId, ownerRoleDefinitionId)
  properties: {
    principalId: businessOwnerPrincipalId
    principalType: 'User'
    roleDefinitionId: ownerRoleDefinitionId
  }
}
