$hook = Join-Path $PSScriptRoot 'precompact-handoff-nudge.ps1'
$fail = 0
$tmp = Join-Path $env:TEMP ("oh-hooktest-precompact-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path (Join-Path $tmp '.claude') -Force | Out-Null
# atrapa sesji z jednym subagentem -> warunek "bylo cos do stracenia" spelniony
$subDir = Join-Path $tmp 'sess\subagents'
New-Item -ItemType Directory -Path $subDir -Force | Out-Null
Set-Content -LiteralPath (Join-Path $subDir 'agent-t1.jsonl') -Value '{}' -Encoding ascii
$fakeTranscript = Join-Path $tmp 'sess.jsonl'
Set-Content -LiteralPath $fakeTranscript -Value '{}' -Encoding ascii
$env:OH_HOOK_ROOT = $tmp
$marker = Join-Path $tmp '.claude\PRECOMPACT_HANDOFF.txt'

function Assert($name, $cond) {
  if ($cond) { Write-Output ("[OK  ] {0}" -f $name) } else { $script:fail++; Write-Output ("[FAIL] {0}" -f $name) }
}
function Invoke-Hook($obj) {
  $json = $obj | ConvertTo-Json -Compress -Depth 6
  return ($json | & powershell.exe -NoProfile -File $hook) -join ''
}

try {
  # 1) UserPromptSubmit BEZ markera -> cisza
  $o = Invoke-Hook @{ hook_event_name='UserPromptSubmit'; session_id='abc12345'; transcript_path=$fakeTranscript }
  Assert 'UserPromptSubmit bez markera -> brak outputu' ([string]::IsNullOrWhiteSpace($o))

  # 2) PreCompact (sesja miala subagenta) -> marker powstaje, ZERO outputu (docs: PreCompact nie
  #    wstrzykuje kontekstu; jedyny kanal to decision:"block", ktorego swiadomie nie uzywamy)
  $o = Invoke-Hook @{ hook_event_name='PreCompact'; session_id='abc12345'; transcript_path=$fakeTranscript; trigger='auto'; custom_instructions=$null }
  Assert 'PreCompact -> marker istnieje' (Test-Path $marker)
  Assert 'PreCompact -> brak outputu (nie blokuje kompakcji)' ([string]::IsNullOrWhiteSpace($o))
  Assert 'marker zawiera trigger' ((Get-Content $marker -Raw) -match 'trigger=auto')

  # 3) UserPromptSubmit Z markerem -> additionalContext + marker skasowany
  $o = Invoke-Hook @{ hook_event_name='UserPromptSubmit'; session_id='abc12345'; transcript_path=$fakeTranscript }
  Assert 'UserPromptSubmit -> jest [PRECOMPACT]' ("$o" -match '\[PRECOMPACT\]')
  Assert 'UserPromptSubmit -> odsyla do oldsession.md' ("$o" -match 'oldsession\.md')
  Assert 'UserPromptSubmit -> hookEventName poprawny' ("$o" -match 'UserPromptSubmit')
  Assert 'marker skasowany po odbiorze' (-not (Test-Path $marker))

  # 4) drugi prompt -> juz cisza (nie powtarza sie co ture)
  $o = Invoke-Hook @{ hook_event_name='UserPromptSubmit'; session_id='abc12345'; transcript_path=$fakeTranscript }
  Assert 'drugi prompt -> cisza' ([string]::IsNullOrWhiteSpace($o))

  # 5) PreCompact w sesji BEZ subagentow i bez zmian (katalog nie-git) -> brak markera
  $tmp2 = Join-Path $env:TEMP ("oh-hooktest-precompact2-" + [guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Path (Join-Path $tmp2 '.claude') -Force | Out-Null
  $empty2 = Join-Path $tmp2 'sess.jsonl'
  Set-Content -LiteralPath $empty2 -Value '{}' -Encoding ascii
  $env:OH_HOOK_ROOT = $tmp2
  Invoke-Hook @{ hook_event_name='PreCompact'; session_id='abc12345'; transcript_path=$empty2; trigger='manual' } | Out-Null
  Assert 'PreCompact bez subagentow i zmian -> brak markera' (-not (Test-Path (Join-Path $tmp2 '.claude\PRECOMPACT_HANDOFF.txt')))
  Remove-Item -LiteralPath $tmp2 -Recurse -Force -ErrorAction SilentlyContinue

  # 6) pusty stdin
  $o = ('' | & powershell.exe -NoProfile -File $hook) -join ''
  Assert 'pusty stdin -> brak outputu' ([string]::IsNullOrWhiteSpace($o))
}
finally {
  Remove-Item Env:\OH_HOOK_ROOT -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
