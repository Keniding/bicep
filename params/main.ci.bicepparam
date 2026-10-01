using '../main.ci.bicep'
extends 'base.bicepparam'

param environment = 'dev'

param tags = {
  environment: 'dev'
  owner: 'keniding'
  costCenter: 'CC-0001'
  project: 'iac-bicep-demo'
}

param sampleSecretValue = readEnvironmentVariable('SAMPLE_SECRET', '')
