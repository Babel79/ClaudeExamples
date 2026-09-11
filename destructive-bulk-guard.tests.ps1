$hook = Join-Path $PSScriptRoot 'destructive-bulk-guard.ps1'
$fail = 0

function Test-Case($name, $cmd, $expectDeny) {
  $json = @{ hook_event_name = 'PreToolUse'; tool_name = 'Bash'; tool_input = @{ command = $cmd } } | ConvertTo-Json -Compress -Depth 5
  $out = ($json | & powershell.exe -NoProfile -File $hook) -join ''
  $denied = ("$out" -match 'permissionDecision')
  $ok = ($denied -eq $expectDeny)
  if (-not $ok) { $script:fail++ }
  $verdict = if ($ok) { 'OK  ' } else { 'FAIL' }
  Write-Output ("[{0}] {1,-58} oczekiwane={2} otrzymane={3}" -f $verdict, $name, $(if($expectDeny){'DENY'}else{'PASS'}), $(if($denied){'DENY'}else{'PASS'}))
}

# --- MUSI BLOKOWAC (4 klasy) ---
Test-Case '(A) sed -i po wszystkich .ts'        "sed -i 's/a/b/' src/*.ts"                        $true
Test-Case '(A) find -exec perl -i'              "find . -name '*.cs' -exec perl -i -pe 's/x/y/' {} \;" $true
Test-Case '(B) rm z wildcardem'                 "rm src/*.log"                                    $true
Test-Case '(C) git checkout -- .'               "git checkout -- ."                               $true
Test-Case '(D) git clean -fd'                   "git clean -fd"                                   $true

# --- MA PRZECHODZIC (cytat komendy w TRESCI pisanego pliku - klasa 6/14 falszywek) ---
$heredoc = @"
cat >> .claude/knowledge-base/change-log.md << 'EOF'
Incydent: agent wykonal `git checkout -- .` i skasowal WIP innego slice'a.
Drugi incydent: `git clean -fd` usunal untracked plik bezpowrotnie.
Nie powtarzac: rm *.log ani sed -i 's/a/b/' *.ts
EOF
"@
Test-Case 'heredoc do .md z cytatami komend'    $heredoc                                          $false
Test-Case 'echo prozy o zakazie do .md'         'echo "nigdy nie rob git checkout -- . przy brudnym drzewie" >> .claude/notes.md' $false
Test-Case 'git clean -n (dry-run)'              "git clean -nd"                                   $false

# --- regresja: to co v1 blokowala slusznie, ma nadal byc blokowane / przepuszczane ---
Test-Case 'git rm jawna lista plikow'           "git rm Moricom.OneHotel.Tests/Dead.cs Old.cs"    $false
Test-Case 'sed -i na JEDNYM pliku'              "sed -i 's/a/b/' Foo.md"                          $false
Test-Case 'zwykly odczyt'                       "git status --short"                              $false
Test-Case 'echo z srednikiem w cudzyslowie'     'echo "krok 1; git clean -fd" >> plan.md'         $false
Test-Case 'lancuch: status && git clean -f'     "git status --short && git clean -f"              $true

# --- pusty stdin ---
$empty = ('' | & powershell.exe -NoProfile -File $hook) -join ''
if ([string]::IsNullOrWhiteSpace($empty)) { Write-Output '[OK  ] pusty stdin -> brak outputu' } else { $fail++; Write-Output '[FAIL] pusty stdin -> jest output' }

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
