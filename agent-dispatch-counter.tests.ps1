# agent-dispatch-counter.tests.ps1 - suita dla agent-dispatch-counter.ps1
# Hook tylko loguje (nie blokuje, nie wstrzykuje), wiec asercje dotycza PLIKU,
# nie stdout. Kazdy przypadek liczy przyrost wierszy w tsv.
#
# IZOLACJA (H3, portabilizacja suit): hook wspiera $env:OH_HOOK_KB_DIR (wprowadzone w H1) -
# przekierowujemy zapis do <tmp>, zeby NIE dotykac zywego .claude\knowledge-base\agents_dispatch_raw.tsv
# tego repo. Zmienna srodowiskowa ustawiona w tym procesie jest dziedziczona przez kazdy
# podproces powershell.exe wywolywany nizej. To jest defekt, ktory naprawiamy: przed izolacja
# ta suita byla jedynym czerwonym wynikiem pelnej bramki, bo kazdy rownolegly dispatch agenta
# dopisywal wiersze do TEGO SAMEGO realnego pliku w trakcie przebiegu.

$hook = "$PSScriptRoot\agent-dispatch-counter.ps1"
$tmp  = Join-Path $env:TEMP ("oh-hooktest-dispatch-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$tsv  = Join-Path $tmp 'agents_dispatch_raw.tsv'
$script:fails = 0

function Get-LineCount {
    if (-not (Test-Path $tsv)) { return 0 }
    return @([System.IO.File]::ReadAllLines($tsv)).Count
}

function Test-Rows($name, $inputObj, $expectedDelta) {
    $before = Get-LineCount
    if ($inputObj -is [string]) { $json = $inputObj } else { $json = $inputObj | ConvertTo-Json -Compress -Depth 6 }
    $out = $json | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook
    $after = Get-LineCount
    $delta = $after - $before
    # hook nie moze nic wypisywac na stdout - to PreToolUse, output zmienialby decyzje
    $silent = -not $out
    if ($delta -eq $expectedDelta -and $silent) { $v = 'OK  ' } else { $v = 'FAIL'; $script:fails++ }
    "[{0}] {1,-56} delta={2} (oczek. {3}) stdout_pusty={4}" -f $v, $name, $delta, $expectedDelta, $silent
}

function Test-LastRow($name, $inputObj, $mustContain) {
    $json = $inputObj | ConvertTo-Json -Compress -Depth 6
    $json | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook | Out-Null
    $lines = [System.IO.File]::ReadAllLines($tsv)
    $last = $lines[$lines.Count - 1]
    if ($last -match [regex]::Escape($mustContain)) { $v = 'OK  ' } else { $v = 'FAIL'; $script:fails++ }
    "[{0}] {1,-56} ostatni wiersz zawiera '{2}'" -f $v, $name, $mustContain
}

"=== agent-dispatch-counter ==="

$env:OH_HOOK_KB_DIR = $tmp
try {
    # SETUP: przy pierwszym uruchomieniu hook tworzy plik Z NAGLOWKIEM, wiec pierwszy
    # zapis daje przyrost 2, nie 1 (zmierzone 2026-09-02 - poprawne zachowanie hooka,
    # bledne zalozenie testu). Zapewniamy istnienie pliku, zeby kazdy przypadek
    # mierzyl czysty przyrost, niezalezny od stanu poczatkowego.
    if (-not (Test-Path $tsv)) {
        $encSetup = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tsv, "ts`tsession_id`tsubagent_type`tmodel`tdescription`r`n", $encSetup)
    }

    # --- nie loguje ---
    Test-Rows 'pusty stdin -> brak wiersza' '' 0
    Test-Rows 'inne narzedzie (Bash) -> brak wiersza' @{ tool_name='Bash'; tool_input=@{ command='ls' } } 0
    Test-Rows 'inne narzedzie (Grep) -> brak wiersza' @{ tool_name='Grep'; tool_input=@{ pattern='x' } } 0

    # --- loguje ---
    Test-Rows 'Agent -> dokladnie jeden wiersz' @{ tool_name='Agent'; session_id='s1'; tool_input=@{ subagent_type='03-qa-agent'; model='sonnet'; description='test' } } 1
    Test-Rows 'Agent bez subagent_type -> nadal jeden wiersz' @{ tool_name='Agent'; session_id='s1'; tool_input=@{ description='bez typu' } } 1

    # --- tresc wiersza ---
    Test-LastRow 'wiersz zawiera typ agenta' @{ tool_name='Agent'; session_id='s2'; tool_input=@{ subagent_type='06-architecture-guardian-agent'; model='opus'; description='audyt' } } '06-architecture-guardian-agent'
    Test-LastRow 'wiersz zawiera model' @{ tool_name='Agent'; session_id='s2'; tool_input=@{ subagent_type='01-github-devops-agent'; model='haiku'; description='commit' } } 'haiku'
    Test-LastRow 'brak typu -> fallback general-purpose' @{ tool_name='Agent'; session_id='s2'; tool_input=@{ description='x' } } 'general-purpose'

    # --- regresja: tabulator/newline w opisie nie moze rozwalic kolumn ---
    $before = Get-LineCount
    @{ tool_name='Agent'; session_id='s3'; tool_input=@{ subagent_type='05-api-agent'; model='sonnet'; description="opis`tz tabem`ni nowa linia" } } |
        ConvertTo-Json -Compress -Depth 6 | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook | Out-Null
    $after = Get-LineCount
    $lines = [System.IO.File]::ReadAllLines($tsv)
    $cols = ($lines[$lines.Count - 1] -split "`t").Count
    if (($after - $before) -eq 1 -and $cols -eq 5) { $v = 'OK  ' } else { $v = 'FAIL'; $script:fails++ }
    "[{0}] {1,-56} wierszy=+{2} kolumn={3} (oczek. +1 / 5)" -f $v, 'tab i newline w opisie nie lamia kolumn', ($after - $before), $cols
}
finally {
    Remove-Item Env:\OH_HOOK_KB_DIR -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

""
if ($script:fails -eq 0) { "WYNIK: OK (0 FAIL)" } else { "WYNIK: FAIL ($script:fails)" }
