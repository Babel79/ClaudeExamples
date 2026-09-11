$hook = Join-Path $PSScriptRoot 'stop-handoff-nudge.ps1'
$fail = 0
$tmp = Join-Path $env:TEMP ("oh-hooktest-stophandoff-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$kb  = Join-Path $tmp '.claude\knowledge-base'
$tasks = Join-Path $tmp '.claude\tasks'
New-Item -ItemType Directory -Path $kb -Force | Out-Null
New-Item -ItemType Directory -Path $tasks -Force | Out-Null

$transcript = Join-Path $tmp 'sess.jsonl'
$handoff    = Join-Path $tasks 'oldsession.md'
$tsv        = Join-Path $kb 'agents_logs_raw.tsv'
$HEADER = "utc`tsession8`tagent_type`tmodel`tout_tokens`tin_tokens`tcache_create`tcache_read`tharness_equiv`tturns`ttool_uses`tduration_sec`tdescription`tagent_id"

# poczatek sesji = 30 minut temu (timestamp pierwszej linii transkryptu)
$sessionStart = (Get-Date).AddMinutes(-30)
Set-Content -LiteralPath $transcript -Encoding ascii -Value @(
  ('{"type":"user","timestamp":"' + $sessionStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') + '"}'),
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Agent"}]}}',
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Agent"}]}}',
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Agent"}]}}'
)

function Assert($name, $cond, $extra) {
  if ($cond) { Write-Output ("[OK  ] {0}" -f $name) } else { $script:fail++; Write-Output ("[FAIL] {0} {1}" -f $name, $extra) }
}
function Set-Tsv([int]$rows) {
  $lines = @($HEADER)
  for ($i = 1; $i -le $rows; $i++) {
    $lines += ("2026-09-02T10:00:0${i}Z`tabc12345`t05-api-agent`topus`t100`t100`t0`t0`t200`t3`t5`t60`topis`tagent-x$i")
  }
  # wiersz obcej sesji - NIE moze byc liczony
  $lines += ("2026-09-02T10:00:09Z`tzzz99999`t07-angular-agent`topus`t1`t1`t0`t0`t2`t1`t1`t1`tobca`tagent-obcy")
  Set-Content -LiteralPath $tsv -Value $lines -Encoding ascii
}
function Set-HandoffAge([int]$minutesAgo) {
  Set-Content -LiteralPath $handoff -Value 'handoff' -Encoding ascii
  (Get-Item -LiteralPath $handoff).LastWriteTime = (Get-Date).AddMinutes(-$minutesAgo)
}
function Invoke-Hook($extra) {
  $o = @{ hook_event_name='Stop'; session_id='abc12345'; transcript_path=$transcript }
  if ($extra) { foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] } }
  $json = $o | ConvertTo-Json -Compress -Depth 6
  return ($json | & powershell.exe -NoProfile -File $hook) -join ''
}

$env:OH_HOOK_ROOT = $tmp
$env:OH_HOOK_KB_DIR = $kb
try {
  # --- POZYTYW: 3 agentow + handoff starszy niz start sesji ---
  Set-Tsv 3
  Set-HandoffAge 90
  $o = Invoke-Hook $null
  Assert 'trzech agentow + stary handoff -> komunikat' ("$o" -match '\[HANDOFF\]') $o
  Assert 'komunikat podaje liczbe wywolan' ("$o" -match '3 wywolan Agent') $o
  Assert 'komunikat odsyla do par.17' ("$o" -match 'par\.17') $o
  Assert 'kanal additionalContext / hookEventName Stop' (("$o" -match 'additionalContext') -and ("$o" -match '"hookEventName":"Stop"')) $o

  # --- ANTY-PETLA: stop_hook_active -> natychmiastowa cisza mimo spelnionych warunkow ---
  $o = Invoke-Hook @{ stop_hook_active = $true }
  Assert 'stop_hook_active -> cisza' ([string]::IsNullOrWhiteSpace($o)) $o

  # --- NEGATYW: handoff nadpisany w tej sesji (mtime swiezszy niz start) ---
  Set-HandoffAge 1
  $o = Invoke-Hook $null
  Assert 'swiezy handoff -> cisza' ([string]::IsNullOrWhiteSpace($o)) $o

  # --- NEGATYW: za malo agentow (2 < prog 3) ---
  Set-Tsv 2
  Set-HandoffAge 90
  $o = Invoke-Hook $null
  Assert 'dwoch agentow -> cisza (prog 3)' ([string]::IsNullOrWhiteSpace($o)) $o

  # --- POZYTYW: brak pliku handoffu w ogole ---
  Set-Tsv 4
  Remove-Item -LiteralPath $handoff -Force -ErrorAction SilentlyContinue
  $o = Invoke-Hook $null
  Assert 'brak oldsession.md -> komunikat' ("$o" -match '\[HANDOFF\]') $o
  Assert 'liczy tylko wiersze wlasnej sesji (4, nie 5)' ("$o" -match '4 wywolan Agent') $o

  # --- FALLBACK: brak tsv -> liczenie z transkryptu (3x "name":"Agent") ---
  Remove-Item -LiteralPath $tsv -Force -ErrorAction SilentlyContinue
  $o = Invoke-Hook $null
  Assert 'fallback z transkryptu -> komunikat' ("$o" -match '\[HANDOFF\]') $o
  Assert 'fallback oznaczony jako transkrypt' ("$o" -match 'transkrypt') $o

  # --- NEGATYW: subagent (ma wlasne SubagentStop) ---
  Set-Tsv 4
  $o = Invoke-Hook @{ agent_id = 'agent-x1' }
  Assert 'subagent -> cisza' ([string]::IsNullOrWhiteSpace($o)) $o

  # --- BRZEG ---
  $o = ('{}' | & powershell.exe -NoProfile -File $hook) -join ''
  Assert 'pusty JSON {} -> cisza' ([string]::IsNullOrWhiteSpace($o)) $o
  $o = ('' | & powershell.exe -NoProfile -File $hook) -join ''
  Assert 'pusty stdin -> brak outputu' ([string]::IsNullOrWhiteSpace($o)) $o
}
finally {
  Remove-Item Env:\OH_HOOK_ROOT -ErrorAction SilentlyContinue
  Remove-Item Env:\OH_HOOK_KB_DIR -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
