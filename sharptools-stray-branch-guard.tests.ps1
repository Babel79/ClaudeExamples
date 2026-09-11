$hookSrc = Join-Path $PSScriptRoot 'sharptools-stray-branch-guard.ps1'
$fail = 0

# Ten hook liczy repo root jako $PSScriptRoot\..\.. (wzgledem WLASNEJ lokalizacji pliku),
# a potem czyta 'git rev-parse --abbrev-ref HEAD' na TYM repo. Zeby NIE ruszac realnego
# HEAD-a repozytorium projektu (main, czyste drzewo), kopiujemy plik hooka NIEZMIENIONY
# do <tmp>\.claude\hooks\ i stawiamy tam osobne, jednorazowe repo git w <tmp> - wtedy
# $PSScriptRoot\..\.. hooka wskazuje na <tmp>, nie na realne repo tego projektu.
$tmp = Join-Path $env:TEMP ("oh-hooktest-strayb-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$hooksDir = Join-Path $tmp '.claude\hooks'
New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
$hook = Join-Path $hooksDir 'sharptools-stray-branch-guard.ps1'
Copy-Item -LiteralPath $hookSrc -Destination $hook -Force

function Invoke-Hook($toolName) {
  $json = @{ tool_name = $toolName } | ConvertTo-Json -Compress
  return ($json | & powershell.exe -NoProfile -File $hook) -join ''
}

function Test-Case($name, $toolName, $expect) {
  # $expect: 'CTX' (nudge additionalContext) | 'SILENT' (brak outputu)
  $out = Invoke-Hook $toolName
  $got = if ("$out" -match 'additionalContext') { 'CTX' } elseif ([string]::IsNullOrWhiteSpace($out)) { 'SILENT' } else { 'INNE' }
  $ok = ($got -eq $expect)
  if (-not $ok) { $script:fail++ }
  $verdict = if ($ok) { 'OK  ' } else { 'FAIL' }
  Write-Output ("[{0}] {1,-58} oczekiwane={2} otrzymane={3}" -f $verdict, $name, $expect, $got)
}

try {
  git -C $tmp init -q
  git -C $tmp config user.email 'test@test.local'
  git -C $tmp config user.name 'test'
  New-Item -ItemType File -Path (Join-Path $tmp 'seed.txt') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $tmp 'seed.txt') -Value 'seed' -Encoding ascii
  git -C $tmp add seed.txt | Out-Null
  git -C $tmp commit -q -m 'seed' | Out-Null

  # --- brak repo git w ogole -> SILENT (test PRZED git init nie mozliwy w tym samym $tmp,
  #     wiec sprawdzamy osobnym, nie-git katalogiem) ---
  $tmpNoGit = Join-Path $env:TEMP ("oh-hooktest-strayb-nogit-" + [guid]::NewGuid().ToString('N').Substring(0,8))
  $hooksDirNoGit = Join-Path $tmpNoGit '.claude\hooks'
  New-Item -ItemType Directory -Path $hooksDirNoGit -Force | Out-Null
  $hookNoGit = Join-Path $hooksDirNoGit 'sharptools-stray-branch-guard.ps1'
  Copy-Item -LiteralPath $hookSrc -Destination $hookNoGit -Force
  $jsonNoGit = @{ tool_name = 'mcp__sharptools__SharpTool_AddMember' } | ConvertTo-Json -Compress
  $outNoGit = ($jsonNoGit | & powershell.exe -NoProfile -File $hookNoGit) -join ''
  if ([string]::IsNullOrWhiteSpace($outNoGit)) { Write-Output '[OK  ] brak repo git w ogole -> SILENT' }
  else { $fail++; Write-Output '[FAIL] brak repo git w ogole -> jest output' }
  Remove-Item -LiteralPath $tmpNoGit -Recurse -Force -ErrorAction SilentlyContinue

  # --- na "main" (nie sharptools/*) -> SILENT nawet dla mutujacego narzedzia ---
  git -C $tmp checkout -q -b main 2>$null
  Test-Case 'mutujacy AddMember, branch=main -> SILENT' 'mcp__sharptools__SharpTool_AddMember' 'SILENT'
  Test-Case 'mutujacy RenameSymbol, branch=main -> SILENT' 'mcp__sharptools__SharpTool_RenameSymbol' 'SILENT'

  # --- read-only tool na branchu sharptools/* -> SILENT (guard ignoruje read-only) ---
  git -C $tmp checkout -q -b sharptools/20260902-120000
  Test-Case 'READ-ONLY ViewDefinition, branch=sharptools/* -> SILENT (nie mutuje)' 'mcp__sharptools__SharpTool_ViewDefinition' 'SILENT'
  Test-Case 'READ-ONLY GetMembers, branch=sharptools/* -> SILENT (nie mutuje)' 'mcp__sharptools__SharpTool_GetMembers' 'SILENT'
  Test-Case 'READ-ONLY FindReferences, branch=sharptools/* -> SILENT (nie mutuje)' 'mcp__sharptools__SharpTool_FindReferences' 'SILENT'

  # --- MUSI NUDGE-owac: mutujace narzedzie + HEAD na sharptools/* ---
  Test-Case 'MUTUJACY AddMember, branch=sharptools/* -> CTX (nudge konsolidacji)' 'mcp__sharptools__SharpTool_AddMember' 'CTX'
  Test-Case 'MUTUJACY RenameSymbol, branch=sharptools/* -> CTX' 'mcp__sharptools__SharpTool_RenameSymbol' 'CTX'
  Test-Case 'MUTUJACY OverwriteMember, branch=sharptools/* -> CTX' 'mcp__sharptools__SharpTool_OverwriteMember' 'CTX'
  Test-Case 'MUTUJACY FindAndReplace, branch=sharptools/* -> CTX' 'mcp__sharptools__SharpTool_FindAndReplace' 'CTX'

  # --- narzedzie spoza sharptools w ogole -> SILENT ---
  Test-Case 'narzedzie Edit (nie sharptools) -> SILENT' 'Edit' 'SILENT'

  # --- brzeg: brak tool_name / pusty stdin ---
  $noTn = (@{} | ConvertTo-Json -Compress | & powershell.exe -NoProfile -File $hook) -join ''
  if ([string]::IsNullOrWhiteSpace($noTn)) { Write-Output '[OK  ] brak tool_name -> brak outputu' }
  else { $fail++; Write-Output '[FAIL] brak tool_name -> jest output' }

  $empty = ('' | & powershell.exe -NoProfile -File $hook) -join ''
  if ([string]::IsNullOrWhiteSpace($empty)) { Write-Output '[OK  ] pusty stdin -> brak outputu' }
  else { $fail++; Write-Output '[FAIL] pusty stdin -> jest output' }

  # sprawdzenie ze tresc nudge'a faktycznie wspomina branch i konsolidacje
  $ctxOut = Invoke-Hook 'mcp__sharptools__SharpTool_AddMember'
  if ($ctxOut -match 'sharptools/' -and $ctxOut -match 'KONSOLIDACJA') { Write-Output '[OK  ] tresc CTX zawiera nazwe brancha i procedure KONSOLIDACJA' }
  else { $fail++; Write-Output '[FAIL] tresc CTX NIE zawiera oczekiwanych fraz' }
}
finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
