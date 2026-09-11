$hook = Join-Path $PSScriptRoot 'subagent-longrun-test-guard.ps1'
$fail = 0
$tSub  = 'C:\fake\sess\subagents\agent-qa1.jsonl'
$tMain = 'C:\fake\sess.jsonl'

function Test-Case($name, $cmd, $transcript, $expectDeny) {
  $j = @{ tool_input = @{ command = $cmd } }
  if ($transcript) { $j['transcript_path'] = $transcript }
  $json = $j | ConvertTo-Json -Compress -Depth 5
  $out  = ($json | & powershell.exe -NoProfile -File $hook) -join ''
  $denied = ("$out" -match 'permissionDecision":"deny')
  $ok = ($denied -eq $expectDeny)
  if (-not $ok) { $script:fail++ }
  $verdict = if ($ok) { 'OK  ' } else { 'FAIL' }
  $exp = if ($expectDeny) { 'DENY' } else { 'PASS' }
  $got = if ($denied) { 'DENY' } else { 'PASS' }
  Write-Output ("[{0}] {1,-58} oczekiwane={2} otrzymane={3}" -f $verdict, $name, $exp, $got)
}

# --- MUSI BLOKOWAC: pelny dotnet test na IT, bez --filter, subagent ---
Test-Case 'dotnet test IntegrationTests bez --filter, subagent' `
  'dotnet test Moricom.OneHotel.IntegrationTests' $tSub $true

Test-Case 'dotnet test na .slnx bez --filter, subagent (ciagnie IT)' `
  'dotnet test Moricom.OneHotel.slnx' $tSub $true

Test-Case 'dotnet test bez zadnego targetu (cala solucja), subagent' `
  'dotnet test' $tSub $true

Test-Case 'dotnet test bez targetu, potem && dalsza komenda, subagent' `
  'dotnet test && echo done' $tSub $true

# --- MA PRZECHODZIC ---
Test-Case 'dotnet test IntegrationTests Z --filter, subagent (dozwolone)' `
  'dotnet test Moricom.OneHotel.IntegrationTests --filter FullyQualifiedName~FooTests' $tSub $false

Test-Case 'dotnet test na konkretnym projekcie .Tests.csproj (nie IT, nie sln, nie bare), subagent' `
  'dotnet test Moricom.OneHotel.Tests.csproj' $tSub $false

Test-Case 'ten sam pelny przebieg IT, ale wola Orchestrator (main, brak subagents\)' `
  'dotnet test Moricom.OneHotel.IntegrationTests' $tMain $false

Test-Case 'dotnet build (nie dotnet test w ogole)' `
  'dotnet build' $tSub $false

Test-Case 'brak transcript_path w ogole' `
  'dotnet test Moricom.OneHotel.IntegrationTests' $null $false

# --- brzeg ---
$noCmd = (@{ tool_input = @{} } | ConvertTo-Json -Compress | & powershell.exe -NoProfile -File $hook) -join ''
if ([string]::IsNullOrWhiteSpace($noCmd)) { Write-Output '[OK  ] brak command -> brak outputu' }
else { $fail++; Write-Output '[FAIL] brak command -> jest output' }

$empty = ('' | & powershell.exe -NoProfile -File $hook) -join ''
if ([string]::IsNullOrWhiteSpace($empty)) { Write-Output '[OK  ] pusty stdin -> brak outputu' }
else { $fail++; Write-Output '[FAIL] pusty stdin -> jest output' }

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
