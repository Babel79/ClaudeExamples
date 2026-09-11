$hook = Join-Path $PSScriptRoot 'grep-guard.ps1'
$fail = 0

function Test-Case($name, $toolInput, $expectDeny, $subagent) {
  $j = @{ hook_event_name = 'PreToolUse'; tool_name = 'Grep'; tool_input = $toolInput }
  if ($subagent) {
    $j['agent_id'] = 'agent-abc'
    $j['agent_type'] = '05-api-agent'
    $j['transcript_path'] = 'C:\x\sess\subagents\agent-abc.jsonl'
  } else {
    $j['transcript_path'] = 'C:\x\sess.jsonl'
  }
  $json = $j | ConvertTo-Json -Compress -Depth 5
  $out = ($json | & powershell.exe -NoProfile -File $hook) -join ''
  $denied = ("$out" -match 'permissionDecision')
  $ok = ($denied -eq $expectDeny)
  if (-not $ok) { $script:fail++ }
  $verdict = if ($ok) { 'OK  ' } else { 'FAIL' }
  Write-Output ("[{0}] {1,-56} oczekiwane={2} otrzymane={3}" -f $verdict, $name, $(if($expectDeny){'DENY'}else{'PASS'}), $(if($denied){'DENY'}else{'PASS'}))
}

# --- MUSI BLOKOWAC ---
Test-Case 'content bez head_limit (z path)'      @{ pattern='foo'; output_mode='content'; path='Moricom.OneHotel.WebApi' } $true  $false
Test-Case 'content z head_limit ale bez path/glob' @{ pattern='foo'; output_mode='content'; head_limit=50 }                  $true  $false
Test-Case 'files_with_matches bez path i glob'   @{ pattern='foo'; output_mode='files_with_matches' }                        $true  $false
Test-Case 'brak output_mode i brak path/glob'    @{ pattern='foo' }                                                          $true  $false

# --- MA PRZECHODZIC ---
Test-Case 'content + head_limit + path'          @{ pattern='foo'; output_mode='content'; head_limit=30; path='Logic' }      $false $false
Test-Case 'count z path (wyjatek)'               @{ pattern='foo'; output_mode='count'; path='Logic' }                       $false $false
Test-Case 'files_with_matches z glob'            @{ pattern='foo'; output_mode='files_with_matches'; glob='**/*.cs' }        $false $false

# --- SUBAGENT: hook milczy zawsze ---
Test-Case 'SUBAGENT: content bez head_limit'     @{ pattern='foo'; output_mode='content' }                                   $false $true

# --- pusty stdin ---
$empty = ('' | & powershell.exe -NoProfile -File $hook) -join ''
if ([string]::IsNullOrWhiteSpace($empty)) { Write-Output '[OK  ] pusty stdin -> brak outputu' } else { $fail++; Write-Output '[FAIL] pusty stdin -> jest output' }

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
