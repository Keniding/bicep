// ============================================================================
// modules/keyvault.bicep  (scope: resourceGroup)
// Key Vault con RBAC + rol "Key Vault Secrets User" para la identidad de la app
// + diagnóstico enviado a Log Analytics
// ============================================================================
import { tagsType } from '../shared/types.bicep'

param location string
param keyVaultName string
param tags tagsType

@description('principalId de la identidad que leerá secretos')
param readerPrincipalId string

@description('Resource ID del Log Analytics Workspace para diagnósticos')
param workspaceId string

@description('Habilita purge protection (recomendado en prod; es irreversible)')
param enablePurgeProtection bool = false

@secure()
@description('Valor inicial opcional de un secreto de ejemplo')
param sampleSecretValue string = ''

resource kv 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    // purge protection no admite 'false' explícito una vez activado → se omite con null
    enablePurgeProtection: enablePurgeProtection ? true : null
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Recurso hijo con la sintaxis "parent"
resource secret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = if (!empty(sampleSecretValue)) {
  parent: kv
  name: 'sample-secret'
  properties: {
    value: sampleSecretValue
  }
}

// Recurso de extensión: role assignment con scope sobre el Key Vault.
// roleDefinitions() (Bicep >= 0.42) resuelve el ID del rol por su nombre.
resource kvSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, readerPrincipalId, 'Key Vault Secrets User')
  scope: kv
  properties: {
    roleDefinitionId: roleDefinitions('Key Vault Secrets User').id
    principalId: readerPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Recurso de extensión: diagnostic settings
// La versión 2021-05-01-preview es la que soporta 'categoryGroup'; se silencia el linter a propósito.
#disable-next-line use-recent-api-versions
resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: kv
  properties: {
    workspaceId: workspaceId
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output id string = kv.id
output name string = kv.name
output uri string = kv.properties.vaultUri
