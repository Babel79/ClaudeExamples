$hook = Join-Path $PSScriptRoot 'sharptools-first-guard.ps1'
$fail = 0

function Test-Case($name, $cmd, $expectDeny) {
  $json = @{ tool_input = @{ command = $cmd } } | ConvertTo-Json -Compress -Depth 5
  $out  = ($json | & powershell.exe -NoProfile -File $hook) -join ''
  $denied = ("$out" -match 'permissionDecision')
  $ok = ($denied -eq $expectDeny)
  if (-not $ok) { $script:fail++ }
  $verdict = if ($ok) { 'OK  ' } else { 'FAIL' }
  $got = if ($denied) { 'DENY' } else { 'PASS' }
  $exp = if ($expectDeny) { 'DENY' } else { 'PASS' }
  Write-Output ("[{0}] {1,-64} oczekiwane={2} otrzymane={3}" -f $verdict, $name, $exp, $got)
}

# --- OCHRONA MUSI ZOSTAC (kod zrodlowy) ---
Test-Case 'edytor strumieniowy in-place na .cs'    "sed -i 's/a/b/' Foo.cs"                       $true
Test-Case 'perl in-place na .cs'                   "perl -i -pe 's/x/y/' Bar.cs"                  $true
Test-Case 'mv z wildcardem na .cs'                 "mv *.cs other/"                               $true
Test-Case 'git rm bulk 3x .cs'                     "git rm A.cs B.cs C.cs"                        $true
Test-Case 'OBEJSCIE: edytor na .cs + redirect .md' "sed -i 's/a/b/' Foo.cs > .claude/x.md"        $true

# --- MA PRZECHODZIC (dokumentacja / dane, nie komenda) ---
$heredoc = @"
cat >> .claude/knowledge-base/agents_logs.md << 'EOF'
Hook SHARPTOOLS-FIRST slusznie zablokowal `sed -i` na pliku Foo.cs u agenta.
EOF
"@
Test-Case 'heredoc do .md OPISUJACY zakaz'         $heredoc                                        $false
Test-Case 'echo prozy o zakazie do .md'            'echo "nie uzywaj sed -i na plikach .cs" >> .claude/notes.md' $false
Test-Case 'git rm pojedynczego .cs (ENV.22 tego projektu)' "git rm Sample.Tests/Dead.cs"             $false
Test-Case 'zwykly odczyt'                          "git status --short"                            $false

# --- H3a (ENV.129): dokladone brakujace przypadki wg zlecenia zadania 2 ---
# sed/perl -i BLOKUJE zawsze, niezaleznie od liczby plikow (nie ma wyjatku analogicznego do git rm)
Test-Case 'sed -i po wielu plikach .cs naraz'      "sed -i 's/a/b/' A.cs B.cs C.cs"                $true
# boundary: dokladnie 2 pliki .cs jawna sciezka, bez wildcardu/petli -> nadal NIE jest bulk (csCount -gt 2 = false)
Test-Case 'git rm DWOCH plikow .cs jawna sciezka (granica ENV.22)' "git rm A.cs B.cs"              $false
# boundary: 3 pliki .cs jawna sciezka -> juz bulk (potwierdzenie gornej granicy z komunikatu hooka)
Test-Case 'git rm TRZECH plikow .cs jawna sciezka (juz bulk)' "git rm A.cs B.cs C.cs"              $true

# ============================================================================
# GM.ENV.132 + GM.ENV.87 (2026-09-10): detektory liczyly trafienia w CALEJ komendzie.
# Kierunek 1 - MA PRZECHODZIC: wzmianka o wzorcu oraz komenda zlozona, ktorej zaden
#              POJEDYNCZY czlon nie jest bulk-mutacja .cs.
# Kierunek 2 - MA NADAL BLOKOWAC: realna bulk-mutacja, takze z cytowana sciezka,
#              po potoku i rozbita na czlony (wariant (b) z naglowka hooka).
# ============================================================================

# --- Kierunek 1: WZMIANKA / komenda zlozona -> PASS ---
Test-Case 'ZLOZONA: odczyt .cs ; niepowiazana komenda z flaga -i (GM.ENV.87)' `
  "sed -n '1,50p' Foo.cs ; grep -i TODO Bar.cs"                                                    $false
Test-Case 'ZLOZONA: odczyt .cs && docker run -i (GM.ENV.132)' `
  "sed -n '1,20p' Foo.cs && docker run -i alpine echo Bar.cs"                                      $false
Test-Case 'ODCZYT edytorem strumieniowym bez zapisu (GM.ENV.87)' `
  "sed -n '/class/,/}/p' Services/Foo.cs"                                                          $false
Test-Case 'CYTAT wzorca w literale do pliku spoza .claude (GM.ENV.132)' `
  'echo "zakazane: sed -i s/a/b/ Foo.cs" >> notes.txt'                                             $false
Test-Case 'grep SZUKAJACY wzorca w repo (GM.ENV.132)' `
  'grep -rn "sed -i .*\.cs" C:/Repo/docs'                                                          $false
Test-Case 'flaga --include=*.cs w wyszukiwarce (nie jest in-place)' `
  'grep -rn --include=*.cs TODO src'                                                               $false

# --- Kierunek 2: OCHRONA NIE OSLABLA -> DENY ---
Test-Case 'BULK z CYTOWANA sciezka .cs (odrzucony wariant (b))' `
  'sed -i "s/a/b/" "Foo.cs"'                                                                       $true
Test-Case 'BULK po potoku: cat ... | edytor -i na .cs' `
  "cat list.txt | sed -i 's/a/b/' Foo.cs"                                                          $true
Test-Case 'BULK rozbity na czlony: git rm A.cs ; git rm B.cs ; git rm C.cs (suma > 2)' `
  'git rm A.cs ; git rm B.cs ; git rm C.cs'                                                        $true
Test-Case 'git rm w petli po .cs' `
  'for f in *.cs; do git rm $f; done'                                                              $true
Test-Case 'edytor in-place przez xargs po liscie .cs' `
  'ls *.cs | xargs sed -i s/a/b/'                                                                  $true
Test-Case 'git rm przez xargs po git ls-files (cytowany glob)' `
  'git ls-files "*.cs" | xargs git rm'                                                             $true
Test-Case 'CYTAT calej petli w literale -> PASS (petla jako proza)' `
  'echo "for f in *.cs; do git rm $f; done" >> notes.txt'                                          $false
Test-Case 'edytor in-place w drugim czlonie (pierwszy niewinny)' `
  "echo start ; sed -i 's/a/b/' Foo.cs"                                                            $true
# regresja: '&' w '2>&1' to przekierowanie, NIE separator czlonow
Test-Case 'edytor in-place na .cs z przekierowaniem 2>&1' `
  "sed -i 's/a/b/' Foo.cs 2>&1"                                                                    $true

# --- brzeg ---
$noCmd = (@{ tool_input = @{} } | ConvertTo-Json -Compress | & powershell.exe -NoProfile -File $hook) -join ''
if ([string]::IsNullOrWhiteSpace($noCmd)) { Write-Output '[OK  ] brak command -> brak outputu' }
else { $fail++; Write-Output '[FAIL] brak command -> jest output' }

$empty = ('' | & powershell.exe -NoProfile -File $hook) -join ''
if ([string]::IsNullOrWhiteSpace($empty)) { Write-Output '[OK  ] pusty stdin -> brak outputu' }
else { $fail++; Write-Output '[FAIL] pusty stdin -> jest output' }

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
exit $fail
