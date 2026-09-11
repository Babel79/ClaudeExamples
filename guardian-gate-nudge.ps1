# PreToolUse (Agent) nudge (rec5): przypomnienie o 06-Guardian przed commit/PR nowego kodu.
# Kontekst: analiza telemetrii wykazala guardian(85):impl(277) -> audyt bywa pomijany.
# Gdy Orchestrator wola 01-github-devops-agent do COMMITU/PR nowej implementacji ->
# przypomnij ze 06-Guardian musial audytowac zmiany impl PRZED commitem.
# Non-blocking (additionalContext). exit 0 always. ASCII-only (PS5.1 czyta .ps1 jako ANSI).
$ErrorActionPreference = 'SilentlyContinue'
try {
  $raw = [Console]::In.ReadToEnd()
  if (-not $raw) { exit 0 }
  $j = $raw | ConvertFrom-Json
  $sub = [string]$j.tool_input.subagent_type
  $prompt = [string]$j.tool_input.prompt
  if (-not $sub) { exit 0 }
  # 2026-09-02 (audyt srodowiska, 6.1): hook strzelal takze na commitach CZYSTEJ DOKUMENTACJI
  # (.md, .claude/, docs) - a Guardian audytuje architekture kodu, wiec przypominanie o nim przy
  # commicie backlogu/KB to czysty szum. Heurystyka: nudge tylko wtedy, gdy w prompcie w ogole
  # wystepuje rozszerzenie pliku KODU. Swiadoma luka: commit kodu opisany bez nazwy pliku
  # ("zacommituj zmiany") nudge'a nie dostanie - to wybor na rzecz zera falszywek.
  $touchesCode = $prompt -match '(?i)\.(cs|ts|html|scss|sql|xaml|csproj|json)\b'

  # tylko 01-github + slowo 'commit' (nie sam 'merge'/'branch') = bramka gdzie mozna pominac Guardiana
  # 2026-09-02: wzorzec byl '\bcommit\b' i NIE lapal polskiej odmiany, ktorej uzywamy w handoffach
  # na co dzien ("Zacommituj zmiany w X.cs") - nudge milczal dokladnie tam, gdzie mial dzialac.
  # Zawezenie do kodu ($touchesCode) pozwala poluzowac to dopasowanie bez ryzyka halasu.
  if ($sub -match '01-github' -and $prompt -match '(?i)commit' -and $touchesCode) {
    $reason = "[GUARDIAN-GATE] Commit/PR nowego kodu przez 01-github. Regula: 06-Guardian po KAZDEJ implementacji (05/07/04/08). Potwierdz ze Guardian audytowal ten changeset PRZED commitem; jesli nie -> odpal 06-architecture-guardian-agent najpierw. (nudge - nie blokuje)"
    $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; additionalContext = $reason } } | ConvertTo-Json -Compress -Depth 6
    Write-Output $out
  }
  exit 0
} catch { exit 0 }
