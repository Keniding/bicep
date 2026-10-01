// ============================================================================
// main.ci.bicep — orquestador (scope: resourceGroup), pensado para CI/CD
//
// Variante de main.bicep para pipelines cuya identidad (OIDC) solo tiene
// permisos sobre un resource group existente, no sobre la suscripción. No
// crea el resource group (main.bicep sigue siendo el que lo crea la primera
// vez) — despliega los mismos módulos, con los mismos nombres derivados, así
// que actualiza los recursos existentes en vez de duplicarlos.
//
// Despliegue (con denyDelete vía deployment stack a nivel de resource group):
//   az stack group create -n stk-demo-dev -g rg-demo-dev-eastus2 -f main.ci.bicep \
//     -p params/main.ci.bicepparam --action-on-unmanage deleteResources --deny-settings-mode denyDelete
// ============================================================================
targetScope = 'resourceGroup'

metadata name = 'Demo app en Azure Container Apps (CI)'
metadata description = 'Variante de main.bicep a nivel de resource group, para pipelines con permisos acotados'
metadata owner = 'platform-team'

import { environmentType, tagsType, containerAppConfigType, resourceName, compactName } from 'shared/types.bicep'

@description('Nombre corto del workload (sin espacios)')
@minLength(2)
@maxLength(12)
param workload string

param environment environmentType

@description('Región Azure')
param location string = resourceGroup().location

@description('Tags obligatorios')
param tags tagsType

param appConfig containerAppConfigType

@description('Purge protection del Key Vault (true en prod)')
param enablePurgeProtection bool = environment == 'prod'

@secure()
param sampleSecretValue string = ''

var shortLocation = take(replace(location, ' ', ''), 10)
var names = {
  law: resourceName('log', workload, environment, shortLocation)
  appi: resourceName('appi', workload, environment, shortLocation)
  id: resourceName('id', workload, environment, shortLocation)
  kv: compactName('kv', workload, environment, subscription().subscriptionId)
  cae: resourceName('cae', workload, environment, shortLocation)
  ca: take(resourceName('ca', workload, environment, shortLocation), 32)
}

module monitoring 'modules/monitoring.bicep' = {
  params: {
    location: location
    workspaceName: names.law
    appInsightsName: names.appi
    retentionInDays: environment == 'prod' ? 90 : 30
    tags: tags
  }
}

module identity 'modules/identity.bicep' = {
  params: {
    location: location
    identityName: names.id
    tags: tags
  }
}

module keyVault 'modules/keyvault.bicep' = {
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

output appUrl string = 'https://${containerApp.outputs.fqdn}'
output keyVaultName string = keyVault.outputs.name
