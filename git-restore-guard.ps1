# git-restore-guard.ps1 - PreToolUse hook, matcher: Bash.  (N-9 z RAPORT_2026-09-02 par.6.2)
#
# PO CO: 'git checkout -- <plik>' i 'git restore <plik>' cofaja plik do HEAD. Przy pracy
# multi-slice (kilku agentow ma niezacommitowane zmiany w tym samym drzewie) taka komenda kasuje
# CUDZY WIP bez ostrzezenia i bez mozliwosci odzyskania - zmiany niezacommitowane nie sa nigdzie
# w historii ([[feedback_git_checkout_destroys_sibling_wip]]).
# destructive-bulk-guard blokuje juz wariant 'git checkout/restore -- .' (cale drzewo). Ten hook
# zajmuje sie wariantem PUNKTOWYM na pojedynczy plik, ktory sam w sobie bywa uzasadniony - dlatego
# 'ask', nie 'deny', i tylko wtedy, gdy drzewo faktycznie ma co stracic (>1 zmieniony plik).
#
# WARUNEK RYZYKA: 'git status --porcelain' w cwd hooka pokazuje >1 plik zmodyfikowany/dodany.
# Przy jednym pliku rewert dotyczy wylacznie wlasnej pracy - pytanie byloby czystym halasem
# (pitfall "ask tam, gdzie nie ma legalnego wyjatku" dziala w obie strony).
#
# DOPASOWANIE DO CZASOWNIKA, NIE DO TEKSTU - ta sama mechanika co destructive-bulk-guard v2:
# wycinamy ciala heredocow i argumenty echo/printf, tniemy na segmenty po ; && || | i nowej linii,
# wzorca szukamy TYLKO na pozycji czasownika. Bez tego cytat komendy w pisanym pliku .md
# (change-log, notatka o incydencie) wywolywalby pytanie - to byla klasa 6/14 falszywek v1.
#
# NIE dotyczy: 'git restore --staged' (to unstage, nie kasuje tresci roboczej),
#              'git checkout <branch>' / 'git checkout -b' (przelaczenie galezi, brak '--'),
#              '-- .' (obsluzone twardym deny w destructive-bulk-guard).
# ASCII-only (PS 5.1 czyta .ps1 jako ANSI). exit 0 always.
$ErrorActionPreference = 'SilentlyContinue'
try {
  $raw = [Console]::In.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
  $j = $null
  try { $j = $raw | ConvertFrom-Json } catch { exit 0 }
  if ($null -eq $j) { exit 0 }

  $cmd = [string]$j.tool_input.command
  if ([string]::IsNullOrWhiteSpace($cmd)) { exit 0 }

  # --- (1) wytnij ciala heredocow ---
  $scan = [regex]::Replace($cmd, '(?sm)<<-?\s*([''"]?)([A-Za-z_][A-Za-z0-9_]*)\1.*?^\s*\2\s*$', ' HEREDOC ')
  $scan = [regex]::Replace($scan, '(?s)<<-?\s*([''"]?)[A-Za-z_][A-Za-z0-9_]*\1.*$', ' HEREDOC ')
  # --- (2) wytnij argumenty echo/printf ---
  $scan = [regex]::Replace($scan, '(?i)\b(echo|printf)\s+("(?:[^"\\]|\\.)*"|''[^'']*''|[^;&|<>\r\n]*)', ' echo ')
  # --- (3) segmenty; czasownik = pierwszy token segmentu ---
  $segments = [regex]::Split($scan, '(?:;|&&|\|\||\||\r?\n)')

  $hit = $null
  foreach ($seg in $segments) {
    if ($null -ne $hit) { break }
    $s = [string]$seg
    if ([string]::IsNullOrWhiteSpace($s)) { continue }
    $s = $s.Trim()
    $s = $s -replace '^\(+\s*', ''
    $s = $s -replace '^(?i)(sudo|env|time|nohup|xargs)\s+', ''
    $s = $s -replace '^[A-Za-z_][A-Za-z0-9_]*=\S*\s+', ''
    if ([string]::IsNullOrWhiteSpace($s)) { continue }

    # (A) git checkout -- <sciezka>   (sciezka inna niz '.', bo '.' lapie destructive-bulk-guard)
    if ($s -match '(?i)^git\s+(-C\s+\S+\s+)?checkout\b') {
      if ($s -match '(?i)\s--\s+(\S+)') {
        $arg = $Matches[1]
        if ($arg -ne '.' -and $arg -notmatch '^-') { $hit = "git checkout -- $arg" }
      }
    }
    # (B) git restore <sciezka>  (bez --staged; '--' opcjonalne)
    elseif ($s -match '(?i)^git\s+(-C\s+\S+\s+)?restore\b') {
      if ($s -notmatch '(?i)--staged\b') {
        $rest = $s -replace '(?i)^git\s+(-C\s+\S+\s+)?restore\b', ''
        $arg = $null
        foreach ($tok in ($rest -split '\s+')) {
          if ([string]::IsNullOrWhiteSpace($tok)) { continue }
          if ($tok -eq '--') { continue }
          if ($tok -match '^-') { continue }          # flagi: --worktree, --source=X, -W ...
          $arg = $tok; break
        }
        if ($arg -and $arg -ne '.') { $hit = "git restore $arg" }
      }
    }
  }

  if (-not $hit) { exit 0 }

  # --- ile plikow jest w grze? ---
  $cwd = if ($env:OH_HOOK_ROOT) { $env:OH_HOOK_ROOT }
         elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR }
         elseif ($j.cwd) { [string]$j.cwd }
         else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  if (-not (Test-Path -LiteralPath $cwd)) { exit 0 }

  $n = 0
  try {
    $st = @(& git -C $cwd status --porcelain 2>$null)
    foreach ($line in $st) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $code = ''
      if ($line.Length -ge 2) { $code = $line.Substring(0, 2) }
      # tylko tracked: zmodyfikowane / dodane / przeniesione / skasowane.
      # '??' (untracked) pomijamy - 'git checkout --' ich nie rusza, wiec nie sa zagrozone.
      if ($code -match '[MARCD]') { $n++ }
    }
  } catch { exit 0 }

  if ($n -le 1) { exit 0 }

  $reason = "[RESTORE-GUARD] Drzewo ma $n zmienionych plikow, a komenda to '$hit'. git checkout -- / git restore cofa plik do HEAD i kasuje cudzy WIP w multi-slice (feedback_git_checkout_destroys_sibling_wip). Rewert punktowy: git hash-object -w + cat-file -p. Potwierdz, jesli zamierzone."
  $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'ask'; permissionDecisionReason = $reason } } | ConvertTo-Json -Compress -Depth 6
  Write-Output $out
  exit 0
}
catch { exit 0 }
