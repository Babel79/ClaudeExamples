$hook = Join-Path $PSScriptRoot 'orchestrator-code-write-guard.ps1'
$fail = 0

function Test-Case($name, $j, $expect) {
  # $expect: 'CTX' (nudge -> additionalContext obecny) | 'SILENT' (brak outputu)
  $json = $j | ConvertTo-Json -Compress -Depth 6
  $out = ($json | & powershell.exe -NoProfile -File $hook) -join ''
  $got = if ("$out" -match 'additionalContext') { 'CTX' } elseif ($out) { 'PASS' } else { 'SILENT' }
  $ok = ($got -eq $expect)
  if (-not $ok) { $script:fail++ }
  $verdict = if ($ok) { 'OK  ' } else { 'FAIL' }
  Write-Output ("[{0}] {1,-64} oczekiwane={2} otrzymane={3}" -f $verdict, $name, $expect, $got)
}

function GlownaPetla($path) {
  @{ hook_event_name = 'PreToolUse'; tool_name = 'Write'; transcript_path = 'C:\x\sess.jsonl'; tool_input = @{ file_path = $path } }
}
function ZSubagenta($path) {
  @{ hook_event_name = 'PreToolUse'; tool_name = 'Write'; agent_id = 'agent-abc1'; agent_type = '05-api-agent'; transcript_path = 'C:\x\sess\subagents\agent-abc1.jsonl'; tool_input = @{ file_path = $path } }
}

# --- 1: zapis do <cokolwiek>.Logic/**.cs z glownej petli -> nudge na 05-api ---
Test-Case '1: glowna petla, <projekt>.Logic/**.cs -> nudge 05-api' `
  (GlownaPetla 'C:/Repository/SomeProject.Logic/Handlers/FooHandler.cs') 'CTX'

# --- 2: ten sam zapis z subagenta -> cisza ---
Test-Case '2: subagent, <projekt>.Logic/**.cs -> cisza' `
  (ZSubagenta 'C:/Repository/SomeProject.Logic/Handlers/FooHandler.cs') 'SILENT'

# --- 3: zapis do .claude/**.md -> cisza ---
Test-Case '3: glowna petla, .claude/**.md -> cisza' `
  (GlownaPetla 'C:/Repository/SomeProject/.claude/skills/foo/SKILL.md') 'SILENT'

# --- 4: zapis do <cokolwiek>.Web/src/**.ts -> nudge na 07-angular ---
Test-Case '4: glowna petla, <projekt>.Web/src/**.ts -> nudge 07-angular' `
  (GlownaPetla 'C:/Repository/SomeProject.Web/src/app/foo.component.ts') 'CTX'

# --- dodatkowe: pokrycie pozostalych warstw z mapy ---
Test-Case '5: glowna petla, <projekt>.Mobile/**.xaml -> nudge 08-maui' `
  (GlownaPetla 'C:/Repository/SomeProject.Mobile/Views/MainPage.xaml') 'CTX'

Test-Case '6: glowna petla, <projekt>.Infrastructure/Scripts/*.sql -> nudge 04-mssql' `
  (GlownaPetla 'C:/Repository/SomeProject.Infrastructure/Scripts/0042_init.sql') 'CTX'

Test-Case '7: glowna petla, <projekt>.WebApi.Tests/FooTests.cs -> nudge 03-qa (nie 05-api)' `
  (GlownaPetla 'C:/Repository/SomeProject.WebApi.Tests/FooTests.cs') 'CTX'

$out7 = (@{ hook_event_name = 'PreToolUse'; tool_name = 'Write'; transcript_path = 'C:\x\sess.jsonl'; tool_input = @{ file_path = 'C:/Repository/SomeProject.WebApi.Tests/FooTests.cs' } } | ConvertTo-Json -Compress -Depth 6 | & powershell.exe -NoProfile -File $hook) -join ''
if ("$out7" -match '03-qa-agent') { Write-Output '[OK  ] 7b: separator KROPKA - wskazany agent to 03-qa (nie 05-api)' }
else { $fail++; Write-Output '[FAIL] 7b: separator KROPKA - oczekiwano 03-qa-agent w komunikacie' }

Test-Case '8: glowna petla, <projekt>.Contracts/**.cs -> nudge 05-api' `
  (GlownaPetla 'C:/Repository/SomeProject.Contracts/Dto/FooDto.cs') 'CTX'

Test-Case '9: glowna petla, <projekt>.GenericElements/**.cs -> nudge 05-api' `
  (GlownaPetla 'C:/Repository/SomeProject.GenericElements/GridDefinitions/FooGrid.cs') 'CTX'

# --- plik poza mapa (np. .gitignore w korzeniu repo, nie objety zadna warstwa) -> cisza ---
Test-Case '10: plik spoza mapy warstw -> cisza' `
  (GlownaPetla 'C:/Repository/SomeProject/README.txt') 'SILENT'

# --- pusty stdin ---
$empty = ('' | & powershell.exe -NoProfile -File $hook) -join ''
if ([string]::IsNullOrWhiteSpace($empty)) { Write-Output '[OK  ] pusty stdin -> brak outputu' } else { $fail++; Write-Output '[FAIL] pusty stdin -> jest output' }

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
