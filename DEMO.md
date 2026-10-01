# Comandos para la demo en vivo

Todo lo que aparece en este documento se ejecutó y se verificó contra una
suscripción real de Azure. Los comandos están pensados para copiar y pegar
tal cual, sin reemplazar nada a mano: cada valor (nombre de recurso, IP, IDs)
se resuelve en el momento con una consulta a Azure y se guarda en una
variable de shell.

> **Importante — orden y sesión de terminal.** Las secciones se apoyan en
> variables definidas en las secciones anteriores (`$RG_NAME`, `$KV_NAME`,
> `$APP_URL`, `$MY_OID`, etc.). Hay que:
>
> 1. Ejecutar las secciones **en orden**, de la 1 a la 5.
> 2. Mantener **la misma ventana de terminal** abierta durante toda la demo —
>    las variables de shell no se comparten entre ventanas ni sobreviven a
>    cerrar la terminal.
> 3. Si un comando falla con un error raro (por ejemplo, mencionando `None`,
>    un recurso vacío, o un HSM que no existe), lo primero que hay que revisar
>    es si la variable que usa ese comando está vacía: `echo "$NOMBRE_VARIABLE"`.
>    Si está vacía, significa que se saltó el bloque donde esa variable se
>    define más arriba — hay que volver a ese bloque y ejecutarlo antes de
>    continuar.
> 4. **Específico de Git Bash / MINGW64 en Windows:** cualquier argumento que
>    empiece con `/` (por ejemplo `/subscriptions/...`) se reescribe
>    automáticamente como una ruta de Windows antes de llegar a `az`
>    (`/subscriptions/...` se convierte en algo como
>    `C:/Program Files/Git/subscriptions/...`), lo que produce errores confusos
>    como `MissingSubscription` o `invalid ResourceId value`. Esto pasa con
>    `--scope`, `--ids` y cualquier flag que reciba un resource ID completo.
>    La solución es anteponer `MSYS_NO_PATHCONV=1` al comando:
>    `MSYS_NO_PATHCONV=1 az resource delete --ids "/subscriptions/..."`.
>    No hace falta en `az rest --url "https://..."` porque ahí el argumento
>    empieza con `https:`, no con `/`, así que no se reescribe.

```bash
SUB=$(az account show --query id -o tsv)
```

---

## 1. Validar sin desplegar (gratis, de solo lectura)

```bash
# Lint + build del orquestador principal
az bicep lint --file main.bicep
az bicep build --file main.bicep --stdout > /dev/null

# Build de los .bicepparam (valida que los parámetros coincidan con los tipos)
az bicep build-params --file params/main.dev.bicepparam --stdout > /dev/null
az bicep build-params --file params/main.prod.bicepparam --stdout > /dev/null

# Variante con Azure Verified Modules (requiere acceso a mcr.microsoft.com)
az bicep restore --file main.avm.bicep --force
az bicep build --file main.avm.bicep --stdout > /dev/null

# What-if: muestra qué se crearía, sin crear nada
az deployment sub what-if -l eastus2 -f main.bicep -p params/main.dev.bicepparam
```

---

## 2. Desplegar el stack principal (dev)

Se usa **deployment stack** (en vez de `az deployment sub create` directo) para que
el conjunto de recursos quede registrado como una unidad gestionada, con
protección `denyDelete`.

```bash
az stack sub create \
  -n stk-demo-dev \
  -l eastus2 \
  -f main.bicep \
  -p params/main.dev.bicepparam \
  --action-on-unmanage deleteResources \
  --deny-settings-mode denyDelete \
  --yes
```

**Nota de una corrida real:** la primera ejecución falló con
`DeploymentStackTenantRegistrationFailed` (error transitorio del lado de Azure al
registrar el stack a nivel de tenant cuando `denySettings != none`). El mensaje de
Azure sugiere reintentar; repetir el mismo comando sin cambiar nada lo resolvió. Si
ocurre durante la demo, basta con volver a correrlo.

Resultado verificado: `provisioningState: succeeded`, 9 recursos gestionados.

Los nombres de los recursos se obtienen de los outputs del propio stack — así no
hace falta hardcodear nada:

```bash
RG_NAME=$(az stack sub show -n stk-demo-dev --query outputs.resourceGroupName.value -o tsv)
KV_NAME=$(az stack sub show -n stk-demo-dev --query outputs.keyVaultName.value -o tsv)
APP_URL=$(az stack sub show -n stk-demo-dev --query outputs.appUrl.value -o tsv)

echo "RG=$RG_NAME  KV=$KV_NAME  URL=$APP_URL"

# Confirmar que la app responde
curl -sI "$APP_URL" | head -1
```

Recursos que crea el stack (nombres derivados de `resourceName()`/`compactName()`
en `shared/types.bicep`, con `workload=demo`, `environment=dev`):

| Recurso | Nombre |
|---|---|
| Resource Group | `$RG_NAME` |
| Log Analytics | `log-demo-dev-eastus2` |
| Application Insights | `appi-demo-dev-eastus2` |
| Identidad administrada | `id-demo-dev-eastus2` |
| Key Vault | `$KV_NAME` (nombre con hash, ver output `keyVaultName`) |
| Container Apps Environment | `cae-demo-dev-eastus2` |
| Container App | `ca-demo-dev-eastus2` |

---

## 3. Comprobar que los servicios funcionan de verdad (no solo que ARM dijo "succeeded")

### 3.1 Container App: revisiones y escalado a cero

```bash
az containerapp revision list -g "$RG_NAME" -n ca-demo-dev-eastus2 \
  --query "[].{name:name, active:properties.active, replicas:properties.replicas}" -o table

az containerapp show -g "$RG_NAME" -n ca-demo-dev-eastus2 \
  --query "{fqdn:properties.configuration.ingress.fqdn, runningStatus:properties.runningStatus}" -o table
```

Verificado: `replicas: 0` en reposo (por `minReplicas: 0` en dev) y
`runningStatus: Running` — escala a cero sin tráfico, y vuelve a responder al
primer request entrante (cold start).

### 3.2 Key Vault: CRUD de secretos — y por qué falla al principio

```bash
az keyvault secret set --vault-name "$KV_NAME" --name demo-test --value "hola"
```

**Hallazgo real, útil para explicar en la demo:** este comando falla con
`Forbidden / ForbiddenByRbac` **incluso para la cuenta Owner de la suscripción**.
Es el comportamiento esperado y es justamente la lección de la sección: con
`enableRbacAuthorization: true`, el plano de datos de Key Vault es independiente
del plano de control. El rol `Owner` tiene `Actions: ["*"]` pero `DataActions: []`
(se puede confirmar con `az role definition list --name Owner --query "[0].permissions"`).
Ni la cuenta dueña de la suscripción puede leer o escribir secretos sin un rol de
datos explícito — es exactamente el diseño de mínimo privilegio implementado en
`modules/keyvault.bicep`, donde solo la identidad administrada recibe
`Key Vault Secrets User`.

Para demostrar el CRUD en vivo, se asigna temporalmente un rol de datos a la cuenta
que está corriendo la demo, y se retira al finalizar:

```bash
MY_OID=$(az ad signed-in-user show --query id -o tsv)
KV_ID=$(az keyvault show --name "$KV_NAME" -g "$RG_NAME" --query id -o tsv)
ROLE_ID=$(az role definition list --name "Key Vault Secrets Officer" --query "[0].name" -o tsv)
RA_NAME=$(powershell.exe -NoProfile -Command "[guid]::NewGuid().ToString()" | tr -d '\r')

# Nota: "az role assignment create --scope <id-de-recurso>" tiene un bug conocido en
# az CLI 2.83.0 que responde "MissingSubscription" con cualquier scope más profundo
# que la suscripción. El workaround es llamar directo a la API de ARM con "az rest".
az rest --method put \
  --url "https://management.azure.com${KV_ID}/providers/Microsoft.Authorization/roleAssignments/${RA_NAME}?api-version=2022-04-01" \
  --body "{\"properties\":{\"roleDefinitionId\":\"/subscriptions/${SUB}/providers/Microsoft.Authorization/roleDefinitions/${ROLE_ID}\",\"principalId\":\"${MY_OID}\",\"principalType\":\"User\"}}"

# Esperar propagación de RBAC (entre 10 y 30 segundos aprox.) y repetir la prueba
az keyvault secret set --vault-name "$KV_NAME" --name demo-test --value "hola-bicep-demo"
az keyvault secret show --vault-name "$KV_NAME" --name demo-test --query "{name:name, value:value}"

# Limpieza: borrar + purgar el secreto (purge protection está apagada en dev)
# y retirar el rol temporal
az keyvault secret delete --vault-name "$KV_NAME" --name demo-test
az keyvault secret purge --vault-name "$KV_NAME" --name demo-test   # si responde "ObjectIsBeingDeleted", reintentar en unos segundos
az rest --method delete \
  --url "https://management.azure.com${KV_ID}/providers/Microsoft.Authorization/roleAssignments/${RA_NAME}?api-version=2022-04-01"
```

### 3.3 Gobernanza del deployment stack: `denyDelete` en acción

Este comando **debe fallar** — el objetivo del ejercicio es precisamente comprobar
que la protección funciona:

```bash
MSYS_NO_PATHCONV=1 az resource delete --ids "/subscriptions/${SUB}/resourceGroups/${RG_NAME}/providers/Microsoft.OperationalInsights/workspaces/log-demo-dev-eastus2"
```

(El prefijo `MSYS_NO_PATHCONV=1` es necesario en Git Bash/MINGW64 en Windows — ver la
nota 4 al principio del documento. En otra terminal, como PowerShell o una shell
Linux/macOS, el comando funciona sin ese prefijo.)

Resultado esperado: Azure rechaza el delete porque el recurso está gestionado por
el stack con `denySettings.mode: denyDelete`. Es un buen momento para mostrarle a
la clase que ni siquiera la cuenta Owner puede borrar el recurso sin pasar por el
stack.

---

## 4. Variante con Azure Verified Modules (más tipos de recursos)

Prueba adicional: desplegar `main.avm.bicep` (Storage Account + Key Vault + Log
Analytics vía AVM) en un resource group aparte, sin tocar el stack de dev.

```bash
MY_OID=$(az ad signed-in-user show --query id -o tsv)

az group create -n rg-demo-avm-test -l eastus2

az deployment group create \
  -g rg-demo-avm-test \
  -f main.avm.bicep \
  -p principalId="$MY_OID" principalType=User
```

**Bug real encontrado y corregido durante las pruebas:** `main.avm.bicep` tenía
`principalType: 'ServicePrincipal'` fijo en el role assignment del módulo AVM de
Key Vault. Al desplegar con una cuenta de usuario (`principalType: User`) fallaba
con `UnmatchedPrincipalType`. Se agregó el parámetro `principalType` (valor por
defecto `ServicePrincipal`, pensado para identidades administradas o pipelines de
CI; se pasa `User` cuando se prueba con una cuenta personal, como en este ejemplo).

> **Si este resource group ya se había borrado antes** (por ejemplo, en un ensayo
> previo de la demo) y se vuelve a crear con el mismo nombre, el nuevo Storage
> Account se genera con el mismo nombre que el anterior (`uniqueString()` depende
> del ID del resource group, que no cambia). El registro DNS del nombre anterior
> puede tardar uno o dos minutos en propagar para el nombre nuevo — si un comando
> contra el storage account falla con `Failed to resolve ... getaddrinfo failed`,
> no es un error de configuración: conviene esperar un minuto y reintentar.

### 4.1 Storage Account: red cerrada por defecto

```bash
ST_NAME=$(az storage account list -g rg-demo-avm-test --query "[0].name" -o tsv)

az storage container create --account-name "$ST_NAME" --name demo --auth-mode login
```

**Otro hallazgo:** el módulo AVM de storage-account trae
`networkRuleSet.defaultAction: Deny` por defecto (seguro por diseño). Falla con
*"blocked by network rules"* hasta agregar explícitamente la IP pública de la
máquina desde la que se ejecuta el comando:

```bash
MY_IP=$(curl -s https://api.ipify.org)
az storage account network-rule add --account-name "$ST_NAME" -g rg-demo-avm-test --ip-address "$MY_IP"
```

Incluso con la IP permitida, crear o borrar el **contenedor** funciona con el rol
Owner (es una operación de plano de control vía ARM), pero **subir, listar o
borrar un blob** vuelve a fallar sin un rol de datos (`Storage Blob Data
Contributor`) — el mismo patrón que en Key Vault: plano de control distinto de
plano de datos.

```bash
echo "contenido de prueba bicep demo" > /tmp/demo-blob.txt

# Esto falla (plano de control, sin rol de datos de Storage)
az storage blob upload --account-name "$ST_NAME" --container-name demo --name demo.txt --file /tmp/demo-blob.txt --auth-mode login --overwrite
```

Para demostrar el CRUD completo del blob, se asigna temporalmente
`Storage Blob Data Contributor` sobre la cuenta de storage, igual que se hizo con
Key Vault en la sección 3.2:

```bash
ST_ID=$(az storage account show --name "$ST_NAME" -g rg-demo-avm-test --query id -o tsv)
ROLE_ID=$(az role definition list --name "Storage Blob Data Contributor" --query "[0].name" -o tsv)
RA_NAME=$(powershell.exe -NoProfile -Command "[guid]::NewGuid().ToString()" | tr -d '\r')

az rest --method put \
  --url "https://management.azure.com${ST_ID}/providers/Microsoft.Authorization/roleAssignments/${RA_NAME}?api-version=2022-04-01" \
  --body "{\"properties\":{\"roleDefinitionId\":\"/subscriptions/${SUB}/providers/Microsoft.Authorization/roleDefinitions/${ROLE_ID}\",\"principalId\":\"${MY_OID}\",\"principalType\":\"User\"}}"
```

**Hallazgo de tiempos:** a diferencia de Key Vault (propagación casi inmediata, en
segundos), la RBAC de datos de Storage tardó en la práctica un poco más de dos
minutos en propagar — Microsoft documenta que puede demorar hasta 5 minutos. Vale
la pena mencionarlo en la demo para que la espera no se lea como que algo está
roto:

```bash
# Red de seguridad: recrea el contenedor si alguien lo borró mientras tanto
# (es idempotente — si ya existe, no hace nada ni da error)
az storage container create --account-name "$ST_NAME" --name demo --auth-mode login -o none

# Reintentar hasta que propague (puede tardar varios minutos)
until az storage blob upload --account-name "$ST_NAME" --container-name demo --name demo.txt --file /tmp/demo-blob.txt --auth-mode login --overwrite -o none 2>/tmp/blob_err.txt; do
  grep -qi "do not have the required permissions" /tmp/blob_err.txt && { echo "todavía propagando, reintento en 10s..."; sleep 10; continue; }
  cat /tmp/blob_err.txt; break
done

az storage blob list --account-name "$ST_NAME" --container-name demo --auth-mode login --query "[].{name:name, size:properties.contentLength}" -o table

# Limpieza: borrar blob, contenedor y retirar el rol temporal
az storage blob delete --account-name "$ST_NAME" --container-name demo --name demo.txt --auth-mode login
az storage container delete --account-name "$ST_NAME" --name demo --auth-mode login
az rest --method delete \
  --url "https://management.azure.com${ST_ID}/providers/Microsoft.Authorization/roleAssignments/${RA_NAME}?api-version=2022-04-01"
```

### 4.2 Limpieza

```bash
az group delete -n rg-demo-avm-test --yes --no-wait
```

Verificado: el grupo de prueba quedó completamente eliminado
(`az group exists -n rg-demo-avm-test` devuelve `false`).

---

## 5. Limpiar todo al cerrar la demo

```bash
az stack sub delete -n stk-demo-dev --action-on-unmanage deleteResources --yes
```

---

## Resumen de hallazgos (para mencionar en la demo)

1. **Owner no implica acceso a datos.** Azure RBAC separa plano de control
   (`Actions`) de plano de datos (`DataActions`); el rol integrado `Owner` tiene
   `Actions: ["*"]` pero `DataActions: []`. Ocurre igual en Key Vault (modo RBAC) y
   en Storage (Blob Data). Es la razón de ser de `enableRbacAuthorization: true` y
   del role assignment acotado a la identidad administrada en
   `modules/keyvault.bicep`.
2. **`denyDelete` en deployment stacks funciona de verdad** — ni la cuenta Owner
   puede borrar un recurso gestionado sin pasar por el stack.
3. **AVM viene seguro por defecto.** El módulo de storage-account deniega la red
   por defecto; hay que abrirla explícitamente (reglas de firewall o endpoints
   privados).
4. **Git Bash en Windows reescribe argumentos que empiezan con `/`** como si
   fueran rutas de archivo (`/subscriptions/...` → `C:/Program Files/Git/subscriptions/...`),
   lo que rompe `--scope`, `--ids` y cualquier flag con un resource ID completo,
   con errores confusos como `MissingSubscription` o `invalid ResourceId value`.
   No es un bug de `az`, es la conversión automática de rutas de MSYS. Se
   soluciona anteponiendo `MSYS_NO_PATHCONV=1` al comando (o usando `az rest`
   con una URL que empiece con `https://`, que no se reescribe).
5. **`DeploymentStackTenantRegistrationFailed`** puede aparecer en el primer
   `az stack ... create` con `denySettings != none` en una suscripción nueva para
   este escenario — reintentar sin cambios suele resolverlo.
6. **`main.avm.bicep` corregido:** `principalType` ahora es un parámetro en vez de
   estar fijo en `'ServicePrincipal'`.
