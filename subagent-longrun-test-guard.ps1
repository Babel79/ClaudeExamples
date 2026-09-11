# PreToolUse (Bash) HARD guard: subagent NIE odpala PELNEGO przebiegu testow integracyjnych.
#  BLOKUJE (deny) 'dotnet test ... IntegrationTests' BEZ '--filter' gdy komende odpala SUBAGENT.
#  Przepuszcza: przebiegi z '--filter' (szybkie, zakres agenta), Tests/E2ETests, Orchestrator (main).
#
#  POWOD (incydent 2026-07-25, karta TEST.42 tego projektu):
#   03-QA odpalil pelny przebieg IntegrationTests (~40 min) w tle i wrocil przedwczesnie
#   ("I'll pause here and wait for the background task notification"). Jego proces NIE zginal
#   razem z nim. Orchestrator, nieswiadomy, wystartowal wlasna bramke 2,5 min pozniej.
#   Przez ~17 min DWA pelne przebiegi mielily TE SAMA baze danych projektu, psujac sobie seed+cleanup.
#   Wynik bramki bylby niewiarygodny w kierunku FALSZYWYCH NIEPOWODZEN.
#   TaskList pokazywal zero zadan, mtime logu byl 15 min stary - wszystkie zwykle sygnaly klamaly.
#
#  To ta sama klasa awarii co 'ng serve' w impl-agent-liveserver-guard.ps1 (dlugi proces
#  przezywajacy agenta), tylko dotyczy testow - dlatego osobny, szerszy guard (WSZYSTKIE subagenty).
#
#  Detekcja subagenta: transcript_path wskazuje <sesja>\subagents\agent-<id>.jsonl
# Defensive, ASCII-only (Windows PowerShell 5.1 czyta .ps1 jako ANSI). exit 0 always.
$ErrorActionPreference = 'SilentlyContinue'
try {
  $raw = [Console]::In.ReadToEnd()
  if (-not $raw) { exit 0 }
  $j = $raw | ConvertFrom-Json

  $cmd = [string]$j.tool_input.command
  if (-not $cmd) { exit 0 }

  # Czy to 'dotnet test'? Jesli nie -> nic nas nie obchodzi.
  if ($cmd -notmatch '(?i)\bdotnet\s+test\b') { exit 0 }

  # Czy celuje w IntegrationTests (albo cala solucje = tez ciagnie IntegrationTests)?
  $hitsIT = $false
  if ($cmd -match '(?i)IntegrationTests') { $hitsIT = $true }
  elseif ($cmd -match '(?i)\.slnx?\b') { $hitsIT = $true }
  # 'dotnet test' bez zadnego targetu = cala solucja z biezacego katalogu
  elseif ($cmd -match '(?i)\bdotnet\s+test\s*(;|&&|\||$)') { $hitsIT = $true }
  if (-not $hitsIT) { exit 0 }

  # Z '--filter' -> przebieg zawezony, szybki, dozwolony.
  if ($cmd -match '(?i)--filter\b') { exit 0 }

  # Czy caller to subagent? transcript_path -> <sesja>\subagents\agent-<id>.jsonl
  $transcript = [string]$j.transcript_path
  if (-not $transcript) { exit 0 }
  if ($transcript -notmatch '(?i)subagents[\\/](agent-[^\\/.]+)') { exit 0 }  # main/Orchestrator -> pass

  $reason = "[SUBAGENT-LONGRUN-TEST-GUARD] Pelny przebieg IntegrationTests (bez --filter) zablokowany dla subagenta. Powod: trwa ~40 min, przezywa Twoj return jako proces-sierota i ZATRUWA kolejna bramke Orchestratora (dwa przebiegi na tej samej bazie = falszywe niepowodzenia; incydent TEST.42 tego projektu, 2026-07-25). CO ZROBIC: uruchom przebieg ZAWEZONY '--filter FullyQualifiedName~<TwojaKlasa>' (szybki, dowodzi Twojego zakresu) i zwroc raport. PELNA BRAMKE odpala Orchestrator po Twoim returnie - to jego odpowiedzialnosc, nie Twoja. NIGDY nie koncz tury z zywym procesem, ktory sam uruchomiles."
  $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $reason } } | ConvertTo-Json -Compress -Depth 6
  Write-Output $out
  exit 0
} catch { exit 0 }
