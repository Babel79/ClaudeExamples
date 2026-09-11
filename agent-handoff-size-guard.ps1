# PreToolUse (Agent) HARD guard: handoff musi byc maly + miec markery.
#  BLOKUJE (deny) gdy prompt do impl-agenta (04/05/07/08) jest > PROG znakow
#  LUB nie zawiera markerow 'SUCCESS CRITERIA' i 'SCOPE'.
#  Cel: wymusic vertical-slice (1 obserwowalne zachowanie, code+test razem),
#  zamiast jednego wielkiego zlecenia ktore zawiesza agenta (~50-65 tool-use).
# Defensive, ASCII-only (Windows PowerShell 5.1 czyta .ps1 jako ANSI). exit 0 always.
$ErrorActionPreference = 'SilentlyContinue'
try {
  $raw = [Console]::In.ReadToEnd()
  if (-not $raw) { exit 0 }
  $j = $raw | ConvertFrom-Json

  $sub = [string]$j.tool_input.subagent_type
  $prompt = [string]$j.tool_input.prompt
  if (-not $prompt) { exit 0 }

  # Tylko impl-agenci (kod/testy). GitHub/Guardian/Docs/Explore/research bez limitu.
  $isImpl = $sub -match '0[4578]-' -or $sub -match '03-qa'

  # 2026-09-02 (audyt srodowiska, 6.1): bramka nie obejmowala 09-e2e ani 14-vps, czyli kodu testow
  # E2E i wdrozenia na PRODUKCJE - dwoch miejsc, gdzie handoff bez SUCCESS CRITERIA/SCOPE kosztuje
  # najwiecej. Limit dlugosci ich NIE dotyczy: scenariusz E2E i runbook deployu z natury sa dlugie,
  # a ciecie ich na slice'y nie ma sensu (jedno przejscie sciezki = jedna calosc).
  $isSectionOnly = $sub -match '(?i)09-e2e' -or $sub -match '(?i)14-vps'

  if (-not $isImpl -and -not $isSectionOnly) { exit 0 }

  $len = $prompt.Length
  $PROG = 8000   # ~2k tokenow handoffu = gorny limit jednego slice (podniesione z 6000 na polecenie usera 2026-08-13)

  $hasCriteria = $prompt -match '(?i)SUCCESS\s*CRITERIA'
  $hasScope    = $prompt -match '(?i)\bSCOPE\b'

  $problems = @()
  if ($isImpl -and $len -gt $PROG) { $problems += "handoff $len znakow > limit $PROG (podziel na mniejszy slice)" }
  if (-not $hasCriteria) { $problems += "brak markera 'SUCCESS CRITERIA'" }
  if (-not $hasScope)    { $problems += "brak markera 'SCOPE'" }

  # F3: SUCCESS CRITERIA nie moze byc "mgla" (nieobserwowalne) - domkniecie bramy klaryfikacji.
  if ($hasCriteria) {
    $critBlock = $prompt
    if ($prompt -match '(?is)SUCCESS\s*CRITERIA(.*?)(?:REFERENCE|\bSCOPE\b|VERIFICATION|$)') { $critBlock = $Matches[1] }
    # slowa-mgly: word-boundary (\b) + klasa znakow [l\u0142] (l zwykle LUB l-z-kreska) tak, by
    # 'ladnie/ladniej' ORAZ 'ladnie/ladniej' (l-z-kreska) triggerowalo, ale 'dokladnie/ukladnie/
    # skladnie/bezladnie' (l-kreska W SRODKU slowa) juz NIE (ENV.8 - 'ADNIE' podlancuch w
    # 'DOKLADNIE' dawal false-positive). Oba warianty pisowni sa potrzebne: stdin dostarcza znak
    # spoza ASCII w SRODKU slowa jako '?' (0x3F), wiec plaskie ASCII 'l' bywa jedynym, co dotrze
    # do hooka mimo ze user napisal 'l-z-kreska' na poczatku slowa (cust_hook_authoring par.3).
    # \u0142 (l-z-kreska) to czysty ASCII-escape w pliku -> odporne na to jak PS5.1 czyta .ps1 (ANSI);
    # .NET regex operuje na Unicode-stringu z ConvertFrom-Json, wiec \b poprawnie widzi granice
    # wokol obu wariantow ('l' i U+0142 sa oba traktowane jako znaki slowa).
    $mush = 'lepiej|\b[l\u0142]adnie|brzydk|nicer|prettier|looks better|probably|chyba|popraw graficznie'
    if ($critBlock -match "(?i)($mush)") {
      $problems += "SUCCESS CRITERIA zawiera slowo-mgle ('$($Matches[1])') - kryterium musi byc OBSERWOWALNE, nie 'lepiej/ladniej'. Dopytaj usera (AskUserQuestion) i wpisz mierzalne 'gotowe gdy {observable}' (cust_orchestrator_clarification)."
    }
  }

  if ($problems.Count -gt 0) {
    $reason = "[HANDOFF-GUARD] Zlecenie do $sub odrzucone: " + ($problems -join '; ') + ". Regula (cust_orchestrator_planning): 1 vertical-slice = 1 obserwowalne zachowanie, code+test razem, handoff <= $PROG znakow, ZAWSZE z 'SUCCESS CRITERIA' + 'SCOPE' + 'REFERENCE FILE'. Podziel na 5 malych petli zamiast 1 duzej."
    $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $reason } } | ConvertTo-Json -Compress -Depth 6
    Write-Output $out
  }
  exit 0
} catch { exit 0 }
