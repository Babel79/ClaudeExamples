$hookSrc = Join-Path $PSScriptRoot 'alert-mutation-leftover.ps1'
$fail = 0

# Hook liczy $root = $PSScriptRoot\..\.. (wzgledem WLASNEJ lokalizacji) i czyta
# <root>\.claude\MUTATION_ALERT.txt. Zeby NIE dotykac realnego pliku alertu w tym
# repo (czytany przez ZYWY hook kazdej sesji - falszywy alarm dla Orchestratora!),
# kopiujemy hooka NIEZMIENIONEGO do <tmp>\.claude\hooks\ i tam podstawiamy alertFile.
$tmp = Join-Path $env:TEMP ("oh-hooktest-mutalert-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$hooksDir = Join-Path $tmp '.claude\hooks'
New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
$hook = Join-Path $hooksDir 'alert-mutation-leftover.ps1'
Copy-Item -LiteralPath $hookSrc -Destination $hook -Force
$alertFile = Join-Path $tmp '.claude\MUTATION_ALERT.txt'

function Invoke-Hook($stdin) {
  if ($null -eq $stdin) { return ('' | & powershell.exe -NoProfile -File $hook) -join '' }
  return ($stdin | & powershell.exe -NoProfile -File $hook) -join ''
}

function Assert($name, $cond, $extra) {
  if ($cond) { Write-Output ("[OK  ] {0}" -f $name) } else { $script:fail++; Write-Output ("[FAIL] {0} {1}" -f $name, $extra) }
}

try {
  # --- MA PRZECHODZIC: plik alertu NIE ISTNIEJE -> SILENT ---
  if (Test-Path -LiteralPath $alertFile) { Remove-Item -LiteralPath $alertFile -Force }
  $out1 = Invoke-Hook '{"hook_event_name":"UserPromptSubmit"}'
  Assert 'brak MUTATION_ALERT.txt -> brak outputu' ([string]::IsNullOrWhiteSpace($out1)) $out1

  # --- MUSI WSTRZYKNAC: plik istnieje z tresci ---
  Set-Content -LiteralPath $alertFile -Value 'Marker mutacji: Foo.cs linia 42 zawiera XXX_MUTATED_XXX' -Encoding utf8
  $out2 = Invoke-Hook '{"hook_event_name":"UserPromptSubmit"}'
  Assert 'MUTATION_ALERT.txt istnieje -> additionalContext' ($out2 -match 'additionalContext') $out2
  Assert 'tresc zawiera "MUTATION LEFTOVER"' ($out2 -match 'MUTATION LEFTOVER')
  # ZMIENIONE 2026-09-08 (H2, portabilizacja hookow): hook juz nie doklada prefiksu GM.
  # do numeru karty (projekt-specyficzny prefiks nie ma sensu w 4 innych projektach).
  Assert 'tresc zawiera "ENV.70"' ($out2 -match 'ENV\.70')
  Assert 'tresc zawiera oryginalna zawartosc pliku alertu' ($out2 -match 'XXX_MUTATED_XXX')
  Assert 'wyjscie jest poprawnym JSON' ($null -ne ($out2 | ConvertFrom-Json))

  # --- plik istnieje ale PUSTY/whitespace -> SILENT ---
  Set-Content -LiteralPath $alertFile -Value '   ' -Encoding utf8
  $out3 = Invoke-Hook '{"hook_event_name":"UserPromptSubmit"}'
  Assert 'MUTATION_ALERT.txt pusty/whitespace -> brak outputu' ([string]::IsNullOrWhiteSpace($out3)) $out3

  # --- tresc > 4000 znakow -> UCIETA z markerem [...uciete] ---
  $long = 'X' * 4500
  Set-Content -LiteralPath $alertFile -Value $long -Encoding ascii
  $out4 = Invoke-Hook '{"hook_event_name":"UserPromptSubmit"}'
  Assert 'dlugi alert -> uciety z markerem [...uciete]' ($out4 -match '\[\.\.\.uciete\]') $out4
  Assert 'dlugi alert -> NIE zawiera pelnych 4500 X (uciete)' ($out4 -notmatch ('X' * 4500))

  # --- pusty stdin (hook nie czyta stdin do tresci alertu, ale nie moze sie wywalic) -> alert nadal wykryty ---
  Set-Content -LiteralPath $alertFile -Value 'test tresc' -Encoding utf8
  $out5 = Invoke-Hook $null
  Assert 'pusty stdin, alert istnieje -> hook i tak dziala (nie czyta stdin)' ($out5 -match 'additionalContext') $out5

  # --- SAMO-WERYFIKACJA (H3a): pozycja cytuje plik, ktory JUZ NIE zawiera markera -> wygasla ---
  # Format pozycji identyczny jak zapisywany przez mutation-leftover-detector.ps1: "  <sciezka> : <nr> : <tresc>"
  $cleanFile = Join-Path $tmp 'CleanNow.cs'
  1..6 | ForEach-Object { "linia $_" } | Set-Content -LiteralPath $cleanFile -Encoding utf8
  Set-Content -LiteralPath $alertFile -Value '  CleanNow.cs : 5 : // niegdys byl tu marker mutacji' -Encoding utf8
  $out6 = Invoke-Hook '{"hook_event_name":"UserPromptSubmit"}'
  Assert 'pozycja bez markera w pliku -> wygasla, brak wstrzykniecia' ([string]::IsNullOrWhiteSpace($out6)) $out6
  Assert 'wszystkie pozycje wygasly -> alert samoczynnie skasowany' (-not (Test-Path -LiteralPath $alertFile))

  # --- SAMO-WERYFIKACJA (H3a): pozycja cytuje plik, ktory NADAL zawiera marker -> wstrzykniete ---
  $liveFile = Join-Path $tmp 'StillMutated.cs'
  @('a','b','c','d', '// MUTATION zywy marker', 'f') | Set-Content -LiteralPath $liveFile -Encoding utf8
  Set-Content -LiteralPath $alertFile -Value '  StillMutated.cs : 5 : // MUTATION zywy marker' -Encoding utf8
  $out7 = Invoke-Hook '{"hook_event_name":"UserPromptSubmit"}'
  Assert 'pozycja z zywym markerem -> wstrzykniete' ($out7 -match 'additionalContext') $out7
  Assert 'tresc potwierdza ponowny odczyt (POTWIERDZONE)' ($out7 -match 'POTWIERDZONE')
  Assert 'tresc cytuje StillMutated.cs' ($out7 -match 'StillMutated\.cs')
  Assert 'zywy alert NIE zostal skasowany z dysku' (Test-Path -LiteralPath $alertFile)

  # --- SAMO-WERYFIKACJA (H3a): blad odczytu cytowanego pliku (sciezka nie istnieje) -> FAIL-CLOSED, alert zostaje ---
  Set-Content -LiteralPath $alertFile -Value '  Nieistniejacy/Duch.cs : 1 : // MUTATION widmo' -Encoding utf8
  $out8 = Invoke-Hook '{"hook_event_name":"UserPromptSubmit"}'
  Assert 'cytowany plik nie istnieje -> fail-closed, wstrzykniete (nie zniknelo po cichu)' ($out8 -match 'additionalContext') $out8
  Assert 'fail-closed: alert NIE zostal skasowany mimo nieodczytywalnego pliku' (Test-Path -LiteralPath $alertFile)

  # ============================================================================
  # WERSJA 3 (Optymalizacja B, 2026-09-10) - ROZROZNIENIE TONU wg "czy ktos jeszcze pracuje".
  # Izolacja: kbDir wyliczany przez hook to $root\.claude\knowledge-base, a $root w tym
  # srodowisku testowym = $tmp (kopia hooka + fallback bez cwd/env) - wiec pliki telemetrii
  # tworzymy pod $tmp\.claude\knowledge-base i NIC nie dotyka realnej telemetrii tego repo.
  # ============================================================================
  $kbDirTest = Join-Path $tmp '.claude\knowledge-base'
  New-Item -ItemType Directory -Path $kbDirTest -Force | Out-Null
  $logsTsv = Join-Path $kbDirTest 'agents_logs_raw.tsv'
  $dispTsv = Join-Path $kbDirTest 'agents_dispatch_raw.tsv'
  $logsHeader = "utc`tsession8`tagent_type`tmodel`tout_tokens`tin_tokens`tcache_create`tcache_read`tharness_equiv`tturns`ttool_uses`tduration_sec`tdescription`tagent_id`tcomplete`tpaid_total"

  # --- PRZYPADEK 1: marker + "agent pracuje" (wiersz complete=0 dla tej sesji) -> TON INFORMACYJNY ---
  Set-Content -LiteralPath $logsTsv -Encoding utf8 -Value @(
    $logsHeader,
    "2026-09-10T10:00:00Z`tliveSess`t05-api-agent`tclaude-sonnet-5`t100`t10`t100`t100`t210`t5`t5`t60`ttest`tagent-live-1`t0`t320"
  )
  if (Test-Path -LiteralPath $dispTsv) { Remove-Item -LiteralPath $dispTsv -Force }
  @('a','b','c','d', '// MUTATION zywy marker', 'f') | Set-Content -LiteralPath $liveFile -Encoding utf8
  Set-Content -LiteralPath $alertFile -Value '  StillMutated.cs : 5 : // MUTATION zywy marker' -Encoding utf8
  $out9 = Invoke-Hook '{"hook_event_name":"UserPromptSubmit","session_id":"liveSess-agent-B-running"}'
  Assert 'ktos jeszcze pracuje -> wstrzykniete (additionalContext)' ($out9 -match 'additionalContext') $out9
  Assert 'ktos jeszcze pracuje -> ton INFORMACYJNY ([i]/INFO)' ($out9 -match '\[i\]' -and $out9 -match 'INFO') $out9
  Assert 'ktos jeszcze pracuje -> BRAK kategorycznego "NIE commituj"' ($out9 -notmatch 'NIE commituj') $out9
  Assert 'ktos jeszcze pracuje -> zywy alert NIE zostal skasowany' (Test-Path -LiteralPath $alertFile)

  # --- PRZYPADEK 2: marker + "nikt nie pracuje" (ten sam plik telemetrii, ale INNA sesja / brak wiersza) -> TON OSTRY (bez zmian) ---
  Set-Content -LiteralPath $alertFile -Value '  StillMutated.cs : 5 : // MUTATION zywy marker' -Encoding utf8
  $out10 = Invoke-Hook '{"hook_event_name":"UserPromptSubmit","session_id":"nobodyworks-session-id"}'
  Assert 'nikt nie pracuje -> wstrzykniete (additionalContext)' ($out10 -match 'additionalContext') $out10
  Assert 'nikt nie pracuje -> ton OSTRY (kategoryczny "NIE commituj")' ($out10 -match 'NIE commituj') $out10
  Assert 'nikt nie pracuje -> BRAK tonu informacyjnego ([i]/INFO)' ($out10 -notmatch '\[i\]' -and $out10 -notmatch '- INFO') $out10

  # --- PRZYPADEK 3: brak PLIKOW telemetrii wcale (inny z 4 projektow, bez historii agentow) -> domyslnie TON OSTRY ---
  Remove-Item -LiteralPath $kbDirTest -Recurse -Force -ErrorAction SilentlyContinue
  Set-Content -LiteralPath $alertFile -Value '  StillMutated.cs : 5 : // MUTATION zywy marker' -Encoding utf8
  $out11 = Invoke-Hook '{"hook_event_name":"UserPromptSubmit","session_id":"any-session"}'
  Assert 'brak telemetrii -> domyslnie ton OSTRY (bezpieczny default)' ($out11 -match 'NIE commituj') $out11

  # --- PRZYPADEK 4: zero wierszy dla TEJ sesji w logs, ALE dispatch > 0 zdarzen dla niej (swiezo zdispatchowany agent) -> INFORMACYJNY ---
  New-Item -ItemType Directory -Path $kbDirTest -Force | Out-Null
  Set-Content -LiteralPath $logsTsv -Encoding utf8 -Value @($logsHeader)   # tylko naglowek, zero wierszy
  $dispHeader = "ts`tsession_id`tsubagent_type`tmodel`tdescription"
  Set-Content -LiteralPath $dispTsv -Encoding utf8 -Value @(
    $dispHeader,
    "2026-09-10T10:00:00Z`tfreshDispatchSession`t05-api-agent`tsonnet`tswiezy dispatch"
  )
  Set-Content -LiteralPath $alertFile -Value '  StillMutated.cs : 5 : // MUTATION zywy marker' -Encoding utf8
  $out12 = Invoke-Hook '{"hook_event_name":"UserPromptSubmit","session_id":"freshDispatchSession"}'
  Assert 'swiezy dispatch bez wiersza w logs -> ton INFORMACYJNY (fallback dispatch>captured)' ($out12 -match '\[i\]' -and $out12 -match 'INFO') $out12
}
finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# potwierdzenie ze REALNY plik alertu w repo NIE zostal utworzony przez ten test
# (ta sama formula co fallback hooka: $PSScriptRoot\..\.. wzgledem WLASNEJ lokalizacji suity,
# a suita lezy obok hooka - wiec dziala z dowolnej lokalizacji repo)
$realAlert = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.claude\MUTATION_ALERT.txt'
if (-not (Test-Path -LiteralPath $realAlert)) { Write-Output '[OK  ] realny .claude\MUTATION_ALERT.txt nadal nie istnieje (test go nie utworzyl)' }
else { $fail++; Write-Output '[FAIL] UWAGA: realny .claude\MUTATION_ALERT.txt ISTNIEJE - sprawdz recznie, czy to nie test' }

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
