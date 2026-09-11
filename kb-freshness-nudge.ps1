# PostToolUse (Write|Edit|MultiEdit) nudge: nowy/zmieniony skrypt migracji lub kontroler
# -> przypomnij o aktualizacji knowledge-base (db-schema.md / api-contracts.md).
# Adresuje drift KB (audyt 2026-06-30: db-schema "Next number 0091" mimo 0118; api-contracts sprzed ~14 kontrolerow).
# SOFT nudge (additionalContext) - NIE blokuje. ASCII-only (PS 5.1 czyta .ps1 jako ANSI). exit 0 always.
#
# WERSJA 2 (2026-09-02) - THROTTLING RAZ NA SESJE PER PLIK.
#   v1 strzelala przy KAZDEJ edycji, wiec agent pracujacy nad jednym kontrolerem dostawal ten sam
#   tekst 5-10 razy w jednym zadaniu. To jest pitfall "nudge na kazdym zdarzeniu" ze skilla
#   cust_hook_authoring (rule4 nudge: 123 emisje w 13 dni, zgloszony jako szum w 9/14 sesji) -
#   przypomnienie powtarzane traci sile i uczy ignorowania calej klasy komunikatow.
#   Klucz throttlingu = session_id + sciezka pliku (lowercase). Stan: .claude/KB_FRESHNESS_SEEN.txt,
#   czyli ten sam katalog markerow, w ktorym precompact-handoff-nudge trzyma PRECOMPACT_HANDOFF.txt.
#   PIERWSZE trafienie w sesji dziala dokladnie jak w v1 (tresc komunikatow bez zmian).
#   Brak session_id (recznie odpalony hook) -> nie throttlujemy, zeby nie zgubic komunikatu.
$ErrorActionPreference = 'SilentlyContinue'
try {
  $raw = [Console]::In.ReadToEnd()
  if (-not $raw) { exit 0 }
  $j = $raw | ConvertFrom-Json
  $path = [string]$j.tool_input.file_path
  if (-not $path) { exit 0 }
  $p = $path -replace '\\','/'

  $msg = $null
  if ($p -match '(?i)Infrastructure/Scripts/[0-9]{4}_.*\.sql$') {
    $msg = "[KB-FRESHNESS] Dotknieto migracji SQL. Po merge zaktualizuj '.claude/knowledge-base/db-schema.md' (Next number + nowa tabela/kolumna) - inaczej drift (audyt: db-schema bylo 28 migracji za kodem). Deleguj do 10-docs-kb-agent przy PR. Nudge - nie blokuje."
  }
  elseif ($p -match '(?i)WebApi/Controllers/.*Controller\.cs$') {
    $msg = "[KB-FRESHNESS] Dotknieto kontrolera. Jesli dodano/zmieniono endpoint - zaktualizuj '.claude/knowledge-base/api-contracts.md' (sekcja endpointow + Last update). Deleguj do 10-docs-kb-agent przy PR. Nudge - nie blokuje."
  }

  if (-not $msg) { exit 0 }

  # --- throttling: raz na sesje per plik ---
  $sid = [string]$j.session_id
  if (-not [string]::IsNullOrWhiteSpace($sid)) {
    $root = if ($env:OH_HOOK_ROOT) { $env:OH_HOOK_ROOT }
            elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR }
            elseif ($j.cwd) { $j.cwd }
            else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $claudeDir = Join-Path $root '.claude'
    if (-not (Test-Path -LiteralPath $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }
    $seenFile = Join-Path $claudeDir 'KB_FRESHNESS_SEEN.txt'
    $key = ($sid + '|' + $p).ToLowerInvariant()
    $enc = [System.Text.UTF8Encoding]::new($false)
    if (Test-Path -LiteralPath $seenFile) {
      foreach ($l in [System.IO.File]::ReadAllLines($seenFile)) {
        if ($l -eq $key) { exit 0 }   # juz przypominane w tej sesji dla tego pliku
      }
    }
    [System.IO.File]::AppendAllText($seenFile, $key + "`r`n", $enc)
  }

  $out = @{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = $msg } } | ConvertTo-Json -Compress -Depth 6
  Write-Output $out
  exit 0
} catch { exit 0 }
