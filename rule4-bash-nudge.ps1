# PreToolUse (Bash) guard + silent telemetry:
#  (A) HARD: 'dotnet build/test/run' piped to grep -> DENY (grep maskuje exit code -> falszywe zielone, PR z historii tego repo).
#      2026-09-02 (audyt srodowiska): 'ask' -> 'deny'. 'ask' w trybie acceptEdits bywal klikany odruchowo,
#      a nie istnieje legalny powod filtrowania wyniku buildu grepem w TEJ SAMEJ komendzie (alternatywa w komunikacie).
#  (B) SOFT -> SILENT: grep/find/sed/sqlcmd jako verb -> TYLKO log do tsv, BEZ additionalContext.
#      2026-09-02: nudge strzelal 123x w oknie 13 dni; konflikt "tryb auto (Bash wszedzie) vs ZASADA 4" zglaszany
#      niezaleznie w 9/14 sesji jako szum. Rozstrzygniecie CLAUDE.md 4a nie zatrzymalo zgloszen, bo hook je
#      generowal na nowo. Pomiar zostaje (tsv), wstrzykiwanie znika. Analiza: .claude/tasks/reports/agent-analize/RAPORT_2026-09-02.md
#
# NORMALIZACJA 2026-09-10 (ENV.142 + ENV.145 - to JEDEN defekt zgloszony dwoma kartami):
#  galaz (A) dopasowywala wzorzec do CALEGO tekstu komendy, wiec nie odrozniala UZYCIA od WZMIANKI.
#  DENY dostawaly: skrypt, ktory wzorzec tylko CYTUJE w literale (trafione realnie 2x); 'grep' szukajacy
#  tego wzorca w repozytorium albo w dokumentacji; zapis karty backlogu z tym wzorcem jako przykladem.
#  Skutek byl odwrotny do zamierzonego - nie dalo sie tym hookiem edytowac ani dokumentowac reguly,
#  ktorej on sam pilnuje.
#  Fix (trzy kroki przed dopasowaniem):
#    1) usun cialo heredoca (to dane, nie komenda),
#    2) zamaskuj literaly w cudzyslowach placeholderem @@LITn@@ (separator w cudzyslowie nie tnie czlonu),
#    3) podziel komende na czlony po ';' '&&' '||' i nowej linii i oceniaj KAZDY czlon OSOBNO.
#  OCHRONA NIE SLABNIE: w czlonie bedacym opakowaniem powloki (bash -c / sh -c / powershell -Command /
#  cmd /c / eval / xargs) literaly sa PRZYWRACANE przed dopasowaniem, wiec realna ewazja
#  'bash -c "dotnet test | grep FAIL"' nadal dostaje DENY. Czlonow NIE dzielimy po '|', bo potok
#  JEST trescia wzorca (A).
# Defensive, ASCII-only (Windows PowerShell 5.1 czyta .ps1 jako ANSI). exit 0 always.
$ErrorActionPreference = 'SilentlyContinue'

# --- wspolna normalizacja (swiadomie zduplikowana w sharptools-first-guard.ps1 -
#     hooki nie maja wspolnego modulu, a rejestracja w settings.json jest poza zakresem) ---
function Remove-HeredocBodies([string]$text) {
  $out = $text
  foreach ($m in [regex]::Matches($text, '<<-?\s*["'']?([A-Za-z_][A-Za-z0-9_]*)["'']?')) {
    $delim = $m.Groups[1].Value
    $body = [regex]::Match($out, '(?ms)<<-?\s*["'']?' + [regex]::Escape($delim) + '["'']?.*?^\s*' + [regex]::Escape($delim) + '\s*$')
    if ($body.Success) { $out = $out.Replace($body.Value, ' HEREDOC_BODY_STRIPPED ') }
  }
  return $out
}

function Get-MaskedLiterals([string]$text) {
  $lits = New-Object System.Collections.ArrayList
  $masked = $text
  $rx = [regex]'"[^"]*"|''[^'']*'''
  while ($true) {
    $m = $rx.Match($masked)
    if (-not $m.Success) { break }
    $idx = $lits.Count
    [void]$lits.Add($m.Value)
    $masked = $masked.Substring(0, $m.Index) + ('@@LIT' + $idx + '@@') + $masked.Substring($m.Index + $m.Length)
  }
  return @{ Masked = $masked; Literals = $lits }
}

function Restore-Literals([string]$seg, $lits) {
  $out = $seg
  for ($i = 0; $i -lt $lits.Count; $i++) { $out = $out.Replace('@@LIT' + $i + '@@', [string]$lits[$i]) }
  return $out
}

try {
  $raw = [Console]::In.ReadToEnd()
  if (-not $raw) { exit 0 }
  $j = $raw | ConvertFrom-Json
  $cmd = [string]$j.tool_input.command
  if (-not $cmd) { exit 0 }

  # (A) HARD: dotnet build/test/run piped into a text filter -> deny (exit code gets masked by the filter)
  $filters = '(grep|egrep|fgrep|findstr|Select-String|sls|tail|head|more|less|cat|sed|awk)'
  $mk = Get-MaskedLiterals (Remove-HeredocBodies $cmd)
  # UWAGA: separatorem jest '&&', NIE pojedynczy '&' - inaczej przekierowanie '2>&1' zostaje
  # przeciete na pol i realny potok 'dotnet build 2>&1 | grep error' przestaje byc wykrywany
  # (zmierzone: dwa czerwone przypadki suity przy pierwszym przebiegu tej wersji).
  foreach ($seg in [regex]::Split($mk.Masked, ';|&&|\|\||\r?\n')) {
    if ([string]::IsNullOrWhiteSpace($seg)) { continue }
    $scan = $seg
    # czlon uruchamiajacy powloke wykonuje TRESC literalu jako komende -> literal jest komenda, nie danymi
    if (($seg -match '(?i)(^|\s)(bash|sh|zsh|dash|ksh|pwsh|powershell)(\.exe)?\b.*(\s|^)-(c|Command)\b') -or
        ($seg -match '(?i)(^|\s)cmd(\.exe)?\b.*(\s|^)/[cCkK]\b') -or
        ($seg -match '(?i)(^|\s)(eval|xargs)\b')) {
      $scan = Restore-Literals $seg $mk.Literals
    }
    if ($scan -match ('(?is)\bdotnet\s+(test|build|run)\b.*\|\s*' + $filters + '\b')) {
      $reason = "[BUILD-GUARD] 'dotnet build/test/run' potokowany do filtra (grep/egrep/findstr/tail/head/cat/less/more/sed/awk) maskuje exit code (exit = exit filtra, nie buildu) -> falszywe zielone (PR z historii tego repo wszedl czerwony na main). ZABLOKOWANE. Uzyj: 'dotnet test ... ; echo EXIT=`$?' - najlepiej z przekierowaniem '> log.txt 2>&1', a log czytaj OSOBNA komenda (Read/Grep tool). Alternatywa: '--logger trx' / '-v:quiet'."
      $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $reason } } | ConvertTo-Json -Compress -Depth 6
      Write-Output $out
      exit 0
    }
  }

  # (B) SILENT telemetry: grep/find/sed/sqlcmd as a command verb -> append one tsv row, no context injection.
  # Wyjatki (ENV.34 tego projektu) zachowane: narzedzie po potoku czyta STDIN; potok do agregatora (wc/sort/uniq/awk/jq/...).
  if ($cmd -match '(?im)(^|;|&&|\|\|)\s*(grep|find|sed|sqlcmd)\b' -and
      $cmd -notmatch '(?i)\|\s*(wc|sort|uniq|awk|jq|python|tr|cut|paste)\b') {
    $tool = $Matches[2].ToLower()
    $sid = [string]$j.session_id
    if ($sid.Length -gt 8) { $sid = $sid.Substring(0, 8) }
    $agent = 'orchestrator'
    try {
      $tp = [string]$j.transcript_path
      if ($tp -match '[\\/]subagents[\\/]') { $agent = 'subagent' }
    } catch {}
    $snippet = ($cmd -replace '[\r\n\t]', ' ')
    if ($snippet.Length -gt 160) { $snippet = $snippet.Substring(0, 160) }
    $row = "{0}`t{1}`t{2}`t{3}`t{4}" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'), $sid, $agent, $tool, $snippet
    $root = if ($env:OH_HOOK_ROOT) { $env:OH_HOOK_ROOT }
            elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR }
            elseif ($j.cwd) { $j.cwd }
            else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $kbDir = if ($env:OH_HOOK_KB_DIR) { $env:OH_HOOK_KB_DIR } else { Join-Path $root '.claude\knowledge-base' }
    $log = Join-Path $kbDir 'rule4_nudges.tsv'
    if (-not (Test-Path $log)) { Set-Content -Path $log -Value "utc`tsession8`tcaller`ttool`tcmd" -Encoding UTF8 }
    Add-Content -Path $log -Value $row -Encoding UTF8
  }
  exit 0
} catch { exit 0 }
