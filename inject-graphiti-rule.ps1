# UserPromptSubmit hook - przypomnienie o grafie wiedzy Graphiti (sekcja 16 CLAUDE.md).
# Cel: group_id to JEDYNA granica izolacji 3 projektow na wspolnej bazie - pominiecie
# zanieczyszcza graf. Non-blocking, ASCII-only.
#
# THROTTLING (dodane 2026-08-13, pomiar sesji 849f6ef6): patrz inject-5-rules.ps1.
# Rzadziej niz 5-zasad ($Every=10), bo pelna regula i tak siedzi na stale w CLAUDE.md sekcja 16,
# a graf dotyczy dwoch momentow zadania (przed planem / po zakonczeniu), nie kazdej tury.
$ErrorActionPreference = 'SilentlyContinue'

$Every = 10

try {
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
      $f = Join-Path $dir "$sess.graphiti"
      $n = 0
      if (Test-Path -LiteralPath $f) { $n = [int](Get-Content -LiteralPath $f -TotalCount 1) }
      $n++
      Set-Content -LiteralPath $f -Value $n -Encoding ascii
      $emit = ((($n - 1) % $Every) -eq 0)
    }
  } catch { $emit = $true }

  if (-not $emit) { exit 0 }

  # prefiks group_id wyprowadzony z nazwy katalogu projektu (ostatni segment po kropce, male litery);
  # np. dla katalogu 'Firma.ProduktX' daje 'produktx'. OH_GRAPHITI_PREFIX pozwala nadpisac wprost;
  # fallback 'onehotel' gdy nazwy nie da sie wyprowadzic (zachowuje dzisiejsze zachowanie tego repo).
  # Kaskada kanoniczna (H1): OH_HOOK_ROOT -> CLAUDE_PROJECT_DIR -> cwd z payloadu JSON -> $PSScriptRoot.
  # Szczebel 'cwd' JEST OBOWIAZKOWY od przenosin do warstwy wspolnej (2026-09-08): hook lezy teraz
  # w ~/.claude/hooks, wiec $PSScriptRoot daje 'C:\Users\<user>' i nazwa projektu wychodzi jako
  # nazwa konta ('babel-tech' zamiast 'onehotel-tech'). Zlapane przez bramke, 8 FAIL.
  $root = if ($env:OH_HOOK_ROOT) { $env:OH_HOOK_ROOT }
          elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR }
          elseif ($j.cwd) { [string]$j.cwd }
          else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  $projName = Split-Path -Leaf $root
  $lastSeg = ($projName -split '\.')[-1]
  $gPrefix = if ($env:OH_GRAPHITI_PREFIX) { $env:OH_GRAPHITI_PREFIX }
             elseif ($lastSeg) { $lastSeg.ToLower() }
             else { 'onehotel' }

  $msg = "[GRAPHITI] Wiedza projektu jest w 7 kategoriach, kazda to OSOBNY group_id: ${gPrefix}-tech (kontrolery/endpointy/tabele/kolumny/moduly UI), ${gPrefix}-domain (biznes, reguly BR i decyzje D), ${gPrefix}-history (sesje), ${gPrefix}-tasks (karty backlogu), ${gPrefix}-env (agenci, skille, hooki, VPS, smsgate, Google Play), ${gPrefix}-hints (pulapki i skroty), ${gPrefix}-stats (koszty i pomiary). Stare jednoworkowe archiwum NIE ISTNIEJE - zostalo rozdzielone do tych 7 kategorii przy migracji na Neo4j 2026-09-04; nie dokladaj go do zapytan. Osobno jest tylko techniczna grupa '${gPrefix}-canary' (fakt dla hooka kanarka) - nie pytaj o nia i nie pisz do niej. group_id to jedyna granica izolacji 3 projektow na wspolnej bazie. PRZED planem: search_nodes / search_memory_facts z group_ids jako TABLICA 2-3 kategorii (podawaj kilka, bo jedna kategoria latwo mija sie z tematem) i zacytuj fakty w planie; nic nie ma -> napisz to wprost. PO zadaniu: add_memory z group_id (l.POJ.) wlasciwej kategorii + episode_body: CO + UZASADNIENIE + DOWOD (nr PR/hash/liczba) + reference_time gdy zdarzenie jest z przeszlosci. UWAGA: 'queued' NIE znaczy zapisane - kolejka serwera jest asynchroniczna, wiec potwierdz epizod zapytaniem cypher-shell do kontenera graphiti-neo4j. NIE zapisuj sekretow ani danych gosci. Szczegoly: skille cust_graphiti_ontology (kategorie), cust_graphiti_curation (zapis), cust_graphiti_usage (odczyt); CLAUDE.md sekcja 16."
  $out = @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = $msg } } | ConvertTo-Json -Compress -Depth 5
  Write-Output $out
  exit 0
} catch { exit 0 }
