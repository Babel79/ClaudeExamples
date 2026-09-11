$hookSrc = Join-Path $PSScriptRoot 'orchestrator-telemetry-capture.ps1'
$fail = 0

# Hook pisze do $PSScriptRoot\..\knowledge-base\orchestrator_actions_raw.tsv - HARDCODED
# wzgledem WLASNEJ lokalizacji, BRAK env-override (w odroznieniu od agent-telemetry-capture.ps1,
# ktory wspiera OH_HOOK_KB_DIR). Realny plik w tym repo to 3.6 MB DZIALAJACEJ telemetrii -
# NIE WOLNO go dotknac. Dlatego kopiujemy hooka NIEZMIENIONEGO do <tmp>\.claude\hooks\
# z siostrzanym <tmp>\.claude\knowledge-base\ - wtedy $PSScriptRoot\..\knowledge-base
# wskazuje w <tmp>, nie na repo. (Jesli katalog knowledge-base nie istnieje, WriteAllText
# rzuca wyjatek zlapany przez try/catch -> cichy brak zapisu - dlatego katalog TWORZYMY.)
$tmp = Join-Path $env:TEMP ("oh-hooktest-orchtel-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$hooksDir = Join-Path $tmp '.claude\hooks'
$kbDir    = Join-Path $tmp '.claude\knowledge-base'
New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
New-Item -ItemType Directory -Path $kbDir -Force | Out-Null
$hook = Join-Path $hooksDir 'orchestrator-telemetry-capture.ps1'
Copy-Item -LiteralPath $hookSrc -Destination $hook -Force
$tsv = Join-Path $kbDir 'orchestrator_actions_raw.tsv'

function Invoke-Hook($obj) {
  $json = $obj | ConvertTo-Json -Compress -Depth 8
  return ($json | & powershell.exe -NoProfile -File $hook) -join ''
}
function Get-Rows() {
  if (-not (Test-Path -LiteralPath $tsv)) { return @() }
  return @(Get-Content -LiteralPath $tsv)
}
function Assert($name, $cond, $extra) {
  if ($cond) { Write-Output ("[OK  ] {0}" -f $name) } else { $script:fail++; Write-Output ("[FAIL] {0} {1}" -f $name, $extra) }
}

try {
  # --- [A] PreToolUse, Agent, MAIN (Orchestrator) -> wiersz z action=Agent ---
  Invoke-Hook @{ hook_event_name='PreToolUse'; session_id='deadbeef12345678'; transcript_path='C:\x\sess.jsonl'
                 tool_name='Agent'; tool_input=@{ subagent_type='05-api-agent'; description='dodaj endpoint' } } | Out-Null
  $rows = Get-Rows
  Assert 'header 6-kolumnowy na 1. linii' ($rows.Count -ge 1 -and $rows[0] -eq "utc`tsession8`tactor`taction`tsubagent_type`tdetail") ($rows | Select-Object -First 1)
  $r1 = ($rows | Where-Object { $_ -match "`tAgent`t" } | Select-Object -Last 1) -split "`t"
  Assert 'wiersz Agent: actor=orchestrator' ($r1[2] -eq 'orchestrator') $r1[2]
  Assert 'wiersz Agent: action=Agent' ($r1[3] -eq 'Agent') $r1[3]
  Assert 'wiersz Agent: subagent_type=05-api-agent' ($r1[4] -eq '05-api-agent') $r1[4]
  Assert 'wiersz Agent: detail=opis' ($r1[5] -eq 'dodaj endpoint') $r1[5]

  # --- [A] PreToolUse, AskUserQuestion, MAIN -> wiersz z detail=questions=N ---
  Invoke-Hook @{ hook_event_name='PreToolUse'; session_id='deadbeef12345678'; transcript_path='C:\x\sess.jsonl'
                 tool_name='AskUserQuestion'; tool_input=@{ questions=@(@{q='a'},@{q='b'},@{q='c'}) } } | Out-Null
  $rAsk = ((Get-Rows) | Where-Object { $_ -match "`tAskUserQuestion`t" } | Select-Object -Last 1) -split "`t"
  Assert 'wiersz AskUserQuestion: questions=3' ($rAsk[5] -eq 'questions=3') $rAsk[5]

  # --- [A] PreToolUse, Agent, SUBAGENT (transcript ma subagents\agent-) -> BRAK wiersza ---
  $before = (Get-Rows).Count
  Invoke-Hook @{ hook_event_name='PreToolUse'; session_id='deadbeef12345678'; transcript_path='C:\x\sess\subagents\agent-q1.jsonl'
                 tool_name='Agent'; tool_input=@{ subagent_type='03-qa-agent'; description='nie powinno wejsc' } } | Out-Null
  Assert 'subagent PreToolUse Agent -> BRAK nowego wiersza' ((Get-Rows).Count -eq $before) ("bylo=$before jest=" + (Get-Rows).Count)

  # --- GM.ENV.146: REALNY ksztalt ladunku subagenta (zmierzony 2026-09-10 na 5 zywych zdarzeniach).
  # Kluczowe: `transcript_path` subagenta wskazuje transkrypt SESJI GLOWNEJ, wiec warunek po
  # sciezce (test wyzej) NIE zadziala. Rozroznia je OBECNOSC `agent_id` / `agent_type`.
  # Bez tego odsiewu kazda operacja kazdego subagenta byla ksiegowana jako akcja Orchestratora.
  $beforeSub = (Get-Rows).Count
  Invoke-Hook @{ hook_event_name='PostToolUse'; session_id='deadbeef12345678'
                 transcript_path='C:\x\projects\proj\deadbeef-1111-2222.jsonl'   # <- SESJA GLOWNA, nie subagents\
                 agent_id='agent-abc123'; agent_type='05-api-agent'
                 tool_name='Edit'; tool_input=@{ file_path='C:\repo\Foo.cs' }; tool_response='ok' } | Out-Null
  Assert 'subagent PostToolUse (agent_id + main transcript_path) -> BRAK wiersza' `
         ((Get-Rows).Count -eq $beforeSub) ("bylo=$beforeSub jest=" + (Get-Rows).Count)

  # sam `agent_type`, bez `agent_id` - tez subagent
  $beforeSub2 = (Get-Rows).Count
  Invoke-Hook @{ hook_event_name='PostToolUse'; session_id='deadbeef12345678'
                 transcript_path='C:\x\projects\proj\deadbeef-1111-2222.jsonl'
                 agent_type='07-angular-agent'
                 tool_name='Write'; tool_input=@{ file_path='C:\repo\a.ts' }; tool_response='ok' } | Out-Null
  Assert 'subagent PostToolUse (sam agent_type) -> BRAK wiersza' `
         ((Get-Rows).Count -eq $beforeSub2) ("bylo=$beforeSub2 jest=" + (Get-Rows).Count)

  # KIERUNEK ODWROTNY - ten sam ksztalt BEZ pol agenta MUSI zostac zapisany.
  # Bez tego testu "naprawa" polegajaca na odsianiu wszystkiego przeszlaby na zielono.
  $beforeMain = (Get-Rows).Count
  Invoke-Hook @{ hook_event_name='PostToolUse'; session_id='deadbeef12345678'
                 transcript_path='C:\x\projects\proj\deadbeef-1111-2222.jsonl'
                 tool_name='Edit'; tool_input=@{ file_path='C:\repo\Main.cs' }; tool_response='ok' } | Out-Null
  Assert 'main-agent PostToolUse (bez agent_id) -> wiersz ZAPISANY' `
         ((Get-Rows).Count -eq $beforeMain + 1) ("bylo=$beforeMain jest=" + (Get-Rows).Count)

  # --- [B] PostToolUse, Grep, MAIN, tool_response string -> chars = dlugosc stringa ---
  Invoke-Hook @{ hook_event_name='PostToolUse'; session_id='deadbeef12345678'; transcript_path='C:\x\sess.jsonl'
                 tool_name='Grep'; tool_input=@{ pattern='FooBar' }; tool_response='0123456789' } | Out-Null
  $rGrep = ((Get-Rows) | Where-Object { $_ -match "`tGrep`t" } | Select-Object -Last 1) -split "`t"
  Assert 'wiersz Grep: action=Grep' ($rGrep[3] -eq 'Grep') $rGrep[3]
  Assert 'wiersz Grep: detail zawiera chars=10' ($rGrep[5] -match 'chars=10;') $rGrep[5]
  Assert 'wiersz Grep: detail zawiera q=FooBar (z tool_input.pattern)' ($rGrep[5] -match 'q=FooBar') $rGrep[5]

  # --- [B] PostToolUse, narzedzie SPOZA listy scanTools (np. Task) -> BRAK wiersza ---
  $before2 = (Get-Rows).Count
  Invoke-Hook @{ hook_event_name='PostToolUse'; session_id='deadbeef12345678'; transcript_path='C:\x\sess.jsonl'
                 tool_name='Task'; tool_response='cokolwiek' } | Out-Null
  Assert 'PostToolUse spoza scanTools -> BRAK nowego wiersza' ((Get-Rows).Count -eq $before2) ("bylo=$before2 jest=" + (Get-Rows).Count)

  # --- sanitize: tab i newline w opisie zamieniane na spacje (nie psuja kolumn tsv) ---
  Invoke-Hook @{ hook_event_name='PreToolUse'; session_id='deadbeef12345678'; transcript_path='C:\x\sess.jsonl'
                 tool_name='Agent'; tool_input=@{ subagent_type="07-angular`tagent"; description="linia1`r`nlinia2" } } | Out-Null
  $rSan = (Get-Rows | Select-Object -Last 1) -split "`t"
  Assert 'sanitize: dokladnie 6 kolumn (tab w danych nie rozjechal split)' ($rSan.Count -eq 6) ("kolumn=" + $rSan.Count)
  Assert 'sanitize: subagent_type bez surowego taba (zamieniony na spacje)' ($rSan[4] -eq '07-angular agent') $rSan[4]
  Assert 'sanitize: detail bez surowego CRLF (zamieniony na spacje)' ($rSan[5] -eq 'linia1 linia2') $rSan[5]

  # --- brzeg: pusty stdin -> brak crasha, brak nowego wiersza ---
  $before3 = (Get-Rows).Count
  ('' | & powershell.exe -NoProfile -File $hook) | Out-Null
  Assert 'pusty stdin -> brak nowego wiersza, brak crasha' ((Get-Rows).Count -eq $before3) ("bylo=$before3 jest=" + (Get-Rows).Count)

  # --- [C] ROTACJA po przekroczeniu 1 MB (GM.ENV.107) ---
  # Bez tego przypadku rotacja bylaby mechanizmem bez bramki - dokladnie ta klasa dlugu,
  # ktora ta karta zglaszala. Realny plik urosl do 5,36 MB / ~35 tys. wierszy bez zadnego sygnalu.
  $bigLine = ('x' * 200)
  $padding = (1..6000 | ForEach-Object { "2026-01-01T00:00:00Z`tdeadbeef`torchestrator`tGrep`t`t$bigLine" })
  Set-Content -LiteralPath $tsv -Value (@("utc`tsession8`tactor`taction`tsubagent_type`tdetail") + $padding) -Encoding utf8
  $sizeBefore = (Get-Item -LiteralPath $tsv).Length
  Assert 'rotacja/przygotowanie: plik testowy przekracza 1 MB' ($sizeBefore -gt 1MB) ("bajtow=$sizeBefore")

  Invoke-Hook @{ hook_event_name='PreToolUse'; session_id='deadbeef12345678'; transcript_path='C:\x\sess.jsonl'
                 tool_name='Agent'; tool_input=@{ subagent_type='03-qa-agent'; description='po rotacji' } } | Out-Null

  $archives = @(Get-ChildItem -LiteralPath $kbDir -Filter 'orchestrator_actions_raw_*.tsv' -ErrorAction SilentlyContinue)
  Assert 'rotacja: powstal dokladnie 1 plik archiwalny' ($archives.Count -eq 1) ("plikow=" + $archives.Count)
  Assert 'rotacja: archiwum ma rozmiar sprzed rotacji (dane NIE skasowane)' ($archives.Count -eq 1 -and $archives[0].Length -eq $sizeBefore) ("archiwum=" + $(if($archives.Count -eq 1){$archives[0].Length}else{'brak'}) + " oczekiwano=$sizeBefore")

  $rowsAfter = Get-Rows
  Assert 'rotacja: nowy plik ma naglowek' ($rowsAfter.Count -ge 1 -and $rowsAfter[0] -eq "utc`tsession8`tactor`taction`tsubagent_type`tdetail") ($rowsAfter | Select-Object -First 1)
  Assert 'rotacja: biezacy wiersz trafil do NOWEGO pliku, nie do archiwum' ($rowsAfter.Count -eq 2 -and $rowsAfter[1] -match 'po rotacji') ("wierszy=" + $rowsAfter.Count)

  # --- [D] BRAK rotacji ponizej progu (nie rotujemy przy kazdym zapisie) ---
  $sizeSmall = (Get-Item -LiteralPath $tsv).Length
  Invoke-Hook @{ hook_event_name='PreToolUse'; session_id='deadbeef12345678'; transcript_path='C:\x\sess.jsonl'
                 tool_name='Agent'; tool_input=@{ subagent_type='05-api-agent'; description='bez rotacji' } } | Out-Null
  $archives2 = @(Get-ChildItem -LiteralPath $kbDir -Filter 'orchestrator_actions_raw_*.tsv' -ErrorAction SilentlyContinue)
  Assert 'brak rotacji ponizej progu: nadal 1 plik archiwalny' ($archives2.Count -eq 1) ("plikow=" + $archives2.Count)
  Assert 'brak rotacji ponizej progu: wiersze dopisane do biezacego' ((Get-Rows).Count -eq 3) ("wierszy=" + (Get-Rows).Count)
}
finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }

# Suita MUSI zwracac niezerowy exit przy bledzie - inaczej nie jest bramka, tylko wydrukiem.
# Zmierzone 2026-09-10 przy kontrdowodzie GM.ENV.146: dwa przypadki byly CZERWONE,
# a proces konczyl sie EXIT=0. Kazdy wolajacy (command, CI, hook-test-all) uznalby to za sukces.
exit ([int]($fail -gt 0))
