# alert-mutation-leftover.ps1 - UserPromptSubmit hook. Para dla mutation-leftover-detector.ps1.
# Karta ENV.70 tego projektu.
#
# Detektor (SubagentStop) tylko ZAPISUJE plik alertu - nie ma jak dostarczyc tresci do Orchestratora.
# Ten hook go PODNOSI przy najblizszej turze i wstrzykuje na wierzch kontekstu.
#
# KOSZT: ZERO gdy czysto (exit 0 bez outputu, plik alertu nie istnieje).
#
# --- WERSJA 2 (portabilizacja H3a) - SAMO-WERYFIKACJA. Karta ENV.6 tego projektu. ---
# PROBLEM v1: hook wstrzykiwal tresc alertu NA SLEPO, bez sprawdzenia czy marker nadal istnieje.
#   Detektor (SubagentStop) potrafi zlapac stan PRZEJSCIOWY w srodku kontrdowodu - agent mutuje
#   plik, uruchamia test, przywraca. Jesli detektor zmierzy w oknie miedzy mutacja a rewertem,
#   zapisuje alert opisujacy kod, ktorego juz nie ma. v1 nie mial jak sie o tym dowiedziec:
#   alert zyl az do RECZNEGO skasowania pliku i krzyczal przy KAZDEJ turze.
#
# DLACZEGO TO GROZNE, a nie tylko uciazliwe: przy powtorzeniu odruch "to znowu to samo" jest
#   silny, a falszywy alarm wyglada IDENTYCZNIE jak prawdziwy. Dzien, w ktorym zignorujemy
#   realny leftover, bedzie wygladal tak samo jak kazdy poprzedni.
#
# FIX: przed wstrzyknieciem hook PONOWNIE czyta cytowane pliki i sprawdza, czy marker tam jeszcze
#   jest. Zero ocalalych -> kasuje przeterminowany alert i milczy (system samoczyszczacy).
#   Czesc ocalala -> wstrzykuje WYLACZNIE ja, z adnotacja ile pozycji wygaslo.
#   Nie da sie odczytac pliku (skasowany w miedzyczasie, zajety) -> traktuj pozycje jako OCALALA
#   (fail-closed: przy watpliwosci alarmuj, bo koszt przeoczonej mutacji jest wyzszy niz koszt
#   jednego alarmu).
#   Alert w formacie innym niz ten zapisywany przez detektor (np. recznie utworzony do testu) ->
#   brak rozpoznawalnych pozycji -> przepusc BEZ ZMIAN (nie umiemy zweryfikowac, fail-closed).
#
# --- WERSJA 3 (Optymalizacja B, 2026-09-10) - ROZROZNIENIE TONU wg "czy ktos jeszcze pracuje". ---
# PROBLEM v2: zmierzone 2026-09-10 - hook strzelil ~20x w jednej sesji na mutacje kontrdowodowe,
#   ktore byly ZYWE i celowe (naleznaly do agentow AKTUALNIE wykonujacych kontrdowod: mutacja ->
#   sprawdz czerwien -> rewert). Sama samo-weryfikacja v2 (marker fizycznie NADAL w pliku) nie
#   odroznia "agent jeszcze nie zdazyl zrewertowac" od "agent zszedl i nikt juz tego nie posprzata"
#   - w obu przypadkach marker jest fizycznie obecny. Tresc alertu byla kategoryczna ("NIE commituj,
#   NIE otwieraj PR i NIE dispatchuj kolejnego agenta, zanim tego nie zrewertujesz") - czyli kazala
#   Orchestratorowi wstrzymac prace i zrewertowac CUDZA, TRWAJACA prace. Orchestrator musial to
#   ~20x swiadomie zignorowac, co uczy ignorowania alertow ktore bywaja prawdziwe.
#
# FIX: PRZED wyborem tresci hook sprawdza, czy w BIEZACEJ SESJI jest jakis subagent, ktory
#   (a) ma w agents_logs_raw.tsv wiersz z complete<>1, albo (b) zostal zdispatchowany
#   (agents_dispatch_raw.tsv) czesciej niz mamy dla niego JAKIKOLWIEK wiersz w agents_logs_raw.tsv
#   (agent tak swiezy, ze telemetria jeszcze nie zdazyla go zlapac).
#   ZRODLO WYBRANE PO WERYFIKACJI (nie na slepo): telemetria v4 (agent-telemetry-capture.ps1)
#   zmienila definicje kolumny 'complete' 2026-09-09 - "complete=1 <=> harness zglosil SubagentStop
#   DLA TEGO agent_id" (sticky). Stara definicja (v3, oparta o stop_reason) NIGDY sie nie domykala
#   (74% wierszy complete=0 na zawsze) - to jest dokladnie luka opisana w GM.ENV.135 tego projektu,
#   ale dotyczy STAREJ wersji telemetrii. Potwierdzone EMPIRYCZNIE na zywym pliku tego repo
#   (.claude/knowledge-base/agents_logs_raw.tsv, sesja d620b60b, 2026-09-10): wszystkie zakonczone
#   agenty maja complete=1, a DWA agenty faktycznie jeszcze dzialajace w chwili pomiaru (rownolegle
#   do tego zadania) maja complete=0 - flaga dziala zgodnie z nowa definicja.
#   Znane ograniczenie (uczciwie, nie ukrywane): agent ktory padnie NIGDY nie generujac SubagentStop
#   dla wlasnego agent_id zostawi wiersz z complete=0 NA STALE - taki wiersz bedzie do konca sesji
#   falszywie odczytywany jako "ktos jeszcze pracuje". Skutek jest ASYMETRYCZNY i celowo bezpieczny:
#   zamiast falszywego OSTREGO alarmu (szkodliwy - kaze rewertowac cudza prace) dostajemy najwyzej
#   falszywy ton INFORMACYJNY (nieszkodliwy - kaze sprawdzic ponownie pozniej). Brak obu plikow
#   telemetrii (np. inny z 4 projektow bez historii agentow) -> sygnal niedostepny -> DOMYSLNIE
#   zachowanie SPRZED tej zmiany (ostry alert), zeby nie oslabic ochrony tam, gdzie nie mamy dowodu.
#
# ASCII-only (PS 5.1 czyta .ps1 jako ANSI). Non-blocking - kazdy blad konczy sie exit 0.
$ErrorActionPreference = 'SilentlyContinue'

function Test-SubagentLikelyLive {
  param([string]$KbDir, [string]$SessionId, [string]$Sess8)
  try {
    if ([string]::IsNullOrWhiteSpace($Sess8)) { return $false }

    $logsFile = Join-Path $KbDir 'agents_logs_raw.tsv'
    $dispFile = Join-Path $KbDir 'agents_dispatch_raw.tsv'

    $distinctAgents = 0
    $incompleteFound = $false
    if (Test-Path -LiteralPath $logsFile) {
      foreach ($line in [System.IO.File]::ReadLines($logsFile)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $cols = $line -split "`t"
        if ($cols[0] -eq 'utc') { continue }   # naglowek
        if ($cols.Length -lt 2 -or $cols[1] -ne $Sess8) { continue }
        $distinctAgents++
        $completeVal = if ($cols.Length -gt 14) { $cols[14] } else { '' }
        if ($completeVal -ne '1') { $incompleteFound = $true }
      }
    }
    if ($incompleteFound) { return $true }

    if ((-not [string]::IsNullOrWhiteSpace($SessionId)) -and (Test-Path -LiteralPath $dispFile)) {
      $dispatched = 0
      foreach ($line in [System.IO.File]::ReadLines($dispFile)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $cols = $line -split "`t"
        if ($cols[0] -eq 'ts') { continue }   # naglowek
        if ($cols.Length -lt 2 -or $cols[1] -ne $SessionId) { continue }
        $dispatched++
      }
      if ($dispatched -gt $distinctAgents) { return $true }
    }

    return $false
  } catch {
    return $false   # brak dowodu -> NIE zmiekczaj tonu (domyslne = stare zachowanie: ostry alert)
  }
}

try {
  $cwd = $null
  $sessionId = $null
  try {
    $raw = [Console]::In.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      $j = $raw | ConvertFrom-Json
      if ($j.cwd) { $cwd = [string]$j.cwd }
      if ($j.session_id) { $sessionId = [string]$j.session_id }
    }
  } catch { }

  $root = if ($env:OH_HOOK_ROOT) { $env:OH_HOOK_ROOT }
          elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR }
          elseif ($cwd) { $cwd }
          else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $kbDir = if ($env:OH_HOOK_KB_DIR) { $env:OH_HOOK_KB_DIR } else { Join-Path $root '.claude\knowledge-base' }
  $sess8 = if ($sessionId -and $sessionId.Length -ge 8) { $sessionId.Substring(0,8) } elseif ($sessionId) { $sessionId } else { $null }
  $someoneLive = Test-SubagentLikelyLive -KbDir $kbDir -SessionId $sessionId -Sess8 $sess8

  $alertFile = Join-Path $root '.claude\MUTATION_ALERT.txt'
  if (-not (Test-Path -LiteralPath $alertFile)) { exit 0 }

  $content = [System.IO.File]::ReadAllText($alertFile)
  if ([string]::IsNullOrWhiteSpace($content)) { exit 0 }

  # --- SAMO-WERYFIKACJA: czy cytowane markery NADAL sa w plikach? ---
  # Format pozycji zapisywanej przez detektor: "  <sciezka> : <nr linii> : <tresc linii>"
  $markerRx = '\b(MUTATION|MUTACJA|MUTANT)\b'
  $tempRx   = '(DO NOT COMMIT|NIE COMMITOWAC)'

  $alive    = @()
  $expired  = 0
  $sawEntry = $false

  foreach ($line in ($content -split "`r?`n")) {
    if ($line -notmatch '^\s{2}(\S.*?)\s:\s(\d+)\s:\s(.*)$') { continue }
    $sawEntry = $true
    $rel = $Matches[1]
    $full = Join-Path $root $rel

    if (-not (Test-Path -LiteralPath $full)) {
      # Plik zniknal - nie mozemy potwierdzic czystosci. Fail-closed: zostaw pozycje.
      $alive += $line
      continue
    }

    $stillThere = $false
    try {
      foreach ($fileLine in [System.IO.File]::ReadLines($full)) {
        if (($fileLine -cmatch $markerRx) -or ($fileLine -cmatch $tempRx)) { $stillThere = $true; break }
      }
    } catch {
      $stillThere = $true   # nie udalo sie odczytac -> fail-closed
    }

    if ($stillThere) { $alive += $line } else { $expired++ }
  }

  # Alert bez rozpoznawalnych pozycji (inny format / recznie napisany) - nie umiemy
  # zweryfikowac -> fail-closed, przepusc bez zmian (ucinajac tylko na dlugosc jak dawniej).
  if (-not $sawEntry) {
    $body = $content
    if ($body.Length -gt 4000) { $body = $body.Substring(0,4000) + "`r`n[...uciete]" }
    if ($someoneLive) {
      $msg = "[i][MUTATION LEFTOVER - ENV.70 - INFO] Hook SubagentStop wykryl marker mutacji w kodzie produkcyjnym. W tej sesji jest (prawdopodobnie) INNY dzialajacy subagent - marker moze nalezec do JEGO trwajacego kontrdowodu (mutacja -> test -> rewert). NIE rewertuj cudzej pracy w toku. Sprawdz ponownie PO zejsciu fali (gdy zaden subagent juz nie dziala) - jesli marker wtedy nadal tu bedzie, to realny leftover. Szczegoly:`r`n" + $body
    } else {
      $msg = "[!!! MUTATION LEFTOVER - ENV.70 !!!] Hook SubagentStop wykryl marker mutacji w KODZIE PRODUKCYJNYM po zejsciu subagenta. Kod SIE KOMPILUJE - zielony build NIE jest dowodem czystosci. NIE commituj, NIE otwieraj PR i NIE dispatchuj kolejnego agenta, zanim tego nie zrewertujesz i nie skasujesz .claude/MUTATION_ALERT.txt. Szczegoly:`r`n" + $body
    }
    $out = @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = $msg } } | ConvertTo-Json -Compress -Depth 5
    Write-Output $out
    exit 0
  }

  # WSZYSTKIE pozycje wygasly -> alert byl przeterminowany. Skasuj i milcz.
  if ($alive.Count -eq 0) {
    Remove-Item -LiteralPath $alertFile -Force -ErrorAction SilentlyContinue
    $logFile = Join-Path $root '.claude\knowledge-base\mutation_alerts.log'
    $nowUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $enc = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText($logFile, "$nowUtc`tAUTO-CLEARED`t$expired pozycji wygaslo (marker juz nie istnieje) - alert skasowany bez alarmowania`r`n", $enc)
    exit 0
  }

  # Czesc ocalala -> alarmuj WYLACZNIE o niej.
  $body = @()
  $body += "MUTATION LEFTOVER - pozycje POTWIERDZONE ponownym odczytem plikow ($($alive.Count)):"
  $body += $alive
  if ($expired -gt 0) {
    $body += ""
    $body += "(Pominieto $expired pozycji, ktore juz nie istnieja w plikach - agent zdazyl je przywrocic.)"
  }
  $body += ""
  $body += "CO ZROBIC: zrewertuj mutacje RECZNIE. Dowod czystosci: brak markera w pliku ORAZ przebieg"
  $body += "testu, ktory przy zywej mutacji musialby padnac. Po posprzataniu skasuj .claude/MUTATION_ALERT.txt"

  $joined = ($body -join "`r`n")
  if ($joined.Length -gt 4000) { $joined = $joined.Substring(0,4000) + "`r`n[...uciete]" }

  if ($someoneLive) {
    $msg = "[i][MUTATION LEFTOVER - ENV.70 - INFO] Marker mutacji w kodzie produkcyjnym, potwierdzony ponownym odczytem pliku. W tej sesji jest (prawdopodobnie) INNY dzialajacy subagent - marker moze nalezec do JEGO trwajacego kontrdowodu (mutacja -> test -> rewert). NIE rewertuj cudzej pracy w toku. Sprawdz ponownie PO zejsciu fali (gdy zaden subagent juz nie dziala) - jesli marker wtedy nadal tu bedzie, to realny leftover i wymaga rewertu.`r`n" + $joined
  } else {
    $msg = "[!!! MUTATION LEFTOVER - ENV.70 !!!] Marker mutacji w KODZIE PRODUKCYJNYM, potwierdzony ponownym odczytem pliku. Kod SIE KOMPILUJE - zielony build NIE jest dowodem czystosci. NIE commituj, NIE otwieraj PR i NIE dispatchuj kolejnego agenta, zanim tego nie zrewertujesz.`r`n" + $joined
  }

  $out = @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = $msg } } | ConvertTo-Json -Compress -Depth 5
  Write-Output $out
  exit 0
} catch { exit 0 }
