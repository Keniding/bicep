// Parámetros base compartidos por todos los entornos.
// "using none" desacopla este archivo de una plantilla concreta (Bicep >= 0.31)
// para que pueda ser extendido con "extends" (GA en Bicep 0.44).
using none

param workload = 'demo'

param appConfig = {
  image: 'mcr.microsoft.com/k8se/quickstart:latest'
  minReplicas: 0
  maxReplicas: 3
  cpu: '0.25'
  memory: '0.5Gi'
  targetPort: 80
}
