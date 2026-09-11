$hook = Join-Path $PSScriptRoot 'subagent-report-guard.ps1'
$fail = 0
$tmp = Join-Path $env:TEMP ("oh-hooktest-reportguard-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$env:OH_HOOK_KB_DIR = $tmp

function Assert($name, $cond, $extra) {
  if ($cond) { Write-Output ("[OK  ] {0}" -f $name) } else { $script:fail++; Write-Output ("[FAIL] {0} {1}" -f $name, $extra) }
}
function Invoke-Hook($agentType, $lastMsg) {
  $o = @{ hook_event_name='SubagentStop'; session_id='abc12345'; agent_id='agent-x1'; transcript_path='C:\x\sess.jsonl' }
  if ($null -ne $agentType) { $o['agent_type'] = $agentType }
  if ($null -ne $lastMsg)   { $o['last_assistant_message'] = $lastMsg }
  $json = $o | ConvertTo-Json -Compress -Depth 6
  return ($json | & powershell.exe -NoProfile -File $hook) -join ''
}

$pelny = @"
STATUS: DONE
CHANGED FILES: Foo.cs:10-20 - dodano walidacje
VERIFICATION: dotnet build -> EXIT=0; 12 PASS / 0 FAIL
NOT DONE / DEFERRED: brak
RECOMMENDATIONS: brak
TOOLS USED: Read, Edit, Bash
SKILLS USED: dotnet-patterns
"@

try {
  # --- MA MILCZEC: raport kompletny ---
  $o = Invoke-Hook '05-api-agent' $pelny
  Assert 'pelny raport -> cisza' ([string]::IsNullOrWhiteSpace($o)) $o

  # --- MA MILCZEC: warianty zapisu kluczy (podkreslnik, mala litera, DEFERRED) ---
  $o = Invoke-Hook '07-angular-agent' "verification: ng build EXIT=0`nNOT_DONE: nic`ntools_used: Read, Edit"
  Assert 'klucze z podkreslnikiem i mala litera -> cisza' ([string]::IsNullOrWhiteSpace($o)) $o
  $o = Invoke-Hook '03-qa-agent' "VERIFICATION: 5 PASS`nDEFERRED: reszta testow`nTOOLS USED: Bash"
  Assert 'DEFERRED zamiast NOT DONE -> cisza' ([string]::IsNullOrWhiteSpace($o)) $o

  # --- MUSI ZGLOSIC: brak jednego klucza ---
  $o = Invoke-Hook '05-api-agent' "STATUS: DONE`nVERIFICATION: build EXIT=0`nNOT DONE: brak"
  Assert 'brak TOOLS USED -> komunikat' ("$o" -match 'REPORT-GUARD') $o
  Assert 'komunikat nazywa brakujacy klucz' ("$o" -match 'TOOLS USED') $o
  Assert 'komunikat idzie kanalem additionalContext' ("$o" -match 'additionalContext') $o
  Assert 'hookEventName = SubagentStop' ("$o" -match 'SubagentStop') $o

  # --- MUSI ZGLOSIC: UCIETY RETURN (maxTurns) - urwany w polowie, bez zadnej sekcji koncowej ---
  $o = Invoke-Hook '04-mssql-agent' "Dodalem skrypt 0119_AddGuestPin.sql. Teraz uruchamiam DbUp, zeby sprawd"
  Assert 'uciety return -> komunikat' ("$o" -match 'REPORT-GUARD') $o
  Assert 'uciety return -> wszystkie 3 klucze w brakach' (("$o" -match 'VERIFICATION') -and ("$o" -match 'NOT DONE') -and ("$o" -match 'TOOLS USED')) $o
  Assert 'uciety return -> podpowiedz o maxTurns' ("$o" -match 'maxTurns') $o

  # --- MA MILCZEC: agent spoza kontraktu (Explore/general-purpose/Plan) ---
  $o = Invoke-Hook 'Explore' "Znalazlem 3 pliki: A.cs, B.cs, C.cs"
  Assert 'Explore niepelny -> cisza (brak kontraktu)' ([string]::IsNullOrWhiteSpace($o)) $o
  $o = Invoke-Hook 'general-purpose' "gotowe"
  Assert 'general-purpose niepelny -> cisza' ([string]::IsNullOrWhiteSpace($o)) $o
  $o = Invoke-Hook '15-nieistniejacy-agent' "gotowe"
  Assert 'typ spoza zakresu 01-14 -> cisza' ([string]::IsNullOrWhiteSpace($o)) $o

  # --- BRZEG: brak agent_type / brak tekstu raportu / pusty JSON / pusty stdin ---
  $o = Invoke-Hook $null "cokolwiek"
  Assert 'brak agent_type -> cisza' ([string]::IsNullOrWhiteSpace($o)) $o
  $o = Invoke-Hook '05-api-agent' ''
  Assert 'pusty last_assistant_message -> cisza (nie oskarzamy bez danych)' ([string]::IsNullOrWhiteSpace($o)) $o
  $o = ('{}' | & powershell.exe -NoProfile -File $hook) -join ''
  Assert 'pusty JSON {} -> cisza' ([string]::IsNullOrWhiteSpace($o)) $o
  $o = ('' | & powershell.exe -NoProfile -File $hook) -join ''
  Assert 'pusty stdin -> brak outputu' ([string]::IsNullOrWhiteSpace($o)) $o

  # --- TELEMETRIA ---
  $tsv = Join-Path $tmp 'report_guard.tsv'
  Assert 'report_guard.tsv powstal' (Test-Path $tsv)
  $body = if (Test-Path $tsv) { Get-Content $tsv -Raw } else { '' }
  Assert 'tsv ma naglowek' ($body -match 'agent_type')
  Assert 'tsv ma wiersz INCOMPLETE' ($body -match 'INCOMPLETE')
  Assert 'tsv ma wiersz OK' ($body -match "`tOK`t")
}
finally {
  Remove-Item Env:\OH_HOOK_KB_DIR -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
