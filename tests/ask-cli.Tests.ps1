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
    It 'antepone el guard e incluye la tarea' {
        $p = Build-ExecutionFirstPrompt 'listar archivos'
        $p | Should -Match 'INSTRUCCION OPERATIVA'
        $p | Should -Match 'TAREA:'
        $p | Should -Match 'listar archivos'
    }
}

Describe 'ConvertTo-SingleLinePrompt' {
    It 'aplana saltos de linea para el shim cmd.exe' {
        $p = Build-ExecutionFirstPrompt 'listar archivos'
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
