# 02 · Arquitectura: cómo funciona Bicep sobre Azure Resource Manager

## 1. Vista general de componentes

```mermaid
flowchart LR
  subgraph Dev["Estación de trabajo / CI"]
    VS["VS Code + extensión Bicep<br/>(Language Server, IntelliSense,<br/>linter, visualizer)"]
    MCP["Bicep MCP Server<br/>(agentes IA)"]
    CLI["Bicep CLI<br/>(bicep / az bicep)"]
    CFG["bicepconfig.json"]
    SRC[".bicep / .bicepparam"]
  end

  subgraph Registries["Fuentes de módulos"]
    MCR["MCR público<br/>br/public:avm/..."]
    ACR["ACR privado<br/>br:miacr.azurecr.io/..."]
    TS["Template Specs<br/>ts:sub/rg/spec:ver"]
  end

  subgraph Azure["Azure (plano de control)"]
    ARM["Azure Resource Manager<br/>Deployments API"]
    POL["Azure Policy<br/>(preflight / deny / audit)"]
    RBAC["RBAC + deny assignments"]
    STK["Deployment Stacks"]
    RPs["Resource Providers<br/>Microsoft.*"]
    EXT["Extensiones Bicep<br/>(Microsoft Graph, Kubernetes)"]
  end

  SRC --> CLI
  CFG --> CLI
  VS --- CLI
  MCP --- CLI
  CLI -- "restore" --> MCR & ACR & TS
  CLI -- "build → ARM JSON<br/>(languageVersion 2.0)" --> ARM
  STK --> ARM
  ARM --> POL
  ARM --> RBAC
  ARM --> RPs
  ARM --> EXT
```

**Idea clave:** Bicep es un *transpilador*. La extensión, el CLI y el MCP server comparten el mismo compilador (.NET; desde Bicep 0.41 sobre **.NET 10**). Azure nunca "ve" Bicep: recibe una plantilla ARM JSON. La única excepción práctica es que `az`/PowerShell compilan por ti de forma transparente al pasar un `.bicep` o `.bicepparam`.

## 2. Pipeline de compilación

```mermaid
flowchart TB
  A[".bicep / .bicepparam"] --> B["Lexer + Parser<br/>→ árbol sintáctico"]
  B --> C["Binder<br/>(símbolos, imports,<br/>módulos, extensiones)"]
  C --> R{"¿Módulos externos?"}
  R -- sí --> RS["bicep restore<br/>→ caché local ~/.bicep"]
  RS --> D
  R -- no --> D["Type checker<br/>(tipos de recursos de Azure,<br/>user-defined types)"]
  D --> E["Linter<br/>(reglas de bicepconfig.json)"]
  E --> F["Emitter"]
  F --> G["ARM JSON<br/>main.json"]
  F --> H["Parámetros JSON<br/>(build-params)"]
```

- **Type checker:** Bicep trae embebidos los esquemas de tipos (`bicep-types-az`) generados desde las especificaciones REST de Azure. Si usas una `apiVersion` que no conoce, emite el warning `BCP081` pero **compila igual** (por eso el soporte es "día 0").
- **Linter:** se ejecuta en el editor y en `bicep lint`/`bicep build`. Las reglas se configuran por nivel (`off`, `info`, `warning`, `error`).

### 2.1 Qué produce el compilador (ejemplo real)

El `main.bicep` del ejemplo (≈115 líneas + 4 módulos + tipos, ≈450 líneas en total) genera **≈1 080 líneas / 35 KB** de ARM JSON. Extracto del resultado real compilado con 0.47.16:

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#",
  "languageVersion": "2.0",
  "contentVersion": "1.0.0.0",
  "metadata": {
    "_generator": { "name": "bicep", "version": "0.47.16.16243" },
    "name": "Demo app en Azure Container Apps"
  },
  "definitions": { "containerAppConfigType": {}, "environmentType": {}, "tagsType": {} },
  "functions": [ { "namespace": "__bicep", "members": { "compactName": {}, "resourceName": {} } } ],
  "resources": {
    "rg":           { "type": "Microsoft.Resources/resourceGroups", "apiVersion": "2025-04-01" },
    "monitoring":   { "type": "Microsoft.Resources/deployments", "dependsOn": ["rg"] },
    "identity":     { "type": "Microsoft.Resources/deployments", "dependsOn": ["rg"] },
    "keyVault":     { "type": "Microsoft.Resources/deployments", "dependsOn": ["identity", "monitoring", "rg"] },
    "containerApp": { "type": "Microsoft.Resources/deployments", "dependsOn": ["identity", "keyVault", "monitoring", "rg"] }
  }
}
```

Observa:

1. **`languageVersion: "2.0"`** → `resources` es un **objeto con nombres simbólicos** (no un array). Bicep lo emite automáticamente cuando usas tipos definidos por el usuario, `existing` con ciertas features, extensiones, etc.
2. **`definitions`** y **`functions`** → los `type` y `func` de Bicep se trasladan al ARM JSON.
3. **Cada `module` es un `Microsoft.Resources/deployments`** (deployment anidado) con `expressionEvaluationOptions.scope = inner`.
4. **`dependsOn` lo calcula Bicep** a partir de las referencias simbólicas (`identity.outputs.principalId` ⇒ depende de `identity`). Nunca lo escribiste a mano.
5. El nombre del deployment de un módulo es opcional; si lo omites, Bicep genera `'<simbolo>-<uniqueString(...)>'`.

## 3. Flujo de un despliegue de extremo a extremo

```mermaid
sequenceDiagram
  autonumber
  actor U as Usuario / Pipeline
  participant CLI as az CLI + Bicep
  participant ARM as Azure Resource Manager
  participant POL as Azure Policy
  participant RP as Resource Providers
  participant H as Historial de deployments

  U->>CLI: az deployment sub create -f main.bicep -p dev.bicepparam
  CLI->>CLI: restore módulos + build → ARM JSON + params JSON
  CLI->>ARM: PUT /subscriptions/{id}/providers/Microsoft.Resources/deployments/{name}
  ARM->>ARM: Autenticación (Entra ID) y autorización (RBAC)
  ARM->>ARM: Validación de plantilla (sintaxis, expresiones, límites)
  ARM->>POL: Preflight: evaluar policies con efecto deny
  POL-->>ARM: OK / Denegado (falla antes de crear nada)
  ARM->>ARM: Construye grafo de dependencias (dependsOn)
  par Recursos sin dependencias en paralelo
    ARM->>RP: PUT recurso A
    ARM->>RP: PUT recurso B
  end
  RP-->>ARM: 200/201 o 202 Accepted (operación async)
  ARM->>RP: Polling de operaciones asíncronas
  ARM->>RP: PUT recursos dependientes (C depende de A)
  ARM->>H: Guarda estado, outputs y operaciones
  ARM-->>CLI: provisioningState: Succeeded / Failed + outputs
  CLI-->>U: Resultado
```

Puntos relevantes:

- **Paralelismo:** ARM despliega en paralelo todo lo que no tiene dependencias entre sí. Para forzar serialización en bucles se usa `@batchSize(n)`.
- **Reintentos:** desde Bicep 0.45.6 el decorador **`@retryOn([...códigos], n)`** está GA para reintentar un recurso ante códigos de error transitorios concretos.
- **Sin rollback transaccional:** si un recurso falla, los ya creados quedan. Existe `--rollback-on-error` (vuelve al último deployment exitoso, sólo a nivel RG), pero lo usual es corregir y redesplegar (idempotencia).

## 4. What-if: previsualización de cambios

```mermaid
flowchart LR
  A["Plantilla + parámetros"] --> B["ARM expande plantillas<br/>anidadas (máx. 500,<br/>timeout 5 min)"]
  B --> C["Lee estado actual<br/>de cada recurso (GET)"]
  C --> D["Normaliza y compara<br/>propiedad a propiedad"]
  D --> E["Create / Modify / Delete*<br/>NoChange / Ignore / Deploy /<br/>NoEffect / Unsupported"]
```

| Comando | Scope |
|---------|-------|
| `az deployment group what-if` | Resource group |
| `az deployment sub what-if` | Subscription |
| `az deployment mg what-if` | Management group |
| `az deployment tenant what-if` | Tenant |
| `az deployment group create --confirm-with-what-if` (`-c`) | Muestra what-if y pide confirmación |
| `az stack-whatif group/sub/mg create` | What-if para **Deployment Stacks** (GA, ago 2026) |

Opciones útiles:

- `--result-format FullResourcePayloads | ResourceIdOnly`
- `--exclude-change-types Ignore NoChange`
- `--validation-level Provider | ProviderNoRbac | Template` (Azure CLI ≥ 2.76.0). `ProviderNoRbac` permite correr what-if con permisos de **solo lectura** — ideal para PRs.
- `--no-pretty-print` para obtener JSON y procesarlo en el pipeline.

**Limitaciones conocidas:** ruido en propiedades con valores por defecto del servidor, recursos referenciados con `templateLink` no se evalúan, `Delete` sólo aparece en modo *complete* (o en stacks con `actionOnUnmanage` de borrado), y si se superan 500 plantillas anidadas u 800 RGs los recursos salen como `Ignore`.

## 5. Arquitectura de módulos y scopes cruzados

Un archivo con `targetScope = 'subscription'` puede crear un RG y desplegar módulos *dentro* de él con `scope: rg`. ARM lo implementa como deployments anidados en distintos scopes:

```mermaid
flowchart TB
  subgraph SUB["Deployment (scope: subscription) · main.bicep"]
    RG["resource rg<br/>Microsoft.Resources/resourceGroups"]
    subgraph RGS["Deployments anidados (scope: rg)"]
      M1["module monitoring<br/>Log Analytics + App Insights"]
      M2["module identity<br/>User-Assigned MI"]
      M3["module keyVault<br/>KV + roleAssignment + diag"]
      M4["module containerApp<br/>CAE + Container App"]
    end
  end
  RG --> M1 & M2
  M1 -- "workspaceId" --> M3
  M2 -- "principalId" --> M3
  M1 -- "workspaceName, connStr" --> M4
  M2 -- "id, clientId" --> M4
  M3 -- "vaultUri" --> M4
```

Funciones de scope disponibles: `resourceGroup('nombre')`, `resourceGroup('subId','nombre')`, `subscription('id')`, `managementGroup('id')`, `tenant()`. Los recursos de **extensión** (role assignments, locks, diagnostic settings, policy assignments) usan la propiedad `scope: <recurso>` para aplicarse sobre otro recurso.

## 6. Arquitectura de Deployment Stacks (resumen)

```mermaid
flowchart TB
  T["Plantilla Bicep / Template Spec"] --> S["Microsoft.Resources/deploymentStacks"]
  S --> D["Deployment ARM"]
  S --> MR["Lista de recursos administrados"]
  S --> DA["Deny assignment<br/>(denyDelete / denyWriteAndDelete)"]
  MR --> R1["Recurso 1"]
  MR --> R2["Recurso 2"]
  MR --> R3["Recurso eliminado de la plantilla"]
  R3 -. "actionOnUnmanage:<br/>detachAll / deleteResources / deleteAll" .-> X["Desvincular o borrar"]
```

Detalle completo en [06 · Deployment Stacks y gobernanza](06-deployment-stacks-gobernanza.md).

## 7. Límites de plataforma que afectan al diseño

| Límite (ARM) | Valor |
|--------------|-------|
| Parámetros por plantilla | 256 |
| Variables por plantilla | 256 |
| Recursos por plantilla (incluye `copy`) | 800 |
| Outputs por plantilla | 64 |
| Longitud de una expresión | 24 576 caracteres |
| Tamaño de plantilla compilada | 4 MB |
| Tamaño de una definición de recurso | 1 MB |
| Tamaño de archivo de parámetros | 4 MB |
| Tamaño de request a la API de ARM | 4 194 304 bytes |
| Historial de deployments por RG / suscripción / MG | 800 (purga automática) |
| Recursos en una plantilla exportada desde portal | 200 |
| What-if: plantillas anidadas | 500 |

**Implicaciones de diseño:** combina parámetros en objetos tipados (para no llegar a 256), divide grandes plataformas en varios deployments/stacks, y vigila el tamaño cuando inyectas archivos con `loadTextContent()`/`loadFileAsBase64()`.

## 8. Seguridad del flujo

```mermaid
flowchart LR
  GH["GitHub Actions / Azure Pipelines"] -- "OIDC token<br/>(federated credential)" --> ENTRA["Microsoft Entra ID"]
  ENTRA -- "access token" --> ARM
  ARM -- "RBAC: rol mínimo<br/>(p. ej. Contributor + RBAC Admin<br/>condicionado)" --> RES["Recursos"]
  KV["Key Vault"] -- "getSecret() en .bicepparam<br/>(enabledForTemplateDeployment)" --> ARM
```

- **Parámetros `@secure()`** no se registran en el historial ni en logs del deployment.
- **Nunca** pongas secretos en outputs (regla de linter `outputs-should-not-contain-secrets`).
- Usa **`getSecret()`** en `.bicepparam` para leer de Key Vault en tiempo de despliegue.
- Prefiere **OIDC / workload identity federation** sobre client secrets en CI/CD.

---
⬅️ [01 · Contexto](01-contexto-iac-azure.md) · ➡️ [03 · Lenguaje Bicep](03-bicep-lenguaje.md)
