$hook = Join-Path $PSScriptRoot 'toolfailure-telemetry.ps1'
$fail = 0
$tmp = Join-Path $env:TEMP ("oh-hooktest-toolfail-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$env:OH_HOOK_KB_DIR = $tmp
$log = Join-Path $tmp 'tool_failures.tsv'

function Assert($name, $cond) {
  if ($cond) { Write-Output ("[OK  ] {0}" -f $name) } else { $script:fail++; Write-Output ("[FAIL] {0}" -f $name) }
}

function Invoke-Hook($obj) {
  $json = $obj | ConvertTo-Json -Compress -Depth 6
  $json | & powershell.exe -NoProfile -File $hook | Out-Null
}

try {
  # 1) awaria Basha u Orchestratora
  Invoke-Hook @{
    hook_event_name='PostToolUseFailure'; session_id='abcdef1234567890'
    transcript_path='C:\x\sess.jsonl'; tool_name='Bash'
    tool_input=@{ command='dotnet test Foo.csproj'; description='run tests' }
    error="Exit code 1`nError: Cannot find module`tTABHERE"
    is_interrupt=$false; duration_ms=4187
  }
  Assert 'plik tool_failures.tsv powstal' (Test-Path $log)
  $lines = @(Get-Content $log)
  Assert 'naglowek + 1 wiersz' ($lines.Count -eq 2)
  Assert 'naglowek zgodny' ($lines[0] -eq "utc`tsession8`tcaller`ttool_name`terror`tinput_snippet")
  $c = $lines[1] -split "`t"
  Assert 'kolumn = 6' ($c.Count -eq 6)
  Assert 'session8 = abcdef12' ($c[1] -eq 'abcdef12')
  Assert 'caller = orchestrator' ($c[2] -eq 'orchestrator')
  Assert 'tool_name = Bash' ($c[3] -eq 'Bash')
  Assert 'error bez tabow i nowych linii' ($c[4] -notmatch "[`t`r`n]" -and $c[4] -match 'Exit code 1')
  Assert 'input_snippet = command' ($c[5] -match 'dotnet test')

  # 2) awaria u subagenta (agent_id obecny)
  Invoke-Hook @{
    hook_event_name='PostToolUseFailure'; session_id='abcdef1234567890'
    transcript_path='C:\x\sess.jsonl'; agent_id='agent-xyz'; agent_type='05-api-agent'
    tool_name='Glob'; tool_input=@{ pattern='**/*.cs' }
    error='Search timed out after 20s'
  }
  $lines = @(Get-Content $log)
  Assert 'drugi wiersz dopisany' ($lines.Count -eq 3)
  $c2 = $lines[2] -split "`t"
  Assert 'caller = subagent:05-api-agent' ($c2[2] -eq 'subagent:05-api-agent')
  Assert 'snippet z pattern' ($c2[5] -eq '**/*.cs')

  # 3) limity dlugosci
  Invoke-Hook @{
    hook_event_name='PostToolUseFailure'; session_id='zzzz1111'
    transcript_path='C:\x\sess.jsonl'; tool_name='Bash'
    tool_input=@{ command=('c' * 400) }; error=('e' * 900)
  }
  $c3 = (@(Get-Content $log))[3] -split "`t"
  Assert 'error przyciety do 200' ($c3[4].Length -eq 200)
  Assert 'snippet przyciety do 120' ($c3[5].Length -eq 120)

  # 4) pusty stdin / brak tool_name
  $before = (Get-Content $log).Count
  $out = ('' | & powershell.exe -NoProfile -File $hook) -join ''
  Assert 'pusty stdin -> brak outputu' ([string]::IsNullOrWhiteSpace($out))
  Invoke-Hook @{ hook_event_name='PostToolUseFailure'; session_id='q' }
  Assert 'brak tool_name -> brak wiersza' ((Get-Content $log).Count -eq $before)
}
finally {
  Remove-Item Env:\OH_HOOK_KB_DIR -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
