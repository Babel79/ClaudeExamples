$hook = Join-Path $PSScriptRoot 'guardian-gate-nudge.ps1'
$fail = 0

function Test-Case($name, $sub, $prompt, $expectNudge) {
  $json = @{ hook_event_name='PreToolUse'; tool_name='Agent'; tool_input=@{ subagent_type=$sub; prompt=$prompt } } | ConvertTo-Json -Compress -Depth 5
  $out = ($json | & powershell.exe -NoProfile -File $hook) -join ''
  $got = ("$out" -match 'GUARDIAN-GATE')
  $ok = ($got -eq $expectNudge)
  if (-not $ok) { $script:fail++ }
  $verdict = if ($ok) { 'OK  ' } else { 'FAIL' }
  Write-Output ("[{0}] {1,-56} oczekiwane={2} otrzymane={3}" -f $verdict, $name, $(if($expectNudge){'NUDGE'}else{'CISZA'}), $(if($got){'NUDGE'}else{'CISZA'}))
}

# --- MA MILCZEC: commit czystej dokumentacji (klasa falszywek) ---
Test-Case 'commit backlogu (.md w .claude)' '01-github-devops-agent' 'Zacommituj .claude/tasks/backlog.md i backlog_task.md' $false
Test-Case 'commit docs/ + README.md'        '01-github-devops-agent' 'commit zmian w docs/architektura.md oraz README.md'         $false

# --- MA STRZELAC: commit kodu ---
Test-Case 'commit kodu C#'                  '01-github-devops-agent' 'commit zmian w RoomController.cs i RoomService.cs'           $true
Test-Case 'polska odmiana "Zacommituj" + kod' '01-github-devops-agent' 'Zacommituj zmiany w RoomController.cs'                     $true
Test-Case 'commit kodu Angular'             '01-github-devops-agent' 'commit room-detail.component.ts + .html'                     $true

# --- poza zakresem ---
Test-Case 'merge bez slowa commit'          '01-github-devops-agent' 'zmerguj PR #123 (Room.cs)'                                   $false
Test-Case 'inny agent'                      '05-api-agent'           'commit RoomController.cs'                                    $false

# --- pusty stdin ---
$empty = ('' | & powershell.exe -NoProfile -File $hook) -join ''
if ([string]::IsNullOrWhiteSpace($empty)) { Write-Output '[OK  ] pusty stdin -> brak outputu' } else { $fail++; Write-Output '[FAIL] pusty stdin -> jest output' }

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
