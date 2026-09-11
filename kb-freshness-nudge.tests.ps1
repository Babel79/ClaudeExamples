$hook = Join-Path $PSScriptRoot 'kb-freshness-nudge.ps1'
$fail = 0
$tmp = Join-Path $env:TEMP ("oh-hooktest-kbfresh-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path (Join-Path $tmp '.claude') -Force | Out-Null

function Assert($name, $cond, $extra) {
  if ($cond) { Write-Output ("[OK  ] {0}" -f $name) } else { $script:fail++; Write-Output ("[FAIL] {0} {1}" -f $name, $extra) }
}
function Invoke-Hook($sessionId, $filePath) {
  $o = @{ hook_event_name='PostToolUse'; tool_name='Edit'; tool_input=@{ file_path = $filePath } }
  if ($null -ne $sessionId) { $o['session_id'] = $sessionId }
  $json = $o | ConvertTo-Json -Compress -Depth 6
  return ($json | & powershell.exe -NoProfile -File $hook) -join ''
}

$ctrl  = 'C:\Repo\Demo.WebApi\Controllers\GuestController.cs'
$ctrl2 = 'C:\Repo\Demo.WebApi\Controllers\RoomController.cs'
$sql   = 'C:\Repo\Demo.Infrastructure\Scripts\0119_AddGuestPin.sql'
$inny  = 'C:\Repo\Demo.Logic\Services\GuestService.cs'

$env:OH_HOOK_ROOT = $tmp
try {
  # --- PIERWSZE trafienie w sesji: zachowanie jak w v1 ---
  $o = Invoke-Hook 'sesja-A' $ctrl
  Assert 'kontroler, 1. raz -> nudge' ("$o" -match 'KB-FRESHNESS') $o
  Assert 'kontroler -> odsyla do api-contracts.md' ("$o" -match 'api-contracts\.md') $o

  # --- THROTTLING: ten sam plik w tej samej sesji -> CISZA (to jest cel zmiany) ---
  $o = Invoke-Hook 'sesja-A' $ctrl
  Assert 'ten sam plik, ta sama sesja -> cisza' ([string]::IsNullOrWhiteSpace($o)) $o
  $o = Invoke-Hook 'sesja-A' $ctrl
  Assert 'trzecia edycja tego samego pliku -> cisza' ([string]::IsNullOrWhiteSpace($o)) $o

  # --- INNY PLIK w tej samej sesji -> nudge (klucz to sesja + sciezka, nie sama sesja) ---
  $o = Invoke-Hook 'sesja-A' $ctrl2
  Assert 'inny kontroler, ta sama sesja -> nudge' ("$o" -match 'KB-FRESHNESS') $o

  # --- TA SAMA sciezka w INNEJ sesji -> nudge (throttling jest per sesja) ---
  $o = Invoke-Hook 'sesja-B' $ctrl
  Assert 'ten sam plik, inna sesja -> nudge' ("$o" -match 'KB-FRESHNESS') $o

  # --- migracja SQL: druga sciezka komunikatu, tez throttlowana ---
  $o = Invoke-Hook 'sesja-A' $sql
  Assert 'migracja SQL, 1. raz -> nudge db-schema' (("$o" -match 'KB-FRESHNESS') -and ("$o" -match 'db-schema\.md')) $o
  $o = Invoke-Hook 'sesja-A' $sql
  Assert 'migracja SQL, 2. raz -> cisza' ([string]::IsNullOrWhiteSpace($o)) $o

  # --- NEGATYW: plik spoza zakresu nigdy nie generuje nudge ---
  $o = Invoke-Hook 'sesja-A' $inny
  Assert 'plik spoza zakresu -> cisza' ([string]::IsNullOrWhiteSpace($o)) $o

  # --- brak session_id: nie throttlujemy, komunikat ma dojsc ---
  $o = Invoke-Hook $null $ctrl
  Assert 'brak session_id -> nudge mimo wszystko' ("$o" -match 'KB-FRESHNESS') $o

  # --- marker throttlingu lezy tam, gdzie inne markery hookow ---
  Assert 'marker KB_FRESHNESS_SEEN.txt w .claude' (Test-Path (Join-Path $tmp '.claude\KB_FRESHNESS_SEEN.txt'))

  # --- BRZEG ---
  $o = ('{}' | & powershell.exe -NoProfile -File $hook) -join ''
  Assert 'pusty JSON {} -> cisza' ([string]::IsNullOrWhiteSpace($o)) $o
  $o = ('' | & powershell.exe -NoProfile -File $hook) -join ''
  Assert 'pusty stdin -> brak outputu' ([string]::IsNullOrWhiteSpace($o)) $o
}
finally {
  Remove-Item Env:\OH_HOOK_ROOT -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
