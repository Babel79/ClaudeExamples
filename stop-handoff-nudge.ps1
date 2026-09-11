# stop-handoff-nudge.ps1 - Stop hook.  (N-6 z RAPORT_2026-09-02 par.6.2)
#
# PO CO: CLAUDE.md par.17 mowi, ze handoff .claude/tasks/oldsession.md ma powstac ZANIM padnie
# sugestia zakonczenia sesji - bo user, ktory zobaczy sugestie pierwszy, robi /clear i wiedza
# sesji przepada. Regula byla wylacznie w tekscie; nic jej nie przypominalo w momencie, w ktorym
# Orchestrator faktycznie konczy ture.
#
# CO ROBI: przy zejsciu Orchestratora sprawdza dwa warunki naraz:
#   (1) sesja byla ciezka - >=3 wywolania Agent,
#   (2) oldsession.md jest STARSZY niz poczatek tej sesji, czyli w tej sesji nie byl nadpisany.
# Oba spelnione -> jedna linia przypomnienia. Ktorykolwiek nie -> CISZA.
# Prog 3 wywolan, a nie 1: sesja z jednym drobnym agentem nie ma czego przekazywac, a nudge na
# kazdym Stopie to dokladnie pitfall "nudge na kazdym zdarzeniu" (rule4 nudge: 123x/13 dni).
#
# ANTY-PETLA: stop_hook_active=true oznacza, ze model kontynuuje PO tym, jak poprzedni hook Stop
# kazal mu isc dalej. Wtedy wychodzimy natychmiast - inaczej hook moglby napedzac sam siebie.
#
# ZRODLO LICZBY AGENTOW (najtansze wiarygodne): .claude/knowledge-base/agents_logs_raw.tsv pisany
# przez agent-telemetry-capture (UPSERT po agent_id, kolumna 2 = session8). Liczymy wiersze tej
# sesji. Fallback, gdy tsv nie ma albo nie zna sesji: zliczenie '"name":"Agent"' w transkrypcie.
#
# KANAL WYJSCIA: hookSpecificOutput.additionalContext dla zdarzenia Stop.
# Zrodlo: cust_hook_authoring par.2 (wiersz Stop: "additionalContext; decision: block") oraz przypis
# docs cytowany w precompact-handoff-nudge - "Stop and SubagentStop ALSO accept
# hookSpecificOutput.additionalContext". Swiadomie NIE uzywamy decision:"block": block zmusza model
# do kontynuowania tury, a to przypomnienie ma byc informacja, nie przymusem.
#
# ASCII-only (PS 5.1 czyta .ps1 jako ANSI). exit 0 always.
$ErrorActionPreference = 'SilentlyContinue'

function Get-FirstTimestamp {
  param([string]$Path)
  $sr = $null
  try {
    $sr = New-Object System.IO.StreamReader($Path)
    while (-not $sr.EndOfStream) {
      $line = $sr.ReadLine()
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $o = $null
      try { $o = $line | ConvertFrom-Json } catch { continue }
      if ($o.timestamp) {
        try {
          return [datetime]::Parse($o.timestamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        } catch { }
      }
    }
  } catch { }
  finally { if ($sr) { $sr.Close(); $sr.Dispose() } }
  return $null
}

function Measure-AgentCallsInTranscript {
  param([string]$Path)
  $n = 0
  $sr = $null
  try {
    $sr = New-Object System.IO.StreamReader($Path)
    while (-not $sr.EndOfStream) {
      $line = $sr.ReadLine()
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $n += ([regex]::Matches($line, '"name"\s*:\s*"Agent"')).Count
    }
  } catch { }
  finally { if ($sr) { $sr.Close(); $sr.Dispose() } }
  return $n
}

try {
  $raw = [Console]::In.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
  $j = $null
  try { $j = $raw | ConvertFrom-Json } catch { exit 0 }
  if ($null -eq $j) { exit 0 }

  # --- anty-petla ---
  if ($j.stop_hook_active) { exit 0 }

  # --- tylko glowny watek (subagent ma wlasne zdarzenie SubagentStop) ---
  if ($j.agent_id) { exit 0 }

  $root = if ($env:OH_HOOK_ROOT) { $env:OH_HOOK_ROOT }
          elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR }
          elseif ($j.cwd) { $j.cwd }
          else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $sid = [string]$j.session_id
  $sess8 = if ($sid.Length -ge 8) { $sid.Substring(0, 8) } else { $sid }

  $transcript = [string]$j.transcript_path

  # --- (1) ile wywolan Agent w tej sesji ---
  $agentCalls = 0
  $srcLabel = 'telemetria'
  try {
    $kbDir = $env:OH_HOOK_KB_DIR
    if ([string]::IsNullOrWhiteSpace($kbDir)) { $kbDir = Join-Path $root '.claude\knowledge-base' }
    $tsv = Join-Path $kbDir 'agents_logs_raw.tsv'
    if ($sess8 -and (Test-Path -LiteralPath $tsv)) {
      foreach ($l in [System.IO.File]::ReadAllLines($tsv)) {
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        $cols = $l -split "`t"
        if ($cols.Length -ge 2 -and $cols[1] -eq $sess8) { $agentCalls++ }
      }
    }
  } catch { }

  if ($agentCalls -eq 0 -and $transcript -and (Test-Path -LiteralPath $transcript)) {
    $agentCalls = Measure-AgentCallsInTranscript -Path $transcript
    $srcLabel = 'transkrypt'
  }

  if ($agentCalls -lt 3) { exit 0 }

  # --- (2) czy oldsession.md byl nadpisany W TEJ sesji ---
  $handoff = Join-Path $root '.claude\tasks\oldsession.md'
  if (Test-Path -LiteralPath $handoff) {
    $sessionStart = $null
    if ($transcript -and (Test-Path -LiteralPath $transcript)) {
      $sessionStart = Get-FirstTimestamp -Path $transcript
      if ($null -eq $sessionStart) {
        try { $sessionStart = (Get-Item -LiteralPath $transcript).CreationTime } catch { }
      }
    }
    # bez punktu odniesienia nie oskarzamy - cisza jest tansza niz falszywy alarm
    if ($null -eq $sessionStart) { exit 0 }

    $mtime = (Get-Item -LiteralPath $handoff).LastWriteTime
    # porownanie w UTC: timestamp z transkryptu jest w formacie roundtrip (Z)
    if ($mtime.ToUniversalTime() -ge $sessionStart.ToUniversalTime()) { exit 0 }
  }
  # brak pliku = tym bardziej nie byl nadpisany -> lecimy dalej

  $msg = "[HANDOFF] W tej sesji bylo $agentCalls wywolan Agent, a oldsession.md nie byl nadpisany (CLAUDE.md par.17). Jesli konczysz sesje - najpierw nadpisz handoff. Telemetria: $agentCalls wierszy agentow dla tej sesji (zrodlo: $srcLabel)."
  $out = @{ hookSpecificOutput = @{ hookEventName = 'Stop'; additionalContext = $msg } } | ConvertTo-Json -Compress -Depth 5
  Write-Output $out
  exit 0
}
catch { exit 0 }
