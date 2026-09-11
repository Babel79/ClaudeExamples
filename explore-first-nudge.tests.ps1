$hook = Join-Path $PSScriptRoot 'explore-first-nudge.ps1'
$fail = 0

function Test-Case($name, $subType, $prompt, $expectCtx) {
  $ti = @{}
  if ($null -ne $subType) { $ti['subagent_type'] = $subType }
  if ($null -ne $prompt)  { $ti['prompt'] = $prompt }
  $json = @{ hook_event_name='PreToolUse'; tool_name='Agent'; transcript_path='C:\x\sess.jsonl'; tool_input=$ti } | ConvertTo-Json -Compress -Depth 6
  $out = ($json | & powershell.exe -NoProfile -File $hook) -join ''
  $got = ("$out" -match 'additionalContext')
  $ok = ($got -eq $expectCtx)
  if (-not $ok) { $script:fail++ }
  $v = if ($ok) { 'OK  ' } else { 'FAIL' }
  Write-Output ("[{0}] {1,-58} oczekiwane={2} otrzymane={3}" -f $v, $name, $(if($expectCtx){'CTX '}else{'CISZA'}), $(if($got){'CTX '}else{'CISZA'}))
}

# --- MUSI PODPOWIEDZIEC: general-purpose na czystym skanie ---
Test-Case 'gp: skan repo bez pisania'   'general-purpose' 'Znajdz wszystkie kontrolery ktore nie maja walidatora i wypisz sciezki.' $true
Test-Case 'gp: pytanie o architekture'  'general-purpose' 'Jak przebiega flow CQRS od kontrolera do repozytorium? Podaj pliki.'    $true

# --- MA MILCZEC: prompt zawiera sygnal pisania ---
Test-Case 'gp: jawne narzedzie Write'   'general-purpose' 'Przeanalizuj repo i uzyj Write aby stworzyc raport.'                    $false
Test-Case 'gp: jawne narzedzie Edit'    'general-purpose' 'Przejrzyj pliki i Edit tam gdzie brakuje using.'                        $false
Test-Case 'gp: Bash w promptcie'        'general-purpose' 'Uruchom Bash: dotnet build i podaj exit code.'                          $false
Test-Case 'gp: PL zapisz'               'general-purpose' 'Policz karty i zapisz wynik do pliku podsumowania.'                     $false
Test-Case 'gp: PL utworz (z ogonkiem)'  'general-purpose' ("Przeskanuj repo i utw" + [char]0x00F3 + "rz plik listy.")              $false
Test-Case 'gp: PL zmien (z ogonkiem)'   'general-purpose' ("Sprawdz plik i zmie" + [char]0x0144 + " naglowek sekcji.")             $false
Test-Case 'gp: PL usun (z ogonkiem)'    'general-purpose' ("Znajdz martwy kod i usu" + [char]0x0144 + " go.")                      $false
Test-Case 'gp: PL dopisz'               'general-purpose' 'Zbadaj temat, dopisz wnioski do change-loga.'                           $false
Test-Case 'gp: PL popraw'               'general-purpose' 'Przejrzyj testy i popraw asercje ktore nie mierza zachowania.'          $false

# --- MA MILCZEC: to nie jest general-purpose ---
Test-Case 'Explore: ten sam skan'       'Explore'         'Znajdz wszystkie kontrolery ktore nie maja walidatora.'                 $false
Test-Case 'agent projektowy 05-api'     '05-api-agent'    'Przeanalizuj kontrolery i podaj wnioski.'                               $false
Test-Case 'Plan'                        'Plan'            'Zaproponuj kolejnosc prac.'                                             $false

# --- REGRESJA falszywki: slowo 'zmiennej'/'usuwanie' w prozie NIE jest sygnalem pisania ---
Test-Case 'proza: zmiennej / usuwanie'  'general-purpose' 'Opisz gdzie uzywana jest ta zmienna i jak dziala usuwanie miekkie.'     $true

# --- BRZEG ---
Test-Case 'brak promptu'                'general-purpose' $null                                                                    $false
Test-Case 'brak subagent_type'          $null             'Znajdz cos w repo.'                                                     $false

$o = ('{}' | & powershell.exe -NoProfile -File $hook) -join ''
if ([string]::IsNullOrWhiteSpace($o)) { Write-Output '[OK  ] pusty JSON {} -> brak outputu' } else { $fail++; Write-Output '[FAIL] pusty JSON {} -> jest output' }
$o = ('' | & powershell.exe -NoProfile -File $hook) -join ''
if ([string]::IsNullOrWhiteSpace($o)) { Write-Output '[OK  ] pusty stdin -> brak outputu' } else { $fail++; Write-Output '[FAIL] pusty stdin -> jest output' }

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
