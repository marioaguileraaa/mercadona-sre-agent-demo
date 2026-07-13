targetScope = 'subscription'

param principalId string
param roleDefinitionId string
@allowed([
  'ServicePrincipal'
  'User'
  'Group'
])
param principalType string

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, principalId, roleDefinitionId)
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: roleDefinitionId
  }
}

output id string = assignment.id
