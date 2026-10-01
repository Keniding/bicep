// ============================================================================
// main.avm.bicep — misma idea usando Azure Verified Modules (registro público MCR)
// Versiones verificadas en MCR el 2026-10-01:
//   avm/res/operational-insights/workspace  0.16.1
//   avm/res/key-vault/vault                 0.14.2
//   avm/res/storage/storage-account         0.33.1
//   avm/res/app/managed-environment         0.16.0
//   avm/res/app/container-app               0.23.0
// NOTA: requiere acceso a mcr.microsoft.com para `bicep restore`.
//       Revisa el README de cada módulo: los nombres de parámetros pueden cambiar entre versiones 0.x.
// ============================================================================
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param workload string = 'demoavm'
param principalId string

var suffix = uniqueString(resourceGroup().id)

module law 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  params: {
    name: 'log-${workload}-${suffix}'
    location: location
  }
}

module kv 'br/public:avm/res/key-vault/vault:0.14.2' = {
  params: {
    name: take('kv${workload}${suffix}', 24)
    location: location
    enableRbacAuthorization: true
    enablePurgeProtection: false
    roleAssignments: [
      {
        principalId: principalId
        roleDefinitionIdOrName: 'Key Vault Secrets User'
        principalType: 'ServicePrincipal'
      }
    ]
    diagnosticSettings: [
      {
        workspaceResourceId: law.outputs.resourceId
      }
    ]
  }
}

module st 'br/public:avm/res/storage/storage-account:0.33.1' = {
  params: {
    name: take('st${workload}${suffix}', 24)
    location: location
    skuName: 'Standard_ZRS'
    kind: 'StorageV2'
    allowBlobPublicAccess: false
  }
}

output keyVaultUri string = kv.outputs.uri
output storageId string = st.outputs.resourceId
