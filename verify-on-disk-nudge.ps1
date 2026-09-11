# verify-on-disk-nudge.ps1 - PostToolUse hook, matcher: Agent.  (N-1 z RAPORT_2026-09-02 par.6.2)
#
# PO CO: ZASADA 2 + cust_agent_protocol sekcja 6 kaza zweryfikowac raport impl-agenta NA DYSKU
# (git status --short + grep/count) ZANIM Orchestrator uwierzy w "PASS". Regula nie miala zadnego
# mechanizmu - phantom-PASS zdarzyl sie 2x, phantom-write 3x. Ten hook wstrzykuje przypomnienie
# dokladnie w momencie, w ktorym Orchestrator dostaje wynik agenta.
#
# ZAKRES (rozszerzony 2026-09-09): agenci implementacyjni (03/04/05/07/08) dostaja PELNY komunikat
# (verify-on-disk + zakaz tury 'czekam'); KAZDY inny agent dostaje krotki - sam zakaz tury 'czekam'.
# Wczesniej dla Explore/Guardian/GitHub byla cisza, bo nie maja 'zmiany na dysku'. Ale problem tur
# 'czekam' nie zalezy od typu agenta: zmierzone w sesji 6f9fee25 - 17 tur BEZ ZADNEGO narzedzia,
# przy srednim kontekscie 235 268 tok/ture = 4,0 mln odczytu cache wyrzucone za komunikaty 'czekam
# na agenta'. To nie jest rzadki przypadek (D4), tylko 16,7% wszystkich tur jednej sesji.
#
# 2026-09-09 POPRAWKA TRESCI: hook odpala sie na POTWIERDZENIU STARTU agenta (wynik narzedzia Agent
# przy dispatchu asynchronicznym), a NIE na jego zejsciu - zweryfikowane na transkrypcie: 0 wstrzykniec
# przy powiadomieniach o zejsciu. Stara tresc mowila 'Agent zszedl' i byla po prostu nieprawdziwa.
#
# Docs (code.claude.com/docs/en/hooks.md): PostToolUse przyjmuje tool_name/tool_input, a
# hookSpecificOutput.additionalContext jest dostarczany "next to the tool result".
# ASCII-only (PS 5.1 czyta .ps1 jako ANSI). exit 0 always.
$ErrorActionPreference = 'SilentlyContinue'
try {
  $raw = [Console]::In.ReadToEnd()
  if (-not $raw) { exit 0 }
  $j = $raw | ConvertFrom-Json

  $sub = [string]$j.tool_input.subagent_type
  if (-not $sub) { exit 0 }

  $waitRule = "NIE koncz tury samym statusem 'czekam na agenta' - powiadomienie o zejsciu obudzi Cie samo, a pusta tura kosztuje PELNY kontekst (zmierzone 2026-09-09: 17 takich tur = 4,0 mln odczytu cache w jednej sesji)."

  if ($sub -match '(?i)^(0[34578]-|03-qa|04-mssql|05-api|07-angular|08-maui)') {
    $msg = "[PO DISPATCHU] Agent wystartowal asynchronicznie - to potwierdzenie STARTU, nie zejscie. 1) $waitRule 2) Gdy wroci: git status --short + grep/count vs raport ZANIM uwierzysz w PASS (cust_agent_protocol sekcja 6); przy fali rownoleglej zrob to JEDNA tura dla wszystkich agentow, ale z osobnym dowodem per karta. 3) Return uciety != awaria - sprawdz dysk zanim re-dispatchujesz."
  }
  else {
    $msg = "[PO DISPATCHU] Agent wystartowal asynchronicznie. $waitRule"
  }
  $out = @{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = $msg } } | ConvertTo-Json -Compress -Depth 6
  Write-Output $out
  exit 0
} catch { exit 0 }
