# sharptools-mutation-guard.tests.ps1 - suita dla sharptools-mutation-guard.ps1 (GM.ENV.155)

$hook = Join-Path $PSScriptRoot 'sharptools-mutation-guard.ps1'
$fail = 0

function Test-Case($name, $inputObj, $expectDeny) {
  $json = $inputObj | ConvertTo-Json -Compress -Depth 6
  $out  = ($json | & powershell.exe -NoProfile -File $hook) -join ''
  $denied = ("$out" -match 'permissionDecision"\s*:\s*"deny"')
  $ok = ($denied -eq $expectDeny)
  if (-not $ok) { $script:fail++ }
  $verdict = if ($ok) { 'OK  ' } else { 'FAIL' }
  $got = if ($denied) { 'DENY' } else { 'PASS' }
  $exp = if ($expectDeny) { 'DENY' } else { 'PASS' }
  Write-Output ("[{0}] {1,-72} oczekiwane={2} otrzymane={3}" -f $verdict, $name, $exp, $got)
}

# ============================================================================
# SUCCESS CRITERIA z handoffu - cztery obowiazkowe przypadki
# ============================================================================

# (1) SharpTool_FindAndReplace -> DENY
Test-Case 'SharpTool_FindAndReplace -> DENY' `
  @{ tool_name = 'mcp__sharptools__SharpTool_FindAndReplace'; tool_input = @{ filePath = 'Foo.cs' } } `
  $true

# (2) SharpTool_FindReferences (odczyt) -> PASS
Test-Case 'SharpTool_FindReferences (odczyt) -> PASS' `
  @{ tool_name = 'mcp__sharptools__SharpTool_FindReferences'; tool_input = @{ symbol = 'Foo' } } `
  $false

# (3) narzedzie spoza SharpTools (Edit) -> PASS
Test-Case 'Edit (spoza SharpTools) -> PASS' `
  @{ tool_name = 'Edit'; tool_input = @{ file_path = 'Foo.cs'; old_string = 'a'; new_string = 'b' } } `
  $false

# (4) ANTY-REGRESJA (wada GM.ENV.154 i siostrzane): komenda/prompt ktora tylko WSPOMINA
#     nazwe 'SharpTool_FindAndReplace' w tresci tekstowej, a WYWOLUJE inne narzedzie -> PASS.
#     tool_name = 'Bash', tresc komendy tylko CYTUJE nazwe zakazanego narzedzia (np. w echo
#     dokumentujacym zakaz, albo w komentarzu do samego hooka). Hook nie zaglada do command.
Test-Case 'Bash z komenda CYTUJACA nazwe SharpTool_FindAndReplace w tresci -> PASS (anty-regresja)' `
  @{ tool_name = 'Bash'; tool_input = @{ command = 'echo "zakazane: mcp__sharptools__SharpTool_FindAndReplace, uzyj Edit" >> notes.md' } } `
  $false

# ============================================================================
# Pelne pokrycie listy z handoffu - kazde mutujace narzedzie osobno
# ============================================================================
$mutatingTools = @(
  'SharpTool_FindAndReplace','SharpTool_AddMember','SharpTool_OverwriteMember',
  'SharpTool_OverwriteRoslynDocument','SharpTool_RenameSymbol','SharpTool_MoveMember',
  'SharpTool_CreateRoslynDocument','SharpTool_ManageAttributes','SharpTool_ManageUsings'
)
foreach ($t in $mutatingTools) {
  Test-Case "mcp__sharptools__$t -> DENY" @{ tool_name = "mcp__sharptools__$t"; tool_input = @{} } $true
}

# ============================================================================
# Pelne pokrycie listy odczytowej z handoffu - kazde narzedzie osobno -> PASS
# ============================================================================
$readonlyTools = @(
  'SharpTool_FindReferences','SharpTool_ViewDefinition','SharpTool_GetMembers',
  'SharpTool_SearchDefinitions','SharpTool_ListImplementations','SharpTool_ReadRawFromRoslynDocument',
  'SharpTool_ReadTypesFromRoslynDocument','SharpTool_LoadSolution','SharpTool_LoadProject',
  'SharpTool_AnalyzeComplexity'
)
foreach ($t in $readonlyTools) {
  Test-Case "mcp__sharptools__$t -> PASS" @{ tool_name = "mcp__sharptools__$t"; tool_input = @{} } $false
}

# --- narzedzia poza obiema listami (Undo, RequestNewTool) - nie sa jawnie zakazane -> PASS ---
Test-Case 'mcp__sharptools__SharpTool_Undo (poza obiema listami) -> PASS' `
  @{ tool_name = 'mcp__sharptools__SharpTool_Undo'; tool_input = @{} } $false

# --- brzeg: brak tool_name / pusty stdin ---
$noName = (@{ tool_input = @{} } | ConvertTo-Json -Compress | & powershell.exe -NoProfile -File $hook) -join ''
if ([string]::IsNullOrWhiteSpace($noName)) { Write-Output '[OK  ] brak tool_name -> brak outputu' }
else { $fail++; Write-Output '[FAIL] brak tool_name -> jest output' }

$empty = ('' | & powershell.exe -NoProfile -File $hook) -join ''
if ([string]::IsNullOrWhiteSpace($empty)) { Write-Output '[OK  ] pusty stdin -> brak outputu' }
else { $fail++; Write-Output '[FAIL] pusty stdin -> jest output' }

# --- reason zawiera poprawke (co zrobic zamiast) ---
$denyOut = (@{ tool_name = 'mcp__sharptools__SharpTool_RenameSymbol'; tool_input = @{} } | ConvertTo-Json -Compress -Depth 6 | & powershell.exe -NoProfile -File $hook) -join ''
if ($denyOut -match 'Edit') { Write-Output '[OK  ] komunikat DENY zawiera poprawke (Edit)' }
else { $fail++; Write-Output '[FAIL] komunikat DENY NIE zawiera poprawki' }

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
exit $fail
