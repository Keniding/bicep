// ============================================================================
// shared/types.bicep
// Tipos y funciones reutilizables (user-defined types + user-defined functions)
// Se consumen con:  import { environmentType, tagsType, resourceName } from '../shared/types.bicep'
// ============================================================================

metadata description = 'Tipos y funciones compartidas para todo el proyecto'

@export()
@description('Entornos soportados')
type environmentType = 'dev' | 'qa' | 'prod'

@export()
@description('Tags obligatorios de la organización')
@sealed()
type tagsType = {
  environment: environmentType
  owner: string
  costCenter: string
  project: string
}

@export()
@description('Configuración de la app de contenedor')
type containerAppConfigType = {
  @description('Imagen completa, ej. mcr.microsoft.com/k8se/quickstart:latest')
  image: string

  @minValue(0)
  @maxValue(30)
  minReplicas: int

  @minValue(1)
  @maxValue(300)
  maxReplicas: int

  @description('CPU en cores (string para admitir decimales: 0.25, 0.5, 1.0)')
  cpu: '0.25' | '0.5' | '0.75' | '1.0' | '2.0'

  memory: '0.5Gi' | '1.0Gi' | '1.5Gi' | '2.0Gi' | '4.0Gi'

  targetPort: int

  @description('Opcional: variables de entorno no secretas')
  env: { *: string }?
}

@export()
@description('Construye un nombre estándar: <abreviatura>-<workload>-<env>-<region>')
func resourceName(abbreviation string, workload string, env environmentType, location string) string =>
  toLower('${abbreviation}-${workload}-${env}-${location}')

@export()
@description('Nombre sin guiones y con sufijo único (para Storage / Key Vault, máx. 24 chars)')
func compactName(abbreviation string, workload string, env environmentType, seed string) string =>
  take(toLower('${abbreviation}${replace(workload, '-', '')}${env}${uniqueString(seed)}'), 24)
