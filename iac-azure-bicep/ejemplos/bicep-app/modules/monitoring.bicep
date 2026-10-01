// ============================================================================
// modules/monitoring.bicep  (scope: resourceGroup)
// Log Analytics Workspace + Application Insights (workspace-based)
// ============================================================================
import { tagsType } from '../shared/types.bicep'

@description('Región de despliegue')
param location string

@description('Nombre del Log Analytics Workspace')
param workspaceName string

@description('Nombre de Application Insights')
param appInsightsName string

@minValue(30)
@maxValue(730)
@description('Días de retención de logs')
param retentionInDays int = 30

param tags tagsType

resource law 'Microsoft.OperationalInsights/workspaces@2025-07-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id // dependencia implícita: no hace falta dependsOn
    DisableLocalAuth: true
  }
}

output workspaceId string = law.id
output workspaceName string = law.name
output appInsightsConnectionString string = appi.properties.ConnectionString
