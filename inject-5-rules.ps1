# UserPromptSubmit hook - wstrzykuje 5 zelaznych zasad jako recency reminder.
# Walczy z rozmywaniem regul w dlugim kontekscie / po kompaktacji. Non-blocking, ASCII-only.
#
# THROTTLING (dodane 2026-08-13, pomiar sesji 849f6ef6):
#   Hook strzelal co ture. 21 tur x 2 injectory = 45 wstrzyknien = ~11k tokenow kontekstu
#   na powtorzenie tresci, ktora JEST w CLAUDE.md ladowanym na starcie sesji.
#   Teraz: tura 1 + co $Every-ta. 21 tur -> 5 wstrzyknien zamiast 21.
#   Tura 1 zawsze, bo po /clear lub kompaktacji to jedyny recency-anchor.
$ErrorActionPreference = 'SilentlyContinue'

$Every = 5

try {
  # --- licznik tur per sesja (plik w TEMP, zycie = sesja) ---
  $emit = $true
  try {
    $raw = [Console]::In.ReadToEnd()
    $sess = ''
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      $j = $raw | ConvertFrom-Json
      $sid = [string]$j.session_id
      if ($sid.Length -ge 8) { $sess = $sid.Substring(0,8) }
    }
    if ($sess) {
      $dir = Join-Path $env:TEMP 'claude-hookstate'
      if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
      $f = Join-Path $dir "$sess.5rules"
      $n = 0
      if (Test-Path -LiteralPath $f) { $n = [int](Get-Content -LiteralPath $f -TotalCount 1) }
      $n++
      Set-Content -LiteralPath $f -Value $n -Encoding ascii
      # emituj na turze 1, potem co $Every-ta (1, 6, 11, ...)
      $emit = ((($n - 1) % $Every) -eq 0)
    }
  } catch { $emit = $true }   # nie umiesz policzyc -> zachowaj sie jak dawniej

  if (-not $emit) { exit 0 }

  $msg = "[5 ZASAD - przypomnienie] 1) Orchestrator NIE pisze kodu/testow/SQL - deleguj (04/05/07/08/03/06); tylko mechaniczne (rename/delecja/1-line/docs/skille) sam + 1 build. 2) Agent zwraca PELEN raport: wszystkie pliki + VERIFICATION z realnym exit code + NOT DONE + RECOMMENDATIONS. 3) Agent ZAWSZE laduje wlasciwy skill przed operacja. 4) Narzedzia: MCP > CLI > Tool(Grep/Glob/Edit) > bash(ostatecznosc); SKANOWANIE nieznanego terenu -> subagent, nie wlasny Grep (kontekst). 5) Powtarzalna sekwencja = command. PONADTO: USER VERIFY przed 03-QA/09-E2E/10-Docs/commit dla user-facing; verify-on-disk (git status+grep) po KAZDYM impl-agencie; NIE oslabiaj testow by przeszly; plan w tabelce + czekaj na OK. CONTEXT-COST GATE (132): pokazuj status koloru na gorze substantywnej odpowiedzi - niebieski=PLAN, zielony=PYTANIA, zolty=kontekst sesji 500-800k (ostrzez usera, proponuj checkpoint/ciecie), czerwony=>800k (STOP: podsumuj + zapisz handoff oldsession.md + zaproponuj /clear lub swieza sesja, CZEKAJ na decyzje). Koszt = tokeny zuzyte w sesji (kumulacja, ~ okno minus 'tokens left'). Plan+akceptacja ZAWSZE."
  $out = @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = $msg } } | ConvertTo-Json -Compress -Depth 5
  Write-Output $out
  exit 0
} catch { exit 0 }
