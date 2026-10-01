// ============================================================================
// modules/containerapp.bicep  (scope: resourceGroup)
// Container Apps Environment + Container App con identidad administrada
// ============================================================================
import { tagsType, containerAppConfigType } from '../shared/types.bicep'

param location string
param environmentName string
param appName string
param tags tagsType

@description('Nombre del Log Analytics Workspace (debe existir en el mismo RG)')
param workspaceName string

@description('Resource ID de la identidad user-assigned')
param identityId string

@description('Client ID de la identidad (para DefaultAzureCredential en la app)')
param identityClientId string

param appInsightsConnectionString string
param keyVaultUri string
param config containerAppConfigType

// Referencia a un recurso existente: no lo despliega, sólo lo lee.
resource law 'Microsoft.OperationalInsights/workspaces@2025-07-01' existing = {
  name: workspaceName
}

resource cae 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey // función list* sobre recurso existente
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

// Variables de entorno base + las opcionales del config (spread en arrays/objetos)
var baseEnv = [
  { name: 'AZURE_CLIENT_ID', value: identityClientId }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
  { name: 'KEYVAULT_URI', value: keyVaultUri }
]
var extraEnv = [for item in items(config.?env ?? {}): { name: item.key, value: item.value }]

resource app 'Microsoft.App/containerApps@2025-01-01' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    environmentId: cae.id
    workloadProfileName: 'Consumption'
    configuration: {
      ingress: {
        external: true
        targetPort: config.targetPort
        transport: 'auto'
        allowInsecure: false
      }
      activeRevisionsMode: 'Single'
    }
    template: {
      containers: [
        {
          name: 'app'
          image: config.image
          resources: {
            cpu: json(config.cpu)
            memory: config.memory
          }
          env: [...baseEnv, ...extraEnv]
        }
      ]
      scale: {
        minReplicas: config.minReplicas
        maxReplicas: config.maxReplicas
        rules: [
          {
            name: 'http-rule'
            http: {
              metadata: {
                concurrentRequests: '50'
              }
            }
          }
        ]
      }
    }
  }
}

output fqdn string = app.properties.configuration.ingress.fqdn
output appId string = app.id
