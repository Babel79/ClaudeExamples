$hook = Join-Path $PSScriptRoot 'it-gate-exclusive-guard.ps1'
$fail = 0

# Ten hook patrzy na REALNE procesy Win32_Process (Name='testhost.exe'), nie na cokolwiek
# co da sie wstrzyknac przez stdin. Zeby dowiesc przypadku DENY, tworzymy PRAWDZIWY,
# krotkozyjacy proces o nazwie pliku "testhost.exe" (kopia powershell.exe) z CommandLine
# zawierajaca "<projekt>.IntegrationTests" - i zabijamy go natychmiast po asercji
# (finally), zeby nie kolidowac z realna bramka /it-gate ktora moze dzialac rownolegle
# w innej sesji.
$tmp = Join-Path $env:TEMP ("oh-hooktest-itgate-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$fakeExe = Join-Path $tmp 'testhost.exe'
Copy-Item -Path (Get-Command powershell.exe).Source -Destination $fakeExe -Force

function Start-FakeTesthost($cmdlineSuffix, $seconds) {
  return Start-Process -FilePath $fakeExe -ArgumentList @('-NoProfile','-Command',"Start-Sleep -Seconds $seconds # $cmdlineSuffix") -PassThru -WindowStyle Hidden
}

# Katalog projektu podawany w payloadzie jako 'cwd' - tak jak robi to realne wywolanie Claude Code.
# DO 2026-09-08 suita go NIE podawala i hook schodzil na ostatni szczebel kaskady ($PSScriptRoot).
# Dzialalo tylko dlatego, ze hook lezal WEWNATRZ repo; po przenosinach do ~/.claude/hooks ten szczebel
# daje 'C:\Users\<konto>', wiec nazwa bazy wychodzila 'babelDB' i guard PRZESTAWAL blokowac.
# Nazwa jest SYNTETYCZNA i celowo NIE jest nazwa tego repo: asercje dowodza, ze rozpoznanie
# "czyj to testhost" PODAZA za katalogiem projektu, zamiast byc zaszyte. To wzmocnienie, nie poluzowanie.
$fakeProjName = 'Firma.ProduktX'
$fakeProjDir  = Join-Path $env:TEMP $fakeProjName

function Test-Case($name, $cmd, $expectDeny) {
  $json = @{ cwd = $fakeProjDir; tool_input = @{ command = $cmd } } | ConvertTo-Json -Compress -Depth 5
  $out  = ($json | & powershell.exe -NoProfile -File $hook) -join ''
  $denied = ("$out" -match 'permissionDecision":"deny')
  $ok = ($denied -eq $expectDeny)
  if (-not $ok) { $script:fail++ }
  $verdict = if ($ok) { 'OK  ' } else { 'FAIL' }
  $exp = if ($expectDeny) { 'DENY' } else { 'PASS' }
  $got = if ($denied) { 'DENY' } else { 'PASS' }
  Write-Output ("[{0}] {1,-58} oczekiwane={2} otrzymane={3}" -f $verdict, $name, $exp, $got)
}

# Empirycznie: 2+ szybkie po sobie wywolania Get-CimInstance Win32_Process (w hooku,
# osobny proces powershell.exe za kazdym razem) na TYM SAMYM zywym procesie potrafia
# nie zobaczyc go za 3. razem (zaobserwowane ~1/3 przebiegow w tym harnessie; pojedyncze
# zapytanie na swiezy proces bylo stabilne 3/3 w izolacji). Dlatego KAZDA asercja DENY
# dostaje WLASNY swiezy proces + wlasny odstep - patrz FINDINGS w raporcie koncowym.
function Test-CaseAgainstFreshProcess($name, $cmdlineSuffix, $seconds, $cmd, $expectDeny) {
  $p = Start-FakeTesthost $cmdlineSuffix $seconds
  Start-Sleep -Milliseconds 1800
  try {
    Test-Case $name $cmd $expectDeny
  } finally {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
  }
}

try {
  # --- MA PRZECHODZIC: brak zywego testhost.exe (tu jeszcze nic nie odpalilismy) ---
  Test-Case 'dotnet test IT, ZADEN testhost.exe nie zyje -> baza wolna' `
    "dotnet test $fakeProjName.IntegrationTests" $false

  Test-Case 'dotnet build (nie dotnet test) -> nieistotne niezaleznie od procesow' `
    'dotnet build' $false

  # --- MUSI BLOKOWAC: zywy testhost.exe z IntegrationTests w CommandLine (kazdy przypadek = swiezy proces) ---
  Test-CaseAgainstFreshProcess 'dotnet test IT, ZYJE testhost.exe (IntegrationTests) -> baza zajeta' `
    "$fakeProjName.IntegrationTests _lockfree_ttag1" 8 `
    "dotnet test $fakeProjName.IntegrationTests" $true

  Test-CaseAgainstFreshProcess 'dotnet test IT Z --filter -> NADAL DENY (ten guard nie zwalnia --filter)' `
    "$fakeProjName.IntegrationTests _lockfree_ttag2" 8 `
    "dotnet test $fakeProjName.IntegrationTests --filter FullyQualifiedName~FooTests" $true

  Test-CaseAgainstFreshProcess 'dotnet test na .slnx -> DENY (ciagnie IT, testhost zyje)' `
    "$fakeProjName.IntegrationTests _lockfree_ttag3" 8 `
    "dotnet test $fakeProjName.slnx" $true

  # --- MA PRZECHODZIC: zywy testhost.exe, ale CommandLine BEZ IntegrationTests (unit testy) ---
  Test-CaseAgainstFreshProcess 'dotnet test IT, zyje testhost.exe ale to Tests (unit), nie IntegrationTests -> PASS' `
    "$fakeProjName.Tests unit-only run" 8 `
    "dotnet test $fakeProjName.IntegrationTests" $false

  # --- brzeg ---
  $noCmd = (@{ tool_input = @{} } | ConvertTo-Json -Compress | & powershell.exe -NoProfile -File $hook) -join ''
  if ([string]::IsNullOrWhiteSpace($noCmd)) { Write-Output '[OK  ] brak command -> brak outputu' }
  else { $fail++; Write-Output '[FAIL] brak command -> jest output' }

  $empty = ('' | & powershell.exe -NoProfile -File $hook) -join ''
  if ([string]::IsNullOrWhiteSpace($empty)) { Write-Output '[OK  ] pusty stdin -> brak outputu' }
  else { $fail++; Write-Output '[FAIL] pusty stdin -> jest output' }
}
finally {
  Get-Process -Name 'testhost' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $fakeExe } | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
