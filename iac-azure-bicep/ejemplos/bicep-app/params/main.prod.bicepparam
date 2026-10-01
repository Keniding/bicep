using '../main.bicep'
extends 'base.bicepparam'

param environment = 'prod'

param tags = {
  environment: 'prod'
  owner: 'keniding'
  costCenter: 'CC-0001'
  project: 'iac-bicep-demo'
}

// En prod se sobrescribe la configuración de escalado
param appConfig = {
  image: 'mcr.microsoft.com/k8se/quickstart:latest'
  minReplicas: 2
  maxReplicas: 10
  cpu: '0.5'
  memory: '1.0Gi'
  targetPort: 80
  env: {
    LOG_LEVEL: 'Warning'
  }
}

// Secreto leído desde un Key Vault existente en tiempo de despliegue
// (el Key Vault debe tener enabledForTemplateDeployment = true)
// param sampleSecretValue = getSecret('<subId>', '<rg>', '<kvName>', 'sample-secret')
