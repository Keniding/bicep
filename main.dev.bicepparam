using '../main.bicep'
extends 'base.bicepparam'

param environment = 'dev'

param tags = {
  environment: 'dev'
  owner: 'keniding'
  costCenter: 'CC-0001'
  project: 'iac-bicep-demo'
}

// Lee una variable de entorno en tiempo de compilación (con valor por defecto)
param sampleSecretValue = readEnvironmentVariable('SAMPLE_SECRET', '')
