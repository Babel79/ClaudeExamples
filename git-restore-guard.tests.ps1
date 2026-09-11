$hook = Join-Path $PSScriptRoot 'git-restore-guard.ps1'
$fail = 0
$tmp = Join-Path $env:TEMP ("oh-hooktest-restore-" + [guid]::NewGuid().ToString('N').Substring(0,8))

# --- prawdziwe repo tymczasowe: hook czyta REALNY 'git status --porcelain' w cwd z wejscia ---
New-Item -ItemType Directory -Path (Join-Path $tmp 'src') -Force | Out-Null
& git -C $tmp init -q 2>$null | Out-Null
foreach ($f in @('src/A.cs','src/B.cs','src/C.cs')) {
  Set-Content -LiteralPath (Join-Path $tmp $f) -Value 'base' -Encoding ascii
}
& git -C $tmp add -A 2>$null | Out-Null
& git -C $tmp -c user.email=t@t -c user.name=t commit -q -m base 2>$null | Out-Null

function Set-Dirty([int]$n) {
  & git -C $tmp -c user.email=t@t -c user.name=t checkout -q -- . 2>$null | Out-Null
  $files = @('src/A.cs','src/B.cs','src/C.cs')
  for ($i = 0; $i -lt $n; $i++) {
    Set-Content -LiteralPath (Join-Path $tmp $files[$i]) -Value ("zmiana " + $i) -Encoding ascii
  }
}
function Test-Case($name, $cmd, $expectAsk) {
  $json = @{ hook_event_name='PreToolUse'; tool_name='Bash'; cwd=$tmp; tool_input=@{ command = $cmd } } | ConvertTo-Json -Compress -Depth 5
  $out = ($json | & powershell.exe -NoProfile -File $hook) -join ''
  $got = ("$out" -match '"permissionDecision":"ask"')
  $ok = ($got -eq $expectAsk)
  if (-not $ok) { $script:fail++ }
  $v = if ($ok) { 'OK  ' } else { 'FAIL' }
  Write-Output ("[{0}] {1,-58} oczekiwane={2} otrzymane={3}" -f $v, $name, $(if($expectAsk){'ASK  '}else{'CISZA'}), $(if($got){'ASK  '}else{'CISZA'}))
}

try {
  # ================= DRZEWO Z 2 ZMIENIONYMI PLIKAMI: rewert punktowy jest ryzykowny =========
  Set-Dirty 2

  Test-Case 'git checkout -- <plik> przy 2 zmianach'  'git checkout -- src/A.cs'                  $true
  Test-Case 'git restore <plik> przy 2 zmianach'      'git restore src/A.cs'                      $true
  Test-Case 'git restore -- <plik>'                   'git restore -- src/A.cs'                   $true
  Test-Case 'lancuch: status && git restore <plik>'   'git status --short && git restore src/A.cs' $true

  # --- MA MILCZEC: to nie jest rewert tresci roboczej ---
  Test-Case 'git checkout <branch> (przelaczenie)'    'git checkout main'                          $false
  Test-Case 'git checkout -b nowa-galaz'              'git checkout -b feature/foo'                $false
  Test-Case 'git restore --staged (unstage)'          'git restore --staged src/A.cs'              $false
  Test-Case 'git checkout -- . (lapie destructive-bulk-guard)' 'git checkout -- .'                 $false
  Test-Case 'zwykly odczyt'                           'git status --short'                         $false
  Test-Case 'git diff'                                'git diff main -- src/A.cs'                  $false

  # --- REGRESJA falszywki (klasa 6/14): CYTAT komendy w tresci pisanego pliku ---
  $heredoc = @"
cat >> .claude/knowledge-base/change-log.md << 'EOF'
Incydent: agent wykonal git checkout -- src/A.cs i skasowal WIP innego slice'a.
Nie powtarzac: git restore src/B.cs przy brudnym drzewie.
EOF
"@
  Test-Case 'heredoc do .md z cytatem komendy'        $heredoc                                     $false
  Test-Case 'echo prozy o zakazie do .md'             'echo "nigdy git restore src/A.cs przy WIP" >> notes.md' $false

  # ================= DRZEWO Z 1 ZMIENIONYM PLIKIEM: brak ryzyka dla cudzej pracy ============
  Set-Dirty 1
  Test-Case '1 zmieniony plik -> cisza (checkout)'    'git checkout -- src/A.cs'                   $false
  Test-Case '1 zmieniony plik -> cisza (restore)'     'git restore src/A.cs'                       $false

  # ================= CZYSTE DRZEWO ==========================================================
  Set-Dirty 0
  Test-Case 'czyste drzewo -> cisza'                  'git checkout -- src/A.cs'                   $false

  # --- BRZEG ---
  $o = ('{}' | & powershell.exe -NoProfile -File $hook) -join ''
  if ([string]::IsNullOrWhiteSpace($o)) { Write-Output '[OK  ] pusty JSON {} -> brak outputu' } else { $fail++; Write-Output '[FAIL] pusty JSON {} -> jest output' }
  $o = ('' | & powershell.exe -NoProfile -File $hook) -join ''
  if ([string]::IsNullOrWhiteSpace($o)) { Write-Output '[OK  ] pusty stdin -> brak outputu' } else { $fail++; Write-Output '[FAIL] pusty stdin -> jest output' }
}
finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
