$hook = Join-Path $PSScriptRoot 'verify-on-disk-nudge.ps1'
$fail = 0

# ============================================================================
# KONTRAKT ZMIENIONY 2026-09-09 (swiadomie, nie oslabienie asercji):
#
#  1. Hook odpala sie na POTWIERDZENIU STARTU agenta, nie na jego zejsciu -
#     zweryfikowane na transkrypcie sesji 6f9fee25: 0 wstrzykniec przy powiadomieniach
#     o zejsciu, 3 natychmiast po wsadowym dispatchu trzech agentow. Stara tresc
#     ("Agent zszedl") byla nieprawdziwa od poczatku, wiec asercje musialy sie zmienic.
#
#  2. Zakres rozszerzony: KAZDY agent dostaje zakaz tur 'czekam', a impl-agenci
#     dodatkowo pelne verify-on-disk. Powod: 17 tur bez zadnego narzedzia w jednej
#     sesji (16,7% wszystkich) x 235 268 tok sredniego kontekstu = 4,0 mln odczytu
#     cache. To nie jest przypadek rzadki, wiec wyjatek D4 ("nie halasuj codziennie")
#     tu nie obowiazuje.
#
#  Asercje sa MOCNIEJSZE niz poprzednio: sprawdzaja nie tylko OBECNOSC nudge'a, ale
#  takze KTORY wariant przyszedl, oraz ZABRANIAJA powrotu falszywej frazy 'Agent zszedl'.
# ============================================================================

function Get-Nudge($subagentType) {
  $ti = @{}
  if ($null -ne $subagentType) { $ti['subagent_type'] = $subagentType }
  $json = @{ hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_input = $ti } | ConvertTo-Json -Compress -Depth 5
  return ("" + ($json | & powershell.exe -NoProfile -File $hook))
}

function Assert($name, $cond) {
  if ($cond) { Write-Output ("[OK  ] {0}" -f $name) }
  else { $script:fail++; Write-Output ("[FAIL] {0}" -f $name) }
}

# --- agenci implementacyjni: PELNY komunikat (verify + zakaz tur 'czekam') ---
foreach ($a in @('05-api-agent','07-angular-agent','03-qa-agent','04-mssql-agent','08-maui-agent')) {
  $o = Get-Nudge $a
  Assert "impl $a -> jest nudge po dispatchu"      ($o -match 'PO DISPATCHU')
  Assert "impl $a -> zawiera verify-on-disk"       ($o -match 'git status --short')
  Assert "impl $a -> zawiera zakaz tury 'czekam'"  ($o -match "czekam na agenta")
}

# --- pozostali agenci: KROTKI komunikat (sam zakaz tur 'czekam', BEZ verify) ---
foreach ($a in @('Explore','06-architecture-guardian-agent','01-github-devops-agent','10-docs-kb-agent')) {
  $o = Get-Nudge $a
  Assert "inny $a -> jest zakaz tury 'czekam'"     ($o -match "czekam na agenta")
  Assert "inny $a -> NIE ma verify-on-disk"        ($o -notmatch 'git status --short')
}

# --- regresja: falszywa fraza nie moze wrocic ---
foreach ($a in @('05-api-agent','Explore')) {
  Assert "regresja $a -> brak nieprawdziwego 'Agent zszedl'" ((Get-Nudge $a) -notmatch 'Agent zszedl')
}

# --- brzegi ---
Assert 'brak subagent_type -> cisza' ([string]::IsNullOrWhiteSpace((Get-Nudge $null)))
$empty = '' | & powershell.exe -NoProfile -File $hook
Assert 'pusty stdin -> brak outputu' ([string]::IsNullOrWhiteSpace("$empty"))

# --- ASCII-only (PS 5.1 czyta .ps1 jako ANSI) ---
$src = Get-Content -LiteralPath $hook -Raw
Assert 'hook jest ASCII-only' (-not ($src -match '[^\x00-\x7F]'))

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
