#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $env:ASKCLI_NO_MAIN = '1'
    $script:ScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'ask-cli.ps1'
    . $script:ScriptPath
}

AfterAll {
    Remove-Item Env:\ASKCLI_NO_MAIN -ErrorAction SilentlyContinue
}

Describe 'Sintaxis del script' {
    It 'parsea sin errores' {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$errs) | Out-Null
        $errs | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-BoolValue' {
    It 'reconoce <value> como <expected>' -TestCases @(
        @{ value = $true;    expected = $true }
        @{ value = 'true';   expected = $true }
        @{ value = 'on';     expected = $true }
        @{ value = '1';      expected = $true }
        @{ value = 'si';     expected = $true }
        @{ value = 'false';  expected = $false }
        @{ value = 'off';    expected = $false }
        @{ value = '0';      expected = $false }
    ) {
        param($value, $expected)
        ConvertTo-BoolValue $value (-not $expected) | Should -Be $expected
    }

    It 'usa el fallback ante valores desconocidos' {
        ConvertTo-BoolValue 'quizas' $true | Should -BeTrue
        ConvertTo-BoolValue $null $false | Should -BeFalse
    }
}

Describe 'ConvertTo-IntValue' {
    It 'convierte numeros validos' {
        ConvertTo-IntValue '42' 0 | Should -Be 42
        ConvertTo-IntValue 7 0 | Should -Be 7
    }
    It 'usa el fallback ante basura' {
        ConvertTo-IntValue 'abc' 180 | Should -Be 180
        ConvertTo-IntValue $null 5 | Should -Be 5
    }
}

Describe 'Default-Config' {
    It 'expone todas las claves documentadas' {
        $cfg = Default-Config
        foreach ($k in @('provider','model','vertexModel','mode','dir','output','lastResume',
                         'lastVertexConvId','copilotPath','allowTools','timeoutSec','historyMax','retry')) {
            $cfg.ContainsKey($k) | Should -BeTrue -Because "falta la clave $k"
        }
    }
    It 'mantiene tipos nativos en numeros y booleanos' {
        $cfg = Default-Config
        $cfg.timeoutSec | Should -BeOfType [int]
        $cfg.historyMax | Should -BeOfType [int]
        $cfg.retry | Should -BeOfType [bool]
    }
}

Describe 'Parse-Options' {
    It 'separa prompt de flags conocidos' {
        $o = Parse-Options @('--model', 'gpt-5', 'hola', 'mundo')
        $o.model | Should -Be 'gpt-5'
        ($o.prompt -join ' ') | Should -Be 'hola mundo'
        $o.passthrough.Count | Should -Be 0
    }

    It 'reenvia flags desconocidos con su valor a passthrough' {
        $o = Parse-Options @('--mcp-server', 'github', 'analiza')
        $o.passthrough | Should -Be @('--mcp-server', 'github')
        ($o.prompt -join ' ') | Should -Be 'analiza'
    }

    It 'reenvia flags desconocidos sin valor' {
        $o = Parse-Options @('--banner', '--json', 'x')
        $o.passthrough | Should -Be @('--banner')
        $o.output | Should -Be 'json'
    }

    It 'trata todo lo que sigue a -- como prompt literal' {
        $o = Parse-Options @('--quiet', '--', '--model', 'no-soy-flag')
        $o.quiet | Should -BeTrue
        ($o.prompt -join ' ') | Should -Be '--model no-soy-flag'
        $o.passthrough.Count | Should -Be 0
    }

    It 'acumula --attach y --add-dir' {
        $o = Parse-Options @('--attach', 'a.txt', '--attach', 'b.txt', '--add-dir', 'C:\x')
        $o.attachments.Count | Should -Be 2
        $o.addDirs | Should -Be @('C:\x')
    }

    It 'soporta --verbose, --no-retry y --timeout' {
        $o = Parse-Options @('--verbose', '--no-retry', '--timeout', '30')
        $o.verbose | Should -BeTrue
        $o.retry | Should -BeFalse
        $o.timeoutSec | Should -Be 30
    }

    It 'tiene retry activo por defecto' {
        (Parse-Options @('x')).retry | Should -BeTrue
    }
}

Describe 'Resolve-Settings' {
    BeforeAll {
        # Aisla los perfiles: sin perfil activo, el resultado depende solo de cfg + opts.
        Mock Get-ActiveProfile { return $null }
    }

    It 'prioriza las opciones sobre la configuracion' {
        $cfg = Default-Config
        $cfg.model = 'auto'
        $o = Parse-Options @('--model', 'gpt-5', '--mode', 'safe')
        $s = Resolve-Settings $cfg $o
        $s.model | Should -Be 'gpt-5'
        $s.mode | Should -Be 'safe'
    }

    It 'cae al default de allowTools cuando esta vacio' {
        $cfg = Default-Config
        $cfg.allowTools = ''
        $s = Resolve-Settings $cfg (Parse-Options @('x'))
        $s.allowTools | Should -Be 'view,glob,rg'
    }

    It 'toma allowTools de las opciones' {
        $s = Resolve-Settings (Default-Config) (Parse-Options @('--allow-tool', 'view'))
        $s.allowTools | Should -Be 'view'
    }

    It 'normaliza timeoutSec invalido a 180' {
        $cfg = Default-Config
        $cfg.timeoutSec = 0
        (Resolve-Settings $cfg (Parse-Options @('x'))).timeoutSec | Should -Be 180
    }

    It 'respeta --timeout' {
        (Resolve-Settings (Default-Config) (Parse-Options @('--timeout', '45'))).timeoutSec | Should -Be 45
    }
}

Describe 'Is-NonOperationalCopilotReply' {
    It 'marca respuestas vacias' {
        Is-NonOperationalCopilotReply '' | Should -BeTrue
        Is-NonOperationalCopilotReply "   `n " | Should -BeTrue
    }

    It 'marca acuses de recibo cortos' {
        Is-NonOperationalCopilotReply 'Listo, entendido.' | Should -BeTrue
        Is-NonOperationalCopilotReply 'Que necesitas?' | Should -BeTrue
    }

    It 'no reintenta ante respuestas largas aunque empiecen igual' {
        $largo = 'Listo, entendido. ' + ('detalle real del analisis. ' * 30)
        $largo.Length | Should -BeGreaterThan 400
        Is-NonOperationalCopilotReply $largo | Should -BeFalse
    }

    It 'no marca trabajo real' {
        Is-NonOperationalCopilotReply 'Encontre 3 archivos modificados: a.ps1, b.ps1, c.ps1' | Should -BeFalse
    }
}

Describe 'Filtros de salida' {
    It 'NoiseRegex descarta ruido de PowerShell/Node' -TestCases @(
        @{ line = 'node.exe : algo' }
        @{ line = '    + CategoryInfo          : NotSpecified' }
        @{ line = '    + FullyQualifiedErrorId : NativeCommandError' }
        @{ line = '~~~~~~~~~~~~~~~' }
        @{ line = 'System.Management.Automation.RemoteException' }
    ) {
        param($line)
        $script:NoiseRegex.IsMatch($line) | Should -BeTrue
    }

    It 'NoiseRegex respeta la salida normal' {
        $script:NoiseRegex.IsMatch('Encontre 3 coincidencias en src/') | Should -BeFalse
    }

    It 'NoiseRegex descarta la traza de error nativo de PowerShell' -TestCases @(
        @{ line = 'At line:6 char:1' }
        @{ line = 'C:\WINDOWS\system32\cmd.exe : ' }
        @{ line = 'C:\Program Files\nodejs\node.exe : algo' }
        @{ line = '+ & node $js --allow-all-tools' }
    ) {
        param($line)
        $script:NoiseRegex.IsMatch($line) | Should -BeTrue
    }

    It 'TelemetryRegex identifica telemetria (visible con --verbose)' -TestCases @(
        @{ line = 'Changes +12 -3' }
        @{ line = 'AI Credits 1.2' }
        @{ line = 'Tokens 4321' }
    ) {
        param($line)
        $script:TelemetryRegex.IsMatch($line) | Should -BeTrue
    }

    It 'TelemetryRegex no es ruido' {
        $script:TelemetryRegex.IsMatch('Tokenizador actualizado') | Should -BeFalse
    }

    It 'ResumeRegex extrae el id de sesion' {
        $m = $script:ResumeRegex.Match('Resume copilot --resume=a1b2c3d4-e5f6')
        $m.Success | Should -BeTrue
        $m.Groups[1].Value | Should -Be 'a1b2c3d4-e5f6'
    }
}

Describe 'Build-ExecutionFirstPrompt' {
    It 'antepone el guard e incluye la tarea (guard=always)' {
        $p = Build-ExecutionFirstPrompt 'listar archivos' @{ guard = 'always' }
        $p | Should -Match 'INSTRUCCION OPERATIVA'
        $p | Should -Match 'TAREA:'
        $p | Should -Match 'listar archivos'
    }

    It 'guard=off devuelve el prompt intacto' {
        Build-ExecutionFirstPrompt 'listar archivos' @{ guard = 'off' } | Should -Be 'listar archivos'
    }

    It 'guard=auto omite el guard si AGENTS.md ya lo contiene' {
        $dir = Join-Path $TestDrive ('guard-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        Write-Utf8NoBom (Join-Path $dir 'AGENTS.md') ("# x`n" + $script:GuardMarker + "`nreglas`n" + $script:GuardMarker)
        Build-ExecutionFirstPrompt 'listar archivos' @{ guard = 'auto'; dir = $dir } | Should -Be 'listar archivos'
    }

    It 'guard=auto antepone el guard si no hay AGENTS.md marcado' {
        $dir = Join-Path $TestDrive ('noguard-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        Build-ExecutionFirstPrompt 'listar archivos' @{ guard = 'auto'; dir = $dir } | Should -Match 'INSTRUCCION OPERATIVA'
    }
}

Describe 'Encoding del script' {
    # PowerShell 5.1 interpreta un .ps1 sin BOM como ANSI: los acentos dentro de
    # ClaimedWriteRegex/NoiseRegex se corrompen y los gates dejan de matchear.
    It 'ask-cli.ps1 tiene BOM UTF-8' {
        $b = [System.IO.File]::ReadAllBytes($script:ScriptPath)
        @($b[0], $b[1], $b[2]) | Should -Be @(239, 187, 191)
    }

    It 'los acentos sobreviven a la carga en runtime' {
        $script:ClaimedWriteRegex.IsMatch('Ya creé el archivo') | Should -BeTrue
        $script:ClaimedWriteRegex.IsMatch('Lo modifiqué correctamente') | Should -BeTrue
        $script:ClaimedWriteRegex.IsMatch('Añadí la sección') | Should -BeTrue
        $script:NoiseRegex.IsMatch('En línea:12 carácter:5') | Should -BeTrue
    }
}

Describe 'Build-PermissionArgs' {
    # --allow-tool solo pre-aprueba; sin --available-tools el modelo puede invocar
    # cualquier herramienta (verificado: --allow-tool=glob ejecutaba powershell).
    It 'modo safe restringe el catalogo con --available-tools' {
        $a = Build-PermissionArgs @{ mode = 'safe'; allowTools = 'view,glob'; denyTools = '' }
        $a | Should -Contain '--available-tools=view,glob'
        $a | Should -Contain '--allow-tool=view,glob'
        $a | Should -Not -Contain '--allow-all-tools'
    }

    It 'modo safe cae al default cuando allowTools esta vacio' {
        $a = Build-PermissionArgs @{ mode = 'safe'; allowTools = ''; denyTools = '' }
        $a | Should -Contain '--available-tools=view,glob,rg'
    }

    It 'modo trusted permite todo' {
        $a = Build-PermissionArgs @{ mode = 'trusted'; allowTools = 'view'; denyTools = '' }
        $a | Should -Contain '--allow-all-tools'
        ($a -join ' ') | Should -Not -Match 'available-tools'
    }

    It 'aplica --deny-tool tambien en modo trusted' {
        $a = Build-PermissionArgs @{ mode = 'trusted'; allowTools = ''; denyTools = 'shell(git push)' }
        $a | Should -Contain '--allow-all-tools'
        $a | Should -Contain '--deny-tool=shell(git push)'
    }

    # --allow-all-tools tiene precedencia sobre --deny-tool (verificado: deny-tool=powershell
    # no impidio la ejecucion). Solo --excluded-tools saca la herramienta del catalogo.
    It 'acompana toda denegacion con --excluded-tools' {
        $a = Build-PermissionArgs @{ mode = 'trusted'; allowTools = ''; denyTools = 'powershell' }
        $a | Should -Contain '--excluded-tools=powershell'
    }

    It 'excluye tambien en modo safe' {
        $a = Build-PermissionArgs @{ mode = 'safe'; allowTools = 'view'; denyTools = 'write' }
        $a | Should -Contain '--excluded-tools=write'
    }

    It 'omite --deny-tool cuando no hay denegaciones' {
        ((Build-PermissionArgs @{ mode = 'safe'; allowTools = 'view'; denyTools = '' }) -join ' ') | Should -Not -Match 'deny-tool'
    }

    It 'usa la forma = (los flags tienen valor opcional en Copilot CLI)' {
        foreach ($f in (Build-PermissionArgs @{ mode = 'safe'; allowTools = 'view'; denyTools = 'write' })) {
            if ($f -ne '--allow-all-tools') { $f | Should -Match '=' }
        }
    }
}

Describe 'Write-Notice (integridad de stdout)' {
    # Un aviso impreso en stdout durante --json rompe ConvertFrom-Json en el consumidor.
    It 'desvia a stderr cuando la salida es JSON' {
        $out = Write-Notice 'aviso' @{ output = 'json' } 6>&1
        $out | Should -BeNullOrEmpty
    }

    It 'usa el host cuando la salida es texto' {
        $out = Write-Notice 'aviso' @{ output = 'text' } 6>&1
        ($out | Out-String) | Should -Match 'aviso'
    }

    It 'tolera settings nulo' {
        { Write-Notice 'aviso' $null 6>&1 | Out-Null } | Should -Not -Throw
    }
}

Describe 'ConvertTo-ToolList' {
    It 'normaliza espacios y deduplica' {
        ConvertTo-ToolList @('view, glob', 'glob,rg') | Should -Be 'view,glob,rg'
    }
    It 'ignora entradas vacias' {
        ConvertTo-ToolList @('', 'view', $null, ' , ') | Should -Be 'view'
    }
    It 'tolera null' {
        ConvertTo-ToolList $null | Should -Be ''
    }
    It 'preserva la sintaxis granular de Copilot CLI' {
        ConvertTo-ToolList 'shell(git push)' | Should -Be 'shell(git push)'
    }
}

Describe 'Resolve-Settings (denegaciones)' {
    It 'acumula denyTools de config y CLI en vez de sobrescribir' {
        $cfg = Default-Config
        $cfg.mode = 'safe'; $cfg.allowTools = 'view'; $cfg.denyTools = 'shell'
        $opts = Parse-Options @('--deny-tool', 'write')
        (Resolve-Settings $cfg $opts).denyTools | Should -Be 'shell,write'
    }

    It 'acumula multiples --deny-tool en la misma linea' {
        $opts = Parse-Options @('--deny-tool', 'write', '--deny-tool', 'shell')
        $opts.denyTools | Should -Be 'write,shell'
    }
}

Describe 'Get-Prop' {
    It 'devuelve el valor cuando existe' {
        $o = '{"a":{"b":42}}' | ConvertFrom-Json
        (Get-Prop (Get-Prop $o 'a') 'b') | Should -Be 42
    }

    It 'devuelve null en propiedad inexistente bajo StrictMode' {
        $o = '{"a":1}' | ConvertFrom-Json
        Get-Prop $o 'noexiste' | Should -BeNullOrEmpty
    }

    It 'tolera entrada nula' {
        Get-Prop $null 'x' | Should -BeNullOrEmpty
    }
}

Describe 'Get-ToolSummary' {
    It 'extrae el argumento representativo' -TestCases @(
        @{ json = '{"arguments":{"command":"git status"}}'; expected = 'git status' }
        @{ json = '{"arguments":{"path":"C:\\tmp\\a.txt"}}'; expected = 'C:\tmp\a.txt' }
        @{ json = '{"arguments":{"pattern":"foo.*bar"}}'; expected = 'foo.*bar' }
    ) {
        param($json, $expected)
        Get-ToolSummary ($json | ConvertFrom-Json) | Should -Be $expected
    }

    It 'colapsa espacios y trunca a 90 chars' {
        $long = 'x' * 200
        $s = Get-ToolSummary (("{`"arguments`":{`"command`":`"$long`"}}") | ConvertFrom-Json)
        $s.Length | Should -Be 93
        $s | Should -Match '\.\.\.$'
    }

    It 'devuelve vacio sin argumentos' {
        Get-ToolSummary ('{}' | ConvertFrom-Json) | Should -Be ''
    }
}

Describe 'Test-IsActionableTask' {
    It 'detecta tareas accionables' -TestCases @(
        @{ p = 'lista los archivos del repo' }
        @{ p = 'crea un script de build' }
        @{ p = 'revisa el codigo de auth.ps1' }
        @{ p = 'ejecuta los tests' }
        @{ p = 'corrige el bug del parser' }
        @{ p = 'list the files in this repo' }
        @{ p = 'run the test suite' }
    ) {
        param($p)
        Test-IsActionableTask $p | Should -BeTrue
    }

    It 'no marca preguntas conceptuales' -TestCases @(
        @{ p = 'que diferencia hay entre TCP y UDP' }
        @{ p = 'explicame la teoria de colas' }
    ) {
        param($p)
        Test-IsActionableTask $p | Should -BeFalse
    }
}

Describe 'Test-HasWriteTool' {
    It 'detecta herramientas de escritura y shells' -TestCases @(
        @{ n = 'create' }
        @{ n = 'edit' }
        @{ n = 'str_replace' }
        @{ n = 'write_file' }
        @{ n = 'bash' }
        @{ n = 'powershell' }
    ) {
        param($n)
        Test-HasWriteTool @(@{ name = $n }) | Should -BeTrue
    }

    It 'no marca herramientas de solo lectura' {
        Test-HasWriteTool @(@{ name = 'view' }, @{ name = 'glob' }) | Should -BeFalse
    }
}

Describe 'Test-ResponseVerification' {
    BeforeAll {
        function New-Res([hashtable]$o) {
            $base = @{ code = 0; text = 'ok'; toolCalls = @(); toolFailed = 0; filesModified = @() }
            foreach ($k in $o.Keys) { $base[$k] = $o[$k] }
            return $base
        }
    }

    It 'aprueba tarea accionable con herramientas ejecutadas' {
        $r = New-Res @{ toolCalls = @(@{ name = 'view'; success = $true }) }
        (Test-ResponseVerification $r 'lista los archivos').ok | Should -BeTrue
    }

    It 'GATE 1: rechaza tarea accionable sin ninguna herramienta' {
        $r = New-Res @{ text = 'Ya revise los archivos y todo esta bien.' }
        $v = Test-ResponseVerification $r 'revisa los archivos del repo'
        $v.ok | Should -BeFalse
        ($v.issues -join ' ') | Should -Match 'ninguna herramienta'
    }

    It 'aprueba pregunta conceptual sin herramientas' {
        (Test-ResponseVerification (New-Res @{}) 'que es la teoria de colas').ok | Should -BeTrue
    }

    It 'GATE 2: rechaza si afirma escribir sin write-tool ni filesModified' {
        $r = New-Res @{ text = 'He creado el archivo config.json con la configuracion.'; toolCalls = @(@{ name = 'view'; success = $true }) }
        $v = Test-ResponseVerification $r 'crea config.json'
        $v.ok | Should -BeFalse
        ($v.issues -join ' ') | Should -Match 'escritura registrada'
    }

    It 'GATE 2 no dispara si hubo write-tool' {
        $r = New-Res @{ text = 'He creado el archivo config.json.'; toolCalls = @(@{ name = 'create'; success = $true }) }
        (Test-ResponseVerification $r 'crea config.json').ok | Should -BeTrue
    }

    It 'GATE 2 no dispara si Copilot reporta filesModified' {
        $r = New-Res @{ text = 'He creado el archivo.'; toolCalls = @(@{ name = 'bash'; success = $true }); filesModified = @('a.txt') }
        (Test-ResponseVerification $r 'crea a.txt').ok | Should -BeTrue
    }

    It 'GATE 3: rechaza si todas las herramientas fallaron' {
        $r = New-Res @{ toolCalls = @(@{ name = 'view'; success = $false }, @{ name = 'glob'; success = $false }); toolFailed = 2 }
        $v = Test-ResponseVerification $r 'lista archivos'
        $v.ok | Should -BeFalse
        ($v.issues -join ' ') | Should -Match 'fallaron'
    }

    It 'acepta fallo parcial' {
        $r = New-Res @{ toolCalls = @(@{ name = 'view'; success = $false }, @{ name = 'glob'; success = $true }); toolFailed = 1 }
        (Test-ResponseVerification $r 'lista archivos').ok | Should -BeTrue
    }

    It 'rechaza respuesta vacia sin ejecucion' {
        (Test-ResponseVerification (New-Res @{ text = '' }) 'hola').ok | Should -BeFalse
    }
}

Describe 'Build-VerificationFeedback' {
    It 'incluye la evidencia real y los problemas detectados' {
        $r = @{ code = 0; text = 'listo'; toolCalls = @(@{ name = 'view'; success = $false }); toolFailed = 1; filesModified = @() }
        $v = Test-ResponseVerification $r 'crea y edita el archivo x'
        $fb = Build-VerificationFeedback $v $r
        $fb | Should -Match 'VERIFICACION FALLIDA'
        $fb | Should -Match 'Herramientas ejecutadas: 1'
        $fb | Should -Match 'view -> FALLO'
        $fb | Should -Match 'Archivos modificados: ninguno'
        $fb | Should -Match 'No describas lo que harias'
    }
}

Describe 'Invoke-AskPrompt (cableado de verificacion y reintento)' {
    BeforeAll {
        $script:Settings = @{ provider = 'copilot'; dir = ''; guard = 'off'; model = ''; mode = 'safe'; allowTools = 'view'; output = 'text' }
        $script:Opts = @{ retry = $true; verify = $true; quiet = $true; resume = ''; noStream = $true }
        function New-CopRes([hashtable]$o) {
            $base = @{ code = 0; text = 'ok'; resume = 'sess-1'; toolCalls = [System.Collections.Generic.List[object]]::new(); toolFailed = 0; filesModified = @(); usage = @{}; streamed = $false }
            foreach ($k in $o.Keys) { $base[$k] = $o[$k] }
            return $base
        }
    }

    It 'no reintenta cuando la verificacion pasa' {
        $script:calls = 0
        Mock Invoke-CopilotPrompt {
            $script:calls++
            $l = [System.Collections.Generic.List[object]]::new(); $l.Add(@{ name = 'view'; success = $true })
            New-CopRes @{ toolCalls = $l }
        }
        $r = Invoke-AskPrompt 'lista los archivos' $script:Settings $script:Opts @{ retry = $true; verify = $true }
        $script:calls | Should -Be 1
        $r.verified | Should -BeTrue
    }

    It 'reintenta sobre la MISMA sesion cuando falla el gate' {
        $script:calls = 0
        $script:resumeUsed = $null
        Mock Invoke-CopilotPrompt {
            param($p, $s, $o, $sessionId, $resumeId)
            $script:calls++
            if ($script:calls -eq 1) { return New-CopRes @{ text = 'Ya revise todo, esta bien.' } }
            $script:resumeUsed = $resumeId
            $l = [System.Collections.Generic.List[object]]::new(); $l.Add(@{ name = 'powershell'; success = $true })
            return New-CopRes @{ text = 'Hay 3 archivos.'; toolCalls = $l }
        }
        $r = Invoke-AskPrompt 'revisa los archivos del repo' $script:Settings $script:Opts @{ retry = $true; verify = $true }
        $script:calls | Should -Be 2
        # Critico: el reintento reusa la sesion (prompt cache) en vez de arrancar una nueva.
        $script:resumeUsed | Should -Be 'sess-1'
        $r.verified | Should -BeTrue
    }

    It 'acumula la evidencia de ambos turnos tras el reintento' {
        $script:calls = 0
        Mock Invoke-CopilotPrompt {
            $script:calls++
            $l = [System.Collections.Generic.List[object]]::new()
            if ($script:calls -eq 1) { $l.Add(@{ name = 'view'; success = $false }); return New-CopRes @{ toolCalls = $l; toolFailed = 1 } }
            $l.Add(@{ name = 'glob'; success = $true }); return New-CopRes @{ toolCalls = $l }
        }
        $r = Invoke-AskPrompt 'lista los archivos' $script:Settings $script:Opts @{ retry = $true; verify = $true }
        @($r.toolCalls).Count | Should -Be 2
    }

    It '--no-verify desactiva el gate y no reintenta' {
        $script:calls = 0
        Mock Invoke-CopilotPrompt { $script:calls++; New-CopRes @{ text = 'Ya revise todo.' } }
        $o = $script:Opts.Clone(); $o.verify = $false
        $r = Invoke-AskPrompt 'revisa los archivos' $script:Settings $o @{ retry = $true; verify = $true }
        $script:calls | Should -Be 1
        $r.verified | Should -BeTrue
    }

    It 'marca verified=false si el reintento tampoco ejecuta nada' {
        Mock Invoke-CopilotPrompt { New-CopRes @{ text = 'Ya revise todo.' } }
        $r = Invoke-AskPrompt 'revisa los archivos' $script:Settings $script:Opts @{ retry = $true; verify = $true }
        $r.verified | Should -BeFalse
        Get-AskExitCode $r | Should -Be 3
    }

    It 'no reintenta si retry esta desactivado, pero sigue reportando el fallo' {
        $script:calls = 0
        Mock Invoke-CopilotPrompt { $script:calls++; New-CopRes @{ text = 'Ya revise todo.' } }
        $o = $script:Opts.Clone(); $o.retry = $false
        $r = Invoke-AskPrompt 'revisa los archivos' $script:Settings $o @{ retry = $true; verify = $true }
        $script:calls | Should -Be 1
        $r.verified | Should -BeFalse
    }
}

Describe 'Get-AskExitCode' {
    It 'propaga el exit code del provider' {
        Get-AskExitCode @{ code = 2; verified = $true } | Should -Be 2
    }
    It 'devuelve 3 cuando la verificacion falla' {
        Get-AskExitCode @{ code = 0; verified = $false } | Should -Be $script:ExitVerificationFailed
    }
    It 'devuelve 0 en exito verificado' {
        Get-AskExitCode @{ code = 0; verified = $true } | Should -Be 0
    }
}

Describe 'ConvertTo-SingleLinePrompt' {
    It 'aplana saltos de linea para el shim cmd.exe' {
        $p = Build-ExecutionFirstPrompt 'listar archivos' @{ guard = 'always' }
        $flat = ConvertTo-SingleLinePrompt $p
        $flat | Should -Not -Match "`n"
        $flat | Should -Match 'INSTRUCCION OPERATIVA'
        # Lo critico: la tarea sobrevive al aplanado (antes se perdia entera).
        $flat | Should -Match 'listar archivos'
    }

    It 'normaliza CRLF y colapsa saltos consecutivos' {
        ConvertTo-SingleLinePrompt "a`r`n`r`nb" | Should -Be 'a | b'
    }

    It 'no altera texto de una sola linea' {
        ConvertTo-SingleLinePrompt 'hola mundo' | Should -Be 'hola mundo'
    }
}

Describe 'Get-CopilotInvoker' {
    It 'usa node directo cuando existe npm-loader.js' {
        Mock Get-CopilotCmd { return 'C:\npm\copilot.cmd' }
        Mock Test-Path { return $true }
        $script:Invoker = $null
        $inv = Get-CopilotInvoker
        $inv.multiline | Should -BeTrue
        $inv.exe | Should -Be 'C:\npm\node.exe'
        $inv.prefix[0] | Should -Match 'npm-loader\.js$'
        $script:Invoker = $null
    }

    It 'cae al shim .cmd cuando no encuentra el entrypoint' {
        Mock Get-CopilotCmd { return 'C:\npm\copilot.cmd' }
        Mock Test-Path { return $false }
        Mock Get-Command { return $null }
        $script:Invoker = $null
        $inv = Get-CopilotInvoker
        $inv.multiline | Should -BeFalse
        $inv.exe | Should -Be 'C:\npm\copilot.cmd'
        $inv.prefix.Count | Should -Be 0
        $script:Invoker = $null
    }
}

Describe 'Write-Utf8NoBom' {    It 'escribe sin BOM' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("askcli-" + [Guid]::NewGuid().ToString() + ".json")
        try {
            Write-Utf8NoBom $tmp '{"a":1}'
            $bytes = [System.IO.File]::ReadAllBytes($tmp)
            $bytes[0] | Should -Be 0x7B  # '{'
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-ActiveProfileRecord' {
    It 'elige el perfil mas especifico del arbol' {
        Mock Load-Profiles {
            return @{
                'C:\repos'          = @{ dir = 'C:\repos'; model = 'padre' }
                'C:\repos\proyecto' = @{ dir = 'C:\repos\proyecto'; model = 'hijo' }
            }
        }
        $rec = Get-ActiveProfileRecord (Default-Config) 'C:\repos\proyecto\src'
        $rec | Should -Not -BeNullOrEmpty
        $rec.profile.model | Should -Be 'hijo'
    }

    It 'no confunde directorios con prefijo comun' {
        Mock Load-Profiles { return @{ 'C:\repos\app' = @{ dir = 'C:\repos\app' } } }
        Get-ActiveProfileRecord (Default-Config) 'C:\repos\app-otro' | Should -BeNullOrEmpty
    }
}

Describe 'Rendimiento del filtrado' {
    It 'filtra 20k lineas en menos de 1 segundo' {
        $lines = 1..20000 | ForEach-Object { "linea de salida normal $_" }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $kept = [System.Collections.Generic.List[string]]::new()
        foreach ($l in $lines) {
            if ($script:NoiseRegex.IsMatch($l)) { continue }
            if ($script:TelemetryRegex.IsMatch($l)) { continue }
            $kept.Add($l)
        }
        $sw.Stop()
        $kept.Count | Should -Be 20000
        $sw.ElapsedMilliseconds | Should -BeLessThan 1000
    }
}

Describe 'v0.5.0 - flags agenticos' {
  It 'no emite flags en modo interactive por defecto' {
    @(Build-AgentArgs @{ agentMode='interactive'; effort=''; assistedApproval=$false; noAskUser=$false; maxContinues=0 }).Count | Should -Be 0
  }
  It 'emite --mode autopilot y max-continues' {
    $a = Build-AgentArgs @{ agentMode='autopilot'; effort='high'; assistedApproval=$false; noAskUser=$false; maxContinues=15 }
    ($a -join ' ') | Should -Be '--mode autopilot --max-autopilot-continues 15 --effort high'
  }
  It 'no emite max-continues fuera de autopilot' {
    (Build-AgentArgs @{ agentMode='plan'; effort=''; assistedApproval=$false; noAskUser=$false; maxContinues=9 }) -join ' ' | Should -Be '--mode plan'
  }
  It 'assisted-approval siempre viaja con --experimental' {
    $a = Build-AgentArgs @{ agentMode='autopilot'; effort=''; assistedApproval=$true; noAskUser=$false; maxContinues=0 }
    $a | Should -Contain '--experimental'
    $a.IndexOf('--experimental') | Should -BeLessThan $a.IndexOf('--assisted-approval')
  }
  It 'emite --no-ask-user' {
    (Build-AgentArgs @{ agentMode='interactive'; effort=''; assistedApproval=$false; noAskUser=$true; maxContinues=0 }) | Should -Contain '--no-ask-user'
  }
}

Describe 'v0.5.0 - parseo de opciones' {
  It '--dev activa autopilot, calidad, trusted y effort high' {
    $o = Parse-Options @('--dev','hola')
    $o.agentMode | Should -Be 'autopilot'
    $o.qualityGate | Should -BeTrue
    $o.mode | Should -Be 'trusted'
    $o.effort | Should -Be 'high'
    $o.maxContinues | Should -Be 15
  }
  It '--dev no pisa un effort explicito previo' {
    (Parse-Options @('--effort','max','--dev','x')).effort | Should -Be 'max'
  }
  It '--autopilot y --plan son atajos' {
    (Parse-Options @('--autopilot','x')).agentMode | Should -Be 'autopilot'
    (Parse-Options @('--plan','x')).agentMode | Should -Be 'plan'
  }
  It '--verify-cmd implica gate de calidad' {
    $o = Parse-Options @('--verify-cmd','npm test','x')
    $o.verifyCommand | Should -Be 'npm test'
    $o.qualityGate | Should -BeTrue
  }
  It '--no-quality desactiva el gate' { (Parse-Options @('--no-quality','x')).quality | Should -BeFalse }
}

Describe 'v0.5.0 - validacion en Resolve-Settings' {
  It 'rechaza effort invalido' {
    { Resolve-Settings (Default-Config) (Parse-Options @('--effort','turbo','x')) } | Should -Throw '*effort invalido*'
  }
  It 'rechaza agent-mode invalido' {
    { Resolve-Settings (Default-Config) (Parse-Options @('--agent-mode','yolo','x')) } | Should -Throw '*agentMode invalido*'
  }
  It 'acepta todos los niveles validos de effort' {
    foreach ($e in @('none','minimal','low','medium','high','xhigh','max')) {
      (Resolve-Settings (Default-Config) (Parse-Options @('--effort',$e,'x'))).effort | Should -Be $e
    }
  }
  It 'la CLI tiene precedencia sobre la config' {
    $c = Default-Config; $c.agentMode = 'plan'
    (Resolve-Settings $c (Parse-Options @('--autopilot','x'))).agentMode | Should -Be 'autopilot'
  }
}

Describe 'v0.5.0 - deteccion de stack' {
  BeforeAll {
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('q-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:tmp | Out-Null
  }
  AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

  It 'un override explicito gana sobre cualquier deteccion' {
    (Get-QualityCommand $script:tmp 'mi-comando').cmd | Should -Be 'mi-comando'
    (Get-QualityCommand $script:tmp 'mi-comando').name | Should -Be 'custom'
  }
  It 'devuelve null sin marcadores' { Get-QualityCommand $script:tmp '' | Should -BeNullOrEmpty }
  It 'detecta node por package.json' {
    $d = Join-Path $script:tmp 'n'; New-Item -ItemType Directory -Path $d | Out-Null
    '{}' | Set-Content (Join-Path $d 'package.json')
    (Get-QualityCommand $d '').name | Should -Be 'node'
  }
  It 'detecta python por pyproject.toml' {
    $d = Join-Path $script:tmp 'py'; New-Item -ItemType Directory -Path $d | Out-Null
    '' | Set-Content (Join-Path $d 'pyproject.toml')
    (Get-QualityCommand $d '').cmd | Should -Be 'python -m pytest -q'
  }
  It 'detecta go por go.mod' {
    $d = Join-Path $script:tmp 'g'; New-Item -ItemType Directory -Path $d | Out-Null
    'module x' | Set-Content (Join-Path $d 'go.mod')
    (Get-QualityCommand $d '').name | Should -Be 'go'
  }
  It 'detecta rust por Cargo.toml' {
    $d = Join-Path $script:tmp 'r'; New-Item -ItemType Directory -Path $d | Out-Null
    '' | Set-Content (Join-Path $d 'Cargo.toml')
    (Get-QualityCommand $d '').name | Should -Be 'rust'
  }
  It 'pester tiene prioridad sobre node en un repo mixto' {
    $d = Join-Path $script:tmp 'mix'; New-Item -ItemType Directory -Path $d | Out-Null
    '{}' | Set-Content (Join-Path $d 'package.json')
    '' | Set-Content (Join-Path $d 'a.Tests.ps1')
    (Get-QualityCommand $d '').name | Should -Be 'pester'
  }
  It 'no revienta con un directorio inexistente' {
    Get-QualityCommand (Join-Path $script:tmp 'no-existe') '' | Should -BeNullOrEmpty
  }
}

Describe 'v0.5.0 - ejecucion del gate de calidad' {
  It 'reporta ok con un comando que sale 0' {
    $g = Invoke-QualityGate (Get-Location).Path 'cmd /c exit 0' 60
    $g.ok | Should -BeTrue
    $g.exitCode | Should -Be 0
  }
  It 'reporta fallo y captura la salida' {
    $g = Invoke-QualityGate (Get-Location).Path 'cmd /c "echo TEST_FALLA_AQUI & exit 7"' 60
    $g.ok | Should -BeFalse
    $g.exitCode | Should -Be 7
    $g.output | Should -Match 'TEST_FALLA_AQUI'
  }
  It 'no altera el directorio de trabajo del proceso actual' {
    $before = (Get-Location).Path
    Invoke-QualityGate $env:TEMP 'cmd /c exit 1' 60 | Out-Null
    (Get-Location).Path | Should -Be $before
  }

  # REGRESION: la primera version usaba Invoke-Expression + $LASTEXITCODE en el
  # proceso actual. $LASTEXITCODE solo lo actualizan los ejecutables nativos, asi
  # que con cmdlets arrastraba el valor de un comando anterior: una suite en rojo
  # se reportaba VERDE. Un gate anti-alucinacion con falsos verdes es peor que no
  # tener gate, asi que se ejecuta en un proceso hijo con exit code real.
  It 'no hereda un $LASTEXITCODE contaminado cuando el comando es un cmdlet' {
    cmd /c exit 7 | Out-Null
    $g = Invoke-QualityGate (Get-Location).Path 'Write-Output "todo bien"' 60
    $g.ok | Should -BeTrue
    $g.exitCode | Should -Be 0
  }
  It 'detecta el fallo de un cmdlet aunque $LASTEXITCODE valga 0' {
    cmd /c exit 0 | Out-Null
    $g = Invoke-QualityGate (Get-Location).Path 'Write-Error "la suite fallo"' 60
    $g.ok | Should -BeFalse
  }
  It 'detecta una excepcion terminante' {
    (Invoke-QualityGate (Get-Location).Path 'throw "boom"' 60).ok | Should -BeFalse
  }
  It 'propaga el exit code exacto de un proceso nativo' {
    (Invoke-QualityGate (Get-Location).Path 'cmd /c exit 3' 60).exitCode | Should -Be 3
  }
  It 'preserva comillas y ampersands en el comando (via -EncodedCommand)' {
    $g = Invoke-QualityGate (Get-Location).Path 'Write-Output "con ""comillas"" dentro"' 60
    $g.ok | Should -BeTrue
    $g = Invoke-QualityGate (Get-Location).Path 'cmd /c "echo a & echo b"' 60
    $g.ok | Should -BeTrue
  }
  It 'aborta y marca timedOut cuando la suite se cuelga' {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $g = Invoke-QualityGate (Get-Location).Path 'Start-Sleep -Seconds 30' 3
    $sw.Stop()
    $g.ok | Should -BeFalse
    $g.timedOut | Should -BeTrue
    $g.exitCode | Should -Be 124
    $sw.Elapsed.TotalSeconds | Should -BeLessThan 15
  }
  It 'no lanza excepcion con un comando inexistente' {
    { Invoke-QualityGate (Get-Location).Path 'comando-que-no-existe-xyz' 60 } | Should -Not -Throw
  }
}

Describe 'v0.5.0 - feedback de calidad' {
  It 'incluye comando, exit y salida real' {
    $f = Build-QualityFeedback @{ command='npm test'; exitCode=1; output='2 failing'; ok=$false }
    $f | Should -Match 'npm test'
    $f | Should -Match '2 failing'
    $f | Should -Match 'VERIFICACION DEL PROYECTO HA FALLADO'
  }
  It 'prohibe explicitamente falsear los tests' {
    Build-QualityFeedback @{ command='x'; exitCode=1; output='y'; ok=$false } | Should -Match 'No modifiques ni desactives los tests'
  }
}

Describe 'v0.5.0 - Get-Prop sobre hashtables' {
  It 'lee claves de hashtable' { Get-Prop @{ a = 42 } 'a' | Should -Be 42 }
  It 'devuelve null en clave ausente sin lanzar' { Get-Prop @{ a = 1 } 'zzz' | Should -BeNullOrEmpty }
  It 'permite que una config antigua sin qualityGate no rompa' {
    ConvertTo-BoolValue (Get-Prop @{ mode = 'trusted' } 'qualityGate') $false | Should -BeFalse
  }
}

Describe 'v0.5.0 - degradacion de --effort en modelos incompatibles' {
  BeforeAll {
    $script:base = @{
      provider='copilot'; model='auto'; mode='trusted'; output='text'; dir=''
      allowTools=''; denyTools=''; timeoutSec=180; agent=''; maxCredits=0; guard='off'
      agentMode='autopilot'; effort='high'; assistedApproval=$false; noAskUser=$false
      maxContinues=0; qualityGate=$false; verifyCommand=''
    }
    $script:opts = @{ resume=''; quiet=$true; verify=$false; retry=$false; quality=$false; attachments=@(); addDirs=@() }
  }

  It 'reintenta sin effort cuando el modelo lo rechaza' {
    $script:calls = New-Object System.Collections.Generic.List[object]
    Mock Invoke-CopilotPrompt {
      $script:calls.Add(@{ effort = $settings.effort })
      if ($settings.effort) {
        return @{ code=1; text=''; resume='s1'; raw='Error: Model "auto" does not support reasoning effort configuration (requested: "high").'
                  toolCalls=(New-Object System.Collections.Generic.List[object]); toolFailed=0; filesModified=@(); usage=@{} }
      }
      return @{ code=0; text='HOLA'; resume='s2'; raw=''
                toolCalls=(New-Object System.Collections.Generic.List[object]); toolFailed=0; filesModified=@(); usage=@{} }
    }
    $r = Invoke-AskPrompt 'di hola' $script:base $script:opts @{ verify=$false; retry=$false }
    $script:calls.Count | Should -Be 2
    $script:calls[0].effort | Should -Be 'high'
    $script:calls[1].effort | Should -BeNullOrEmpty
    $r.code | Should -Be 0
  }

  It 'no degrada ante un fallo por otra causa' {
    $script:calls2 = New-Object System.Collections.Generic.List[object]
    Mock Invoke-CopilotPrompt {
      $script:calls2.Add(1)
      return @{ code=1; text=''; resume='s1'; raw='Error: network unreachable'
                toolCalls=(New-Object System.Collections.Generic.List[object]); toolFailed=0; filesModified=@(); usage=@{} }
    }
    Invoke-AskPrompt 'di hola' $script:base $script:opts @{ verify=$false; retry=$false } | Out-Null
    $script:calls2.Count | Should -Be 1
  }

  It 'no muta el hashtable de settings del llamador' {
    Mock Invoke-CopilotPrompt {
      if ($settings.effort) {
        return @{ code=1; text=''; resume='s1'; raw='does not support reasoning effort'
                  toolCalls=(New-Object System.Collections.Generic.List[object]); toolFailed=0; filesModified=@(); usage=@{} }
      }
      return @{ code=0; text='ok'; resume='s2'; raw=''
                toolCalls=(New-Object System.Collections.Generic.List[object]); toolFailed=0; filesModified=@(); usage=@{} }
    }
    $s = @{} ; foreach ($k in $script:base.Keys) { $s[$k] = $script:base[$k] }
    Invoke-AskPrompt 'di hola' $s $script:opts @{ verify=$false; retry=$false } | Out-Null
    $s.effort | Should -Be 'high'
  }
}


Describe 'v0.5.0 - deteccion inmune a dependencias de terceros' {
  BeforeAll {
    $script:vd = Join-Path ([System.IO.Path]::GetTempPath()) ('vend-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $script:vd 'node_modules\lib\test') -Force | Out-Null
    '{}' | Set-Content (Join-Path $script:vd 'package.json')
    '' | Set-Content (Join-Path $script:vd 'node_modules\lib\test\Vendor.Tests.ps1')
  }
  AfterAll { Remove-Item $script:vd -Recurse -Force -ErrorAction SilentlyContinue }

  # REGRESION: un *.Tests.ps1 dentro de node_modules pertenece a un tercero. La
  # primera version lo detectaba y ejecutaba Pester en un repo Node.
  It 'ignora tests que viven dentro de node_modules' {
    (Get-QualityCommand $script:vd '').name | Should -Be 'node'
  }
  It 'si detecta un test propio fuera de las dependencias' {
    '' | Set-Content (Join-Path $script:vd 'Propio.Tests.ps1')
    (Get-QualityCommand $script:vd '').name | Should -Be 'pester'
    Remove-Item (Join-Path $script:vd 'Propio.Tests.ps1') -Force
  }
  It 'ignora proyectos .NET dentro de directorios de artefactos' {
    $d = Join-Path $script:vd 'net'
    New-Item -ItemType Directory -Path (Join-Path $d 'obj') -Force | Out-Null
    '' | Set-Content (Join-Path $d 'obj\Generado.csproj')
    'module x' | Set-Content (Join-Path $d 'go.mod')
    (Get-QualityCommand $d '').name | Should -Be 'go'
  }
}


Describe 'v0.5.0 - el gate de calidad no borra la evidencia de verificacion' {
  BeforeAll {
    $script:qs = @{
      provider='copilot'; model='auto'; mode='trusted'; output='text'; dir=''
      allowTools=''; denyTools=''; timeoutSec=60; agent=''; maxCredits=0; guard='off'
      agentMode='autopilot'; effort=''; assistedApproval=$false; noAskUser=$false
      maxContinues=0; qualityGate=$true; verifyCommand='cmd /c exit 0'
    }
    $script:qo = @{ resume=''; quiet=$true; verify=$true; retry=$true; quality=$true; attachments=@(); addDirs=@() }
  }

  # REGRESION: el reintento del gate asignaba verified=$true e issues=@() a ciegas.
  # Si la verificacion determinista ya habia fallado, sus issues legitimos se
  # perdian en cuanto la suite acababa en verde: la corrida mas sospechosa (dos
  # reintentos) era la que salia mas limpia.
  It 'no marca como verificada una respuesta que sigue sin ejecutar nada' {
        Mock Invoke-CopilotPrompt {
      @{ code=0; text='Ya cree el archivo config.json.'; resume='s1'; raw=''
         toolCalls=([System.Collections.Generic.List[object]]::new()); toolFailed=0; filesModified=@(); usage=@{} }
    }
    Mock Get-QualityCommand { @{ name='custom'; cmd='cmd /c exit 0' } }
    Mock Test-HasWriteTool { $true }          # fuerza a que el gate se ejecute
    Mock Invoke-QualityGate { @{ ok=$false; exitCode=1; output='1 failed'; command='x'; ms=1; timedOut=$false } }

    $r = Invoke-AskPrompt 'crea el archivo config.json' $script:qs $script:qo @{ verify=$true; retry=$true }
    $r.verified | Should -BeFalse
    @($r.issues).Count | Should -BeGreaterThan 0
  }

  It 'acumula toolFailed de ambos turnos en el reintento de calidad' {
    $script:n = 0
    Mock Invoke-CopilotPrompt {
      $script:n++
      # 2 herramientas con 1 fallo: la verificacion determinista pasa (no fallaron
      # todas), de modo que el unico reintento posible es el del gate de calidad.
      $l = [System.Collections.Generic.List[object]]::new()
      $l.Add(@{ name='edit'; summary='x'; success=$true })
      $l.Add(@{ name='powershell'; summary='y'; success=$false })
      @{ code=0; text='listo'; resume='s1'; raw=''; toolCalls=$l; toolFailed=1
         filesModified=@('a.py'); usage=@{} }
    }
    Mock Get-QualityCommand { @{ name='custom'; cmd='cmd /c exit 0' } }
    $script:g = 0
    Mock Invoke-QualityGate {
      $script:g++
      if ($script:g -eq 1) { @{ ok=$false; exitCode=1; output='rojo'; command='x'; ms=1; timedOut=$false } }
      else { @{ ok=$true; exitCode=0; output=''; command='x'; ms=1; timedOut=$false } }
    }
    $r = Invoke-AskPrompt 'arregla el bug de suma' $script:qs $script:qo @{ verify=$true; retry=$true }
    $script:n | Should -Be 2
    $r.toolFailed | Should -Be 2
    $r.quality.ok | Should -BeTrue
  }

  It 'expone el fallo de la suite en issues cuando queda roja' {
    Mock Invoke-CopilotPrompt {
      $l = [System.Collections.Generic.List[object]]::new()
      $l.Add(@{ name='edit'; summary='x'; success=$true })
      @{ code=0; text='arreglado'; resume=''; raw=''; toolCalls=$l; toolFailed=0
         filesModified=@('a.py'); usage=@{} }
    }
    Mock Get-QualityCommand { @{ name='custom'; cmd='mi-suite' } }
    Mock Invoke-QualityGate { @{ ok=$false; exitCode=2; output='2 failed'; command='mi-suite'; ms=1; timedOut=$false } }
    $r = Invoke-AskPrompt 'arregla el bug' $script:qs $script:qo @{ verify=$true; retry=$true }
    $r.verified | Should -BeFalse
    ($r.issues -join ' ') | Should -Match 'suite del proyecto falla'
    Get-AskExitCode $r | Should -Be 3
  }

  It 'omite el gate cuando no se toco codigo' {
    Mock Invoke-CopilotPrompt {
      $l = [System.Collections.Generic.List[object]]::new()
      $l.Add(@{ name='view'; summary='x'; success=$true })
      @{ code=0; text='La funcion suma dos enteros.'; resume=''; raw=''; toolCalls=$l
         toolFailed=0; filesModified=@(); usage=@{} }
    }
    Mock Invoke-QualityGate { throw 'el gate NO deberia ejecutarse sin cambios de codigo' }
    $r = Invoke-AskPrompt 'que hace la funcion add?' $script:qs $script:qo @{ verify=$true; retry=$true }
    $r.quality | Should -BeNullOrEmpty
  }
}
