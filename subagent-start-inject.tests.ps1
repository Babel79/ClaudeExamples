$hook = Join-Path $PSScriptRoot 'subagent-start-inject.ps1'
$fail = 0

function Invoke-Hook($agentType) {
  $json = @{ hook_event_name = 'SubagentStart'; agent_id = 'agent-test1'; agent_type = $agentType } | ConvertTo-Json -Compress -Depth 5
  return ($json | & powershell.exe -NoProfile -File $hook) -join ''
}

function Get-Ctx($out) {
  if (-not $out) { return '' }
  try { return ([string](($out | ConvertFrom-Json).hookSpecificOutput.additionalContext)) } catch { return '' }
}

function Assert($name, $cond) {
  if ($cond) { Write-Output ("[OK  ] {0}" -f $name) } else { $script:fail++; Write-Output ("[FAIL] {0}" -f $name) }
}

# --- agent implementacyjny: pelny blok ---
$o = Invoke-Hook '05-api-agent'
$c = Get-Ctx $o
Assert 'impl: zawiera marker [SUBAGENT-RULES]'      ($c -match '\[SUBAGENT-RULES\]')
Assert 'impl: wymienia TOOLS USED i SKILLS USED'    ($c -match 'TOOLS USED' -and $c -match 'SKILLS USED')
Assert 'impl: wymienia NOT DONE + RECOMMENDATIONS'  ($c -match 'NOT DONE' -and $c -match 'RECOMMENDATIONS')
# 2026-09-03: user odmrozil zapis do backlogu (par.13). Asercja odwrocona wraz z regula, nie po to
# by test przeszedl - hook ma teraz KAZAC zakladac karte w obu plikach.
# ZMIENIONA 2026-09-08 (H2, portabilizacja hookow): hook juz nie zaszywa konkretnej nazwy backlogu
# (planowana zmiana nazwy w tym projekcie) - bez OH_BACKLOG_PREFIX opisuje plik wzorcem backlog*.md.
# 2026-09-09 (GM.ENV.79): doktryna zmieniona SWIADOMIE, nie asercja oslabiona.
# Bylo: hook kazal agentowi zalozyc karte samemu ('zakladasz jako karte'), a
# subagent-start-inject dla read-only ORAZ scripts/backlog/add_card.py:21 mowily
# odwrotnie ('ID nadaje zawsze Orchestrator'). Trzy zrodla, trzy tresci.
# Asercja jest teraz MOCNIEJSZA: wymaga nowej treci I zabrania powrotu starej.
Assert 'impl: BACKLOG - karte zaklada Orchestrator, nie agent (GM.ENV.79)' ($c -match 'backlog\*\.md' -and $c -match '(?i)zaklada Orchestrator' -and $c -notmatch '(?i)zakladasz jako karte')
Assert 'impl: kolejnosc MCP > CLI > Tool > bash'    ($c -match 'MCP > CLI > Tool')
Assert 'impl: zakaz oslabiania testow'              ($c -match '(?i)nie oslabia')
Assert 'impl: PARTIAL przy maxTurns'                ($c -match 'PARTIAL' -and $c -match 'maxTurns')
Assert ("impl: dlugosc <= 900 zn. (jest {0})" -f $c.Length) ($c.Length -le 900)
Assert 'impl: ASCII-only'                           ($c -notmatch '[^\x00-\x7F]')

# --- agent read-only: wersja skrocona ---
$o2 = Invoke-Hook 'Explore'
$c2 = Get-Ctx $o2
Assert 'Explore: zawiera marker [SUBAGENT-RULES]'   ($c2 -match '\[SUBAGENT-RULES\]')
Assert 'Explore: wymienia TOOLS USED'               ($c2 -match 'TOOLS USED')
Assert ("Explore: krotka wersja < 300 zn. (jest {0})" -f $c2.Length) ($c2.Length -lt 300)
Assert 'Explore: ASCII-only'                        ($c2 -notmatch '[^\x00-\x7F]')

$o3 = Invoke-Hook 'claude-code-guide'
$c3 = Get-Ctx $o3
Assert 'claude-code-guide: krotka wersja'           ($c3.Length -lt 300 -and $c3 -match '\[SUBAGENT-RULES\]')

# --- pusty stdin ---
$empty = ('' | & powershell.exe -NoProfile -File $hook) -join ''
Assert 'pusty stdin -> brak outputu'                ([string]::IsNullOrWhiteSpace($empty))

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
