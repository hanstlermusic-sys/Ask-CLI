# ask-cli

Wrapper avanzado para **GitHub Copilot CLI** con soporte adicional para un backend Vertex local (HanstlerS).

Añade sobre Copilot CLI: perfiles por proyecto (con modo estricto), historial de sesiones, prompt de "ejecución primero", salida JSON y una capa de configuración persistente.

## Requisitos

- Windows con PowerShell 5.1 (funciona) o **PowerShell 7 / `pwsh`** (recomendado, arranque más rápido).
- [GitHub Copilot CLI](https://github.com/github/copilot-cli) instalado y en el `PATH` (`copilot.cmd`).
- Opcional: HanstlerS local API en `http://127.0.0.1:8717` para `--provider vertex`.

## Instalación

Clona el repo y añade la carpeta al `PATH`, o invoca directamente:

```powershell
.\ask-cli.cmd doctor
```

El wrapper `ask-cli.cmd` detecta `pwsh` automáticamente y cae a `powershell` si no existe.

## Uso

```powershell
ask-cli run "lista los archivos modificados y resume el diff"
ask-cli run "audita dependencias" --safe --allow-tool view,glob,rg
ask-cli run "genera un reporte" --json --no-stream
ask-cli chat --model gpt-5
ask-cli sessions list 10
ask-cli doctor
```

El primer argumento también puede ser el prompt directamente:

```powershell
ask-cli "¿qué hace este repo?"
```

### Comandos

| Comando | Descripción |
|---|---|
| `run "<prompt>"` | Ejecuta un prompt de una sola pasada. |
| `chat` | Abre Copilot CLI interactivo con los ajustes resueltos. |
| `resume [id]` | Reanuda la última sesión (o la indicada). |
| `sessions [list\|clear] [n]` | Lista o borra el historial local de sesiones. |
| `model show\|set <id>` | Consulta o fija el modelo por defecto. |
| `auth status\|login\|logout` | Delegado a Copilot CLI / `gh`. |
| `doctor` | Diagnóstico de entorno, rutas, latencias y estado de verificación. |
| `version` | Versión de ask-cli. |
| `init-instructions [ruta]` | Escribe el guard de ejecución en `AGENTS.md` (idempotente). |
| `project init\|show\|strict` | Perfiles por directorio. |
| `config show\|set <k> <v>` | Configuración global. |

## Verificación anti-alucinación

El problema clásico de un wrapper sobre un LLM es que el modelo *diga* que hizo algo sin haberlo hecho.
Intentar resolverlo pidiéndoselo por prompt no es verificable: `"Ya revisé los archivos"` supera cualquier
filtro de texto sin haber ejecutado nada.

`ask-cli` invoca siempre Copilot CLI con `--output-format json` y analiza el **JSONL de eventos**
(`tool.execution_start`, `tool.execution_complete`, `result`). La decisión no se toma sobre la prosa,
sino sobre la evidencia de ejecución:

| Gate | Condición de fallo |
|---|---|
| 1. Ejecución | La tarea contiene un verbo accionable y se registraron **0** llamadas a herramientas. |
| 2. Consistencia | El texto afirma haber creado/modificado algo, pero no hubo herramienta de escritura ni `codeChanges.filesModified`. |
| 3. Sanidad | Todas las herramientas invocadas fallaron, o la respuesta está vacía sin ejecución. |

Ante un fallo, `ask-cli` **reintenta sobre la misma sesión** (`--resume=<id>`) enviando la evidencia real
como feedback. Reusar la sesión no es un detalle: mantiene el contexto y convierte los ~27 k tokens de
`cache_write` de la primera llamada en `cache_read` en la segunda, en lugar de repagarlos.

Si tras el reintento sigue sin verificar, el proceso termina con **exit code 3** y la lista de problemas.
Se desactiva con `--no-verify` o `config set verify false`.

```powershell
ask-cli run "lista los .ps1 y cuenta sus lineas" --json
# -> "verified": true, "tools": [{"name":"powershell","summary":"Get-ChildItem ...","success":true}]
```

### El guard: de tokens por llamada a instrucciones cacheadas

Antes, el bloque de instrucciones operativas se anteponía a *cada* prompt. Con `init-instructions` pasa a
vivir en `AGENTS.md`, que Copilot CLI carga automáticamente y cachea:

```powershell
ask-cli init-instructions .
```

Con `guard = auto` (por defecto), `ask-cli` detecta el marcador en `AGENTS.md` y deja de anteponerlo.
`guard = always` fuerza el prepend; `guard = off` lo desactiva.

### Opciones

| Opción | Descripción |
|---|---|
| `--provider copilot\|vertex` | Backend a usar. |
| `--model <id>` | Modelo de Copilot. |
| `--vertex-model <id>` | Modelo para el provider `vertex`. |
| `--dir <ruta>` | Directorio de trabajo (`-C` de Copilot CLI). |
| `--add-dir <ruta>` | Directorio extra de contexto (repetible). |
| `--attach <ruta>` | Adjunto (repetible). |
| `--resume <id>` | Reanuda una sesión. |
| `--allow-tool <lista>` | Herramientas permitidas en modo `safe`. |
| `--agent <nombre>` | Agente custom de Copilot CLI. |
| `--max-credits <n>` | Límite de AI credits premium por sesión. |
| `--timeout <seg>` | Timeout de red del provider `vertex`. |
| `--json` | Salida JSON (desactiva streaming). |
| `--quiet` | Sin mensajes accesorios. |
| `--verbose` | Muestra el razonamiento del modelo y telemetría detallada. |
| `--no-stream` | Desactiva el streaming incremental. |
| `--no-retry` | No reintenta ante verificación fallida. |
| `--no-verify` | Desactiva la verificación determinista de ejecución. |
| `--safe` / `--trusted` | Atajos de modo de permisos. |
| `--force-profile-override` | Ignora un perfil estricto. |
| `--` | Todo lo que siga se trata como prompt literal. |

**Passthrough:** cualquier flag `--*` no reconocido se reenvía tal cual a Copilot CLI. Esto permite usar
funcionalidad de Copilot CLI (por ejemplo configuración de servidores MCP) sin tener que modificar `ask-cli`.

## Modos de permisos

- `trusted` (por defecto): pasa `--allow-all-tools` a Copilot CLI.
- `safe`: pasa `--allow-tool` con la lista de `allowTools` (por defecto `view,glob,rg`).

## Configuración

Archivos en `~/.ask-cli/`:

- `config.json` — configuración global (UTF-8 sin BOM).
- `project-profiles.json` — perfiles por directorio.
- `history.jsonl` — historial de invocaciones (rotado automáticamente).

| Clave | Default | Descripción |
|---|---|---|
| `provider` | `copilot` | Backend por defecto. |
| `model` | `auto` | Modelo de Copilot. |
| `vertexModel` | `vertex-gemini-pro` | Modelo de Vertex. |
| `mode` | `trusted` | `trusted` o `safe`. |
| `dir` | `` | Directorio de trabajo por defecto. |
| `output` | `text` | `text` o `json`. |
| `copilotPath` | `` | Cache de la ruta de `copilot.cmd` (evita escanear el `PATH`). |
| `allowTools` | `view,glob,rg` | Herramientas del modo `safe`. |
| `timeoutSec` | `180` | Timeout de red del provider `vertex`. |
| `historyMax` | `2000` | Líneas conservadas al rotar el historial. |
| `retry` | `true` | Reintento ante verificación fallida. |
| `verify` | `true` | Gates de verificación determinista sobre el JSONL. |
| `guard` | `auto` | `auto` (omite el guard si está en `AGENTS.md`), `always`, `off`. |
| `agent` | `` | Agente custom de Copilot CLI. |
| `maxCredits` | `0` | Límite de AI credits premium (0 = sin límite). |

### Códigos de salida

| Código | Significado |
|---|---|
| `0` | Éxito verificado. |
| `1` | Error de uso o del provider. |
| `3` | La respuesta no superó la verificación tras el reintento. |

## Perfiles por proyecto

```powershell
ask-cli project init . --provider copilot --model gpt-5 --strict-profile
ask-cli project show .
ask-cli project strict off .
```

Un perfil **estricto** bloquea `provider`, `model`, `mode` y `dir` dentro del árbol del proyecto.
Se salta con `--force-profile-override`.

## Rendimiento

Decisiones deliberadas en el hot path:

- **Invocación directa a `node`**: se resuelve el entrypoint real (`npm-loader.js`) y se salta el shim
  `copilot.cmd`. Además de evitar un proceso `cmd.exe` intermedio, corrige la pérdida de prompts multilínea
  (ver abajo) y elimina el ruido de `NativeCommandError` en la salida.
- **Streaming incremental** en ambos providers: la salida de Copilot CLI se filtra e imprime línea a línea, no al final.
- **`List<string>`** en lugar de `$array +=` (evita reasignación O(n²); ~27x en salidas de 10k líneas).
- **Dos `Regex` compilados** en vez de once `-match` por línea (~10x en el filtrado).
- **Cache de `copilotPath`** en `config.json`: la resolución baja de ~100 ms a ~8 ms por invocación.
- **Historial acotado**: `Get-Content -Tail` para leer y rotación por tamaño (2 MB) para escribir.
- **Reintento acotado**: solo se reintenta si la verificación falla, y siempre sobre la misma sesión.
- **Sesión fijada por adelantado** (`--session-id <uuid>`): permite reintentar con `--resume` reusando el
  prompt cache. Una corrida real de referencia escribe ~27,5 k tokens de caché; el reintento antiguo
  arrancaba sesión nueva y los repagaba, el actual los lee.
- **Guard fuera del hot path**: con `init-instructions`, el bloque de instrucciones deja de enviarse en cada
  prompt y pasa a `AGENTS.md`, que Copilot cachea.
- **Sin doble parseo**: el JSONL se consume en un solo `ForEach-Object` que streamea, acumula texto,
  registra herramientas y extrae telemetría en la misma pasada.

### Correcciones relevantes

**Prompts multilínea truncados.** `copilot.cmd` es un shim npm que pasa por `cmd.exe`, y `cmd.exe` corta los
argumentos en el primer salto de línea. Como `ask-cli` antepone un bloque de instrucciones seguido de
`\n\nTAREA:\n<prompt>`, Copilot recibía **solo el bloque de instrucciones** y la tarea real se perdía en silencio.
Ahora se invoca `node npm-loader.js` directamente, lo que preserva el argumento completo. Si el entrypoint no
se encuentra, se cae al shim y el prompt se aplana con `ConvertTo-SingleLinePrompt` en vez de perderse.
`ask-cli doctor` reporta cuál de los dos caminos está activo.

**Filtro de ruido incompleto.** Las líneas `    + CategoryInfo` / `    + FullyQualifiedErrorId` que emite
PowerShell llevan prefijo `+ `, por lo que el filtro original nunca las capturaba y se colaban en la salida.

**Script sin BOM interpretado como ANSI.** PowerShell 5.1 asume ANSI para un `.ps1` sin BOM. El archivo estaba
en UTF-8 sin BOM, así que en runtime `cre[eé]` se cargaba como `cre[eÃ©]`: los patrones con acentos **nunca
matcheaban**, degradando en silencio el gate de consistencia y el filtro de errores en español. Se añadió el
BOM UTF-8 y un test de regresión que lo verifica.

**Flags con valor opcional.** `--resume` y `--allow-tool` declaran su valor como opcional en Copilot CLI, por lo
que `--resume abc` no enlaza (`abc` se interpreta como argumento posicional). Ahora se emiten como
`--resume=abc` y `--allow-tool=view,glob,rg`.

### Limitaciones conocidas

- `timeoutSec` aplica al provider `vertex`. El provider `copilot` hereda el comportamiento de Copilot CLI
  (sin timeout forzado desde el wrapper).
- El chat interactivo continuo no está disponible para `--provider vertex`.
- La verificación solo cubre el provider `copilot`: `vertex` no expone telemetría de herramientas y se reporta
  siempre como verificado.
- Los gates usan heurística léxica para decidir si una tarea es *accionable*. Puede haber falsos positivos
  (una pregunta redactada como orden) que provoquen un reintento innecesario; `--no-verify` lo desactiva.
- Windows-first: se resuelve `copilot.cmd` y se usan rutas con `\`.

## Desarrollo

```powershell
Install-Module Pester -Scope CurrentUser -Force
Invoke-Pester .\tests
```

Los tests cargan el script con `ASKCLI_NO_MAIN=1`, lo que define las funciones sin ejecutar el CLI.
