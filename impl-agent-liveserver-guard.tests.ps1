$hook = Join-Path $PSScriptRoot 'impl-agent-liveserver-guard.ps1'
$fail = 0
$tmp = Join-Path $env:TEMP ("oh-hooktest-liveserver-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$sub = Join-Path $tmp 'sess\subagents'
New-Item -ItemType Directory -Path $sub -Force | Out-Null

function New-Meta($agentId, $agentType) {
  $p = Join-Path $sub ($agentId + '.meta.json')
  [System.IO.File]::WriteAllText($p, (@{ agentType = $agentType } | ConvertTo-Json -Compress))
}

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

try {
  New-Meta 'agent-api1' '05-api-agent'
  New-Meta 'agent-web1' '07-angular-agent'
  New-Meta 'agent-e2e1' '09-e2e-agent'
  $tApi = Join-Path $sub 'agent-api1.jsonl'
  $tWeb = Join-Path $sub 'agent-web1.jsonl'
  $tE2e = Join-Path $sub 'agent-e2e1.jsonl'
  $tNoMeta = Join-Path $sub 'agent-nometa1.jsonl'
  $tMain = Join-Path $tmp 'sess.jsonl'

  # --- MUSI BLOKOWAC: dev-server + impl-subagent (04/05/07/08) ---
  Test-Case 'ng serve, 07-angular subagent' 'ng serve --port 57526' $tWeb $true
  Test-Case 'npm start, 05-api subagent'    'npm start'             $tApi $true
  Test-Case 'npm run start, 05-api subagent' 'npm run start'        $tApi $true
  Test-Case 'yarn start, 07-angular subagent' 'yarn start'          $tWeb $true

  # --- MA PRZECHODZIC ---
  Test-Case 'ng build (nie dev-server)'      'ng build'              $tWeb $false
  Test-Case 'ng serve, ale main-agent (brak subagents\ w transcript)' 'ng serve' $tMain $false
  Test-Case 'ng serve, subagent 09-e2e (nie impl 0[4578])' 'ng serve' $tE2e $false
  Test-Case 'ng serve, subagent bez meta.json -> konserwatywnie przepusc' 'ng serve' $tNoMeta $false
  Test-Case 'dotnet build (nie dev-server komenda w ogole)' 'dotnet build' $tApi $false
  Test-Case 'brak transcript_path w ogole' 'ng serve' $null $false

  # --- brzeg ---
  $noCmd = (@{ tool_input = @{} } | ConvertTo-Json -Compress | & powershell.exe -NoProfile -File $hook) -join ''
  if ([string]::IsNullOrWhiteSpace($noCmd)) { Write-Output '[OK  ] brak command -> brak outputu' }
  else { $fail++; Write-Output '[FAIL] brak command -> jest output' }

  $empty = ('' | & powershell.exe -NoProfile -File $hook) -join ''
  if ([string]::IsNullOrWhiteSpace($empty)) { Write-Output '[OK  ] pusty stdin -> brak outputu' }
  else { $fail++; Write-Output '[FAIL] pusty stdin -> jest output' }
}
finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
