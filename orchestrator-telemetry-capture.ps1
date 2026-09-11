# orchestrator-telemetry-capture.ps1 - hook telemetrii MAIN-AGENTA (Orchestratora).
#
# DWA TRYBY (jeden skrypt, dwa wpisy w settings.local.json):
#   [A] PreToolUse  (matcher: Agent|AskUserQuestion)
#       -> lapie DECYZJE Orchestratora: jaki agent dispatchowany, jaka runda pytan.
#       -> PreToolUse odpala sie PRZED wykonaniem => NIE zna rozmiaru wyniku.
#   [B] PostToolUse (matcher: Grep|Read|Glob|PowerShell|Bash|Edit|Write)
#       -> lapie KOSZT KONTEKSTU wlasnych operacji Orchestratora (chars wyniku).
#
# DLACZEGO [B] (dodane 2026-08-13, pomiar sesji 849f6ef6):
#   Telemetria logowala tylko Agent+AskUserQuestion => w statystykach bloku C widac bylo
#   "33 Agent + 4 AskUserQuestion" i wygladalo oszczednie. Realnie kontekst zjadlo
#   195 wlasnych operacji Orchestratora (55x Grep = 31k tokenow, jeden Grep = 17k).
#   Agenci kosztowali 52k output = 0.03% z 176M cache-read. Mierzylismy nie to co trzeba.
#   Bez [B] nie da sie zmierzyc poprawy, bo nie logowalismy pozycji ktora dominuje.
#
# ZRODLO ROZDZIALU: SubagentStop lapie koszt AGENTOW (agents_logs_raw.tsv, schema v2).
#   Ten hook pisze do osobnego orchestrator_actions_raw.tsv (ksztalt = akcja main-agenta).
# Detekcja main vs subagent: subagent ma w ladunku pola 'agent_id'/'agent_type' (GM.ENV.146).
#   NIE po transcript_path - u subagenta wskazuje on transkrypt sesji GLOWNEJ. Szczegoly nizej.
# ZASADA: NIGDY nie blokuj. Kazdy blad -> exit 0 po cichu. Append-only.
# ASCII-only (Windows PowerShell 5.1 czyta .ps1 jako ANSI).

$ErrorActionPreference = 'SilentlyContinue'

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $j = $raw | ConvertFrom-Json

    # --- Tylko main-agent (Orchestrator). Odsiew subagentow. ---
    #
    # GM.ENV.146 (naprawione 2026-09-10, ZMIERZONE na 5 zywych ladunkach hooka).
    # Bylo: 'transcript_path -match subagents[\\/]agent-'. Ten warunek NIE MOGL zadzialac ani razu,
    # bo w zdarzeniach PostToolUse pochodzacych z SUBAGENTA pole `transcript_path` wskazuje
    # transkrypt SESJI GLOWNEJ (<session-uuid>.jsonl), a nie plik subagenta. Pola
    # `agent_transcript_path` w tych ladunkach NIE MA (jest tylko przy SubagentStop).
    # Skutek: kazda operacja kazdego subagenta byla ksiegowana jako akcja Orchestratora -
    # 327 zapisanych akcji przy ~45 realnych w sesji 09462602 (7x zawyzenia). Zgadzaly sie
    # wylacznie wiersze `Agent` i `AskUserQuestion`, bo tych subagent nie wywoluje.
    #
    # Rozroznia je OBECNOSC pary pol `agent_id` + `agent_type` - wystepuja wylacznie
    # w ladunku subagenta. Sprawdzamy ISTNIENIE pola, nie jego wartosc: pole nieobecne
    # zwraca $null tak samo jak pole puste, a tylko pierwsze znaczy "to main-agent".
    $props = $j.PSObject.Properties.Name
    if ($props -contains 'agent_id' -or $props -contains 'agent_type') { exit 0 }

    # Zapasowy warunek po sciezce - zostaje na wypadek, gdyby harness kiedys zaczal
    # podawac wlasciwy transkrypt subagenta. Sam z siebie NIE wystarcza (patrz wyzej).
    $transcript = [string]$j.transcript_path
    if ($transcript -match '(?i)subagents[\\/]agent-') { exit 0 }

    $toolName = [string]$j.tool_name
    if ([string]::IsNullOrWhiteSpace($toolName)) { exit 0 }

    $sessionId = [string]$j.session_id
    $sess8 = if ($sessionId.Length -ge 8) { $sessionId.Substring(0,8) } else { $sessionId }

    $ev = [string]$j.hook_event_name
    $action = ''; $subagentType = ''; $detail = ''

    if ($ev -eq 'PostToolUse') {
        # --- [B] koszt kontekstu wlasnych operacji ---
        $scanTools = @('Grep','Read','Glob','PowerShell','Bash','Edit','Write')
        if ($scanTools -notcontains $toolName) { exit 0 }

        $chars = 0
        try {
            $resp = $j.tool_response
            if ($null -ne $resp) {
                if ($resp -is [string]) { $chars = $resp.Length }
                else { $chars = ($resp | ConvertTo-Json -Depth 12 -Compress).Length }
            }
        } catch { $chars = -1 }   # -1 = nie dalo sie zmierzyc (nie gubimy wiersza)

        # krotka etykieta CO bylo pytane - bez tego nie wiadomo ktory Grep kosztowal 17k
        $ti = $j.tool_input
        $q = ''
        foreach ($f in @('pattern','file_path','command','path')) {
            $v = [string]$ti.$f
            if (-not [string]::IsNullOrWhiteSpace($v)) { $q = $v; break }
        }
        if ($q.Length -gt 60) { $q = $q.Substring(0,60) }

        $action = $toolName
        $detail = "chars=$chars;q=$q"
    }
    else {
        # --- [A] decyzje Orchestratora (PreToolUse) ---
        if ($toolName -eq 'Agent') {
            $action = 'Agent'
            $subagentType = [string]$j.tool_input.subagent_type
            $detail = [string]$j.tool_input.description
        }
        elseif ($toolName -eq 'AskUserQuestion') {
            $action = 'AskUserQuestion'
            $qs = $j.tool_input.questions
            $n = 0
            if ($qs) { $n = @($qs).Count }
            $detail = "questions=$n"
        }
        else { exit 0 }
    }

    # sanitize tabs/newlines
    $subagentType = $subagentType -replace "`t",' ' -replace "`r?`n",' '
    $detail = $detail -replace "`t",' ' -replace "`r?`n",' '

    $root = if ($env:OH_HOOK_ROOT) { $env:OH_HOOK_ROOT }
            elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR }
            elseif ($j.cwd) { $j.cwd }
            else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $kbDir   = if ($env:OH_HOOK_KB_DIR) { $env:OH_HOOK_KB_DIR } else { Join-Path $root '.claude\knowledge-base' }
    $outFile = Join-Path $kbDir 'orchestrator_actions_raw.tsv'
    $enc = [System.Text.UTF8Encoding]::new($false)

    # ROTACJA (GM.ENV.107, 2026-09-09). Ten plik rosl bez zadnego ograniczenia i osiagnal 5,36 MB /
    # ~35 tys. wierszy - ok. 95% objetosci calej telemetrii, przy sasiadach rzedu 50-83 KB. Zaden hook,
    # skrypt ani command go nie rotowal. Rotujemy PRZED zapisem, zeby biezacy wiersz trafil juz do
    # nowego pliku; istniejaca galaz '-not (Test-Path)' ponizej sama dopisze naglowek.
    # Nazwa z miesiacem, a nie z timestampem, zeby archiwum nie rozsypalo sie na setki plikow.
    $ROTATE_BYTES = 1MB
    $existing = Get-Item -LiteralPath $outFile -ErrorAction SilentlyContinue
    if ($existing -and $existing.Length -gt $ROTATE_BYTES) {
        $stamp    = (Get-Date).ToUniversalTime().ToString('yyyy-MM')
        $archive  = Join-Path $kbDir ("orchestrator_actions_raw_" + $stamp + ".tsv")
        $n = 1
        while (Test-Path -LiteralPath $archive) {
            $archive = Join-Path $kbDir ("orchestrator_actions_raw_" + $stamp + "_" + $n + ".tsv")
            $n++
        }
        Move-Item -LiteralPath $outFile -Destination $archive -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $outFile)) {
        $header = "utc`tsession8`tactor`taction`tsubagent_type`tdetail"
        [System.IO.File]::WriteAllText($outFile, $header + "`r`n", $enc)
    }

    $nowUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $row = "$nowUtc`t$sess8`torchestrator`t$action`t$subagentType`t$detail"
    [System.IO.File]::AppendAllText($outFile, $row + "`r`n", $enc)
}
catch {
    # celowo cicho - telemetria nie moze nigdy przeszkodzic w pracy
}

exit 0
