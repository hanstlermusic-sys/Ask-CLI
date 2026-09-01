# Prueba end-to-end de los gates en la ruta vertex.
# Levanta un servidor falso que imita el formato de stream de HanstlerS y
# comprueba que ask-cli reconstruye la evidencia y NO declara verificado lo que
# no lo esta. No necesita credenciales ni HanstlerS real.
$ErrorActionPreference = 'Stop'
$port = 8791
$askCli = Join-Path (Split-Path -Parent $PSScriptRoot) 'ask-cli.cmd'

# Escenario que decide el servidor falso segun lo que pida el cliente.
$server = {
    param($port)
    $ell = [char]0x2026
    $chk = [char]0x2713
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://127.0.0.1:$port/")
    $listener.Start()
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $body = (New-Object System.IO.StreamReader($ctx.Request.InputStream)).ReadToEnd()
        $res = $ctx.Response
        $res.ContentType = 'text/event-stream'
        $sw = New-Object System.IO.StreamWriter($res.OutputStream)
        if ($body -match 'DETENER') { $listener.Stop(); $sw.Dispose(); break }

        if ($body -match 'ESCENARIO_MIENTE') {
            # Afirma haber escrito, pero no ejecuta ninguna herramienta.
            $texto = 'Listo, ya cree el archivo config.json con todo lo pedido.'
        } elseif ($body -match 'ESCENARIO_BUCLE') {
            $l = "search_in_files(TODO) $ell $chk 0 resultados"
            $texto = "$l`n$l`n$l`nNo encontre nada."
        } else {
            $texto = "write_file(config.json) $ell $chk post-check ok`nHecho."
        }
        $sw.Write("event: chunk`ndata: " + ($texto | ConvertTo-Json -Compress) + "`n`n")
        $sw.Write("event: done`ndata: {""code"":0}`n`n")
        $sw.Flush(); $sw.Dispose(); $res.Close()
    }
    $listener.Close()
}

$job = Start-Job -ScriptBlock $server -ArgumentList $port
Start-Sleep -Seconds 3

# Apunta ask-cli al servidor falso usando su propio escritor de config: escribir
# el JSON a mano con Set-Content -Encoding UTF8 mete BOM en PowerShell 5.1, el
# parseo falla en silencio y la corrida acaba pegando al HanstlerS real.
$cfgPath = Join-Path $env:USERPROFILE '.ask-cli\config.json'
$urlPrevia = 'http://127.0.0.1:8717'
if (Test-Path $cfgPath) {
    $prev = ((Get-Content $cfgPath -Raw) | ConvertFrom-Json).hanstlersUrl
    if ($prev) { $urlPrevia = $prev }
}
& $askCli config set hanstlersUrl "http://127.0.0.1:$port" | Out-Null

# Salvaguarda: si la config no quedo aplicada, abortar antes de lanzar nada
# contra el HanstlerS real (que ejecutaria herramientas de verdad en el disco).
$urlActiva = ((Get-Content $cfgPath -Raw) | ConvertFrom-Json).hanstlersUrl
if ($urlActiva -ne "http://127.0.0.1:$port") {
    throw "ABORTADO: hanstlersUrl quedo en '$urlActiva'; la prueba habria golpeado el servidor real."
}

# --no-retry aisla el veredicto del primer intento: sin el, el reintento
# volveria a preguntar y enmascararia el fallo de verificacion.
function Invoke-Case([string]$prompt) {
    $out = & $askCli run $prompt --provider vertex --json --no-stream --no-retry 2>&1 | Out-String
    $jsonStart = $out.IndexOf('{')
    if ($jsonStart -lt 0) { throw "sin JSON en la salida: $out" }
    return ($out.Substring($jsonStart) | ConvertFrom-Json)
}

$fail = 0
function Check([string]$name, [bool]$cond, [string]$detail) {
    if ($cond) { Write-Host "  PASS  $name" }
    else { Write-Host "  FAIL  $name -> $detail"; $script:fail++ }
}

try {
    Write-Host "`n--- la ruta vertex ya reconstruye la evidencia ---"
    $r = Invoke-Case 'crea el archivo config.json'
    Check 'registra la herramienta ejecutada' (@($r.tools).Count -ge 1) "tools=$(@($r.tools).Count)"
    Check 'marca verificado cuando hay evidencia' ($r.verified -eq $true) "verified=$($r.verified)"

    Write-Host "`n--- ya no se declara verificado sin comprobar ---"
    $r2 = Invoke-Case 'ESCENARIO_MIENTE crea el archivo config.json'
    Check 'detecta que afirma escribir sin evidencia' ($r2.verified -eq $false) "verified=$($r2.verified)"
    Check 'explica el motivo' (($r2.issues -join ' ') -match 'afirma haber creado') "issues=$($r2.issues -join '|')"

    Write-Host "`n--- detecta el bucle improductivo ---"
    $r3 = Invoke-Case 'ESCENARIO_BUCLE busca los TODO del proyecto'
    Check 'marca el bucle' (($r3.issues -join ' ') -match 'Bucle improductivo') "issues=$($r3.issues -join '|')"
}
finally {
    try { Invoke-RestMethod -Uri "http://127.0.0.1:$port/" -Method Post -Body 'DETENER' -TimeoutSec 5 | Out-Null } catch {}
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    if ($null -ne $askCli) { & $askCli config set hanstlersUrl $urlPrevia | Out-Null }
}

Write-Host ""
if ($fail -gt 0) { Write-Host "=== $fail COMPROBACIONES FALLARON ==="; exit 1 }
Write-Host '=== TODO OK ==='
exit 0
