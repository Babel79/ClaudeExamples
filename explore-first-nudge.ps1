# explore-first-nudge.ps1 - PreToolUse hook, matcher: Agent.  (N-5 z RAPORT_2026-09-02 par.6.2)
#
# PO CO: pomiar 16 sesji - subagenci typu 'general-purpose' wyprodukowali 658k tokenow wyjscia,
# podczas gdy 'Explore' na porownywalnej pracy 228k. Roznica bierze sie stad, ze general-purpose
# ma pelen zestaw narzedzi i pisze obszerne raporty, a Explore jest read-only i zwraca sam wniosek.
# Dla zadania, ktore jest CZYSTYM SKANEM (nic nie zapisuje), general-purpose to czysty narzut.
#
# CO ROBI: gdy dispatch idzie na subagent_type='general-purpose', a prompt NIE zawiera zadnego
# sygnalu pisania (Write / Edit / Bash / zapisz / utworz / napisz / zmien / popraw / usun / dopisz)
# -> jedna linia podpowiedzi. NIE BLOKUJE - decyzja zostaje przy Orchestratorze, bo prompt bywa
# opisowy i sygnal jest z natury slaby (pitfall "kategoryczny komunikat przy slabym sygnale").
# Inny subagent_type albo prompt z sygnalem pisania -> CISZA.
#
# KANAL WYJSCIA: hookSpecificOutput.additionalContext dla PreToolUse.
# Zrodlo: cust_hook_authoring par.2 - wiersz PreToolUse dopuszcza obok permissionDecision takze
# 'additionalContext'. Swiadomie NIE ustawiamy permissionDecision='allow' (to obeszloby normalna
# sciezke uprawnien) ani 'deny'/'ask' (sygnal za slaby na zatrzymanie pracy).
#
# POLSKIE SLOWA BEZ OGONKOW: skrypt jest ASCII-only (PS 5.1 czyta .ps1 jako ANSI), a regex PS na
# UTF-8 bywa zawodny ([[feedback_bash_grep_breaks_utf8_classes]]). Dlatego z promptu USUWAMY znaki
# spoza ASCII przed dopasowaniem: 'zmien'/'zmien' -> 'zmie', 'usun' -> 'usu', 'utworz' -> 'utwrz'.
# Granice slowa (\b) chroni przed trafieniem w 'zmiennej' czy 'usuwanie' opisujace cudzy kod.
# exit 0 always.
$ErrorActionPreference = 'SilentlyContinue'
try {
  $raw = [Console]::In.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
  $j = $null
  try { $j = $raw | ConvertFrom-Json } catch { exit 0 }
  if ($null -eq $j) { exit 0 }

  $ti = $j.tool_input
  if ($null -eq $ti) { exit 0 }

  $sub = [string]$ti.subagent_type
  if ($sub -ne 'general-purpose') { exit 0 }

  $prompt = [string]$ti.prompt
  if ([string]::IsNullOrWhiteSpace($prompt)) { exit 0 }

  # normalizacja: wytnij wszystko spoza ASCII (ogonki), zeby dopasowanie bylo deterministyczne
  $p = [regex]::Replace($prompt, '[^\x00-\x7F]', '')

  $writeSignals = @(
    '\bWrite\b', '\bEdit\b', '\bMultiEdit\b', '\bBash\b',
    # 'utworz': ogonek stoi W SRODKU slowa, wiec ani usuniecie znaku spoza ASCII, ani przejscie
    # przez stdin (gdzie 'o' z kreska potrafi zamienic sie w '?') nie daje jednej formy.
    # Dlatego tolerujemy dowolne 0-2 znaki nie-biale miedzy 'utw' a 'rz'.
    '\bzapisz\b', '\bzapisa', '\butw\S{0,2}rz\b', '\bnapisz\b',
    '\bzmie[n]?\b', '\bpopraw\b', '\busu[n]?\b', '\bdopisz\b'
  )
  foreach ($rx in $writeSignals) {
    if ($p -match "(?i)$rx") { exit 0 }
  }

  $msg = "[EXPLORE-FIRST] Zadanie wyglada na skan (bez Write/Edit/Bash). general-purpose = 658k tok out vs Explore 228k w 16 sesjach. Uzyj subagent_type:'Explore' chyba ze agent ma pisac pliki."
  $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; additionalContext = $msg } } | ConvertTo-Json -Compress -Depth 5
  Write-Output $out
  exit 0
}
catch { exit 0 }
