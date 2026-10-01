// ============================================================================
// modules/identity.bicep  (scope: resourceGroup)
// User-Assigned Managed Identity para la app
// ============================================================================
import { tagsType } from '../shared/types.bicep'

param location string
param identityName string
param tags tagsType

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: identityName
  location: location
  tags: tags
}

output id string = uami.id
output principalId string = uami.properties.principalId
output clientId string = uami.properties.clientId
