# 01 · Contexto: Infraestructura como Código en Azure

## 1. ¿Qué es IaC y por qué importa?

**Infraestructura como Código (IaC)** es la práctica de describir la infraestructura (redes, cómputo, bases de datos, identidades, políticas) en archivos de texto versionables, revisables y ejecutables, en lugar de crearla a mano desde un portal.

| Propiedad | Qué significa en la práctica |
|-----------|------------------------------|
| **Declarativa** | Describes el *estado deseado* ("quiero un Key Vault con RBAC"), no los pasos ("crea, luego configura, luego…"). |
| **Idempotente** | Aplicar el mismo archivo N veces produce el mismo resultado; la segunda ejecución no duplica recursos. |
| **Versionable** | Vive en Git: historial, PRs, revisión por pares, rollback por commit. |
| **Reproducible** | Los entornos dev/qa/prod salen del mismo código con parámetros distintos. |
| **Auditable** | Cada cambio tiene autor, fecha y motivo (commit + pipeline). |
| **Testeable** | Linter, validación preflight, *what-if*/plan, policy-as-code antes de tocar producción. |

### Imperativo vs declarativo

```mermaid
flowchart LR
  subgraph Imperativo["Imperativo (scripts az / PowerShell)"]
    direction TB
    i1["az group create"] --> i2["az keyvault create"]
    i2 --> i3["az role assignment create"]
    i3 --> i4{"¿ya existía?<br/>¿falló a medias?"}
    i4 -->|"tú manejas<br/>los casos"| i5[Lógica de reintento / if-exists]
  end
  subgraph Declarativo["Declarativo (Bicep / ARM / Terraform)"]
    direction TB
    d1["Archivo con<br/>estado deseado"] --> d2["Motor calcula<br/>diferencias"]
    d2 --> d3["Crea / actualiza<br/>sólo lo necesario"]
  end
```

## 2. El plano de control: Azure Resource Manager (ARM)

Todo en Azure pasa por **Azure Resource Manager**, el servicio de despliegue y administración. Portal, Azure CLI, PowerShell, SDKs, REST, Bicep, Terraform y Pulumi son **clientes** de la misma API de ARM. Por eso:

- Las mismas reglas de **RBAC**, **Azure Policy**, **locks** y **límites** aplican a cualquier herramienta.
- Una herramienta de IaC es, en esencia, una forma distinta de *producir llamadas a ARM*.

```mermaid
flowchart TB
  subgraph Clientes
    Portal[Azure Portal]
    CLI[Azure CLI / PowerShell]
    SDK[SDKs / REST]
    Bicep[Bicep → ARM JSON]
    TF[Terraform / OpenTofu]
    Pulumi[Pulumi]
    K8s[ASO / Crossplane]
  end
  Clientes --> ARM["Azure Resource Manager<br/>(autenticación Entra ID, RBAC,<br/>Policy, locks, throttling)"]
  ARM --> RP1[Microsoft.Storage]
  ARM --> RP2[Microsoft.KeyVault]
  ARM --> RP3[Microsoft.App]
  ARM --> RP4["Microsoft.* (resto de resource providers)"]
```

### 2.1 Jerarquía de scopes (ámbitos)

```mermaid
flowchart TB
  T["Tenant (Microsoft Entra ID)"] --> MGR["Root Management Group"]
  MGR --> MG1["Management Group: Platform"]
  MGR --> MG2["Management Group: Landing Zones"]
  MG2 --> S1["Subscription: app-prod"]
  MG2 --> S2["Subscription: app-dev"]
  S1 --> RG1["Resource Group: rg-app-prod"]
  RG1 --> R1["Recursos: Key Vault, Container App, ..."]
```

| Scope | `targetScope` en Bicep | Comando CLI de despliegue | Casos típicos |
|-------|------------------------|---------------------------|---------------|
| Resource group | `resourceGroup` (por defecto) | `az deployment group create` | Workloads, la mayoría de recursos |
| Subscription | `subscription` | `az deployment sub create` | Crear RGs, policy/role assignments, budgets |
| Management group | `managementGroup` | `az deployment mg create` | Policy definitions/assignments de organización |
| Tenant | `tenant` | `az deployment tenant create` | Crear management groups, suscripciones (EA/MCA) |

### 2.2 Modos de despliegue

| Modo | Comportamiento | Riesgo |
|------|----------------|--------|
| **Incremental** (por defecto) | Crea/actualiza lo declarado. Lo que existe en el RG y **no** está en la plantilla se deja intacto. | Deriva (drift) y "basura" acumulada. |
| **Complete** | Elimina del RG lo que no está en la plantilla. Sólo a nivel de resource group. | Borrados accidentales. Microsoft recomienda **Deployment Stacks** en su lugar. |

> **Importante sobre el modo incremental:** ARM aplica las propiedades del recurso *como un todo* (PUT). Si omites una propiedad en la plantilla, el resource provider puede resetearla a su valor por defecto. "Incremental" se refiere a qué **recursos** se tocan, no a un *merge* de propiedades.

### 2.3 ¿Y el estado?

- **Bicep/ARM no tiene archivo de estado.** El estado real es lo que existe en Azure. ARM guarda un **historial de deployments** (máx. 800 por scope, se purgan automáticamente).
- **Terraform/OpenTofu/Pulumi** mantienen un **state file** (local o remoto: Azure Storage, HCP Terraform, Pulumi Cloud…) que mapea el código con los IDs reales.
- **Deployment Stacks** añaden a ARM una noción de "conjunto de recursos administrados", lo más parecido a estado que tiene el mundo nativo — sin archivo que custodiar.

## 3. Línea de tiempo de IaC en Azure

```mermaid
timeline
  title Evolución de IaC en Azure (hitos verificados)
  2014 : Azure Resource Manager y plantillas ARM JSON
  2020 : Project Bicep presentado (Ignite 2020, demo de Mark Russinovich)
  2021 : Bicep v0.3 primera versión con soporte oficial : Template Specs
  2023 : Ago - Terraform cambia a licencia BSL 1.1 : Nace OpenTofu (MPL 2.0)
  2024 : Abr - Radius entra a CNCF Sandbox : May 23 - Deployment Stacks GA
  2025 : Feb 27 - IBM completa la compra de HashiCorp : Pulumi azure-native v3 : Dic 10 - CDKTF archivado
  2026 : Ene - Bicep MCP Server en NuGet : Feb 16 - ALZ-Bicep clásico sale del accelerator : Abr - bicep console GA : Jun - extends en .bicepparam GA : Jul 27 - azurerm v5.0 : Jul 31 - Blueprints congela nuevas definiciones : Ago - What-if para Deployment Stacks GA : Sep 8 - Bicep v0.47.16
  2027 : Ene 31 - Retiro total de Azure Blueprints : Feb 16 - ALZ-Bicep clásico archivado
```

## 4. Familias de herramientas IaC para Azure

```mermaid
quadrantChart
  title Herramientas IaC para Azure
  x-axis "Solo Azure" --> "Multi-cloud"
  y-axis "DSL declarativo" --> "Lenguaje de propósito general"
  quadrant-1 "Multi-cloud + código"
  quadrant-2 "Azure + código"
  quadrant-3 "Azure + DSL"
  quadrant-4 "Multi-cloud + DSL"
  "ARM JSON": [0.08, 0.10]
  "Bicep": [0.15, 0.25]
  "azd (orquesta Bicep/TF)": [0.25, 0.40]
  "ASO v2 (CRDs)": [0.20, 0.15]
  "Terraform azurerm": [0.80, 0.25]
  "OpenTofu": [0.85, 0.30]
  "Crossplane": [0.75, 0.12]
  "Radius": [0.65, 0.45]
  "Pulumi": [0.85, 0.85]
```

| Familia | Herramientas | Cuándo encaja |
|---------|--------------|---------------|
| **Nativo Azure (DSL)** | ARM JSON, **Bicep**, Template Specs, Deployment Stacks | 100 % Azure, soporte día 0, sin estado que custodiar, integración con Policy/portal |
| **Multi-cloud (DSL)** | Terraform (HCL), OpenTofu | Varias nubes/SaaS (GitHub, Datadog, Cloudflare…), equipos ya invertidos en HCL |
| **Lenguajes generales** | Pulumi (TS, Python, Go, C#, Java, YAML) | Equipos de software que quieren tests unitarios, abstracciones OOP, loops reales |
| **Kubernetes-native** | Azure Service Operator v2, Crossplane | GitOps (Flux/Argo CD) donde todo se declara como CRD |
| **Plataforma de aplicaciones** | azd, Radius | Experiencia "dev-first": app + infra con un comando; recetas para platform engineering |

## 5. Vocabulario esencial

| Término | Definición |
|---------|-----------|
| **Resource provider (RP)** | Servicio que implementa un tipo de recurso, p. ej. `Microsoft.KeyVault`. Debe estar *registrado* en la suscripción. |
| **Resource type + apiVersion** | `Microsoft.KeyVault/vaults@2024-11-01`. La versión de API define el esquema de propiedades. |
| **Deployment** | Recurso `Microsoft.Resources/deployments`: una ejecución de plantilla con su resultado e historial. |
| **Nested / linked deployment** | Un deployment dentro de otro. En Bicep cada `module` se convierte en un deployment anidado. |
| **Preflight validation** | Validación que ARM hace antes de crear nada (sintaxis, cuotas, Policy con efecto `deny`, permisos). |
| **What-if** | Previsualización de cambios (equivalente a `terraform plan`). |
| **Template Spec** | Recurso de Azure que almacena una plantilla versionada y compartible con RBAC. |
| **Deployment Stack** | Recurso que agrupa y gobierna el ciclo de vida de los recursos de una plantilla (borrar/desvincular lo que sale, deny assignments). |
| **AVM** | Azure Verified Modules: módulos oficiales Bicep/Terraform mantenidos por Microsoft. |
| **Drift** | Diferencia entre lo declarado en código y lo real en Azure (por cambios manuales). |

---
➡️ Siguiente: [02 · Arquitectura ARM + Bicep](02-arquitectura-arm-bicep.md)
