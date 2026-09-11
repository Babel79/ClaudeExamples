$hook = Join-Path $PSScriptRoot 'agent-telemetry-capture.ps1'
$fail = 0
$tmp = Join-Path $env:TEMP ("oh-hooktest-telemetry-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$kb  = Join-Path $tmp 'kb'
$sub = Join-Path $tmp 'sess\subagents'
New-Item -ItemType Directory -Path $kb -Force | Out-Null
New-Item -ItemType Directory -Path $sub -Force | Out-Null
$env:OH_HOOK_KB_DIR = $kb
$tsv = Join-Path $kb 'agents_logs_raw.tsv'
$a1  = Join-Path $sub 'agent-t1.jsonl'
$HEADER_V2 = "utc`tsession8`tagent_type`tmodel`tout_tokens`tin_tokens`tcache_create`tcache_read`tharness_equiv`tturns`ttool_uses`tduration_sec`tdescription`tagent_id"
$HEADER_V3 = $HEADER_V2 + "`tcomplete"
$HEADER = $HEADER_V3 + "`tpaid_total"
$COL_AGENT_ID = 13
$COL_COMPLETE = 14
$COL_PAID = 15

function Assert($name, $cond, $extra) {
  if ($cond) { Write-Output ("[OK  ] {0}" -f $name) } else { $script:fail++; Write-Output ("[FAIL] {0} {1}" -f $name, $extra) }
}
# $agentTranscript trafia do payloadu jako agent_transcript_path. Od v4 nazwa TEGO pliku decyduje,
# ktory wiersz dostaje complete=1 - dlatego kazde wywolanie musi wskazywac wlasciwego agenta.
function Invoke-Hook($agentTranscript, $evt) {
  if (-not $evt) { $evt = 'SubagentStop' }
  $json = @{ hook_event_name=$evt; session_id='deadbeef12345678'
             transcript_path=(Join-Path $tmp 'sess.jsonl'); agent_transcript_path=$agentTranscript
             agent_id='t1'; agent_type='05-api-agent'; last_assistant_message='done' } | ConvertTo-Json -Compress -Depth 6
  return ($json | & powershell.exe -NoProfile -File $hook) -join ''
}
function Get-Row($agentId, $file) {
  if (-not $file) { $file = $tsv }
  foreach ($l in (Get-Content $file)) {
    $c = $l -split "`t"
    if ($c.Length -gt $COL_AGENT_ID -and $c[$COL_AGENT_ID] -eq $agentId) { return $c }
  }
  return $null
}

# L1 = tura z narzedziem, L3 = ostatnia linia BEZ stop_reason (rekord apiBlockIndex=0, na takim
# rekordzie transkrypt agenta konczy sie TRWALE - to jest powod zmiany definicji 'complete' w v4),
# L4 = kolejna tura, L5 = tura dolozona po wznowieniu agenta przez SendMessage.
$L1 = '{"timestamp":"2026-09-02T10:00:00.000Z","message":{"role":"assistant","id":"m1","model":"claude-test","stop_reason":"tool_use","usage":{"input_tokens":5,"output_tokens":100,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0},"content":[{"type":"tool_use","name":"Read"}]}}'
$L2 = '{"timestamp":"2026-09-02T10:00:10.000Z","message":{"role":"user","content":"x"}}'
$L3 = '{"timestamp":"2026-09-02T10:01:00.000Z","message":{"role":"assistant","id":"m2","model":"claude-test","usage":{"input_tokens":2,"output_tokens":50,"cache_creation_input_tokens":200,"cache_read_input_tokens":1100},"content":[{"type":"text","text":"raport"}]}}'
$L4 = '{"timestamp":"2026-09-02T10:02:00.000Z","message":{"role":"assistant","id":"m3","model":"claude-test","stop_reason":"end_turn","usage":{"input_tokens":3,"output_tokens":70,"cache_creation_input_tokens":300,"cache_read_input_tokens":1350},"content":[{"type":"text","text":"koniec"}]}}'
$L5 = '{"timestamp":"2026-09-02T10:03:00.000Z","message":{"role":"assistant","id":"m4","model":"claude-test","stop_reason":"end_turn","usage":{"input_tokens":4,"output_tokens":80,"cache_creation_input_tokens":400,"cache_read_input_tokens":2000},"content":[{"type":"text","text":"jeszcze raz"}]}}'
# D1-D3 = JEDNA wiadomosc asystenta zapisana jako TRZY rekordy (apiBlockIndex 0..2) z tym samym
# message.id i tym samym usage; ostatni niesie komplet output_tokens. To jest defekt N1.
$D1 = '{"timestamp":"2026-09-02T11:00:00.000Z","message":{"role":"assistant","id":"m9","model":"claude-test","usage":{"input_tokens":10,"output_tokens":0,"cache_creation_input_tokens":500,"cache_read_input_tokens":700},"content":[{"type":"text","text":"a"}]}}'
$D2 = '{"timestamp":"2026-09-02T11:00:01.000Z","message":{"role":"assistant","id":"m9","model":"claude-test","usage":{"input_tokens":10,"output_tokens":40,"cache_creation_input_tokens":500,"cache_read_input_tokens":700},"content":[{"type":"text","text":"b"}]}}'
$D3 = '{"timestamp":"2026-09-02T11:00:02.000Z","message":{"role":"assistant","id":"m9","model":"claude-test","usage":{"input_tokens":10,"output_tokens":90,"cache_creation_input_tokens":500,"cache_read_input_tokens":700},"content":[{"type":"text","text":"c"}]}}'

try {
  # --- migracja formatu v1 (11 kolumn, output_tokens) -> _v1.tsv ---
  Set-Content -LiteralPath $tsv -Value "utc`tsession8`tagent_type`tmodel`toutput_tokens`tinput_tokens_last`tturns`tduration_sec`ttranscript_lines`tdescription`tagent_id" -Encoding ascii
  Add-Content -LiteralPath $tsv -Value "2026-01-01T00:00:00Z`tsess0000`tExplore`tm`t1`t2`t3`t4`t5`tstary`tagent-old" -Encoding ascii

  # --- przebieg 1: plik agenta NIEPELNY (tak jak w chwili SubagentStop) ---
  [System.IO.File]::WriteAllLines($a1, @($L1,$L2,$L3))
  [System.IO.File]::WriteAllText((Join-Path $sub 'agent-t1.meta.json'), '{"agentType":"05-api-agent","description":"test slice"}')
  Invoke-Hook $a1 | Out-Null

  Assert 'stary plik przeniesiony do agents_logs_raw_v1.tsv' (Test-Path (Join-Path $kb 'agents_logs_raw_v1.tsv'))
  Assert 'nowy naglowek 16-kolumnowy (complete + paid_total)' ((Get-Content $tsv -TotalCount 1) -eq $HEADER)
  $r = Get-Row 'agent-t1'
  Assert 'wiersz agent-t1 istnieje' ($null -ne $r)
  Assert 'agent_type z meta.json' ($r[2] -eq '05-api-agent') $r[2]
  Assert 'model z transcriptu' ($r[3] -eq 'claude-test') $r[3]
  Assert 'out_tokens = 150 (suma po dedup)' ($r[4] -eq '150') $r[4]
  Assert 'in_tokens = 7 (suma po dedup)' ($r[5] -eq '7') $r[5]
  Assert 'cache_create = 1200 (suma po dedup)' ($r[6] -eq '1200') $r[6]
  Assert 'cache_read = 1100 (suma po dedup)' ($r[7] -eq '1100') $r[7]
  Assert 'harness_equiv = 1352 (ostatnia linia: 2+50+200+1100)' ($r[8] -eq '1352') $r[8]
  Assert 'turns = 2 (unikalne message.id)' ($r[9] -eq '2') $r[9]
  Assert 'tool_uses = 1' ($r[10] -eq '1') $r[10]
  Assert 'duration_sec = 60' ($r[11] -eq '60') $r[11]
  Assert 'description z meta.json' ($r[12] -eq 'test slice') $r[12]
  # N2: paid_total = in+out+cache_create+cache_read po deduplikacji = 7+150+1200+1100.
  Assert 'paid_total = 2457 (suma czterech kolumn po dedup)' ($r[$COL_PAID] -eq '2457') $r[$COL_PAID]
  # ZMIANA SEMANTYKI v4 (bylo: 'transkrypt uciety (brak stop_reason) -> complete=0').
  # Stary przypadek pinowal definicje opierajaca sie na stop_reason ostatniej linii - ta definicja
  # byla NIENAPRAWIALNA: transkrypt agenta konczy sie trwale na rekordzie bez stop_reason, wiec 74%
  # wierszy mialo complete=0 na zawsze. Od v4 complete=1 <=> przyszedl SubagentStop dla TEGO agenta,
  # a tutaj agent_transcript_path wskazuje wlasnie agent-t1 - mimo ze L3 nie ma stop_reason.
  Assert 'SubagentStop dla agent-t1 -> complete=1 mimo braku stop_reason' ($r[$COL_COMPLETE] -eq '1') $r[$COL_COMPLETE]

  Assert 'wiersz w STARYM formacie odszedl razem z plikiem do _v1' ($null -eq (Get-Row 'agent-old'))
  Assert '_v1 zawiera stary wiersz' ((Get-Content (Join-Path $kb 'agents_logs_raw_v1.tsv') -Raw) -match 'agent-old')

  # --- wiersz obcej sesji w NOWYM formacie musi przezyc rewrite ---
  Add-Content -LiteralPath $tsv -Value "2026-01-01T00:00:00Z`tOTHER111`tExplore`tm`t1`t2`t3`t4`t5`t6`t7`t8`tobca sesja`tagent-foreign`t1`t99" -Encoding ascii

  # --- przebieg 2: plik DOPELNIONY asynchronicznie -> UPSERT, nie drugi wiersz ---
  #     to jest dokladnie bug v1: .seen blokowal powrot i zostawal ogryzek
  [System.IO.File]::WriteAllLines($a1, @($L1,$L2,$L3,$L4))
  Invoke-Hook $a1 | Out-Null
  $rows = @(Get-Content $tsv) | Where-Object { $_ -match 'agent-t1' }
  Assert 'nadal DOKLADNIE 1 wiersz dla agent-t1 (upsert)' ($rows.Count -eq 1) ("jest " + $rows.Count)
  $r = Get-Row 'agent-t1'
  Assert 'harness_equiv zaktualizowany do 1723' ($r[8] -eq '1723') $r[8]
  Assert 'out_tokens zaktualizowany do 220' ($r[4] -eq '220') $r[4]
  Assert 'turns zaktualizowane do 3' ($r[9] -eq '3') $r[9]
  Assert 'paid_total zaktualizowany do 4180 (10+220+1500+2450)' ($r[$COL_PAID] -eq '4180') $r[$COL_PAID]
  Assert 'ponowny SubagentStop dla agent-t1 -> complete nadal 1' ($r[$COL_COMPLETE] -eq '1') $r[$COL_COMPLETE]
  Assert 'wiersz obcej sesji zachowany po rewrite' ($null -ne (Get-Row 'agent-foreign'))
  Assert 'wiersz obcej sesji zachowal paid_total' ((Get-Row 'agent-foreign')[$COL_PAID] -eq '99') (Get-Row 'agent-foreign')[$COL_PAID]

  # --- NOWY (N1): trzy rekordy o wspolnym message.id licza sie RAZ, ostatni wygrywa ---
  $a3 = Join-Path $sub 'agent-t3.jsonl'
  [System.IO.File]::WriteAllLines($a3, @($D1,$D2,$D3))
  Invoke-Hook $a3 | Out-Null
  $r3 = Get-Row 'agent-t3'
  Assert 'dedup: out_tokens = 90 (ostatni rekord wygrywa, nie 130)' ($r3[4] -eq '90') $r3[4]
  Assert 'dedup: in_tokens = 10 (nie 30)' ($r3[5] -eq '10') $r3[5]
  Assert 'dedup: cache_create = 500 (nie 1500)' ($r3[6] -eq '500') $r3[6]
  Assert 'dedup: cache_read = 700 (nie 2100)' ($r3[7] -eq '700') $r3[7]
  Assert 'dedup: turns = 1 (jedna wiadomosc)' ($r3[9] -eq '1') $r3[9]
  Assert 'dedup: paid_total = 1300 (nie 3760)' ($r3[$COL_PAID] -eq '1300') $r3[$COL_PAID]

  # --- NOWY (N3): agent BEZ wlasnego SubagentStop -> complete=0 ---
  # agent-t2 istnieje w katalogu, ale hook wolany jest ze zdarzeniem dla agent-t1: pelny skan
  # zaklada wiersz t2, a ten NIE MOZE dostac complete=1, bo harness nie zglosil jego konca.
  $a2 = Join-Path $sub 'agent-t2.jsonl'
  [System.IO.File]::WriteAllLines($a2, @($L1,$L3))
  Invoke-Hook $a1 | Out-Null
  Assert 'wiersz agent-t2 dopisany przy skanie' ($null -ne (Get-Row 'agent-t2'))
  Assert 'agent bez wlasnego SubagentStop -> complete=0' ((Get-Row 'agent-t2')[$COL_COMPLETE] -eq '0') (Get-Row 'agent-t2')[$COL_COMPLETE]
  Assert 'wiersz agent-t1 nadal jeden' ((@(Get-Content $tsv) | Where-Object { $_ -match 'agent-t1' }).Count -eq 1)

  # --- STICKY: SubagentStop innego agenta NIE kasuje juz ustawionej jedynki ---
  Invoke-Hook $a2 | Out-Null
  Assert 'SubagentStop dla agent-t2 -> jego complete=1' ((Get-Row 'agent-t2')[$COL_COMPLETE] -eq '1') (Get-Row 'agent-t2')[$COL_COMPLETE]
  Assert 'sticky: agent-t1 zachowal complete=1 po pelnym skanie' ((Get-Row 'agent-t1')[$COL_COMPLETE] -eq '1') (Get-Row 'agent-t1')[$COL_COMPLETE]
  Assert 'sticky: agent-t3 zachowal complete=1 po pelnym skanie' ((Get-Row 'agent-t3')[$COL_COMPLETE] -eq '1') (Get-Row 'agent-t3')[$COL_COMPLETE]

  # --- DRUGI PRZEBIEG (UserPromptSubmit): kryterium to mtime pliku, nie flaga 'complete' ---
  # ZMIANA SEMANTYKI v4 (bylo: 'drugi przebieg POMIJA wiersz complete=1'). Stare kryterium przestalo
  # cokolwiek znaczyc, bo od v4 complete=1 dostaje KAZDY agent po SubagentStop, niezaleznie od tego,
  # czy jego transkrypt zdazyl sie dopisac. Kryterium jest teraz 'plik mlodszy niz znacznik utc wiersza'.
  [System.IO.File]::WriteAllLines($a1, @($L1,$L2,$L3,$L4,$L5))
  (Get-Item $a1).LastWriteTimeUtc = [datetime]::Parse('2020-01-01T00:00:00Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
  $o2 = Invoke-Hook $a2 'UserPromptSubmit'
  Assert 'UserPromptSubmit nie pisze nic na stdout (nie zasmieca kontekstu)' ([string]::IsNullOrWhiteSpace($o2)) $o2
  Assert 'drugi przebieg POMIJA plik starszy niz znacznik utc (agent-t1 nadal 1723)' ((Get-Row 'agent-t1')[8] -eq '1723') (Get-Row 'agent-t1')[8]
  # ten sam plik, ale mtime PO znaczniku -> drugi przebieg musi go przeliczyc BEZ SubagentStop
  (Get-Item $a1).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(1)
  Invoke-Hook $a2 'UserPromptSubmit' | Out-Null
  Assert 'drugi przebieg przelicza plik mlodszy niz znacznik (agent-t1 -> 2484)' ((Get-Row 'agent-t1')[8] -eq '2484') (Get-Row 'agent-t1')[8]
  Assert 'drugi przebieg poprawil paid_total agent-t1 na 6664' ((Get-Row 'agent-t1')[$COL_PAID] -eq '6664') (Get-Row 'agent-t1')[$COL_PAID]
  Assert 'drugi przebieg nie zmienil complete agent-t1' ((Get-Row 'agent-t1')[$COL_COMPLETE] -eq '1') (Get-Row 'agent-t1')[$COL_COMPLETE]
  Assert 'drugi przebieg nie zdublowal wiersza agent-t1' ((@(Get-Content $tsv) | Where-Object { $_ -match 'agent-t1' }).Count -eq 1)

  # --- pusty stdin ---
  $o = ('' | & powershell.exe -NoProfile -File $hook) -join ''
  Assert 'pusty stdin -> brak outputu' ([string]::IsNullOrWhiteSpace($o))

  # --- brak katalogu subagents -> cisza, plik nietkniety ---
  $before = (Get-Content $tsv -Raw)
  $json = @{ hook_event_name='SubagentStop'; session_id='deadbeef'; transcript_path='C:\nie\ma\takiej.jsonl' } | ConvertTo-Json -Compress
  $json | & powershell.exe -NoProfile -File $hook | Out-Null
  Assert 'brak subagents/ -> plik bez zmian' ((Get-Content $tsv -Raw) -eq $before)

  # --- migracja v2 -> v4 NIE KASUJE danych (dwie kolumny dochodza na koncu) ---
  $kb2 = Join-Path $tmp 'kb2'
  New-Item -ItemType Directory -Path $kb2 -Force | Out-Null
  $tsv2 = Join-Path $kb2 'agents_logs_raw.tsv'
  Set-Content -LiteralPath $tsv2 -Value $HEADER_V2 -Encoding ascii
  Add-Content -LiteralPath $tsv2 -Value "2026-01-01T00:00:00Z`tOLDSESS1`tExplore`tm`t11`t22`t33`t44`t55`t6`t7`t8`tv2 wiersz`tagent-v2row" -Encoding ascii
  $env:OH_HOOK_KB_DIR = $kb2
  Invoke-Hook $a1 | Out-Null
  Assert 'v2->v4: naglowek podniesiony do 16 kolumn' ((Get-Content $tsv2 -TotalCount 1) -eq $HEADER)
  $rv2 = Get-Row 'agent-v2row' $tsv2
  Assert 'v2->v4: stary wiersz NIE skasowany' ($null -ne $rv2)
  Assert 'v2->v4: dane starego wiersza nietkniete (harness 55)' ($rv2[8] -eq '55') $rv2[8]
  Assert 'v2->v4: complete pusty = nieznane' ($rv2[$COL_COMPLETE] -eq '') ("[" + $rv2[$COL_COMPLETE] + "]")
  Assert 'v2->v4: paid_total pusty = epoka sprzed dedup' ($rv2[$COL_PAID] -eq '') ("[" + $rv2[$COL_PAID] + "]")
  Assert 'v2->v4: NIE utworzono _v1.tsv (to nie jest format v1)' (-not (Test-Path (Join-Path $kb2 'agents_logs_raw_v1.tsv')))
  Assert 'v2->v4: nowy wiersz agent-t1 dopisany' ($null -ne (Get-Row 'agent-t1' $tsv2))

  # --- migracja v3 -> v4 NIE KASUJE danych i zachowuje istniejaca flage complete ---
  $kb3 = Join-Path $tmp 'kb3'
  New-Item -ItemType Directory -Path $kb3 -Force | Out-Null
  $tsv3 = Join-Path $kb3 'agents_logs_raw.tsv'
  Set-Content -LiteralPath $tsv3 -Value $HEADER_V3 -Encoding ascii
  Add-Content -LiteralPath $tsv3 -Value "2026-01-01T00:00:00Z`tOLDSESS2`tExplore`tm`t11`t22`t33`t44`t66`t6`t7`t8`tv3 wiersz`tagent-v3row`t1" -Encoding ascii
  $env:OH_HOOK_KB_DIR = $kb3
  Invoke-Hook $a1 | Out-Null
  Assert 'v3->v4: naglowek podniesiony do 16 kolumn' ((Get-Content $tsv3 -TotalCount 1) -eq $HEADER)
  $rv3 = Get-Row 'agent-v3row' $tsv3
  Assert 'v3->v4: stary wiersz NIE skasowany' ($null -ne $rv3)
  Assert 'v3->v4: dane starego wiersza nietkniete (harness 66)' ($rv3[8] -eq '66') $rv3[8]
  Assert 'v3->v4: complete zachowane' ($rv3[$COL_COMPLETE] -eq '1') $rv3[$COL_COMPLETE]
  Assert 'v3->v4: paid_total pusty (sumy v3 sa zawyzone, nie wolno ich utrwalac)' ($rv3[$COL_PAID] -eq '') ("[" + $rv3[$COL_PAID] + "]")
  Assert 'v3->v4: NIE utworzono _v1.tsv' (-not (Test-Path (Join-Path $kb3 'agents_logs_raw_v1.tsv')))

  # --- REGRESJA 2026-09-09: NIEZNANY naglowek + istniejacy _v1.tsv NIE MOZE kasowac danych ---
  # Realny incydent: naglowek byl juz v3, _v1.tsv istnialo od 2026-09-02, wiec plik wpadl w galaz
  # 'else { Remove-Item }' i 286 wierszy telemetrii zniknelo. Odzyskane z kopii zapasowej.
  $kb4 = Join-Path $tmp 'kb4'
  New-Item -ItemType Directory -Path $kb4 -Force | Out-Null
  $tsv4 = Join-Path $kb4 'agents_logs_raw.tsv'
  Set-Content -LiteralPath $tsv4 -Value "zupelnie`tinny`tnaglowek" -Encoding ascii
  Add-Content -LiteralPath $tsv4 -Value "cenny`twiersz`ttelemetrii" -Encoding ascii
  Set-Content -LiteralPath (Join-Path $kb4 'agents_logs_raw_v1.tsv') -Value "zajete" -Encoding ascii
  $env:OH_HOOK_KB_DIR = $kb4
  Invoke-Hook $a1 | Out-Null
  $rescued = @(Get-ChildItem $kb4 -Filter 'agents_logs_raw.tsv.unknown-header-*.bak')
  Assert 'nieznany naglowek: dane odlozone do kopii, NIE skasowane' ($rescued.Count -eq 1) ("plikow: " + $rescued.Count)
  Assert 'nieznany naglowek: kopia zawiera stary wiersz' ((Get-Content $rescued[0].FullName -Raw) -match 'cenny')
  Assert 'nieznany naglowek: _v1.tsv nie nadpisane' ((Get-Content (Join-Path $kb4 'agents_logs_raw_v1.tsv') -Raw) -match 'zajete')
}
finally {
  Remove-Item Env:\OH_HOOK_KB_DIR -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
