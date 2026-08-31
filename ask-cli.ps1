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

function Ensure-AskHome {
  if (-not (Test-Path $AskHome)) { New-Item -ItemType Directory -Path $AskHome | Out-Null }
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
          if ($cfg.ContainsKey($p.Name) -and $null -ne $p.Value) { $cfg[$p.Name] = [string]$p.Value }
        }
      }
    } catch {}
  }
  return $cfg
}

function Save-Config($cfg) {
  Ensure-AskHome
  ($cfg | ConvertTo-Json -Depth 6) | Out-File -FilePath $ConfigPath -Encoding utf8
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
  ($profiles | ConvertTo-Json -Depth 8) | Out-File -FilePath $ProfilesPath -Encoding utf8
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
  $cmd = Get-Command 'copilot.cmd' -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Path) { return $cmd.Path }
  $cmd2 = Get-Command 'copilot' -ErrorAction SilentlyContinue
  if ($cmd2 -and $cmd2.Path) { return $cmd2.Path }
  throw "Copilot CLI no encontrado en PATH."
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
  Add-Content -Path $HistoryPath -Value $line
}

function Get-LastResume {
  if (-not (Test-Path $HistoryPath)) { return '' }
  $lines = Get-Content $HistoryPath -ErrorAction SilentlyContinue
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    try {
      $obj = $lines[$i] | ConvertFrom-Json
      if ($obj.resume) { return [string]$obj.resume }
    } catch {}
  }
  return ''
}

function Invoke-CopilotPrompt([string]$prompt, [hashtable]$settings, [hashtable]$opts) {
  $cmd = Get-CopilotCmd
  $args = @()
  if ($settings.dir) { $args += @('-C', $settings.dir) }
  if ($settings.model) { $args += @('--model', $settings.model) }
  if ($opts.resume) { $args += @('--resume', $opts.resume) }
  if ($opts.attachments) {
    foreach ($a in $opts.attachments) { $args += @('--attachment', $a) }
  }
  if ($settings.mode -eq 'trusted') {
    $args += '--allow-all-tools'
  } else {
    $args += @('--allow-tool', 'view,glob,rg')
  }
  if ($settings.output -eq 'json') { $args += @('--output-format', 'json') }
  $args += @('--prompt', $prompt)

  $rawLines = @()
  & $cmd @args 2>&1 | ForEach-Object { $rawLines += [string]$_ }
  $exitCode = $LASTEXITCODE
  $resume = ''
  foreach ($l in $rawLines) {
    if ($l -match '--resume=([0-9a-fA-F-]{8,})') { $resume = $Matches[1] }
  }
  $filtered = @()
  foreach ($l in $rawLines) {
    if ($l -match '^\s*Changes\s+\+\d+\s+-\d+\s*$') { continue }
    if ($l -match '^\s*AI Credits\b') { continue }
    if ($l -match '^\s*Tokens\b') { continue }
    if ($l -match '^\s*Resume\s+copilot\s+--resume=') { continue }
    if ($l -match '^\s*node\.exe\s*:') { continue }
    if ($l -match '^\s*En\s+.+copilot\.ps1:') { continue }
    if ($l -match '^\s*\+.*npm-loader\.js') { continue }
    if ($l -match '^\s*~{5,}\s*$') { continue }
    if ($l -match '^\s*CategoryInfo') { continue }
    if ($l -match '^\s*FullyQualifiedErrorId') { continue }
    if ($l -match '^\s*System\.Management\.Automation\.RemoteException\s*$') { continue }
    $filtered += $l
  }
  $text = ($filtered -join [Environment]::NewLine).Trim()
  return @{
    code = $exitCode
    text = $text
    resume = $resume
    raw = ($rawLines -join [Environment]::NewLine)
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
  $error = ''
  $doneCode = 0
  $rawLines = New-Object System.Collections.Generic.List[string]
  $printedStream = $false

  try {
    $req = [System.Net.HttpWebRequest]::Create('http://127.0.0.1:8717/api/chat')
    $req.Method = 'POST'
    $req.ContentType = 'application/json'
    $req.Timeout = 180000
    $req.ReadWriteTimeout = 180000
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
        try { $error = [string]($dataRaw | ConvertFrom-Json) } catch { $error = $dataRaw }
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
  if ($error) { return @{ code = 1; text = $error; resume = $convId; route = $route; raw = $raw; streamed = $printedStream } }
  return @{ code = $doneCode; text = $acc.Trim(); resume = $convId; route = $route; raw = $raw; streamed = $printedStream }
}

function Show-Help {
@'
ask-cli - Wrapper avanzado para Copilot CLI + Vertex (HanstlerS)

Uso:
  ask-cli run "pregunta..." [--provider copilot|vertex] [--model <id>] [--resume <id>] [--json] [--quiet] [--no-stream]
  ask-cli chat [--provider copilot] [--model <id>] [--resume <sessionId>]
  ask-cli resume [sessionId] [--provider copilot|vertex]
  ask-cli model show
  ask-cli model set <id>
  ask-cli auth status|login|logout
  ask-cli doctor
  ask-cli project init [ruta] [--provider ...] [--model ...] [--strict-profile|--relaxed-profile]
  ask-cli project show [ruta]
  ask-cli project strict on|off [ruta]
  ask-cli config show
  ask-cli config set <provider|model|vertexModel|mode|dir|output> <valor>

Notas:
  - Modo trusted: usa --allow-all-tools.
  - Modo safe: limita permisos a view,glob,rg.
  - Provider vertex usa HanstlerS local API en http://127.0.0.1:8717/api/chat.
  - Perfil estricto bloquea provider/model/mode/dir del proyecto; usa --force-profile-override para saltarlo.
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
    quiet = $false
    noStream = $false
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
      '--json'     { $opts.output = 'json' }
      '--quiet'    { $opts.quiet = $true }
      '--no-stream' { $opts.noStream = $true }
      '--safe'     { $opts.mode = 'safe' }
      '--trusted'  { $opts.mode = 'trusted' }
      '--force-profile-override' { $opts.forceProfileOverride = $true }
      '--strict-profile' { $opts.strictProfile = 'strict' }
      '--relaxed-profile' { $opts.strictProfile = 'relaxed' }
      default      { $opts.prompt += $t }
    }
    $i++
  }
  return $opts
}

if (-not $Args -or $Args.Count -eq 0) {
  Show-Help
  exit 0
}

$cfg = Load-Config
$cmd = [string]$Args[0]

# Backward compatibility: ask-cli "pregunta"
if ($cmd -notin @('run','chat','resume','model','auth','doctor','project','config','help')) {
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
  $effectivePrompt = Build-ExecutionFirstPrompt $prompt
  $res = $null
  if ($settings.provider -eq 'vertex') {
    $res = Invoke-VertexPrompt $effectivePrompt $settings $opts $cfg
    if (($res.code -eq 0) -and (Is-NonOperationalCopilotReply $res.text)) {
      $retryPrompt = $effectivePrompt + "`n`nREINTENTO OBLIGATORIO: ejecuta la tarea ahora, no pidas más datos intermedios."
      $res = Invoke-VertexPrompt $retryPrompt $settings $opts $cfg
    }
    if ($res.resume) { $cfg.lastVertexConvId = $res.resume }
  } else {
    $res = Invoke-CopilotPrompt $effectivePrompt $settings $opts
    if (($res.code -eq 0) -and (Is-NonOperationalCopilotReply $res.text)) {
      $retryPrompt = $effectivePrompt + "`n`nREINTENTO OBLIGATORIO: ejecuta la tarea ahora, no pidas más datos intermedios."
      $res = Invoke-CopilotPrompt $retryPrompt $settings $opts
    }
    if ($res.resume) { $cfg.lastResume = $res.resume }
  }
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
    $effectivePrompt = Build-ExecutionFirstPrompt $prompt
    $res = $null
    if ($settings.provider -eq 'vertex') {
      $res = Invoke-VertexPrompt $effectivePrompt $settings $opts $cfg
      if (($res.code -eq 0) -and (Is-NonOperationalCopilotReply $res.text)) {
        $retryPrompt = $effectivePrompt + "`n`nREINTENTO OBLIGATORIO: ejecuta la tarea ahora, no pidas más datos intermedios."
        $res = Invoke-VertexPrompt $retryPrompt $settings $opts $cfg
      }
      if ($res.resume) { $cfg.lastVertexConvId = $res.resume }
    } else {
      $res = Invoke-CopilotPrompt $effectivePrompt $settings $opts
      if (($res.code -eq 0) -and (Is-NonOperationalCopilotReply $res.text)) {
        $retryPrompt = $effectivePrompt + "`n`nREINTENTO OBLIGATORIO: ejecuta la tarea ahora, no pidas más datos intermedios."
        $res = Invoke-CopilotPrompt $retryPrompt $settings $opts
      }
      if ($res.resume) { $cfg.lastResume = $res.resume }
    }
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
    $cp = Get-CopilotCmd
    $cpArgs = @()
    if ($settings.dir) { $cpArgs += @('-C', $settings.dir) }
    if ($settings.model) { $cpArgs += @('--model', $settings.model) }
    if ($opts.resume) { $cpArgs += @('--resume', $opts.resume) }
    if ($settings.mode -eq 'trusted') { $cpArgs += '--allow-all-tools' } else { $cpArgs += @('--allow-tool', 'view,glob,rg') }
    & $cp @cpArgs
    exit $LASTEXITCODE
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
    $cp = Get-CopilotCmd
    $cpArgs = @('--resume', $id)
    & $cp @cpArgs
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
    $cp = Get-CopilotCmd
    if ($sub -eq 'login') { & $cp 'login'; exit $LASTEXITCODE }
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
    Write-Host "=== ask-cli doctor ==="
    try { $cp = Get-CopilotCmd; Write-Host ("copilot: OK (" + $cp + ")") } catch { Write-Host "copilot: FAIL"; exit 1 }
    try {
      $state = Invoke-RestMethod -Uri 'http://127.0.0.1:8717/api/state' -TimeoutSec 5
      Write-Host ("hanstlers: OK model=" + $state.model)
    } catch { Write-Host "hanstlers: WARN (no responde en :8717)" }
    Write-Host ("config: " + $ConfigPath)
    Write-Host ("history: " + $HistoryPath)
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
      $cfg[$k] = $v
      Save-Config $cfg
      Write-Host ("OK " + $k + "=" + $v)
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
