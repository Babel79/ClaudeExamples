# mutation-leftover-detector.ps1 - SubagentStop hook. Karta ENV.70.
#
# PROBLEM (incydent bloku C, 2026-08-13):
#   03-QA wykonujacy kontrdowod zostal uciety przez maxTurns (73 tool_uses) W POLOWIE cyklu,
#   zostawiajac w Program.cs zamontowana mutacje `// MUTATION 2` - doslowne cofniecie poprawki,
#   ktora ten sam commit wprowadzal. MUTACJA KOMPILUJE SIE BEZ BLEDU. Zlapane wylacznie
#   verify-on-disk. Gdyby uciecie potraktowac jako "agent skonczyl" -> mutacja weszlaby do PR
#   z zielonym buildem.
#
# DLACZEGO ISTNIEJACE REGULY NIE ZADZIALALY:
#   cust_agent_protocol par.3 zasada 1 ("NIGDY nie koncz tury na akcji-w-toku") oraz /counterproof
#   krok 4 (obowiazkowy rewert) ZAKLADAJA, ze agent decyduje kiedy konczy. Przy ucieciu maxTurns
#   agent NIE MA tury, w ktorej moglby posprzatac - regula adresowana do agenta jest z definicji
#   nieegzekwowalna. Ta sama klasa co ENV.48.
#
# DLACZEGO SubagentStop:
#   odpala sie gdy agent SCHODZI - takze przy ucieciu maxTurns, takze gdy agent nie zdazyl nic
#   posprzatac. To jedyny moment, ktory NIE zalezy od wspolpracy agenta.
#
# CO ROBI: skanuje TYLKO pliki zmienione wzgledem HEAD (szybko, celnie) pod katem markerow
#   mutacji w kodzie PRODUKCYJNYM. Znalezione -> plik alertu .claude/MUTATION_ALERT.txt,
#   ktory podnosi hook alert-mutation-leftover.ps1 (UserPromptSubmit) przy najblizszej turze.
#
# WERSJA 3 (2026-09-02) - WARUNEK UCIECIA. Pomiar audytu: 7 alarmow na 7 bylo FALSZYWYCH.
#   Przyczyna: /counterproof ma mutacje "w toku" Z DEFINICJI - agent montuje mutacje, sprawdza
#   czerwien testu i rewertuje. Detektor strzelal w srodku tego normalnego okna, a alarm jest
#   kategoryczny ("NIE commituj") i za kazdym razem wymagal dwutorowej weryfikacji. Falszywy alarm
#   z zakazem jest drozszy niz brak alarmu (D4).
#   Rozroznienie: agent, ktory ZAKONCZYL normalnie, wystawia w ostatniej wiadomosci VERDICT albo
#   STATUS: (cust_agent_protocol). Agent uciety przez maxTurns nie ma tury, w ktorej moglby to
#   napisac - i to jest DOKLADNIE przypadek, przed ktorym ten detektor ma chronic.
#   Zrodlo tekstu: pole last_assistant_message z wejscia SubagentStop (docs
#   code.claude.com/docs/en/hooks.md: "contains the text content of the subagent's final response,
#   so hooks can access it without parsing the transcript file"). Docs ostrzegaja tez, ze
#   transcript_path "is written asynchronously and may lag", wiec parsowanie jsonl to tylko fallback.
#   Marker + VERDICT -> wylacznie wpis INFO-in-progress do logu, BEZ pliku MUTATION_ALERT.txt.
#   Marker + brak VERDICT -> zachowanie dotychczasowe (pelny alarm).
#
# ZASADA: NIGDY nie blokuj agenta. Kazdy blad -> exit 0 po cichu. ASCII-only (PS 5.1 czyta ANSI).

$ErrorActionPreference = 'SilentlyContinue'

try {
    $raw = [Console]::In.ReadToEnd()
    $sess8 = ''
    $payload = $null
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try {
            $payload = $raw | ConvertFrom-Json
            $sid = [string]$payload.session_id
            if ($sid.Length -ge 8) { $sess8 = $sid.Substring(0,8) }
        } catch {}
    }

    $root = if ($env:OH_HOOK_ROOT) { $env:OH_HOOK_ROOT }
            elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR }
            elseif ($payload.cwd) { $payload.cwd }
            else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) { exit 0 }

    # --- pliki zmienione wzgledem HEAD (tracked) + untracked ---
    $changed = @()
    $changed += (& git -C $root diff --name-only HEAD 2>$null)
    $changed += (& git -C $root ls-files --others --exclude-standard 2>$null)
    $changed = $changed | Where-Object { $_ } | Select-Object -Unique
    if (-not $changed) { exit 0 }

    # --- tylko KOD PRODUKCYJNY ---
    # wykluczamy testy (mutacja w tescie jest legalna), .claude, bin/obj/node_modules
    $codeExt  = @('.cs','.ts','.html','.scss','.css','.xaml','.sql','.razor')
    $excludeRx = '(?i)([\\/]|^)(bin|obj|node_modules|\.claude|\.git)([\\/]|$)|(?i)tests?[\\/]|(?i)\.(spec|tests?)\.'

    # marker mutacji: ALL-CAPS MUTATION/MUTACJA tuz po otwarciu komentarza.
    # Konwencja /counterproof; ALL-CAPS + kontekst komentarza chroni przed trafieniem
    # w slowo "mutation" w zwyklej prozie (np. komentarz o testach mutacyjnych).
    #
    # WERSJA 2 (2026-08-13) - v1 wymagala markera TUZ po znaku komentarza ('//\s*MUTATION')
    # i PRZEPUSCILA pierwszy realny przypadek: agent 07-angular uzyl
    # '// TEMP MUTATION FOR COUNTERPROOF - DO NOT COMMIT'. Slowo TEMP pomiedzy rozbijalo
    # dopasowanie. Test v1 sprawdzal wylacznie wzorzec wymyslony przez autora detektora -
    # bramka testowana na wlasnym happy-path. Teraz: marker gdziekolwiek w linii komentarza.
    # Case-sensitive (-cmatch) + ALL-CAPS chroni przed alarmem na prozie
    # ("komentarz o testach mutacyjnych", "mutation testing") - takie linie MAJA przechodzic.
    $commentRx = '(//|/\*|^\s*\*|#|<!--|--)'
    $markerRx  = '\b(MUTATION|MUTACJA|MUTANT)\b'
    $tempRx    = '(DO NOT COMMIT|NIE COMMITOWAC)'

    $hits = @()
    foreach ($rel in $changed) {
        if ($rel -match $excludeRx) { continue }
        $ext = [System.IO.Path]::GetExtension($rel)
        if ($codeExt -notcontains $ext) { continue }

        $full = Join-Path $root $rel
        if (-not (Test-Path -LiteralPath $full)) { continue }   # skasowany w diffie

        $n = 0
        foreach ($line in [System.IO.File]::ReadLines($full)) {
            $n++
            if (($line -match $commentRx) -and (($line -cmatch $markerRx) -or ($line -cmatch $tempRx))) {
                $t = $line.Trim()
                if ($t.Length -gt 120) { $t = $t.Substring(0,120) }
                $hits += "  $rel : $n : $t"
            }
        }
    }

    if ($hits.Count -eq 0) { exit 0 }

    # --- CZY AGENT ZAKONCZYL NORMALNIE? (warunek uciecia, wersja 3) ---
    $finalText = ''
    if ($payload) { $finalText = [string]$payload.last_assistant_message }
    if ([string]::IsNullOrWhiteSpace($finalText)) {
        # fallback: ostatni blok tekstu asystenta z wlasnego transcriptu agenta
        try {
            $atp = [string]$payload.agent_transcript_path
            if ([string]::IsNullOrWhiteSpace($atp)) {
                $tp = [string]$payload.transcript_path
                if ($tp) {
                    $sd = ($tp -replace '\.jsonl$','') + '\subagents'
                    if (Test-Path -LiteralPath $sd) {
                        $newest = Get-ChildItem -LiteralPath $sd -Filter 'agent-*.jsonl' -ErrorAction SilentlyContinue |
                                  Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-2) } |
                                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
                        if ($newest) { $atp = $newest.FullName }
                    }
                }
            }
            if ($atp -and (Test-Path -LiteralPath $atp)) {
                foreach ($line in [System.IO.File]::ReadLines($atp)) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    $o = $null; try { $o = $line | ConvertFrom-Json } catch { continue }
                    $m = $o.message
                    if ($null -eq $m -or $m.role -ne 'assistant') { continue }
                    foreach ($c in $m.content) {
                        if ($c -and $c.type -eq 'text' -and $c.text) { $finalText = [string]$c.text }
                    }
                }
            }
        } catch {}
    }

    $claudeDir = Join-Path $root '.claude'
    $kbDir     = if ($env:OH_HOOK_KB_DIR) { $env:OH_HOOK_KB_DIR } else { Join-Path $claudeDir 'knowledge-base' }
    if (-not (Test-Path -LiteralPath $kbDir)) { New-Item -ItemType Directory -Path $kbDir -Force | Out-Null }
    $alertFile = Join-Path $claudeDir 'MUTATION_ALERT.txt'
    $logFile   = Join-Path $kbDir 'mutation_alerts.log'
    $enc = [System.Text.UTF8Encoding]::new($false)
    $nowUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    # Agent zamknal prace normalnie (wystawil VERDICT / STATUS:) -> mutacja jest "w toku" wlasnego
    # cyklu /counterproof albo juz opisana w raporcie. Tylko log, ZERO alarmu.
    if ($finalText -match '(?i)\bVERDICT\b' -or $finalText -match '(?i)\bSTATUS\s*:') {
        [System.IO.File]::AppendAllText($logFile, "$nowUtc`t$sess8`tINFO-in-progress`t$($hits.Count) trafien`t$($hits -join ' | ')`r`n", $enc)
        exit 0
    }

    # --- ALERT (agent zszedl bez VERDICT: uciecie maxTurns / przerwanie) ---
    $body = @()
    $body += "MUTATION LEFTOVER DETECTED - $nowUtc (sesja $sess8)"
    $body += "Agent zszedl (byc moze uciety przez maxTurns) zostawiajac marker mutacji w KODZIE PRODUKCYJNYM."
    $body += "Karta ENV.70 tego projektu. Kompiluje sie bez bledu - build NIE jest tu dowodem."
    $body += ""
    $body += "ZNALEZIONE ($($hits.Count)):"
    $body += $hits
    $body += ""
    $body += "CO ZROBIC: zrewertuj mutacje RECZNIE (git checkout moze byc niemozliwy - drzewo bywa brudne"
    $body += "praca innych agentow). Dowod czystosci: git hash-object <plik> sprzed mutacji vs po rewercie"
    $body += "(porownanie z main:<plik> jest bez sensu, gdy plik ma legalnie roznic sie od main)."
    $body += "Po posprzataniu skasuj ten plik: .claude/MUTATION_ALERT.txt"

    [System.IO.File]::WriteAllText($alertFile, ($body -join "`r`n") + "`r`n", $enc)
    [System.IO.File]::AppendAllText($logFile, "$nowUtc`t$sess8`t$($hits.Count) trafien`t$($hits -join ' | ')`r`n", $enc)
}
catch {
    # celowo cicho - detektor nie moze nigdy przeszkodzic w pracy
}

exit 0
