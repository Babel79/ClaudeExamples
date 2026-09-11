# agent-telemetry-capture.ps1 - SubagentStop + UserPromptSubmit hook. WERSJA 4 (2026-09-09).
#
# CO SIE ZMIENILO W v4 I DLACZEGO (pomiar sesji 6ce5971f):
#   (N1) SUMY usage byly ZAWYZONE 2,22x. Jedna wiadomosc asystenta zapisuje sie w transkrypcie jako
#        KILKA rekordow (apiBlockIndex 0..N) z TYM SAMYM message.id i TYM SAMYM blokiem 'usage'.
#        v3 sumowala kazda linie -> ta sama tura liczona N razy. Zmierzone na 6ce5971f:
#        naiwnie in/out/cache_create/cache_read = 1618 / 225917 / 4346808 / 81316313 (razem 85 890 656),
#        po deduplikacji po message.id = 704 / 222677 / 1548695 / 36922886 (razem 38 694 962).
#        Fix: usage zbierane do slownika po message.id, OSTATNI rekord wiadomosci wygrywa (ma komplet
#        output_tokens). Kolumny 'turns' i 'tool_uses' byly poprawne i NIE sa ruszane.
#   (N2) Nowa kolumna 'paid_total' NA KONCU = in + out + cache_create + cache_read po deduplikacji.
#        UWAGA: to SUROWE TOKENY ZAPLACONE, a NIE koszt w pieniadzu. cache_read jest bilingowany
#        ulamkiem stawki wejscia, output wielokrotnoscia. Zeby zrobic z tego koszt, trzeba przemnozyc
#        kazda skladowa przez jej wage cenowa - kolumna sama w sobie kosztem NIE jest.
#   (N3) Flaga 'complete' zmienila DEFINICJE. v3 opierala ja na stop_reason ostatniej linii asystenta,
#        co bylo nienaprawialne: transkrypt agenta konczy sie TRWALE na rekordzie apiBlockIndex=0
#        ostatniej wiadomosci, a stop_reason niesie dopiero rekord domykajacy, ktory NIGDY nie trafia
#        do pliku. Stad complete=0 w 74% wierszy. Od v4: complete=1 <=> harness zglosil SubagentStop
#        dla TEGO agenta (nazwa pliku z agent_transcript_path = agent_id). Flaga jest STICKY - pelny
#        skan przy kolejnym SubagentStop przelicza wiersze od zera i musi ZACHOWAC juz ustawione 1.
#   Skutkiem N3 kryterium drugiego przebiegu nie moze juz byc 'complete<>1' (complete nie mowi nic
#   o kompletnosci DANYCH). Drugi przebieg (UserPromptSubmit) przelicza wiersz, gdy plik jsonl agenta
#   jest MLODSZY (mtime) niz znacznik 'utc' w wierszu - czyli gdy transkrypt dopisal sie po pomiarze.
#
# CO SIE ZMIENILO W v3 I DLACZEGO (pomiar sesji b494dba5, 5 agentow):
#   Zglaszany "rozjazd 2,8-4,9x" wzgledem subagent_tokens harnessu NIE byl bledem hooka: porownywano
#   kolumne 5 (out_tokens = SUMA output_tokens) z wielkoscia harnessu. Wlasciwa kolumna to 9
#   (harness_equiv) i zgadza sie ona w granicach 1,4% (182155/180125, 187514/185085, 233945/232702,
#   143918/145828). Dowod: dla wszystkich 5 agentow ostatnia linia asystenta w pliku BYLA JUZ
#   zapisana przed chwila zapisu hooka (0 linii po tym momencie), wiec (a)=(b)=(c) - laga nie bylo.
#   Zostaje jednak realna luka, ktorej wersja 2 nie widziala:
#   (1) transkrypt MOZE lagowac (docs: "written asynchronously and may lag") i nic w tsv tego nie
#       pokazuje - wiersz z ogryzka wyglada identycznie jak wiersz kompletny;
#   (2) UPSERT dopelnia wiersze poprzednich agentow, ale OSTATNI agent sesji nie ma juz kolejnego
#       SubagentStop, wiec jego wiersz nigdy nie jest odczytywany drugi raz.
#   Fix: kolumna 'complete' (NA KONCU, kompatybilnie) + DRUGI PRZEBIEG na UserPromptSubmit, ktory
#   przelicza wylacznie wiersze z complete<>1. Zmierzone na tej sesji: agent ubity mid-tool-use ma
#   stop_reason='tool_use', a agent H4 pusty stop_reason (zapis w trakcie domykania tury) - oba
#   dostaja complete=0 i sa domykane w drugim przebiegu; agenci z 'end_turn' -> complete=1.
#
# CO SIE ZMIENILO I DLACZEGO (audyt srodowiska, RAPORT_2026-09-02 par.1.6 / O-1):
#   Wersja 1 zanizala 126x wzgledem recznych wpisow w agents_logs.md. Dwie przyczyny, obie zmierzone:
#   (a) plik <sesja>\subagents\agent-<id>.jsonl jest pisany ASYNCHRONICZNIE i w chwili SubagentStop
#       bywa NIEKOMPLETNY. v1 oznaczala go w .seen i NIGDY nie wracala -> zapisany byl ogryzek.
#       Fix: brak .seen. Hook przetwarza WSZYSTKIE agent-*.jsonl sesji i robi UPSERT po agent_id,
#       wiec kazdy kolejny SubagentStop dopelnia wiersze poprzednich agentow.
#   (b) v1 raportowala sume output_tokens (dla agenta A: 68 900) jako "koszt", podczas gdy harness
#       w metadanych Agent tool zwraca subagent_tokens = ROZMIAR OKNA KONTEKSTU agenta na koncu
#       (dla A: 309 011). To dwie rozne wielkosci.
#
# WZOR harness_equiv (ustalony pomiarem na 5 agentach sesji 718cc506, skrypt find_formula2.py):
#   harness_equiv = usage OSTATNIEJ linii asystenta z usage:
#                   input_tokens + output_tokens + cache_creation_input_tokens + cache_read_input_tokens
#   Zmierzone odchylenie vs subagent_tokens harnessu:
#     A 307 348 vs 309 011 (-0,54%) | B 131 001 vs 130 516 (+0,37%) | C 60 147 vs 60 696 (-0,90%)
#     D 280 283 vs 282 201 (-0,68%) | E 108 172 vs 105 160 (+2,86%; agent wznawiany 2x przez SendMessage,
#       plik zawiera oba przebiegi, wiec porownanie z pojedyncza wartoscia E2 jest z natury nieostre)
#   Sumowanie usage po WSZYSTKICH liniach asystenta NIE odtwarza tej liczby (dla A dawaloby 21,9 mln,
#   bo cache_read powtarza sie w kazdej turze) - dlatego kolumny out/in/cache sa RAPORTOWANE OSOBNO
#   jako sumy, a harness_equiv liczony jest z ostatniej linii.
#
# ZASADA: NIGDY nie blokuj agenta. Kazdy blad -> exit 0 po cichu. ASCII-only (PS 5.1 czyta .ps1 jako ANSI).

$ErrorActionPreference = 'SilentlyContinue'

# KANON KONTRAKTU KOLUMN: .claude/rules/agents-telemetry.md (decyzja CLAUDE.md par.4a, 2026-09-09).
# Znaczenie kolumn, semantyke 'complete'/'paid_total' i uskok formatu opisuje TAMTEN plik - tu jest
# wylacznie implementacja. Zmieniasz zestaw kolumn? Najpierw kanon, potem te linie.
# Dlaczego to jest tylko komentarz, a nie druga kopia opisu (GM.ENV.125, 2026-09-09): dokument urosl
# do 54 linii pelnego kontraktu, a hook definiowal go niezaleznie - dwa zrodla prawdy o tym samym
# formacie rozjezdzaly sie tym szybciej, im wiecej kazde z nich opisywalo.
$HEADER_V2 = "utc`tsession8`tagent_type`tmodel`tout_tokens`tin_tokens`tcache_create`tcache_read`tharness_equiv`tturns`ttool_uses`tduration_sec`tdescription`tagent_id"
$HEADER_V3 = $HEADER_V2 + "`tcomplete"
$HEADER = $HEADER_V3 + "`tpaid_total"

# Indeksy kolumn (stale, bo naglowek jest staly): agent_id = 13, complete = 14, paid_total = 15.
$COL_AGENT_ID = 13
$COL_COMPLETE = 14
$COL_UTC = 0

function Get-AgentRow {
    param([string]$JsonlPath, [string]$Sess8, [string]$NowUtc, [int]$Complete)

    $agentId = [System.IO.Path]::GetFileNameWithoutExtension($JsonlPath)   # agent-<hash>

    # usage zbierane PER message.id - jedna wiadomosc = kilka rekordow (apiBlockIndex 0..N) z tym
    # samym usage; sumowanie po liniach zawyzalo 2,22x (patrz naglowek pliku, N1).
    $usageById = New-Object 'System.Collections.Specialized.OrderedDictionary'
    $lastIn = 0; $lastOut = 0; $lastCc = 0; $lastCr = 0
    $model = 'n/d'; $tools = 0
    $ids = @{}; $turns = 0
    $noIdSeq = 0
    $firstTs = $null; $lastTs = $null

    foreach ($line in [System.IO.File]::ReadLines($JsonlPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $o = $null
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.timestamp) {
            try {
                $dt = [datetime]::Parse($o.timestamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                if ($null -eq $firstTs) { $firstTs = $dt }
                $lastTs = $dt
            } catch {}
        }
        $m = $o.message
        if ($null -eq $m) { continue }
        if ($m.role -ne 'assistant') { continue }

        if ($m.model) { $model = [string]$m.model }
        $mid = [string]$m.id
        if ($mid -and -not $ids.ContainsKey($mid)) { $ids[$mid] = $true; $turns++ }

        foreach ($c in $m.content) {
            if ($c -and $c.type -eq 'tool_use') { $tools++ }
        }

        $u = $m.usage
        if ($null -eq $u) { continue }
        $ui = 0; $uo = 0; $ucc = 0; $ucr = 0
        if ($u.input_tokens) { $ui = [int]$u.input_tokens }
        if ($u.output_tokens) { $uo = [int]$u.output_tokens }
        if ($u.cache_creation_input_tokens) { $ucc = [int]$u.cache_creation_input_tokens }
        if ($u.cache_read_input_tokens) { $ucr = [int]$u.cache_read_input_tokens }
        # UPSERT po message.id: OSTATNI rekord danej wiadomosci wygrywa (ma komplet output_tokens).
        $key = if ($mid) { $mid } else { $noIdSeq++; "noid-$noIdSeq" }
        $usageById[$key] = @($ui, $uo, $ucc, $ucr)
        # ostatnia linia asystenta Z usage = koncowy rozmiar okna kontekstu agenta
        $lastIn = $ui; $lastOut = $uo; $lastCc = $ucc; $lastCr = $ucr
    }

    $outSum = 0; $inSum = 0; $ccSum = 0; $crSum = 0
    foreach ($v in $usageById.Values) {
        $inSum += $v[0]; $outSum += $v[1]; $ccSum += $v[2]; $crSum += $v[3]
    }

    $harness = $lastIn + $lastOut + $lastCc + $lastCr

    # paid_total = surowe tokeny ZAPLACONE (po deduplikacji). NIE jest to koszt w pieniadzu -
    # cache_read jest bilingowany ulamkiem stawki, output wielokrotnoscia; brakuje wag cenowych.
    $paidTotal = $inSum + $outSum + $ccSum + $crSum

    $dur = ''
    if ($firstTs -and $lastTs) { $dur = [int]($lastTs - $firstTs).TotalSeconds }

    $agentType = '?'; $desc = ''
    $metaPath = ($JsonlPath -replace '\.jsonl$', '') + '.meta.json'
    if (Test-Path -LiteralPath $metaPath) {
        try {
            # UWAGA: 'Get-Content -Raw' w PS 5.1 czyta plik bez BOM jako ANSI i robi mojibake
            # z polskich znakow w opisie zadania (zmierzone: "nowosci" -> "nowoAaEURsci").
            # Czytamy jawnie jako UTF-8.
            $meta = [System.IO.File]::ReadAllText($metaPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            if ($meta.agentType) { $agentType = [string]$meta.agentType }
            if ($meta.description) { $desc = ([string]$meta.description) -replace "`t", ' ' -replace "`r?`n", ' ' }
        } catch {}
    }

    return "$NowUtc`t$Sess8`t$agentType`t$model`t$outSum`t$inSum`t$ccSum`t$crSum`t$harness`t$turns`t$tools`t$dur`t$desc`t$agentId`t$Complete`t$paidTotal"
}

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $payload = $raw | ConvertFrom-Json

    $sessionId = [string]$payload.session_id
    $sess8 = if ($sessionId.Length -ge 8) { $sessionId.Substring(0, 8) } else { $sessionId }

    # DRUGI PRZEBIEG: hook jest zarejestrowany takze na UserPromptSubmit. Tam nie ma nowego agenta -
    # celem jest wylacznie dopelnienie wierszy, ktorych transkrypt dopisal sie PO ostatnim pomiarze
    # (ostatni agent sesji nigdy nie dostaje kolejnego SubagentStop). Zdarzenie inne niz SubagentStop
    # => tryb selektywny: czytamy tylko te jsonl, ktore sa mlodsze niz znacznik 'utc' wiersza.
    $evt = [string]$payload.hook_event_name
    $selective = ($evt -and $evt -ne 'SubagentStop')

    # Katalog subagents. Zrodlo 1: agent_transcript_path (docs code.claude.com/docs/en/hooks.md,
    # sekcja "SubagentStop input" - pole wskazuje wlasny transcript agenta w podkatalogu subagents/).
    # Zrodlo 2 (fallback, gdy pole nieobecne): <main transcript bez .jsonl>\subagents (zachowanie v1).
    $subDir = $null
    $atp = [string]$payload.agent_transcript_path
    # complete=1 <=> harness zglosil SubagentStop dla TEGO agenta. Nazwa pliku z agent_transcript_path
    # jest rownoczesnie agent_id wiersza (patrz N3 w naglowku). Na UserPromptSubmit nic nie domykamy.
    $stopAgentId = ''
    if (-not [string]::IsNullOrWhiteSpace($atp)) {
        try { $subDir = [System.IO.Path]::GetDirectoryName($atp) } catch {}
        if (-not $selective) {
            try { $stopAgentId = [System.IO.Path]::GetFileNameWithoutExtension($atp) } catch {}
        }
    }
    if ([string]::IsNullOrWhiteSpace($subDir) -or -not (Test-Path -LiteralPath $subDir)) {
        $transcript = [string]$payload.transcript_path
        if ([string]::IsNullOrWhiteSpace($transcript)) { exit 0 }
        $subDir = ($transcript -replace '\.jsonl$', '') + '\subagents'
    }
    if (-not (Test-Path -LiteralPath $subDir)) { exit 0 }

    $root = if ($env:OH_HOOK_ROOT) { $env:OH_HOOK_ROOT }
            elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR }
            elseif ($payload.cwd) { $payload.cwd }
            else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $kbDir = if ($env:OH_HOOK_KB_DIR) { $env:OH_HOOK_KB_DIR } else { Join-Path $root '.claude\knowledge-base' }
    if (-not (Test-Path -LiteralPath $kbDir)) { New-Item -ItemType Directory -Path $kbDir -Force | Out-Null }

    $outFile = Join-Path $kbDir 'agents_logs_raw.tsv'
    $v1File = Join-Path $kbDir 'agents_logs_raw_v1.tsv'
    $lockFile = Join-Path $kbDir 'agents_logs_raw.lock'
    $enc = [System.Text.UTF8Encoding]::new($false)
    $nowUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    # --- migracja: plik w STARYM formacie (kolumna output_tokens) -> _v1, zaczynamy nowy ---
    if (Test-Path -LiteralPath $outFile) {
        $h = ''
        $sr = $null
        try { $sr = New-Object System.IO.StreamReader($outFile); $h = $sr.ReadLine() } catch {} finally { if ($sr) { $sr.Close(); $sr.Dispose() } }
        if ($h -and $h -ne $HEADER) {
            if ($h -eq $HEADER_V2 -or $h -eq $HEADER_V3) {
                # v2/v3 -> v4: nowe kolumny dochodza NA KONCU, wiec stare wiersze sa nadal wazne.
                # NIE kasujemy ich (to jedyna kopia telemetrii) - doklejamy puste pola = "nieznane".
                # paid_total zostaje PUSTY takze dla wierszy v3: ich sumy pochodza z epoki sprzed
                # deduplikacji (zawyzone 2,22x), wiec wyliczenie go tutaj utrwaliloby blad jako dane.
                $pad = if ($h -eq $HEADER_V2) { "`t`t" } else { "`t" }
                $oldLines = [System.IO.File]::ReadAllLines($outFile)
                $upg = New-Object System.Collections.ArrayList
                foreach ($ol in $oldLines) {
                    if ([string]::IsNullOrWhiteSpace($ol)) { continue }
                    if ($ol -eq $HEADER_V2 -or $ol -eq $HEADER_V3) { continue }
                    [void]$upg.Add($ol + $pad)
                }
                [System.IO.File]::WriteAllText($outFile, ($HEADER + "`r`n" + (($upg -join "`r`n")) + "`r`n"), $enc)
            }
            elseif (-not (Test-Path -LiteralPath $v1File)) { Move-Item -LiteralPath $outFile -Destination $v1File -Force }
            else {
                # BYLO: Remove-Item $outFile. To SKASOWALO 286 wierszy telemetrii 2026-09-09: naglowek
                # byl juz v3, _v1.tsv istnialo od 2026-09-02, wiec plik trafil w galaz 'usun'. Zaden
                # nieznany naglowek nie moze konczyc sie kasowaniem jedynej kopii - odkladamy z data.
                $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
                Move-Item -LiteralPath $outFile -Destination ($outFile + ".unknown-header-$stamp.bak") -Force
            }
        }
    }

    # --- lock: rownolegli agenci moga zejsc w tej samej chwili, a robimy REWRITE calego pliku ---
    $fs = $null
    for ($i = 0; $i -lt 25; $i++) {
        try { $fs = [System.IO.File]::Open($lockFile, 'OpenOrCreate', 'ReadWrite', 'None'); break } catch { Start-Sleep -Milliseconds 120 }
    }

    try {
        # --- istniejace wiersze (kolejnosc zachowana), indeks po agent_id (ostatnia kolumna) ---
        $existing = @()
        if (Test-Path -LiteralPath $outFile) {
            $all = [System.IO.File]::ReadAllLines($outFile)
            foreach ($l in $all) {
                if ([string]::IsNullOrWhiteSpace($l)) { continue }
                if ($l -eq $HEADER) { continue }
                $existing += $l
            }
        }

        # --- stan wierszy juz zapisanych: agent_id -> complete oraz agent_id -> utc pomiaru ---
        $known = @{}
        $knownUtc = @{}
        foreach ($l in $existing) {
            $c = $l -split "`t"
            $kid = if ($c.Length -gt $COL_AGENT_ID) { $c[$COL_AGENT_ID] } else { $c[$c.Length - 1] }
            $kcm = if ($c.Length -gt $COL_COMPLETE) { $c[$COL_COMPLETE] } else { '' }
            if ($kid) { $known[$kid] = $kcm; $knownUtc[$kid] = $c[$COL_UTC] }
        }

        # --- przelicz agent-*.jsonl tej sesji (upsert, nie append) ---
        # SubagentStop: WSZYSTKIE (transkrypt biezacego agenta bywa niekompletny, a UPSERT dopelnia
        # tez wiersze poprzednikow). UserPromptSubmit (drugi przebieg): tylko pliki MLODSZE niz
        # znacznik 'utc' wiersza - od v4 'complete' nie mowi juz nic o kompletnosci DANYCH (N3),
        # wiec kryterium jest mtime. Gdy nic sie nie dopisalo, hook nie czyta ani jednego jsonl.
        $fresh = [ordered]@{}
        foreach ($af in (Get-ChildItem -LiteralPath $subDir -Filter 'agent-*.jsonl' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)) {
            $aid = [System.IO.Path]::GetFileNameWithoutExtension($af.Name)
            if ($selective -and $knownUtc.ContainsKey($aid)) {
                $rowUtc = $null
                try { $rowUtc = [datetime]::Parse($knownUtc[$aid], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch {}
                if ($rowUtc -and $af.LastWriteTimeUtc -lt $rowUtc) { continue }
            }
            # STICKY: raz ustawione complete=1 przezywa pelny skan (inaczej kolejny SubagentStop
            # innego agenta wyzerowalby flage wszystkim poprzednikom).
            $cmp = 0
            if ($known.ContainsKey($aid) -and $known[$aid] -eq '1') { $cmp = 1 }
            elseif ($stopAgentId -and $aid -eq $stopAgentId) { $cmp = 1 }
            $row = Get-AgentRow -JsonlPath $af.FullName -Sess8 $sess8 -NowUtc $nowUtc -Complete $cmp
            if ($row) { $fresh[$aid] = $row }
        }
        if ($fresh.Count -gt 0) {
            $final = New-Object System.Collections.ArrayList
            $placed = @{}
            foreach ($l in $existing) {
                $cols = $l -split "`t"
                $aid = if ($cols.Length -gt $COL_AGENT_ID) { $cols[$COL_AGENT_ID] } elseif ($cols.Length -ge 1) { $cols[$cols.Length - 1] } else { '' }
                if ($aid -and $fresh.Contains($aid)) {
                    if (-not $placed.ContainsKey($aid)) { [void]$final.Add($fresh[$aid]); $placed[$aid] = $true }
                } else {
                    [void]$final.Add($l)
                }
            }
            foreach ($aid in @($fresh.Keys)) {
                if (-not $placed.ContainsKey($aid)) { [void]$final.Add($fresh[$aid]); $placed[$aid] = $true }
            }

            $tmp = $outFile + '.tmp'
            [System.IO.File]::WriteAllText($tmp, ($HEADER + "`r`n" + (($final -join "`r`n")) + "`r`n"), $enc)
            Move-Item -LiteralPath $tmp -Destination $outFile -Force
        }
    }
    finally {
        if ($fs) { $fs.Close(); $fs.Dispose() }
    }
}
catch {
    # celowo cicho - telemetria nie moze nigdy przeszkodzic w pracy
}

exit 0
