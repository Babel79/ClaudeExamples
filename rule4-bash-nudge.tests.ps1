$hook = Join-Path $PSScriptRoot 'rule4-bash-nudge.ps1'
$fail = 0

function Test-Case($name, $cmd, $expectDeny) {
  $json = @{ tool_input = @{ command = $cmd }; session_id = 'ruletestsess01' } | ConvertTo-Json -Compress -Depth 5
  $out  = ($json | & powershell.exe -NoProfile -File $hook) -join ''
  $denied = ("$out" -match 'permissionDecision":"deny')
  $ok = ($denied -eq $expectDeny)
  if (-not $ok) { $script:fail++ }
  $verdict = if ($ok) { 'OK  ' } else { 'FAIL' }
  $exp = if ($expectDeny) { 'DENY' } else { 'PASS' }
  $got = if ($denied) { 'DENY' } else { 'PASS' }
  Write-Output ("[{0}] {1,-64} oczekiwane={2} otrzymane={3}" -f $verdict, $name, $exp, $got)
}

# ============================================================================
# (A) HARD deny: dotnet build/test/run | grep -> nie pisze pliku, bezpieczne bez izolacji
# ============================================================================
Test-Case 'dotnet test | grep -> DENY (maskuje exit code, PR #285)' `
  'dotnet test Moricom.OneHotel.Tests | grep FAIL' $true
Test-Case 'dotnet build | grep -> DENY' `
  'dotnet build 2>&1 | grep -i error' $true
Test-Case 'dotnet run | grep -> DENY' `
  'dotnet run --project Foo | grep listening' $true
Test-Case 'dotnet test bez pipe do grep -> PASS' `
  'dotnet test Moricom.OneHotel.Tests --logger trx' $false
Test-Case 'dotnet test | grep, ale WYNIK grep pipe dalej do wc (agregator) -> PASS (wyjatek GM.ENV.34, ale to inny wzorzec - test opisuje sama komende (A) patrzy TYLKO na dotnet ... | grep)' `
  'cat build.log | grep error | wc -l' $false

# --- GM.ENV.61 (2026-09-09): kazdy filtr tekstowy po potoku maskuje exit code, nie tylko grep ---
Test-Case 'dotnet test | tail -> DENY (GM.ENV.61)' `
  'dotnet test Moricom.OneHotel.Tests | tail -20' $true
Test-Case 'dotnet build | head -> DENY (GM.ENV.61)' `
  'dotnet build 2>&1 | head -50' $true
Test-Case 'dotnet test | findstr -> DENY (GM.ENV.61)' `
  'dotnet test Moricom.OneHotel.Tests | findstr /i error' $true
Test-Case 'dotnet test ; echo EXIT -> PASS (wzorzec NAKAZANY przez CLAUDE.md par.9, nie blokujemy)' `
  'dotnet test Moricom.OneHotel.Tests ; echo EXIT=$?' $false
Test-Case 'dotnet test > log 2>&1 -> PASS (przekierowanie zachowuje exit code)' `
  'dotnet test Moricom.OneHotel.Tests > log.txt 2>&1' $false

# ============================================================================
# (A2) GM.ENV.142 + GM.ENV.145 (2026-09-10) - JEDEN defekt, dwie karty:
# wzorzec dopasowywany do calego tekstu komendy nie odroznial UZYCIA od WZMIANKI.
# Kierunek 1: WZMIANKA (literal / heredoc / wyszukiwanie wzorca) MA PRZECHODZIC.
# Kierunek 2: realny potok buildu do filtra MA NADAL BLOKOWAC - takze gdy jest ukryty
#             w opakowaniu powloki ('bash -c "..."'), bo tam literal JEST komenda.
# IZOLACJA: czlon z 'grep' jako czasownikiem trafia do galezi (B) i pisze wiersz tsv,
# wiec ta sekcja tez przekierowuje zapis przez $env:OH_HOOK_KB_DIR.
# ============================================================================
$tmpA = Join-Path $env:TEMP ("oh-hooktest-rule4a-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmpA -Force | Out-Null
$env:OH_HOOK_KB_DIR = $tmpA
try {
  $citeHeredoc = @'
cat >> .claude/tasks/backlog.md << 'EOF'
Przyklad ZLEGO wzorca: dotnet test Moricom.OneHotel.Tests | grep FAIL - maskuje exit code.
EOF
'@
  Test-Case 'CYTAT w heredocu do backlogu -> PASS (GM.ENV.145)' `
    $citeHeredoc $false
  Test-Case 'CYTAT w literale (echo do pliku) -> PASS (GM.ENV.142)' `
    'echo "zle: dotnet test Foo | grep FAIL" >> notes.txt' $false
  Test-Case 'CYTAT w literale zapisywany do .md w .claude -> PASS (GM.ENV.145)' `
    'echo "dotnet build | grep error jest zakazane" >> .claude/knowledge-base/change-log.md' $false
  Test-Case 'grep SZUKAJACY tego wzorca w repo -> PASS (GM.ENV.142)' `
    'grep -rn "dotnet test .* | grep" C:/Repo/docs' $false
  Test-Case 'skrypt PS z wzorcem w literale (Set-Content) -> PASS (GM.ENV.142)' `
    'Set-Content -Path doc.md -Value "dotnet test | grep FAIL"' $false

  # --- OCHRONA NIE MOZE OSLABNAC ---
  Test-Case 'REALNY potok po && w drugim czlonie -> DENY' `
    'cd Moricom.OneHotel.Tests && dotnet test | grep FAIL' $true
  Test-Case 'EWAZJA: bash -c z potokiem w literale -> DENY (literal JEST komenda)' `
    'bash -c "dotnet test Moricom.OneHotel.Tests | grep FAIL"' $true
  Test-Case 'EWAZJA: powershell -Command z potokiem w literale -> DENY' `
    'powershell -Command "dotnet build | Select-String error"' $true
  Test-Case 'REALNY potok w drugim czlonie po srednika (pierwszy czlon niewinny) -> DENY' `
    'echo start ; dotnet test | tail -5' $true
  # Ten przypadek zalezy WPROST od segmentacji: bez podzialu na czlony obecnosc 'bash -c'
  # gdziekolwiek w komendzie przywracalaby literaly TAKZE w czlonie z cytatem -> falszywy DENY.
  Test-Case 'CYTAT w jednym czlonie + niepowiazany bash -c w drugim -> PASS (segmentacja)' `
    'echo "dotnet test | grep FAIL" >> notes.txt ; bash -c "ls -la"' $false
}
finally {
  Remove-Item Env:\OH_HOOK_KB_DIR -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmpA -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================================
# (B) SOFT -> SILENT: grep/find/sed/sqlcmd jako verb -> TYLKO log do tsv, BEZ additionalContext.
# IZOLACJA (H3, portabilizacja suit): hook wspiera $env:OH_HOOK_KB_DIR (wprowadzone w H1,
# patrz rule4-bash-nudge.ps1) - przekierowujemy zapis do <tmp>, zeby NIE dotknac
# zywej telemetrii tego repo ('.claude/knowledge-base/rule4_nudges.tsv', referencjonowanej
# w CLAUDE.md 4a: "123x w oknie 13 dni"). Zmienna dziedziczona przez kazdy podproces
# powershell.exe wywolywany w Test-Case. To zastepuje wczesniejszy backup-swap-restore na
# REALNEJ sciezce (dzialal, ale operowal na tym samym pliku co zywa telemetria - kolizja
# przy rownoleglym przebiegu innej sesji byla mozliwa; env-var izoluje calkowicie).
# ============================================================================
$tmp    = Join-Path $env:TEMP ("oh-hooktest-rule4-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$realTsv = Join-Path $tmp 'rule4_nudges.tsv'

$env:OH_HOOK_KB_DIR = $tmp
try {
  # narzedzie SILENT (brak permissionDecision, brak additionalContext) niezaleznie od outputu -
  # jedyny obserwowalny efekt to zapis do tsv, wiec asercja PASS==brak deny (nigdy DENY dla (B))
  Test-Case 'grep jako verb komendy -> PASS (silent, tylko log)' 'grep -r "TODO" .' $false
  Test-Case 'find jako verb -> PASS (silent, tylko log)' 'find . -name "*.cs"' $false
  Test-Case 'sed jako verb -> PASS (silent, tylko log)' 'sed -n "1,5p" foo.txt' $false
  Test-Case 'sqlcmd jako verb -> PASS (silent, tylko log)' 'sqlcmd -Q "SELECT 1"' $false
  Test-Case 'grep po && (nie na poczatku komendy) -> PASS (tez loguje)' 'cd foo && grep bar baz.txt' $false

  # wyjatek GM.ENV.34: potok do agregatora (wc/sort/uniq/awk/jq/python/tr/cut/paste) -> NIE loguje
  Test-Case 'grep | wc -l (wyjatek agregatora) -> PASS (i NIE loguje - assert nizej)' 'grep foo bar.txt | wc -l' $false
  Test-Case 'find | sort (wyjatek agregatora) -> PASS' 'find . -name "*.md" | sort' $false

  $rows = if (Test-Path -LiteralPath $realTsv) { @(Get-Content -LiteralPath $realTsv) } else { @() }
  if ($rows.Count -ge 1 -and $rows[0] -eq "utc`tsession8`tcaller`ttool`tcmd") { Write-Output '[OK  ] header 5-kolumnowy utworzony' }
  else { $fail++; Write-Output ('[FAIL] header nieoczekiwany: ' + ($rows | Select-Object -First 1)) }

  $grepRows = $rows | Where-Object { $_ -match "`tgrep`t" }
  if ($grepRows.Count -eq 2) { Write-Output '[OK  ] dokladnie 2 wiersze z tool=grep (bezposredni + po &&; NIE agregatorowy)' }
  else { $fail++; Write-Output ("[FAIL] oczekiwano 2 wiersze tool=grep, jest " + $grepRows.Count) }

  $findRows = $rows | Where-Object { $_ -match "`tfind`t" }
  if ($findRows.Count -eq 1) { Write-Output '[OK  ] dokladnie 1 wiersz z tool=find (agregatorowy find|sort NIE zalogowany)' }
  else { $fail++; Write-Output ("[FAIL] oczekiwano 1 wiersz tool=find, jest " + $findRows.Count) }

  $sedRow = ($rows | Where-Object { $_ -match "`tsed`t" }) -split "`t"
  if ($sedRow -and $sedRow[2] -eq 'orchestrator') { Write-Output '[OK  ] wiersz sed: caller=orchestrator (brak subagents\ w transcript_path)' }
  else { $fail++; Write-Output ('[FAIL] wiersz sed caller niepoprawny: ' + ($sedRow -join '|')) }

  # --- caller=subagent gdy transcript_path zawiera subagents\ ---
  $jsonSub = @{ tool_input = @{ command = 'grep TODO src/' }; session_id = 'ruletestsess01'; transcript_path = 'C:\x\sess\subagents\agent-z1.jsonl' } | ConvertTo-Json -Compress
  ($jsonSub | & powershell.exe -NoProfile -File $hook) | Out-Null
  $rows2 = @(Get-Content -LiteralPath $realTsv)
  $subRow = ($rows2 | Where-Object { $_ -match "`tsubagent`tgrep`t" } | Select-Object -Last 1)
  if ($subRow) { Write-Output '[OK  ] wiersz z transcript subagenta: caller=subagent' }
  else { $fail++; Write-Output '[FAIL] brak wiersza caller=subagent' }
}
finally {
  Remove-Item Env:\OH_HOOK_KB_DIR -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================================
# brzeg
# ============================================================================
$noCmd = (@{ tool_input = @{} } | ConvertTo-Json -Compress | & powershell.exe -NoProfile -File $hook) -join ''
if ([string]::IsNullOrWhiteSpace($noCmd)) { Write-Output '[OK  ] brak command -> brak outputu' }
else { $fail++; Write-Output '[FAIL] brak command -> jest output' }

$empty = ('' | & powershell.exe -NoProfile -File $hook) -join ''
if ([string]::IsNullOrWhiteSpace($empty)) { Write-Output '[OK  ] pusty stdin -> brak outputu' }
else { $fail++; Write-Output '[FAIL] pusty stdin -> jest output' }

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
exit $fail
