$hook = Join-Path $PSScriptRoot 'inject-5-rules.ps1'
$fail = 0
# Throttling stan zyje w $env:TEMP\claude-hookstate\<sess8>.5rules (hardcoded w hooku,
# brak env-override) - uzywamy UNIKALNEGO session_id per test i sprzatamy plik na koniec.
$stateDir = Join-Path $env:TEMP 'claude-hookstate'

function Invoke-Hook($sessionId) {
  if ($sessionId) {
    $json = @{ session_id = $sessionId } | ConvertTo-Json -Compress
    return ($json | & powershell.exe -NoProfile -File $hook) -join ''
  } else {
    return ('' | & powershell.exe -NoProfile -File $hook) -join ''
  }
}

function Assert($name, $cond, $extra) {
  if ($cond) { Write-Output ("[OK  ] {0}" -f $name) } else { $script:fail++; Write-Output ("[FAIL] {0} {1}" -f $name, $extra) }
}

# UWAGA: hook obcina session_id do PIERWSZYCH 8 znakow dla nazwy pliku stanu (sid.Substring(0,8)) -
# $sess MUSI miec DOKLADNIE 8 znakow, inaczej test i hook licza na DWOCH ROZNYCH plikach.
$sess = ('t5' + [guid]::NewGuid().ToString('N').Substring(0,6))
if ($sess.Length -ne 8) { throw "test setup: sess musi miec 8 znakow, ma $($sess.Length)" }
$stateFile = Join-Path $stateDir "$sess.5rules"

try {
  # --- tura 1 (brak pliku stanu) -> MUSI wstrzyknac ---
  $out1 = Invoke-Hook $sess
  Assert 'tura 1: wstrzykuje additionalContext' ($out1 -match 'additionalContext') $out1
  Assert 'tura 1: tresc zawiera "ZASAD" (5 zelaznych zasad)' ($out1 -match 'ZASAD')
  Assert 'tura 1: tresc zawiera "MCP" (kolejnosc narzedzi)' ($out1 -match 'MCP')
  Assert 'tura 1: wyjscie jest poprawnym JSON' ($null -ne ($out1 | ConvertFrom-Json))

  # --- tura 2..5: throttling -> CISZA (Every=5, emit tylko na 1,6,11,...) ---
  $out2 = Invoke-Hook $sess
  Assert 'tura 2: throttled -> brak outputu' ([string]::IsNullOrWhiteSpace($out2)) $out2
  $out3 = Invoke-Hook $sess
  Assert 'tura 3: throttled -> brak outputu' ([string]::IsNullOrWhiteSpace($out3)) $out3
  $out4 = Invoke-Hook $sess
  Assert 'tura 4: throttled -> brak outputu' ([string]::IsNullOrWhiteSpace($out4)) $out4
  $out5 = Invoke-Hook $sess
  Assert 'tura 5: throttled -> brak outputu' ([string]::IsNullOrWhiteSpace($out5)) $out5

  # --- tura 6: (6-1)%5==0 -> MUSI znow wstrzyknac ---
  $out6 = Invoke-Hook $sess
  Assert 'tura 6: znow wstrzykuje (co 5-ta)' ($out6 -match 'additionalContext') $out6

  # --- pusty stdin / brak session_id -> $sess pozostaje pusty -> emit ZAWSZE (brak liczenia tur) ---
  $outNoSess1 = Invoke-Hook $null
  $outNoSess2 = Invoke-Hook $null
  Assert 'brak session_id, wywolanie 1: emit (nie liczy tur)' ($outNoSess1 -match 'additionalContext') $outNoSess1
  Assert 'brak session_id, wywolanie 2: emit (nie liczy tur, throttling wymaga sess)' ($outNoSess2 -match 'additionalContext') $outNoSess2
}
finally {
  Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
