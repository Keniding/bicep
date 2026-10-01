// ============================================================================
// main.bicep  — orquestador (scope: subscription)
// Crea el Resource Group y despliega los módulos dentro de él.
//
// Despliegue:
//   az deployment sub create -l eastus2 -f main.bicep -p params/main.dev.bicepparam
// What-if:
//   az deployment sub what-if -l eastus2 -f main.bicep -p params/main.dev.bicepparam
// Deployment stack:
//   az stack sub create -n stk-demo-dev -l eastus2 -f main.bicep \
//     -p params/main.dev.bicepparam --action-on-unmanage deleteResources --deny-settings-mode denyDelete
// ============================================================================
targetScope = 'subscription'

metadata name = 'Demo app en Azure Container Apps'
metadata description = 'RG + Log Analytics + App Insights + UAMI + Key Vault + Container App'
metadata owner = 'platform-team'

import { environmentType, tagsType, containerAppConfigType, resourceName, compactName } from 'shared/types.bicep'

// ---------------------------------------------------------------- parámetros
@description('Nombre corto del workload (sin espacios)')
@minLength(2)
@maxLength(12)
param workload string

param environment environmentType

@description('Región Azure')
param location string = deployment().location

@description('Tags obligatorios')
param tags tagsType

param appConfig containerAppConfigType

@description('Purge protection del Key Vault (true en prod)')
param enablePurgeProtection bool = environment == 'prod'

@secure()
param sampleSecretValue string = ''

// ---------------------------------------------------------------- variables
var shortLocation = take(replace(location, ' ', ''), 10)
var names = {
  rg: resourceName('rg', workload, environment, shortLocation)
  law: resourceName('log', workload, environment, shortLocation)
  appi: resourceName('appi', workload, environment, shortLocation)
  id: resourceName('id', workload, environment, shortLocation)
  kv: compactName('kv', workload, environment, subscription().subscriptionId)
  cae: resourceName('cae', workload, environment, shortLocation)
  ca: take(resourceName('ca', workload, environment, shortLocation), 32)
}

// ---------------------------------------------------------------- recursos
resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: names.rg
  location: location
  tags: tags
}

module monitoring 'modules/monitoring.bicep' = {
  scope: rg // módulo desplegado en otro scope (RG) desde una plantilla de suscripción
  params: {
    location: location
    workspaceName: names.law
    appInsightsName: names.appi
    retentionInDays: environment == 'prod' ? 90 : 30
    tags: tags
  }
}

module identity 'modules/identity.bicep' = {
  scope: rg
  params: {
    location: location
    identityName: names.id
    tags: tags
  }
}

module keyVault 'modules/keyvault.bicep' = {
  scope: rg
  params: {
    location: location
    keyVaultName: names.kv
    tags: tags
    readerPrincipalId: identity.outputs.principalId
    workspaceId: monitoring.outputs.workspaceId
    enablePurgeProtection: enablePurgeProtection
    sampleSecretValue: sampleSecretValue
  }
}

module containerApp 'modules/containerapp.bicep' = {
  scope: rg
  params: {
    location: location
    environmentName: names.cae
    appName: names.ca
    tags: tags
    workspaceName: monitoring.outputs.workspaceName
    identityId: identity.outputs.id
    identityClientId: identity.outputs.clientId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    keyVaultUri: keyVault.outputs.uri
    config: appConfig
  }
}

// ---------------------------------------------------------------- outputs
output resourceGroupName string = rg.name
output appUrl string = 'https://${containerApp.outputs.fqdn}'
output keyVaultName string = keyVault.outputs.name
