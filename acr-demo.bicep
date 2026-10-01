// ============================================================================
// acr-demo.bicep — demuestra las cuatro formas de compartir código Bicep:
// local, ACR privado (br:corp), MCR público (br/public) y Template Specs (ts:).
// No forma parte del despliegue principal (main.bicep); es solo para la demo.
// ============================================================================
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param tags object = {
  environment: 'dev'
  owner: 'demo'
  costCenter: 'CC-0001'
  project: 'iac-bicep-demo'
}

// 1) Local: ruta relativa dentro del mismo repo
module identityLocal 'modules/identity.bicep' = {
  name: 'identity-local'
  params: {
    location: location
    identityName: 'id-demo-local'
    tags: tags
  }
}

// 2) ACR privado: alias "corp" definido en bicepconfig.json -> moduleAliases.br.corp
module identityFromAcr 'br/corp:identity:v1' = {
  name: 'identity-from-acr'
  params: {
    location: location
    identityName: 'id-demo-acr'
    tags: tags
  }
}

// 3) MCR público: Azure Verified Modules (prefijo br/public, sin alias)
module lawFromAvm 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'law-from-avm'
  params: {
    name: 'log-demo-avm-source'
    location: location
  }
}

// 4) Template Specs: alias "corpSpecs" definido en bicepconfig.json -> moduleAliases.ts.corpSpecs
module monitoringFromSpec 'ts/corpSpecs:monitoring-module:v1' = {
  name: 'monitoring-from-spec'
  params: {
    location: location
    workspaceName: 'log-demo-spec-source'
    appInsightsName: 'appi-demo-spec-source'
    tags: tags
  }
}
