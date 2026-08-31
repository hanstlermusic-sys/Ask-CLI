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
| `--allow-tool <lista>` | Herramientas disponibles en modo `safe` (restringe el catálogo). |
| `--deny-tool <lista>` | Herramientas prohibidas; acumulable, aplica también en `trusted`. |
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

Copilot CLI distingue entre *pre-aprobar* y *restringir*, y la diferencia es fácil de pasar por alto:

| Flag de Copilot CLI | Efecto real |
|---|---|
| `--allow-tool` | Evita el prompt de confirmación. **No restringe nada.** |
| `--available-tools` | Solo estas herramientas quedan disponibles para el modelo. |
| `--deny-tool` | Prohíbe, pero **`--allow-all-tools` tiene precedencia sobre él**. |
| `--excluded-tools` | Quita del catálogo; es el único que funciona junto a `--allow-all-tools`. |

Verificado empíricamente: `--allow-tool=glob` con una tarea que pedía contar procesos **ejecutó `powershell`
igualmente**. Por eso `ask-cli` construye los permisos así:

- `safe`: `--available-tools=<lista> --allow-tool=<lista>` (por defecto `view,glob,rg`). Restringe de verdad.
- `trusted` (por defecto): `--allow-all-tools`.
- `--deny-tool <lista>`: se emite como `--deny-tool` **y** `--excluded-tools`, para que la denegación
  sobreviva a `--allow-all-tools`. Es acumulable entre config, perfil y línea de comandos: una denegación
  nunca se pierde por definir otra en otra capa.

```powershell
ask-cli run "audita el repo" --safe --allow-tool "view,glob,rg"
ask-cli run "refactoriza src/" --trusted --deny-tool "powershell"
ask-cli doctor --safe --deny-tool write   # muestra los flags exactos que se emitirian
```

Copilot CLI acepta sintaxis granular, que `ask-cli` pasa intacta:

```powershell
ask-cli run "haz commit" --trusted --deny-tool "shell(git push)"
```

> **La exclusión es por nombre de herramienta, no por capacidad.** Al excluir `powershell`, el modelo intentó
> `read_powershell`, `list_powershell` y `task`. Si necesitas contención real usa `safe` con una lista blanca
> explícita, que es cerrada por construcción, en lugar de una lista negra.

## Instalación en cualquier máquina

```powershell
git clone https://github.com/hanstlermusic-sys/Ask-CLI.git
cd Ask-CLI
.\ask-cli.cmd install
```

`install` copia el CLI a `$HOME\.ask-cli\bin` y añade esa ruta al PATH **de usuario**
(no necesita permisos de administrador). Abre una terminal nueva y ya lo invocas como
`ask-cli` desde cualquier carpeta. `uninstall` deshace ambos pasos y **conserva la
configuración** en `$HOME\.ask-cli`.

Requisitos reales: Copilot CLI en el PATH y Node. `pwsh` 7 es opcional pero recomendado
(el shim lo prefiere porque arranca bastante más rápido que Windows PowerShell 5.1).
`ask-cli doctor` cierra con una línea de estado de instalación que dice exactamente qué
falta en una máquina nueva.

El provider `vertex` habla con un backend **local y opcional** (HanstlerS). Su URL sale
de la clave de configuración `hanstlersUrl`, así que puede apuntar a otro host o puerto.
En una máquina donde no exista, `doctor` lo reporta como `n/a` en vez de como aviso: no
es un componente que falte, es uno que no se usa.

## Detección de bucles improductivos

Un agente puede repetir la misma llamada con los mismos argumentos indefinidamente. Cada
llamada "tiene éxito", así que ningún otro gate lo ve: la corrida parece sana mientras
gira en falso hasta agotar las iteraciones.

`ask-cli` marca como fallo **N llamadas idénticas consecutivas** (mismo nombre y mismos
argumentos; `loopThreshold`, 3 por defecto). Se exige que sean *consecutivas* a propósito:
repetir un comando idéntico separado por otras llamadas es normal y productivo — el ciclo
test → parche → test ejecuta la misma suite varias veces, pero con un `apply_patch` en
medio. Lo anómalo es la repetición inmediata, sin nada que pudiera haber cambiado el
resultado.

El reintento tampoco usa el mensaje habitual. Decirle "ejecuta ahora las herramientas
necesarias" a un agente atascado es contraproducente: es justo lo que cree estar haciendo.
El feedback le prohíbe explícitamente repetir esa llamada y le da tres salidas: usar lo que
ya obtuvo, cambiar de herramienta o de argumentos, o **detenerse y explicar qué le falta**.
Rendirse con un diagnóstico es más útil que insistir.

Solo se juzga el turno más reciente: si el agente cayó en un bucle y el reintento lo
sacó, no se le sigue penalizando por ello.

## Modo dev autónomo

`--dev` es el atajo recomendado para "hazlo tú". Combina autonomía de ejecución con una red de
seguridad que no depende de lo que el modelo *diga*:

```powershell
ask-cli run "corrige el bug de la funcion add en calc.py" --dev
```

Equivale a `--autopilot --trusted --effort high --quality --max-continues 15`.

### Qué aporta frente a `copilot --autopilot`

Copilot CLI da por terminada la tarea cuando el modelo emite `task_complete`. Nadie comprueba que
el proyecto siga compilando o que los tests pasen. ask-cli sí:

1. El agente trabaja hasta declararse completo.
2. Si tocó código, ask-cli **ejecuta la suite real del proyecto**.
3. Si falla, le devuelve la salida literal del test (no un resumen) sobre la misma sesión y le exige
   corregir la causa raíz, prohibiendo explícitamente tocar los tests para forzar un verde.
4. Vuelve a ejecutar la suite **y vuelve a pasar los gates de verificación**: que la suite acabe en
   verde no borra que el agente afirmara haber hecho algo que no hizo.
5. Solo entonces sale con `0`. Si la suite sigue roja, sale con `3` y el fallo aparece en `issues`.

Ejemplo real: ante `add` (bug) y `divide` (sin validar división por cero), pidiendo *sólo* arreglar
`add`, el agente arregló `add` y emitió `task_complete`. El gate detectó que `test_divide_by_zero`
seguía roja, se lo devolvió, y el agente corrigió también `divide`. Sin el gate, la corrida habría
terminado en verde con la suite en rojo.

### Detección de la suite

Se elige el primer marcador presente, de más específico a más genérico:

| Stack | Marcador | Comando |
|---|---|---|
| Pester | `*.Tests.ps1` | `Invoke-Pester -Path . -Output None -CI` |
| Node | `package.json` | `npm test --silent` |
| Python | `pyproject.toml`, `pytest.ini`, `setup.cfg`, `tests/` | `python -m pytest -q` |
| .NET | `*.sln`, `*.csproj` | `dotnet test --nologo -v q` |
| Go | `go.mod` | `go test ./...` |
| Rust | `Cargo.toml` | `cargo test --quiet` |

Con `--verify-cmd "<comando>"` (o `verifyCommand` en config) fijas el tuyo y te saltas la detección.
Si no hay suite detectable, el gate se omite con un aviso: nunca bloquea por no encontrar tests.

Las búsquedas recursivas ignoran `node_modules`, `.venv`, `site-packages`, `target`, `vendor`,
`obj`, `dist` y similares: un `*.Tests.ps1` dentro de una dependencia pertenece a un tercero y
detectarlo elegiría el stack equivocado.

La suite se ejecuta en un **proceso hijo**, no en la sesión actual. Esto no es un detalle de
implementación: `$LASTEXITCODE` solo lo actualizan los ejecutables nativos, así que evaluar un
cmdlet (`Invoke-Pester`) en el proceso actual arrastra el código de salida de un comando anterior
y puede reportar **verde una suite en rojo**. El proceso hijo garantiza un exit code real, aplica
el timeout de verdad (`exitCode` 124 y `timedOut` si se excede) e impide que un `exit` dentro del
comando de verificación mate el wrapper. El comando viaja como `-EncodedCommand`, de modo que
comillas y ampersands en un `verifyCommand` propio llegan intactos.

### Autonomía del agente

| Opción | Efecto |
|---|---|
| `--dev` | Atajo recomendado (ver arriba). |
| `--autopilot` | El agente itera solo hasta terminar. |
| `--plan` | Solo planifica; no ejecuta cambios. |
| `--effort <nivel>` | `none`...`max`. Ver aviso abajo. |
| `--max-continues <n>` | Iteraciones máximas de autopilot (default de Copilot: 5). |
| `--assisted-approval` | Juez de aprobación de Copilot (experimental). |
| `--no-ask-user` | Prohíbe al agente preguntar; falla en vez de bloquearse. |
| `--quality` / `--no-quality` | Fuerza o desactiva el gate de calidad. |

> **`--effort` y el modelo `auto`.** El modelo por defecto rechaza la configuración de reasoning
> effort y aborta la corrida entera. ask-cli lo detecta y **reintenta automáticamente sin el flag**
> en vez de fallar. Para usar `--effort` de verdad, fija un modelo que lo soporte con `--model`.
> `ask-cli doctor` avisa de esta combinación.

> **`--assisted-approval` no es una barrera de seguridad.** El flag se ignora en silencio sin
> `--experimental` (ask-cli siempre los emite juntos). Aun activándolo correctamente, en pruebas el
> juez **aprobó el borrado permanente de archivos**. Para contención real usa el modo `safe` con
> lista blanca; no confíes en el juez.

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
| `denyTools` | `` | Herramientas prohibidas (acumulable con perfil y CLI). |
| `timeoutSec` | `180` | Timeout de red del provider `vertex`. |
| `historyMax` | `2000` | Líneas conservadas al rotar el historial. |
| `retry` | `true` | Reintento ante verificación fallida. |
| `verify` | `true` | Gates de verificación determinista sobre el JSONL. |
| `guard` | `auto` | `auto` (omite el guard si está en `AGENTS.md`), `always`, `off`. |
| `agent` | `` | Agente custom de Copilot CLI. |
| `maxCredits` | `0` | Límite de AI credits premium (0 = sin límite). |
| `agentMode` | `interactive` | `interactive`, `plan` o `autopilot`. |
| `effort` | `` | Nivel de reasoning effort (`none`…`max`). |
| `assistedApproval` | `false` | Juez de aprobación experimental de Copilot. |
| `maxContinues` | `0` | Iteraciones máximas de autopilot (0 = default de Copilot). |
| `noAskUser` | `false` | Prohíbe al agente hacer preguntas. |
| `qualityGate` | `false` | Ejecuta la suite del proyecto tras tocar código. |
| `verifyCommand` | `` | Comando de verificación explícito (omite la detección). |

### Códigos de salida

| Código | Significado |
|---|---|
| `0` | Éxito verificado. |
| `1` | Error de uso o del provider. |
| `3` | La respuesta no superó la verificación tras el reintento, o el gate de calidad quedó en rojo. |

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

**Modo `safe` que no restringía.** `--allow-tool` solo pre-aprueba: no limita el catálogo de herramientas.
El modo `safe` lo usaba en solitario, así que `--safe --allow-tool glob` seguía permitiendo que el modelo
ejecutara `powershell`. Se añadió `--available-tools`, que sí cierra el catálogo. Con el arreglo, el propio
modelo responde *"no hay una herramienta de ejecución de PowerShell disponible en esta sesión"*.

**Denegaciones ignoradas.** `--allow-all-tools` tiene precedencia sobre `--deny-tool`, de modo que una
denegación en modo `trusted` no tenía efecto. Ahora cada denegación se emite también como `--excluded-tools`.

**Avisos que rompían el JSON.** Los mensajes de progreso del reintento se escribían en stdout, corrompiendo
la salida de `--json` (`ConvertFrom-Json` fallaba con *Invalid JSON primitive*). Ahora van a stderr.

**Colisión con la variable automática `$profile`.** `Resolve-Settings` usaba `$profile`, que en PowerShell es
una variable automática con la ruta del perfil. Funcionaba por sombreado local, pero era frágil bajo
`Set-StrictMode`; se renombró a `$prof`.

### Limitaciones conocidas

- `timeoutSec` aplica al provider `vertex`. El provider `copilot` hereda el comportamiento de Copilot CLI
  (sin timeout forzado desde el wrapper).
- El chat interactivo continuo no está disponible para `--provider vertex`.
- La verificación solo cubre el provider `copilot`: `vertex` no expone telemetría de herramientas y se reporta
  siempre como verificado.
- Los gates usan heurística léxica para decidir si una tarea es *accionable*. Puede haber falsos positivos
  (una pregunta redactada como orden) que provoquen un reintento innecesario; `--no-verify` lo desactiva.
- `--deny-tool` excluye por **nombre exacto de herramienta**, no por capacidad: excluir `powershell` no impide
  que el modelo recurra a `read_powershell` o `task`. Para contención real usa `safe` con lista blanca.
- El gate de calidad ejecuta el comando detectado **en tu máquina**, con tus permisos. Revisa
  `ask-cli doctor` antes de usar `--dev` en un repo desconocido.
- `--effort` es incompatible con el modelo `auto`; ask-cli degrada automáticamente (ver arriba).
- `--assisted-approval` no contiene operaciones destructivas; no lo uses como control de seguridad.
- Windows-first: se resuelve `copilot.cmd` y se usan rutas con `\`.

## Desarrollo

```powershell
Install-Module Pester -Scope CurrentUser -Force
Invoke-Pester .\tests
```

Los tests cargan el script con `ASKCLI_NO_MAIN=1`, lo que define las funciones sin ejecutar el CLI.
