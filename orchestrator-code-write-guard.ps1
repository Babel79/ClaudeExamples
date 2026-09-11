# orchestrator-code-write-guard.ps1 - PreToolUse (Write|Edit) guard dla ZASADY 1 CLAUDE.md:
# Orchestrator NIE pisze kodu aplikacji, deleguje do specjalisty. (karta ENV.130)
#
# LUKA: guardian-gate-nudge i agent-handoff-size-guard reaguja dopiero na wywolanie narzedzia
# Agent. Sesja, w ktorej Orchestrator napisal kod SAM i nie zawolal nikogo, nie wyzwala zadnego
# z nich - bramka nie ma jak sie dowiedziec, ze zostala ominieta. Incydent 2026-08-08 (inny
# projekt): cala sesja portu Angulara/MAUI, migracji i testow wykonana w glownej petli.
#
# ZRODLO WZORCA (czytane, NIE kopiowane 1:1): Moricom.OneRecognition ma
# orchestrator-code-write-guard.ps1 z ta sama luka. Mapa sciezka->agent jest TUTAJ
# sparametryzowana po SEGMENCIE WARSTWY (np. ".Logic/"), nie po pelnej nazwie projektu ani
# literale konkretnego repo - separator warstwy bywa KROPKA (Nazwa.Projektu.Logic), nie tylko
# ukosnik. To dokladnie ten blad, przez ktory test-weaken-guard w trzech projektach nie odpalil
# ani razu od czerwca (regex `[\/]WebApi[\/]` nigdy nie lapal realnej sciezki z kropka).
#
# ZACHOWANIE: nudge (NIE blokuje). Wskazuje agenta wlasciwego dla sciezki.
# ZAKRES: wylacznie glowna petla - subagenci sa POMIJANI (oni MAJA pisac kod, to jest delegacja).
# Rozpoznanie subagenta: pole agent_id obecne TYLKO wewnatrz wywolania subagenta (docs,
# code.claude.com/docs/en/hooks.md, "Common input fields"; ten sam idiom co grep-guard.ps1).
#
# Defensive, ASCII-only (Windows PowerShell 5.1 czyta .ps1 jako ANSI). exit 0 always.
$ErrorActionPreference = 'SilentlyContinue'
try {
  $raw = [Console]::In.ReadToEnd()
  if (-not $raw) { exit 0 }
  $j = $raw | ConvertFrom-Json

  # --- tylko glowna petla (jak grep-guard.ps1) ---
  if ($j.agent_id) { exit 0 }
  $tp = [string]$j.transcript_path
  if ($tp -match '[\\/]subagents[\\/]') { exit 0 }

  $path = [string]$j.tool_input.file_path
  if (-not $path) { exit 0 }
  $p = $path.Replace('\', '/')

  # --- kaskada $root, jak w pozostalych hookach (subagent-report-guard.ps1) ---
  $root = if ($env:OH_HOOK_ROOT) { $env:OH_HOOK_ROOT }
          elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR }
          elseif ($j.cwd) { [string]$j.cwd }
          else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  $rootNorm = ([string]$root).Replace('\', '/').TrimEnd('/')

  # sciezka wzgledna do repo, gdy da sie ja policzyc; inaczej fallback = pelna sciezka
  # (fallback jest celowy - hook musi dzialac tez na cudzych/testowych sciezkach spoza $root,
  # bo mapa jest sparametryzowana po segmencie, nie po konkretnym repo).
  $rel = $p
  if ($rootNorm -and $p.StartsWith($rootNorm, [StringComparison]::OrdinalIgnoreCase)) {
    $rel = $p.Substring($rootNorm.Length).TrimStart('/')
  }

  # --- sciezki WYLACZONE: dokumentacja, srodowisko agentow, konfiguracja, dane testowe.
  # To jest praca mechaniczna/dokumentacyjna, ktora orchestrator robi sam (CLAUDE.md 1.1a). ---
  if ($rel -match '(?i)(^|/)\.claude/|(^|/)prompts/|(^|/)schemas/|\.md$|(^|/)storage/') { exit 0 }

  # --- mapa SEGMENT WARSTWY -> agent. Separator "." LUB "/" po obu stronach segmentu. ---
  # Kolejnosc: warstwy wieloplatformowe/testowe NAJPIERW (waskie), C# ogolny NA KONCU (szeroki) -
  # zeby np. "Projekt.WebApi.Tests/FooTests.cs" trafil do 03-qa, nie do 05-api.
  $agent = $null
  switch -Regex ($rel) {
    '(?i)[./]Web/src/.*\.(ts|html|scss)$'          { $agent = '07-angular-agent'; break }
    '(?i)[./]Mobile[./].*\.(xaml|cs)$'             { $agent = '08-maui-agent';    break }
    '(?i)[./]Infrastructure/Scripts/.*\.sql$'      { $agent = '04-mssql-agent';   break }
    '(?i)[./]\w*Tests\w*[./].*\.cs$'               { $agent = '03-qa-agent';      break }
    '(?i)[./](WebApi|Logic|Contracts|GenericElements)[./].*\.cs$' { $agent = '05-api-agent'; break }
  }
  if (-not $agent) { exit 0 }

  $file = Split-Path $path -Leaf
  $reason = "[DELEGACJA] Piszesz '$file' bezposrednio w glownej petli. Wlasciwy agent: $agent (CLAUDE.md zasada 1). " +
            "Wyjatek dozwolony: praca MECHANICZNA - rename, delecja, 1-line config. " +
            "Jesli to nie jest praca mechaniczna: przerwij, pokaz plan i deleguj. " +
            "Jesli narzedzie Agent jest niedostepne w tej sesji - POWIEDZ TO USEROWI JAWNIE " +
            "zamiast po cichu robic wszystko samemu. Nudge - akcja PRZECHODZI."

  $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; additionalContext = $reason } } | ConvertTo-Json -Compress -Depth 6
  Write-Output $out
  exit 0
} catch { exit 0 }
