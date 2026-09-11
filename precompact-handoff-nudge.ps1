# precompact-handoff-nudge.ps1 - JEDEN skrypt, DWA zdarzenia.  (N-7 z RAPORT_2026-09-02 par.6.2)
#   1) PreCompact       -> zostawia marker .claude/PRECOMPACT_HANDOFF.txt
#   2) UserPromptSubmit -> podnosi marker jako additionalContext i kasuje go
#
# DLACZEGO TAK, A NIE PROSCIEJ - USTALENIE Z DOKUMENTACJI (code.claude.com/docs/en/hooks.md):
#   PreCompact NIE potrafi wstrzyknac kontekstu. W tabeli "Decision control" PreCompact stoi w
#   wierszu 'Top-level decision' z polami: decision: "block", reason - a przypis mowi wprost, ze
#   sposrod tego wiersza "Stop and SubagentStop ALSO accept hookSpecificOutput.additionalContext".
#   PreCompact w tym wyliczeniu NIE wystepuje; nie ma go tez w wierszu "Context only"
#   (SessionStart, SubagentStart, PostModelSwitch). Do tego sekcja "Exit code 0" wymienia zdarzenia,
#   ktorych stdout trafia do Claude jako kontekst - UserPromptSubmit, UserPromptExpansion,
#   SessionStart, PostModelSwitch - PreCompact tam nie ma, wiec goly stdout ida do debug logu.
#   Sekcja PreCompact dodaje: "Claude Code discards a PreCompact hook's systemMessage and continue".
#   Jedyny kanal PreCompact do modelu to decision:"block", ktory ZATRZYMUJE kompakcje - a blokowanie
#   auto-kompakcji po przekroczeniu limitu okna wywala biezace zadanie ("the underlying error
#   surfaces and the current request fails"). Dlatego nie blokujemy.
#   Rozwiazanie: marker na dysku + odbior przy najblizszym prompcie usera (ten sam wzorzec, co
#   mutation-leftover-detector -> alert-mutation-leftover).
#
# KONSEKWENCJA, KTORA TRZEBA ZNAC: przypomnienie dociera PO kompakcji, nie przed. Chroni przed
# utrata stanu nie tak, ze zatrzymuje kompakcje, tylko tak, ze zaraz po niej kaze odtworzyc handoff
# z tego, co zostalo (CLAUDE.md par.17). Zeby dostac je PRZED - trzeba by blokowac kompakcje.
#
# ASCII-only (PS 5.1 czyta .ps1 jako ANSI). exit 0 always.
$ErrorActionPreference = 'SilentlyContinue'

try {
  $raw = [Console]::In.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
  $j = $raw | ConvertFrom-Json

  $root = if ($env:OH_HOOK_ROOT) { $env:OH_HOOK_ROOT }
          elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR }
          elseif ($j.cwd) { $j.cwd }
          else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  $claudeDir = Join-Path $root '.claude'
  if (-not (Test-Path -LiteralPath $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }
  $marker = Join-Path $claudeDir 'PRECOMPACT_HANDOFF.txt'
  $enc = [System.Text.UTF8Encoding]::new($false)

  $ev = [string]$j.hook_event_name

  # ---------- 1) PRE-COMPACT: zostaw marker ----------
  if ($ev -eq 'PreCompact') {
    # Marker tylko wtedy, gdy sesja ma co tracic: byly wywolania Agent ALBO drzewo jest brudne.
    $worth = $false
    try {
      $tp = [string]$j.transcript_path
      if ($tp) {
        $subDir = ($tp -replace '\.jsonl$', '') + '\subagents'
        if (Test-Path -LiteralPath $subDir) {
          $n = @(Get-ChildItem -LiteralPath $subDir -Filter 'agent-*.jsonl' -ErrorAction SilentlyContinue).Count
          if ($n -gt 0) { $worth = $true }
        }
      }
    } catch {}
    if (-not $worth) {
      try {
        $st = & git -C $root status --porcelain 2>$null
        if ($st) { $worth = $true }
      } catch {}
    }
    if (-not $worth) { exit 0 }

    $trig = [string]$j.trigger
    if (-not $trig) { $trig = 'auto' }
    $nowUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $body = "PRECOMPACT $nowUtc trigger=$trig"
    [System.IO.File]::WriteAllText($marker, $body + "`r`n", $enc)
    exit 0
  }

  # ---------- 2) USER-PROMPT-SUBMIT: podnies marker ----------
  if (-not (Test-Path -LiteralPath $marker)) { exit 0 }

  $stamp = ''
  try { $stamp = ([System.IO.File]::ReadAllText($marker)).Trim() } catch {}
  Remove-Item -LiteralPath $marker -Force

  $msg = "[PRECOMPACT] Kontekst tej sesji zostal skompaktowany ($stamp). W sesji byly wywolania Agent lub zmiany plikow, wiec czesc szczegolow jest juz poza oknem. Zanim ruszysz dalej: odtworz i zapisz .claude/tasks/oldsession.md (CLAUDE.md par.17) - stan na wejsciu, CO DALEJ z ID kart, zmierzone pulapki, NOT DONE. Handoff opisuje stan i wiedze, nie streszcza rozmowy."
  $out = @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = $msg } } | ConvertTo-Json -Compress -Depth 5
  Write-Output $out
  exit 0
}
catch { exit 0 }
