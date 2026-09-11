# subagent-start-inject.ps1 - SubagentStart hook.  (N-2 z RAPORT_2026-09-02 par.6.2)
#
# PO CO: te same reguly byly kopiowane do 12 plikow agentow (23% ich objetosci to boilerplate,
# ~6,6k tok wejscia) i ROZJECHALY sie - audyt znalazl 14 sprzecznosci miedzy kopiami. Hook daje
# JEDNO zrodlo prawdy, ktore dziala od razu - bez czekania na nowa sesje (zmiana pliku
# agenta/skilla wchodzi dopiero od nastepnej sesji).
# 2026-09-03: zapis do backlogu ODMROZONY decyzja usera - regula 5 wrocila do par.13 (agent zaklada
# karte od razu). Reszta par.18 (MVP FREEZE) obowiazuje bez zmian.
#
# Docs (code.claude.com/docs/en/hooks.md, sekcja "SubagentStart"): zdarzenie dostaje agent_id
# i agent_type; "SubagentStart hooks can't block subagent creation, but they can inject context
# into the subagent" przez hookSpecificOutput.additionalContext, wstawiany "at the start of the
# conversation, before its first prompt".
#
# Tekst jest FAKTOGRAFICZNY, nie rozkazujacy - docs ostrzegaja, ze tresc w formie polecen
# out-of-band potrafi wzbudzic obrone przed prompt-injection zamiast trafic do kontekstu.
# ASCII-only (PS 5.1 czyta .ps1 jako ANSI). exit 0 always.
$ErrorActionPreference = 'SilentlyContinue'
try {
  $raw = [Console]::In.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
  $j = $raw | ConvertFrom-Json
  if ($null -eq $j) { exit 0 }

  $type = [string]$j.agent_type
  if (-not $type) { $type = [string]$j.tool_input.subagent_type }

  # Nazwa backlogu ZMIENILA sie 2026-09-08 (zadanie R): backlog6GM* -> backlog.md/backlog_task.md.
  # Ten hook przetrwal ja bez zmiany kodu, bo nie zna zadnej nazwy na sztywno - i tak zostaje,
  # bo warstwa wspolna obsluguje 4 projekty, a kazdy moze nazywac backlog inaczej.
  # OH_BACKLOG_PREFIX pozwala nadac nazwe per-projekt; bez niej opisujemy plik wzorcem backlog*.md.
  $backlogPrefix = if ($env:OH_BACKLOG_PREFIX) { $env:OH_BACKLOG_PREFIX } else { $null }
  $backlogFiles = if ($backlogPrefix) { "$backlogPrefix.md ORAZ ${backlogPrefix}_task.md" }
                  else { "plikach backlog*.md" }

  # agenci czysto badawczy/read-only: pelny blok jest dla nich narzutem bez pozytku
  $isReadOnly = $type -match '(?i)^(Explore|Plan|claude-code-guide|statusline-setup)$'

  if ($isReadOnly) {
    $msg = "[SUBAGENT-RULES] Raport koncowy zawiera: wynik, przejrzane sciezki, TOOLS USED i SKILLS USED. Karty backlogu nie zakladasz sam (nie masz narzedzi zapisu) - znalezisko to jedno zdanie w RECOMMENDATIONS, karte zaklada Orchestrator (CLAUDE.md par.13)."
  }
  else {
    $msg = "[SUBAGENT-RULES] Kontrakt projektu (CLAUDE.md + cust_agent_protocol):" +
      " 1) RAPORT pelny: FILES (sciezka:linie), VERIFICATION (komenda + REALNY exit code), NOT DONE, RECOMMENDATIONS, TOOLS USED, SKILLS USED, ENV SIGNALS. Niepelny odrzucany." +
      " 2) SKILLE: sprawdz frontmatter skills: i ~/.claude/skills/_CATALOG.md (NIE katalog repo), zaladuj wlasciwy; brak zglos w RECOMMENDATIONS." +
      " 3) NARZEDZIA: MCP > CLI > Tool > bash; tryb auto tego nie znosi (CLAUDE.md 4a)." +
      " 4) TESTY: testu nie oslabia sie, zeby przeszedl." +
      " 5) BACKLOG: wykryty dlug -> gotowa tresc karty BEZ ID w RECOMMENDATIONS; karte w $backlogFiles zaklada Orchestrator (/backlog-add)." +
      " 6) LIMITY: handoff daje budzet w minutach; przy koncu NIE zaczynaj nowej petli - zwroc PARTIAL z NOT DONE (maxTurns). Notatnik postepu w scratchpadzie, sciezka w VERIFICATION." +
      " 7) BRAMKI: tylko przebiegi z --filter; pelne uruchamia Orchestrator."
  }

  $out = @{ hookSpecificOutput = @{ hookEventName = 'SubagentStart'; additionalContext = $msg } } | ConvertTo-Json -Compress -Depth 6
  Write-Output $out
  exit 0
} catch { exit 0 }
