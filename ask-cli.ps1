#!/usr/bin/env pwsh
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Continue'

$AskHome = Join-Path $HOME '.ask-cli'
$ConfigPath = Join-Path $AskHome 'config.json'
$HistoryPath = Join-Path $AskHome 'history.jsonl'
$ProfilesPath = Join-Path $AskHome 'project-profiles.json'

$script:AskCliVersion = '0.3.0'
$script:ResolvedCopilot = ''
$script:Invoker = $null
$script:Cfg = $null

$RxCompiled = [System.Text.RegularExpressions.RegexOptions]::Compiled

# Ruido de PowerShell/Node que nunca aporta nada al usuario: se descarta siempre.
# Nota: PowerShell emite CategoryInfo/FullyQualifiedErrorId con prefijo "    + ", de ahi el \+? opcional.
$script:NoiseRegex = [regex]::new(
  '^\s*(?:node\.exe\s*:|[A-Za-z]:\\.*\\(?:cmd|powershell|node)\.exe\s*:|At line:\d+ char:\d+|En\s+l[ií]nea:\s*\d+|En\s+.+copilot\.ps1:|\+.*npm-loader\.js|\+\s*&\s|~{5,}\s*$|\+?\s*CategoryInfo\b|\+?\s*FullyQualifiedErrorId\b|System\.Management\.Automation\.RemoteException\s*$)',
  $RxCompiled)

# Telemetria util (creditos, tokens, diff, resume): oculta por defecto, visible con --verbose.
$script:TelemetryRegex = [regex]::new(
  '^\s*(?:Changes\s+\+\d+\s+-\d+\s*$|AI Credits\b|Tokens\b|Resume\s+copilot\s+--resume=)',
  $RxCompiled)

$script:ResumeRegex = [regex]::new('--resume=([0-9a-fA-F-]{8,})', $RxCompiled)

function Ensure-AskHome {
  if (-not (Test-Path $AskHome)) { New-Item -ItemType Directory -Path $AskHome | Out-Null }
}

function Write-Utf8NoBom([string]$path, [string]$content) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path, $content, $enc)
}

function ConvertTo-BoolValue($value, [bool]$fallback) {
  if ($null -eq $value) { return $fallback }
  if ($value -is [bool]) { return $value }
  $s = ([string]$value).Trim().ToLower()
  if ($s -in @('1', 'true', 'on', 'yes', 'si')) { return $true }
  if ($s -in @('0', 'false', 'off', 'no')) { return $false }
  return $fallback
}

function ConvertTo-IntValue($value, [int]$fallback) {
  if ($null -eq $value) { return $fallback }
  $n = 0
  if ([int]::TryParse([string]$value, [ref]$n)) { return $n }
  return $fallback
}

function Default-Config {
  return @{
    provider = 'copilot'
    model = 'auto'
    vertexModel = 'vertex-gemini-pro'
    mode = 'trusted' # trusted|safe
    dir = ''
    output = 'text' # text|json
    lastResume = ''
    lastVertexConvId = ''
    copilotPath = ''      # cache de la ruta resuelta de copilot.cmd
    allowTools = 'view,glob,rg'
    timeoutSec = 180
    historyMax = 2000
    retry = $true
  }
}

function Load-Config {
  Ensure-AskHome
  $cfg = Default-Config
  if (Test-Path $ConfigPath) {
    try {
      $raw = Get-Content $ConfigPath -Raw
      if ($raw) {
        $obj = ConvertFrom-Json $raw -ErrorAction Stop
        foreach ($p in $obj.PSObject.Properties) {
          if ($cfg.ContainsKey($p.Name) -and $null -ne $p.Value) {
            if ($p.Value -is [bool] -or $p.Value -is [int] -or $p.Value -is [long] -or $p.Value -is [double]) {
              $cfg[$p.Name] = $p.Value
            } else {
              $cfg[$p.Name] = [string]$p.Value
            }
          }
        }
      }
    } catch {}
  }
  return $cfg
}

function Save-Config($cfg) {
  Ensure-AskHome
  Write-Utf8NoBom $ConfigPath ($cfg | ConvertTo-Json -Depth 6)
}

function Convert-ObjectToHashtable($obj) {
  if ($null -eq $obj) { return $null }
  if ($obj -is [string] -or $obj -is [ValueType]) { return $obj }
  if ($obj -is [System.Collections.IDictionary]) {
    $h = @{}
    foreach ($k in $obj.Keys) { $h[[string]$k] = Convert-ObjectToHashtable $obj[$k] }
    return $h
  }
  if ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string])) {
    $arr = @()
    foreach ($it in $obj) { $arr += ,(Convert-ObjectToHashtable $it) }
    return $arr
  }
  if ($obj.PSObject -and $obj.PSObject.Properties) {
    $h2 = @{}
    foreach ($p in $obj.PSObject.Properties) { $h2[$p.Name] = Convert-ObjectToHashtable $p.Value }
    return $h2
  }
  return $obj
}

function Load-Profiles {
  Ensure-AskHome
  if (-not (Test-Path $ProfilesPath)) { return @{} }
  try {
    $raw = Get-Content $ProfilesPath -Raw
    if (-not $raw) { return @{} }
    $obj = ConvertFrom-Json $raw
    $h = Convert-ObjectToHashtable $obj
    if ($h -is [System.Collections.IDictionary]) { return $h }
  } catch {}
  return @{}
}

function Save-Profiles($profiles) {
  Ensure-AskHome
  Write-Utf8NoBom $ProfilesPath ($profiles | ConvertTo-Json -Depth 8)
}

function Resolve-FullPath([string]$pathInput) {
  if ($pathInput) { return [System.IO.Path]::GetFullPath($pathInput) }
  return [System.IO.Path]::GetFullPath((Get-Location).Path)
}

function Get-ActiveProfileRecord($cfg, [string]$dir) {
  $profiles = Load-Profiles
  $target = $dir
  if (-not $target) { $target = $cfg.dir }
  if (-not $target) { $target = (Get-Location).Path }
  $full = Resolve-FullPath $target
  $bestKey = ''
  $bestLen = -1
  foreach ($k in $profiles.Keys) {
    $pk = Resolve-FullPath ([string]$k)
    if ($full.Length -lt $pk.Length) { continue }
    $prefix = $full.Substring(0, $pk.Length)
    if ($prefix.ToLower() -ne $pk.ToLower()) { continue }
    if ($full.Length -gt $pk.Length) {
      $nextChar = $full.Substring($pk.Length, 1)
      if ($nextChar -ne '\') { continue }
    }
    if ($pk.Length -gt $bestLen) {
      $bestLen = $pk.Length
      $bestKey = $k
    }
  }
  if (-not $bestKey) { return $null }
  return @{
    key = [string]$bestKey
    profile = $profiles[$bestKey]
  }
}

function Get-ActiveProfile($cfg, [string]$dir) {
  $rec = Get-ActiveProfileRecord $cfg $dir
  if ($null -eq $rec) { return $null }
  return $rec.profile
}

function Resolve-Settings($cfg, [hashtable]$opts) {
  $profile = Get-ActiveProfile $cfg $opts.dir
  $out = @{}
  $out.provider = if ($opts.provider) { $opts.provider } elseif ($profile -and $profile.provider) { [string]$profile.provider } else { [string]$cfg.provider }
  $out.model = if ($opts.model) { $opts.model } elseif ($profile -and $profile.model) { [string]$profile.model } else { [string]$cfg.model }
  $out.vertexModel = if ($opts.vertexModel) { $opts.vertexModel } elseif ($profile -and $profile.vertexModel) { [string]$profile.vertexModel } else { [string]$cfg.vertexModel }
  $out.mode = if ($opts.mode) { $opts.mode } elseif ($profile -and $profile.mode) { [string]$profile.mode } else { [string]$cfg.mode }
  $out.output = if ($opts.output) { $opts.output } else { [string]$cfg.output }
  $out.dir = if ($opts.dir) { $opts.dir } elseif ($profile -and $profile.dir) { [string]$profile.dir } else { [string]$cfg.dir }
  $out.allowTools = if ($opts.allowTools) { [string]$opts.allowTools } elseif ($profile -and $profile.allowTools) { [string]$profile.allowTools } else { [string]$cfg.allowTools }
  if (-not $out.allowTools) { $out.allowTools = 'view,glob,rg' }
  $out.timeoutSec = if ((ConvertTo-IntValue $opts.timeoutSec 0) -gt 0) { ConvertTo-IntValue $opts.timeoutSec 180 } else { ConvertTo-IntValue $cfg.timeoutSec 180 }
  if ($out.timeoutSec -le 0) { $out.timeoutSec = 180 }
  return $out
}

function Apply-ProfilePolicy($cfg, [hashtable]$opts, [hashtable]$settings) {
  $profile = Get-ActiveProfile $cfg ''
  if (-not $profile -and $opts.dir) { $profile = Get-ActiveProfile $cfg $opts.dir }
  if (-not $profile) { return @{ settings = $settings; profile = $null } }
  $isStrict = $true
  if ($null -ne $profile.strict) {
    try { $isStrict = [bool]$profile.strict } catch { $isStrict = $true }
  }
  if (-not $isStrict) { return @{ settings = $settings; profile = $profile } }
  if ($opts.forceProfileOverride) { return @{ settings = $settings; profile = $profile } }

  $profileDir = [System.IO.Path]::GetFullPath([string]$profile.dir)
  if ($opts.dir) {
    $requestedDir = [System.IO.Path]::GetFullPath([string]$opts.dir)
    $reqLow = $requestedDir.ToLower()
    $profLow = $profileDir.ToLower()
    $inside = $reqLow.StartsWith($profLow) -and ($reqLow.Length -eq $profLow.Length -or $reqLow.Substring($profLow.Length,1) -eq '\')
    if (-not $inside) {
      throw "Perfil estricto activo: no puedes cambiar --dir fuera de $profileDir (usa --force-profile-override)."
    }
  }
  if ($opts.provider -and $opts.provider -ne [string]$profile.provider) {
    throw "Perfil estricto activo: provider bloqueado en '$($profile.provider)' (usa --force-profile-override)."
  }
  if ($opts.mode -and $opts.mode -ne [string]$profile.mode) {
    throw "Perfil estricto activo: mode bloqueado en '$($profile.mode)' (usa --force-profile-override)."
  }
  if ($opts.model) {
    $expectedModel = if ([string]$profile.provider -eq 'vertex') { [string]$profile.vertexModel } else { [string]$profile.model }
    if ($opts.model -ne $expectedModel) {
      throw "Perfil estricto activo: model bloqueado en '$expectedModel' (usa --force-profile-override)."
    }
  }
  if ($opts.vertexModel -and [string]$profile.provider -eq 'vertex' -and $opts.vertexModel -ne [string]$profile.vertexModel) {
    throw "Perfil estricto activo: vertexModel bloqueado en '$($profile.vertexModel)' (usa --force-profile-override)."
  }

  $settings.provider = [string]$profile.provider
  $settings.model = [string]$profile.model
  $settings.vertexModel = [string]$profile.vertexModel
  $settings.mode = [string]$profile.mode
  $settings.dir = $profileDir
  return @{ settings = $settings; profile = $profile }
}

function Get-CopilotCmd {
  if ($script:ResolvedCopilot -and (Test-Path $script:ResolvedCopilot)) { return $script:ResolvedCopilot }
  $cached = ''
  if ($script:Cfg -and $script:Cfg.ContainsKey('copilotPath')) { $cached = [string]$script:Cfg.copilotPath }
  if ($cached -and (Test-Path $cached)) {
    $script:ResolvedCopilot = $cached
    return $cached
  }
  $found = ''
  foreach ($name in @('copilot.cmd', 'copilot')) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c -and $c.Path) { $found = $c.Path; break }
  }
  if (-not $found) { throw "Copilot CLI no encontrado en PATH." }
  $script:ResolvedCopilot = $found
  if ($script:Cfg -and $script:Cfg.ContainsKey('copilotPath') -and ([string]$script:Cfg.copilotPath) -ne $found) {
    $script:Cfg.copilotPath = $found
    try { Save-Config $script:Cfg } catch {}
  }
  return $found
}

# copilot.cmd es un shim npm que pasa por cmd.exe, y cmd.exe TRUNCA los argumentos
# en el primer salto de linea: el prompt multilinea perderia todo despues del guard.
# Por eso resolvemos el entrypoint real (node + npm-loader.js) y lo invocamos directo.
function Get-CopilotInvoker {
  if ($null -ne $script:Invoker) { return $script:Invoker }
  $cmdPath = Get-CopilotCmd
  $inv = @{ exe = $cmdPath; prefix = @(); multiline = $false }
  try {
    $dir = Split-Path -Parent $cmdPath
    $js = Join-Path $dir 'node_modules\@github\copilot\npm-loader.js'
    if (Test-Path $js) {
      $node = Join-Path $dir 'node.exe'
      if (-not (Test-Path $node)) {
        $nc = Get-Command 'node' -ErrorAction SilentlyContinue
        $node = if ($nc -and $nc.Path) { $nc.Path } else { '' }
      }
      if ($node) { $inv = @{ exe = $node; prefix = @($js); multiline = $true } }
    }
  } catch {}
  $script:Invoker = $inv
  return $inv
}

# Fallback para el shim .cmd: aplana el prompt para que cmd.exe no lo trunque.
function ConvertTo-SingleLinePrompt([string]$text) {
  return ((([string]$text) -replace "`r`n", "`n") -replace "`n+", ' | ').Trim()
}

function Build-ExecutionFirstPrompt([string]$prompt) {
  $guard = @'
INSTRUCCION OPERATIVA:
- Ejecuta herramientas/comandos cuando el usuario pida listar, validar, revisar, comprobar o diagnosticar algo.
- No respondas solo con recomendaciones si la tarea requiere datos reales del sistema o archivos.
- Si un intento falla por permisos, prueba una alternativa de lectura/consulta no destructiva y reporta resultado real.
- No preguntes "¿procedo?" ni pidas confirmación para tareas normales; actúa y entrega resultado.
- FLUIDEZ: avanza de corrido hasta completar la tarea; no te detengas para pedir pasos intermedios.
- Si faltan detalles menores, asume la opción razonable y continúa.
- Solo haz preguntas si falta un dato crítico imposible de inferir o si la acción es destructiva/irreversible.
'@
  return ($guard + "`n`nTAREA:`n" + $prompt)
}

function Is-NonOperationalCopilotReply([string]$text) {
  $t = [string]$text
  if (-not $t.Trim()) { return $true }
  # Una respuesta larga ya representa trabajo real: nunca vale la pena pagar un segundo round-trip.
  if ($t.Length -gt 400) { return $false }
  $low = $t.ToLower()
  if ($low -match '^\s*listo[,.\s]*entendido') { return $true }
  if ($low -match '^\s*entendido\.\s*estoy listo y operativo') { return $true }
  if ($low -match '^\s*qué necesitas|^\s*que necesitas|^\s*what do you need') { return $true }
  if ($low -match 'disponibles:\s*`?todos`?\s*y\s*`?todo_deps`?') { return $true }
  if ($low -match 'estado:\s*\n?-?\s*cwd:') { return $true }
  return $false
}

function Append-History([hashtable]$entry) {
  Ensure-AskHome
  $line = ($entry | ConvertTo-Json -Depth 8 -Compress)
  Add-Content -Path $HistoryPath -Value $line -Encoding UTF8
  $max = 2000
  if ($script:Cfg) { $max = ConvertTo-IntValue $script:Cfg.historyMax 2000 }
  if ($max -le 0) { return }
  # Chequeo por tamano: evita releer el archivo completo en cada invocacion.
  try {
    $info = Get-Item $HistoryPath -ErrorAction SilentlyContinue
    if ($info -and $info.Length -gt 2MB) {
      $keep = @(Get-Content $HistoryPath -Tail $max -ErrorAction SilentlyContinue)
      Write-Utf8NoBom $HistoryPath (($keep -join "`n") + "`n")
    }
  } catch {}
}

function Get-LastResume {
  if (-not (Test-Path $HistoryPath)) { return '' }
  $lines = @(Get-Content $HistoryPath -Tail 200 -ErrorAction SilentlyContinue)
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    try {
      $obj = $lines[$i] | ConvertFrom-Json
      if ($obj.resume) { return [string]$obj.resume }
    } catch {}
  }
  return ''
}

function Invoke-CopilotPrompt([string]$prompt, [hashtable]$settings, [hashtable]$opts) {
  $inv = Get-CopilotInvoker
  $exe = [string]$inv.exe
  $cargs = @() + $inv.prefix
  if ($settings.dir) { $cargs += @('-C', $settings.dir) }
  if ($settings.model) { $cargs += @('--model', $settings.model) }
  if ($opts.resume) { $cargs += @('--resume', $opts.resume) }
  foreach ($a in $opts.attachments) { $cargs += @('--attachment', [string]$a) }
  foreach ($d in $opts.addDirs) { $cargs += @('--add-dir', [string]$d) }
  if ($settings.mode -eq 'trusted') {
    $cargs += '--allow-all-tools'
  } else {
    $cargs += @('--allow-tool', [string]$settings.allowTools)
  }
  if ($settings.output -eq 'json') { $cargs += @('--output-format', 'json') }
  foreach ($p in $opts.passthrough) { $cargs += [string]$p }
  $finalPrompt = if ($inv.multiline) { $prompt } else { ConvertTo-SingleLinePrompt $prompt }
  $cargs += @('--prompt', $finalPrompt)

  $rawLines = [System.Collections.Generic.List[string]]::new()
  $filtered = [System.Collections.Generic.List[string]]::new()
  $verbose = [bool]$opts.verbose
  $stream = ($settings.output -ne 'json') -and (-not $opts.noStream)

  # Streaming real: cada linea se filtra e imprime conforme el proceso la emite.
  & $exe @cargs 2>&1 | ForEach-Object {
    $line = [string]$_
    $rawLines.Add($line)
    if ($script:NoiseRegex.IsMatch($line)) { return }
    if ((-not $verbose) -and $script:TelemetryRegex.IsMatch($line)) { return }
    $filtered.Add($line)
    if ($stream) { Write-Host $line }
  }
  $exitCode = $LASTEXITCODE
  if ($null -eq $exitCode) { $exitCode = 0 }

  $resume = ''
  foreach ($l in $rawLines) {
    $m = $script:ResumeRegex.Match($l)
    if ($m.Success) { $resume = $m.Groups[1].Value }
  }

  $text = (($filtered -join [Environment]::NewLine)).Trim()
  return @{
    code = $exitCode
    text = $text
    resume = $resume
    route = ''
    raw = ($rawLines -join [Environment]::NewLine)
    streamed = ($stream -and $filtered.Count -gt 0)
  }
}

function Invoke-VertexPrompt([string]$prompt, [hashtable]$settings, [hashtable]$opts, [hashtable]$cfg) {
  $model = if ($opts.model) { $opts.model } else { $settings.vertexModel }
  if (-not $model) { $model = 'vertex-gemini-pro' }
  $convId = if ($opts.resume) { $opts.resume } else { ('askcli-' + [Guid]::NewGuid().ToString()) }
  $body = @{
    message = $prompt
    model = $model
    convId = $convId
  } | ConvertTo-Json -Depth 6
  $response = $null
  $reader = $null
  $event = ''
  $route = ''
  $acc = ''
  $errText = ''
  $doneCode = 0
  $rawLines = New-Object System.Collections.Generic.List[string]
  $printedStream = $false

  try {
    $req = [System.Net.HttpWebRequest]::Create('http://127.0.0.1:8717/api/chat')
    $req.Method = 'POST'
    $req.ContentType = 'application/json'
    $timeoutMs = (ConvertTo-IntValue $settings.timeoutSec 180) * 1000
    if ($timeoutMs -le 0) { $timeoutMs = 180000 }
    $req.Timeout = $timeoutMs
    $req.ReadWriteTimeout = $timeoutMs
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $req.ContentLength = $bytes.Length
    $reqStream = $req.GetRequestStream()
    $reqStream.Write($bytes, 0, $bytes.Length)
    $reqStream.Dispose()
    $response = $req.GetResponse()
    $reader = [System.IO.StreamReader]::new($response.GetResponseStream())
    while (-not $reader.EndOfStream) {
      $line = $reader.ReadLine()
      if ($null -eq $line) { continue }
      $rawLines.Add($line)
      if ($line -like 'event:*') {
        $event = ($line -replace '^event:\s*', '').Trim()
        continue
      }
      if ($line -notlike 'data:*') { continue }
      $dataRaw = ($line -replace '^data:\s*', '').Trim()
      if ($event -eq 'chunk') {
        $chunkText = ''
        try { $chunkText = [string]($dataRaw | ConvertFrom-Json) } catch { $chunkText = $dataRaw }
        $acc += $chunkText
        if ($settings.output -ne 'json' -and -not $opts.noStream) {
          Write-Host -NoNewline $chunkText
          $printedStream = $true
        }
      } elseif ($event -eq 'route') {
        try { $obj = $dataRaw | ConvertFrom-Json; if ($obj.model) { $route = [string]$obj.model } } catch {}
      } elseif ($event -eq 'status') {
        if (-not $opts.quiet -and $settings.output -ne 'json' -and -not $opts.noStream) {
          try { $statusText = [string]($dataRaw | ConvertFrom-Json); if ($statusText) { Write-Host ("`n[status] " + $statusText) } } catch {}
        }
      } elseif ($event -eq 'error') {
        try { $errText = [string]($dataRaw | ConvertFrom-Json) } catch { $errText = $dataRaw }
      } elseif ($event -eq 'done') {
        try {
          $objDone = $dataRaw | ConvertFrom-Json
          if ($null -ne $objDone.code) { $doneCode = [int]$objDone.code }
        } catch {}
      }
    }
  } catch [System.Net.WebException] {
    $statusCode = 0
    $errBody = ''
    if ($_.Exception.Response) {
      try {
        $resp = $_.Exception.Response
        $statusCode = [int]$resp.StatusCode
        $rdr = [System.IO.StreamReader]::new($resp.GetResponseStream())
        $errBody = $rdr.ReadToEnd()
        $rdr.Dispose()
      } catch {}
    }
    $msg = if ($statusCode -gt 0) { "HTTP $statusCode en HanstlerS API." } else { 'Error conectando a HanstlerS local API (:8717).' }
    return @{ code = 1; text = $msg; resume = $convId; route = $route; raw = $errBody; streamed = $printedStream }
  } catch {
    return @{ code = 1; text = 'Error conectando a HanstlerS local API (:8717).'; resume = $convId; route = $route; raw = $_.Exception.Message; streamed = $printedStream }
  } finally {
    if ($printedStream -and $settings.output -ne 'json' -and -not $opts.noStream) { Write-Host '' }
    if ($reader) { try { $reader.Dispose() } catch {} }
    if ($response) { try { $response.Dispose() } catch {} }
  }

  $raw = ($rawLines -join "`n")
  if ($errText) { return @{ code = 1; text = $errText; resume = $convId; route = $route; raw = $raw; streamed = $printedStream } }
  return @{ code = $doneCode; text = $acc.Trim(); resume = $convId; route = $route; raw = $raw; streamed = $printedStream }
}

function Invoke-AskPrompt([string]$prompt, [hashtable]$settings, [hashtable]$opts, [hashtable]$cfg) {
  $effective = Build-ExecutionFirstPrompt $prompt
  $res = if ($settings.provider -eq 'vertex') {
    Invoke-VertexPrompt $effective $settings $opts $cfg
  } else {
    Invoke-CopilotPrompt $effective $settings $opts
  }

  $wantRetry = ConvertTo-BoolValue $opts.retry $true
  if ($wantRetry) { $wantRetry = ConvertTo-BoolValue $cfg.retry $true }
  if ($wantRetry -and ($res.code -eq 0) -and (Is-NonOperationalCopilotReply $res.text)) {
    $retryPrompt = $effective + "`n`nREINTENTO OBLIGATORIO: ejecuta la tarea ahora, no pidas más datos intermedios."
    if ($res.streamed -eq $true -and -not $opts.quiet) { Write-Host "[ask-cli] respuesta no operativa, reintentando..." }
    $res = if ($settings.provider -eq 'vertex') {
      Invoke-VertexPrompt $retryPrompt $settings $opts $cfg
    } else {
      Invoke-CopilotPrompt $retryPrompt $settings $opts
    }
  }

  if ($res.resume) {
    if ($settings.provider -eq 'vertex') { $cfg.lastVertexConvId = $res.resume } else { $cfg.lastResume = $res.resume }
  }
  return $res
}

function Show-Help {
@'
ask-cli - Wrapper avanzado para Copilot CLI + Vertex (HanstlerS)

Uso:
  ask-cli run "pregunta..." [opciones]
  ask-cli chat [--provider copilot] [--model <id>] [--resume <sessionId>]
  ask-cli resume [sessionId] [--provider copilot|vertex]
  ask-cli sessions [list|clear] [n]
  ask-cli model show
  ask-cli model set <id>
  ask-cli auth status|login|logout
  ask-cli doctor
  ask-cli version
  ask-cli project init [ruta] [--provider ...] [--model ...] [--strict-profile|--relaxed-profile]
  ask-cli project show [ruta]
  ask-cli project strict on|off [ruta]
  ask-cli config show
  ask-cli config set <clave> <valor>

Opciones:
  --provider copilot|vertex   Backend a usar.
  --model <id>                Modelo (copilot) o modelo directo.
  --vertex-model <id>         Modelo para provider vertex.
  --dir <ruta>                Directorio de trabajo (-C en Copilot CLI).
  --add-dir <ruta>            Directorio extra de contexto (repetible).
  --attach <ruta>             Adjunto (repetible).
  --resume <id>               Reanuda sesion.
  --allow-tool <lista>        Herramientas permitidas en modo safe.
  --timeout <seg>             Timeout de red del provider vertex.
  --json                      Salida JSON (desactiva streaming).
  --quiet                     Sin mensajes accesorios.
  --verbose                   Muestra telemetria (AI Credits, Tokens, Changes).
  --no-stream                 Desactiva streaming incremental.
  --no-retry                  No reintenta ante respuesta no operativa.
  --safe | --trusted          Atajos de modo.
  --force-profile-override    Ignora un perfil estricto.
  --                          Todo lo que siga es prompt literal.

Notas:
  - Modo trusted: usa --allow-all-tools. Modo safe: limita a --allow-tool (default view,glob,rg).
  - Flags --* no reconocidos se reenvian tal cual a Copilot CLI (passthrough), p.ej. MCP.
  - Provider vertex usa HanstlerS local API en http://127.0.0.1:8717/api/chat.
  - Perfil estricto bloquea provider/model/mode/dir del proyecto; usa --force-profile-override.
  - Claves de config: provider, model, vertexModel, mode, dir, output, copilotPath,
    allowTools, timeoutSec, historyMax, retry.
'@ | Write-Host
}

function Parse-Options([string[]]$tokens) {
  $opts = @{
    provider = ''
    model = ''
    vertexModel = ''
    mode = ''
    output = ''
    dir = ''
    resume = ''
    attachments = @()
    addDirs = @()
    passthrough = @()
    allowTools = ''
    timeoutSec = 0
    quiet = $false
    noStream = $false
    verbose = $false
    retry = $true
    forceProfileOverride = $false
    strictProfile = ''
    prompt = @()
  }
  $i = 0
  while ($i -lt $tokens.Count) {
    $t = [string]$tokens[$i]
    switch ($t) {
      '--provider' { $i++; if ($i -lt $tokens.Count) { $opts.provider = [string]$tokens[$i] } }
      '--model'    { $i++; if ($i -lt $tokens.Count) { $opts.model = [string]$tokens[$i] } }
      '--vertex-model' { $i++; if ($i -lt $tokens.Count) { $opts.vertexModel = [string]$tokens[$i] } }
      '--mode'     { $i++; if ($i -lt $tokens.Count) { $opts.mode = [string]$tokens[$i] } }
      '--dir'      { $i++; if ($i -lt $tokens.Count) { $opts.dir = [string]$tokens[$i] } }
      '--resume'   { $i++; if ($i -lt $tokens.Count) { $opts.resume = [string]$tokens[$i] } }
      '--attach'   { $i++; if ($i -lt $tokens.Count) { $opts.attachments += [string]$tokens[$i] } }
      '--add-dir'  { $i++; if ($i -lt $tokens.Count) { $opts.addDirs += [string]$tokens[$i] } }
      '--allow-tool' { $i++; if ($i -lt $tokens.Count) { $opts.allowTools = [string]$tokens[$i] } }
      '--timeout'  { $i++; if ($i -lt $tokens.Count) { $opts.timeoutSec = ConvertTo-IntValue $tokens[$i] 0 } }
      '--json'     { $opts.output = 'json' }
      '--quiet'    { $opts.quiet = $true }
      '--verbose'  { $opts.verbose = $true }
      '--no-stream' { $opts.noStream = $true }
      '--no-retry' { $opts.retry = $false }
      '--retry'    { $opts.retry = $true }
      '--safe'     { $opts.mode = 'safe' }
      '--trusted'  { $opts.mode = 'trusted' }
      '--force-profile-override' { $opts.forceProfileOverride = $true }
      '--strict-profile' { $opts.strictProfile = 'strict' }
      '--relaxed-profile' { $opts.strictProfile = 'relaxed' }
      default {
        if ($t -eq '--') {
          # Todo lo que sigue es prompt literal.
          $i++
          while ($i -lt $tokens.Count) { $opts.prompt += [string]$tokens[$i]; $i++ }
        } elseif ($t.StartsWith('--')) {
          # Flag desconocido: se reenvia tal cual a Copilot CLI (passthrough).
          $opts.passthrough += $t
          if (($i + 1) -lt $tokens.Count -and -not ([string]$tokens[$i + 1]).StartsWith('-')) {
            $i++
            $opts.passthrough += [string]$tokens[$i]
          }
        } else {
          $opts.prompt += $t
        }
      }
    }
    $i++
  }
  return $opts
}

if ($env:ASKCLI_NO_MAIN -eq '1') { return }

if (-not $Args -or $Args.Count -eq 0) {
  Show-Help
  exit 0
}

$cfg = Load-Config
$script:Cfg = $cfg
$cmd = [string]$Args[0]

# Backward compatibility: ask-cli "pregunta"
if ($cmd -notin @('run','chat','resume','sessions','model','auth','doctor','project','config','help','version','--version','-v')) {
  $opts = Parse-Options @($Args)
  $settings = Resolve-Settings $cfg $opts
  try {
    $policy = Apply-ProfilePolicy $cfg $opts $settings
    $settings = $policy.settings
  } catch {
    Write-Host $_.Exception.Message
    exit 1
  }
  $prompt = ($opts.prompt -join ' ').Trim()
  if (-not $prompt) { Show-Help; exit 1 }
  $res = Invoke-AskPrompt $prompt $settings $opts $cfg
  Save-Config $cfg
  Append-History @{
    ts = (Get-Date).ToString('s')
    provider = $settings.provider
    model = if ($settings.provider -eq 'vertex') { $settings.vertexModel } else { $settings.model }
    prompt = $prompt
    resume = $res.resume
    code = $res.code
  }
  if ($settings.output -eq 'json') {
    @{ ok = ($res.code -eq 0); provider = $settings.provider; resume = $res.resume; text = $res.text } | ConvertTo-Json -Depth 6
  } else {
    if ($res.text -and -not ($res['streamed'] -eq $true)) { $res.text | Write-Host }
  }
  exit $res.code
}

switch ($cmd) {
  'help' {
    Show-Help
    exit 0
  }
  { $_ -in @('version','--version','-v') } {
    Write-Host ("ask-cli " + $script:AskCliVersion)
    exit 0
  }
  'run' {
    $opts = Parse-Options @($Args[1..($Args.Count-1)])
    $settings = Resolve-Settings $cfg $opts
    try {
      $policy = Apply-ProfilePolicy $cfg $opts $settings
      $settings = $policy.settings
    } catch {
      Write-Host $_.Exception.Message
      exit 1
    }
    $prompt = ($opts.prompt -join ' ').Trim()
    if (-not $prompt) { Write-Host "Falta prompt. Uso: ask-cli run `"tu pregunta`""; exit 1 }
    $res = Invoke-AskPrompt $prompt $settings $opts $cfg
    Save-Config $cfg
    Append-History @{
      ts = (Get-Date).ToString('s')
      provider = $settings.provider
      model = if ($settings.provider -eq 'vertex') { $settings.vertexModel } else { $settings.model }
      prompt = $prompt
      resume = $res.resume
      code = $res.code
    }
    if ($settings.output -eq 'json') {
      $routeVal = if ($null -ne $res['route']) { [string]$res['route'] } else { '' }
      @{ ok = ($res.code -eq 0); provider = $settings.provider; resume = $res.resume; route = $routeVal; text = $res.text } | ConvertTo-Json -Depth 6
    } else {
      if ($res.text -and -not ($res['streamed'] -eq $true)) { $res.text | Write-Host }
      if (-not $opts.quiet -and $res.resume) { Write-Host ("resume: " + $res.resume) }
    }
    exit $res.code
  }
  'chat' {
    $opts = Parse-Options @($Args[1..($Args.Count-1)])
    $settings = Resolve-Settings $cfg $opts
    try {
      $policy = Apply-ProfilePolicy $cfg $opts $settings
      $settings = $policy.settings
    } catch {
      Write-Host $_.Exception.Message
      exit 1
    }
    if ($settings.provider -eq 'vertex') {
      Write-Host "Chat interactivo continuo no aplica para provider=vertex. Usa: ask-cli run ""prompt"" --provider vertex"
      exit 1
    }
    $cp = Get-CopilotInvoker
    $cpArgs = @() + $cp.prefix
    if ($settings.dir) { $cpArgs += @('-C', $settings.dir) }
    if ($settings.model) { $cpArgs += @('--model', $settings.model) }
    if ($opts.resume) { $cpArgs += @('--resume', $opts.resume) }
    if ($settings.mode -eq 'trusted') { $cpArgs += '--allow-all-tools' } else { $cpArgs += @('--allow-tool', [string]$settings.allowTools) }
    foreach ($d in $opts.addDirs) { $cpArgs += @('--add-dir', [string]$d) }
    foreach ($p in $opts.passthrough) { $cpArgs += [string]$p }
    & $cp.exe @cpArgs
    exit $LASTEXITCODE
  }
  'sessions' {
    $sub = if ($Args.Count -ge 2) { [string]$Args[1] } else { 'list' }
    if ($sub -eq 'clear') {
      if (Test-Path $HistoryPath) { Remove-Item $HistoryPath -Force }
      Write-Host 'Historial borrado.'
      exit 0
    }
    if ($sub -notin @('list')) { Write-Host 'Uso: ask-cli sessions [list|clear] [n]'; exit 1 }
    if (-not (Test-Path $HistoryPath)) { Write-Host 'Sin sesiones registradas.'; exit 0 }
    $n = if ($Args.Count -ge 3) { ConvertTo-IntValue $Args[2] 20 } else { 20 }
    if ($n -le 0) { $n = 20 }
    $lines = @(Get-Content $HistoryPath -Tail $n -ErrorAction SilentlyContinue)
    $rows = @()
    foreach ($l in $lines) {
      try { $rows += ($l | ConvertFrom-Json) } catch {}
    }
    if ($rows.Count -eq 0) { Write-Host 'Sin sesiones registradas.'; exit 0 }
    $rows |
      Select-Object ts, provider, model, code, resume,
        @{ n = 'prompt'; e = {
            $p = [string]$_.prompt
            if ($p.Length -gt 60) { $p.Substring(0, 60) + '...' } else { $p }
          } } |
      Format-Table -AutoSize
    exit 0
  }
  'resume' {
    $opts = Parse-Options @($Args[1..($Args.Count-1)])
    $id = ''
    if ($opts.prompt.Count -gt 0) { $id = [string]$opts.prompt[0] }
    if (-not $id) { $id = if ($opts.provider -eq 'vertex') { [string]$cfg.lastVertexConvId } else { [string]$cfg.lastResume } }
    if (-not $id) { $id = Get-LastResume }
    if (-not $id) { Write-Host "No hay sesión previa para reanudar."; exit 1 }
    if ($opts.provider -eq 'vertex') {
      Write-Host ("Reanuda Vertex usando: ask-cli run ""<prompt>"" --provider vertex --resume " + $id)
      exit 0
    }
    $cp = Get-CopilotInvoker
    $cpArgs = @() + $cp.prefix + @('--resume', $id)
    & $cp.exe @cpArgs
    exit $LASTEXITCODE
  }
  'model' {
    if ($Args.Count -lt 2 -or $Args[1] -eq 'show') {
      Write-Host ("provider=" + $cfg.provider)
      Write-Host ("model=" + $cfg.model)
      Write-Host ("vertexModel=" + $cfg.vertexModel)
      exit 0
    }
    if ($Args.Count -ge 3 -and $Args[1] -eq 'set') {
      $m = [string]$Args[2]
      if ($m -like 'vertex-*') { $cfg.provider = 'vertex'; $cfg.vertexModel = $m } else { $cfg.provider = 'copilot'; $cfg.model = $m }
      Save-Config $cfg
      Write-Host ("OK model=" + $m)
      exit 0
    }
    Write-Host "Uso: ask-cli model show | ask-cli model set <id>"
    exit 1
  }
  'auth' {
    $sub = if ($Args.Count -ge 2) { [string]$Args[1] } else { 'status' }
    $cp = Get-CopilotInvoker
    if ($sub -eq 'login') { $la = @() + $cp.prefix + @('login'); & $cp.exe @la; exit $LASTEXITCODE }
    if ($sub -eq 'logout') {
      $gh = Get-Command 'gh' -ErrorAction SilentlyContinue
      if ($gh) {
        & $gh.Path 'auth' 'logout' '--hostname' 'github.com' '--yes'
        exit $LASTEXITCODE
      }
      Write-Host "gh CLI no encontrado. Cierra sesión manualmente en GitHub CLI."
      exit 1
    }
    $gh2 = Get-Command 'gh' -ErrorAction SilentlyContinue
    if ($gh2) {
      & $gh2.Path 'auth' 'status'
      exit $LASTEXITCODE
    }
    Write-Host "gh CLI no encontrado para revisar estado."
    exit 1
  }
  'doctor' {
    Write-Host ("=== ask-cli doctor (v" + $script:AskCliVersion + ") ===")
    Write-Host ("host: PowerShell " + $PSVersionTable.PSVersion)
    $pwsh = Get-Command 'pwsh' -ErrorAction SilentlyContinue
    if ($pwsh) { Write-Host ("pwsh7: OK (" + $pwsh.Path + ")") } else { Write-Host "pwsh7: WARN (no instalado; el arranque es mas lento en PS 5.1)" }
    try {
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $cp = Get-CopilotCmd
      $sw.Stop()
      Write-Host ("copilot: OK (" + $cp + ") resuelto en " + $sw.ElapsedMilliseconds + " ms")
      $inv = Get-CopilotInvoker
      if ($inv.multiline) {
        Write-Host ("invoker: node directo (" + $inv.exe + ") - prompts multilinea OK")
      } else {
        Write-Host "invoker: WARN shim copilot.cmd (cmd.exe trunca en el primer salto de linea; los prompts se aplanan)"
      }
    } catch { Write-Host "copilot: FAIL"; exit 1 }
    $vtimeout = ConvertTo-IntValue $cfg.timeoutSec 180
    try {
      $state = Invoke-RestMethod -Uri 'http://127.0.0.1:8717/api/state' -TimeoutSec 5
      Write-Host ("hanstlers: OK model=" + $state.model)
    } catch { Write-Host "hanstlers: WARN (no responde en :8717)" }
    Write-Host ("timeoutSec: " + $vtimeout + " (aplica al provider vertex)")
    Write-Host ("config: " + $ConfigPath)
    Write-Host ("history: " + $HistoryPath)
    if (Test-Path $HistoryPath) {
      $hi = Get-Item $HistoryPath
      Write-Host ("history size: " + [math]::Round($hi.Length / 1KB, 1) + " KB (rotacion a " + (ConvertTo-IntValue $cfg.historyMax 2000) + " lineas sobre 2 MB)")
    }
    exit 0
  }
  'project' {
    if ($Args.Count -lt 2) { Write-Host "Uso: ask-cli project init|show|strict ..."; exit 1 }
    $sub = [string]$Args[1]
    if ($sub -eq 'show') {
      $target = if ($Args.Count -ge 3) { [string]$Args[2] } else { (Get-Location).Path }
      $rec = Get-ActiveProfileRecord $cfg $target
      if ($null -eq $rec) { Write-Host ("Sin perfil para: " + (Resolve-FullPath $target)); exit 1 }
      $rec.profile | ConvertTo-Json -Depth 8
      exit 0
    }
    if ($sub -eq 'strict') {
      if ($Args.Count -lt 3) { Write-Host "Uso: ask-cli project strict on|off [ruta]"; exit 1 }
      $flag = [string]$Args[2]
      $target = if ($Args.Count -ge 4) { [string]$Args[3] } else { (Get-Location).Path }
      $rec = Get-ActiveProfileRecord $cfg $target
      if ($null -eq $rec) { Write-Host ("Sin perfil para: " + (Resolve-FullPath $target)); exit 1 }
      $full = [string]$rec.key
      $profiles = Load-Profiles
      if ($flag -in @('on','true','1')) { $profiles[$full].strict = $true }
      elseif ($flag -in @('off','false','0')) { $profiles[$full].strict = $false }
      else { Write-Host "Valor inválido. Usa on|off."; exit 1 }
      Save-Profiles $profiles
      Write-Host ("Perfil actualizado: strict=" + [string]$profiles[$full].strict)
      exit 0
    }
    if ($sub -ne 'init') { Write-Host "Uso: ask-cli project init [ruta] [--provider ...] [--model ...]"; exit 1 }
    $rest = @()
    if ($Args.Count -gt 2) { $rest = @($Args[2..($Args.Count-1)]) }
    $opts = Parse-Options $rest
    $settings = Resolve-Settings $cfg $opts
    $target = if ($opts.prompt.Count -gt 0) { [string]$opts.prompt[0] } elseif ($opts.dir) { $opts.dir } else { (Get-Location).Path }
    $full = [System.IO.Path]::GetFullPath($target)
    $strictValue = $true
    if ($opts.strictProfile -eq 'relaxed') { $strictValue = $false }
    $profiles = Load-Profiles
    $profiles[$full] = @{
      dir = $full
      provider = $settings.provider
      model = $settings.model
      vertexModel = $settings.vertexModel
      mode = $settings.mode
      allowTools = $settings.allowTools
      strict = $strictValue
      updatedAt = (Get-Date).ToString('s')
    }
    Save-Profiles $profiles
    $cfg.dir = $full
    Save-Config $cfg
    Write-Host ("Perfil creado: " + $full + " (strict=" + [string]$strictValue + ")")
    exit 0
  }
  'config' {
    if ($Args.Count -lt 2 -or $Args[1] -eq 'show') {
      $cfg | ConvertTo-Json -Depth 4
      exit 0
    }
    if ($Args.Count -ge 4 -and $Args[1] -eq 'set') {
      $k = [string]$Args[2]
      $v = [string]$Args[3]
      if (-not ($cfg.ContainsKey($k))) { Write-Host ("Clave inválida: " + $k); exit 1 }
      if ($k -in @('timeoutSec','historyMax')) { $cfg[$k] = ConvertTo-IntValue $v (ConvertTo-IntValue $cfg[$k] 0) }
      elseif ($k -in @('retry')) { $cfg[$k] = ConvertTo-BoolValue $v $true }
      else { $cfg[$k] = $v }
      Save-Config $cfg
      Write-Host ("OK " + $k + "=" + [string]$cfg[$k])
      exit 0
    }
    Write-Host "Uso: ask-cli config show | ask-cli config set <key> <value>"
    exit 1
  }
  default {
    Show-Help
    exit 1
  }
}
