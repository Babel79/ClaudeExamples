$hook = Join-Path $PSScriptRoot 'agent-handoff-size-guard.ps1'
$fail = 0

function Test-Case($name, $sub, $prompt, $expectDeny) {
  $json = @{ hook_event_name='PreToolUse'; tool_name='Agent'; tool_input=@{ subagent_type=$sub; prompt=$prompt } } | ConvertTo-Json -Compress -Depth 5
  $out = ($json | & powershell.exe -NoProfile -File $hook) -join ''
  $denied = ("$out" -match 'permissionDecision')
  $ok = ($denied -eq $expectDeny)
  if (-not $ok) { $script:fail++ }
  $verdict = if ($ok) { 'OK  ' } else { 'FAIL' }
  Write-Output ("[{0}] {1,-56} oczekiwane={2} otrzymane={3}" -f $verdict, $name, $(if($expectDeny){'DENY'}else{'PASS'}), $(if($denied){'DENY'}else{'PASS'}))
}

$full  = "SCOPE: tylko RoomController.cs`nSUCCESS CRITERIA: GET /api/rooms zwraca 200 i liste`nREFERENCE FILE: GuestController.cs"
$noScope = "SUCCESS CRITERIA: GET /api/rooms zwraca 200`nREFERENCE FILE: GuestController.cs"
$long  = $full + ("`n" + ('x' * 9000))

# --- NOWE: 09-e2e i 14-vps objete bramka sekcji ---
Test-Case '14-vps bez SCOPE'                        '14-vps-deploy-agent' $noScope $true
Test-Case '14-vps z SCOPE + SUCCESS CRITERIA'       '14-vps-deploy-agent' $full    $false
Test-Case '14-vps dlugi handoff (BEZ limitu dlug.)' '14-vps-deploy-agent' $long    $false
Test-Case '09-e2e bez SCOPE'                        '09-e2e-agent'        $noScope $true
Test-Case '09-e2e z sekcjami, dlugi'                '09-e2e-agent'        $long    $false

# --- REGRESJA: impl-agenci bez zmian (limit 8000 nadal dziala) ---
Test-Case '05-api z sekcjami'                       '05-api-agent'        $full    $false
Test-Case '05-api bez SCOPE'                        '05-api-agent'        $noScope $true
Test-Case '05-api handoff > 8000 znakow'            '05-api-agent'        $long    $true
Test-Case '03-qa bez SUCCESS CRITERIA'              '03-qa-agent'         'SCOPE: testy'  $true
Test-Case '01-github (poza bramka)'                 '01-github-devops-agent' 'zacommituj' $false
Test-Case 'Explore (poza bramka)'                   'Explore'             'poszukaj X'   $false

# --- slowo-mgla w kryterium ---
Test-Case '05-api: kryterium "zeby bylo ladniej"'   '05-api-agent' "SCOPE: x`nSUCCESS CRITERIA: ma byc lepiej" $true
Test-Case '05-api: DOKLADNIE nie jest mgla (ENV.8)" ' '05-api-agent' "SCOPE: x`nSUCCESS CRITERIA: dokladnie 3 wiersze w tabeli" $false

# --- H3b: plaski ASCII "ladniej" (bez ogonka) musi DENY tak samo jak "ladniej" z ogonkiem ---
Test-Case '05-api: kryterium plaskie ASCII "ma byc ladniej" (bez ogonka)' '05-api-agent' "SCOPE: x`nSUCCESS CRITERIA: ma byc ladniej" $true

# --- H3b: "ukladnie" plaskie ASCII (bez ogonka) - inny podlancuch z "ladnie" w srodku slowa,
# tak samo jak "dokladnie" - NIE moze byc false-positive po rozszerzeniu regexu o wariant [l|l-kreska] ---
Test-Case '05-api: ukladnie plaskie ASCII (bez ogonka) nie jest mgla' '05-api-agent' "SCOPE: x`nSUCCESS CRITERIA: system ma ukladnie sortowac rekordy" $false

# --- H3b: kryterium mierzalne (obserwowalna liczba) przechodzi bez slow-mgiel ---
Test-Case '05-api: kryterium mierzalne (GET zwraca 200 i 5 wierszy)' '05-api-agent' "SCOPE: x`nSUCCESS CRITERIA: GET /api/rooms zwraca 200 i dokladnie 5 wierszy w odpowiedzi JSON" $false

# --- pusty stdin ---
$empty = ('' | & powershell.exe -NoProfile -File $hook) -join ''
if ([string]::IsNullOrWhiteSpace($empty)) { Write-Output '[OK  ] pusty stdin -> brak outputu' } else { $fail++; Write-Output '[FAIL] pusty stdin -> jest output' }

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
