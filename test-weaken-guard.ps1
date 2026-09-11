# PreToolUse (Edit/Write/MultiEdit) guard+nudge:
#  (A) TEST files: ADD of a test-weakening pattern -> ASK (testing-patterns 2.1, anti-weaken).
#  (B) APP/BUSINESS code (non-test, non-.claude): non-blocking nudge -> Rule 1 (deleguj do specjalisty).
# Defensive: ANY error / irrelevant path => exit 0 (never blocks legit work). ASCII-only.
$ErrorActionPreference = 'SilentlyContinue'
try {
  $raw = [Console]::In.ReadToEnd()
  if (-not $raw) { exit 0 }
  $j = $raw | ConvertFrom-Json
  $ti = $j.tool_input
  if (-not $ti) { exit 0 }
  $path = [string]$ti.file_path
  if (-not $path) { exit 0 }

  # never nudge for .claude/ (skills, agents, commands, docs, hooks) or markdown
  if ($path -match '(?i)[\\/]\.claude[\\/]') { exit 0 }
  if ($path -match '(?i)\.(md|json|ya?ml|txt)$') { exit 0 }

  $isTest = $path -match '(?i)(\.spec\.ts$|Tests?\.cs$|[\\/]Tests?[\\/])'

  if ($isTest) {
    $added = ''
    $old   = ''
    if ($ti.content)    { $added = [string]$ti.content }
    if ($ti.new_string) { $added = [string]$ti.new_string; $old = [string]$ti.old_string }
    if ($ti.edits)      { foreach ($e in $ti.edits) { $added += "`n" + [string]$e.new_string } }
    if (-not $added) { exit 0 }

    $patterns = @(
      '\[Skip', '\[Ignore', '\bit\.skip\(', '\bxit\(', '\bdescribe\.skip',
      '\bfit\(', 'Assert\.True\(\s*true\s*\)', '\bSkip\s*=', 'Should\(\)\.NotThrow'
    )
    $hit = $null
    foreach ($p in $patterns) {
      if ($added -match $p) {
        if ($old -and ($old -match $p)) { continue }
        $hit = $p; break
      }
    }
    if (-not $hit) { exit 0 }
    $reason = "[TEST-GUARD] testing-patterns 2.1 (HARD RULE): zmiana w pliku testowym dodaje wzorzec oslabiajacy test ($hit). Dozwolone TYLKO gdy: (1) realna zmiana kontraktu z uzasadnieniem 'nowa = poprawna spec', albo (2) [Skip]/[Ignore] z konkretnym powodem. ZAKAZ oslabiania by 'przeszlo'. Potwierdz swiadomie albo popraw KOD zamiast testu."
    $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'ask'; permissionDecisionReason = $reason } } | ConvertTo-Json -Compress -Depth 6
    Write-Output $out
    exit 0
  }

  # (B) app/business code -> rule 1 nudge (non-blocking)
  $appCode = (
    # [\\/.] przed nazwa warstwy: realne foldery projektu to <Nazwa>.WebApi / .Logic / .Contracts / .Infrastructure / .GenericElements / .Mobile
    # (KROPKA, nie separator, bo nazwa katalogu projektu poprzedza segment warstwy) - z samym [\\/] nudge RULE1 nie odpalal na zadnym pliku tego repo od 2026-06-07; poprawka 2026-09-02 (test N-10)
    $path -match '(?i)[\\/.]WebApi[\\/]Controllers[\\/]' -or
    $path -match '(?i)[\\/.]Logic[\\/]' -or
    $path -match '(?i)[\\/.]Contracts[\\/]' -or
    $path -match '(?i)[\\/.]Infrastructure[\\/](Entities|Repositories)[\\/]' -or
    $path -match '(?i)[\\/.]Infrastructure[\\/]Scripts[\\/].*\.sql$' -or
    $path -match '(?i)[\\/.]GenericElements[\\/]' -or
    $path -match '(?i)\.(component|service)\.ts$' -or
    $path -match '(?i)[\\/.]Mobile[\\/].*\.(xaml|cs)$'
  )
  if ($appCode) {
    $reason = "[RULE1] '$path' wyglada na kod app/business. Jesli to NIE mechaniczna 1-linijka (rename/delecja/config) -> deleguj do specjalisty (04-MSSQL/05-API/07-Angular/08-MAUI) + 06-Guardian. Przypomnienie - akcja PRZECHODZI (nie blokuje)."
    $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; additionalContext = $reason } } | ConvertTo-Json -Compress -Depth 6
    Write-Output $out
  }
  exit 0
} catch { exit 0 }
