$hook = Join-Path $PSScriptRoot 'mutation-leftover-detector.ps1'
$fail = 0
$tmp = Join-Path $env:TEMP ("oh-hooktest-mutation-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function Assert($name, $cond, $extra) {
  if ($cond) { Write-Output ("[OK  ] {0}" -f $name) } else { $script:fail++; Write-Output ("[FAIL] {0} {1}" -f $name, $extra) }
}
function Reset-Repo {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  & git -C $tmp init -q 2>$null | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $tmp '.claude\knowledge-base') -Force | Out-Null
  # untracked plik kodu produkcyjnego z markerem mutacji (konwencja /counterproof)
  Set-Content -LiteralPath (Join-Path $tmp 'Program.cs') -Value @(
    'public class P {',
    '  // MUTATION 2 - DO NOT COMMIT',
    '  public int X => 1;',
    '}') -Encoding ascii
}
function Invoke-Hook($lastMsg) {
  $o = @{ hook_event_name='SubagentStop'; session_id='abc12345'; transcript_path=(Join-Path $tmp 'sess.jsonl') }
  if ($null -ne $lastMsg) { $o['last_assistant_message'] = $lastMsg }
  $json = $o | ConvertTo-Json -Compress -Depth 6
  return ($json | & powershell.exe -NoProfile -File $hook) -join ''
}

$env:OH_HOOK_ROOT = $tmp
try {
  $alert = Join-Path $tmp '.claude\MUTATION_ALERT.txt'
  $log   = Join-Path $tmp '.claude\knowledge-base\mutation_alerts.log'

  # --- PRZYPADEK 1: agent zakonczyl NORMALNIE (VERDICT) -> tylko log INFO, ZERO alarmu ---
  # To jest klasa 7/7 falszywych alarmow: /counterproof ma mutacje "w toku" z definicji.
  Reset-Repo
  Invoke-Hook "VERDICT: PASS - kontrdowod wykonany, mutacja zrewertowana w kroku 4." | Out-Null
  Assert 'VERDICT -> BRAK MUTATION_ALERT.txt' (-not (Test-Path $alert))
  Assert 'VERDICT -> wpis INFO-in-progress w logu' ((Test-Path $log) -and ((Get-Content $log -Raw) -match 'INFO-in-progress'))

  # --- PRZYPADEK 1b: agent zakonczyl przez STATUS: ---
  Reset-Repo
  Invoke-Hook "STATUS: PARTIAL`nNOT DONE: rewert mutacji opisany nizej" | Out-Null
  Assert 'STATUS: -> BRAK MUTATION_ALERT.txt' (-not (Test-Path $alert))

  # --- PRZYPADEK 2: agent UCIETY (brak VERDICT/STATUS) -> pelny alarm ---
  Reset-Repo
  Invoke-Hook "Sprawdzam teraz czy test czerwienieje..." | Out-Null
  Assert 'brak VERDICT -> MUTATION_ALERT.txt powstaje' (Test-Path $alert)
  Assert 'alert wskazuje plik i linie' ((Test-Path $alert) -and ((Get-Content $alert -Raw) -match 'Program\.cs'))

  # --- PRZYPADEK 3: brak markera mutacji w kodzie -> cisza mimo braku VERDICT ---
  Reset-Repo
  Set-Content -LiteralPath (Join-Path $tmp 'Program.cs') -Value 'public class P { public int X => 1; }' -Encoding ascii
  Invoke-Hook "koniec" | Out-Null
  Assert 'brak markera -> brak alarmu' (-not (Test-Path $alert))

  # --- PRZYPADEK 4: marker w PLIKU TESTOWYM jest legalny -> brak alarmu ---
  Reset-Repo
  Remove-Item -LiteralPath (Join-Path $tmp 'Program.cs') -Force
  New-Item -ItemType Directory -Path (Join-Path $tmp 'Tests') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $tmp 'Tests\FooTests.cs') -Value '// MUTATION probe' -Encoding ascii
  Invoke-Hook "koniec" | Out-Null
  Assert 'marker w tescie -> brak alarmu' (-not (Test-Path $alert))

  # --- pusty stdin ---
  $o = ('' | & powershell.exe -NoProfile -File $hook) -join ''
  Assert 'pusty stdin -> brak outputu' ([string]::IsNullOrWhiteSpace($o))
}
finally {
  Remove-Item Env:\OH_HOOK_ROOT -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
