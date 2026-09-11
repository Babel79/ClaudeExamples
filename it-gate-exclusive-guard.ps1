# PreToolUse (Bash) HARD guard: bramka IntegrationTests ma WYLACZNOSC na bazie danych projektu
#  (nazwa wyprowadzona z katalogu projektu + 'DB', konfigurowalna przez OH_HOOK_DB_NAME).
#  BLOKUJE (deny) kazde 'dotnet test ... IntegrationTests' gdy ZYJE juz inny testhost.exe
#  nalezacy do przebiegu IntegrationTests. Dotyczy WSZYSTKICH (Orchestrator i subagenci).
#
#  POWOD (incydent 2026-07-25, karta TEST.42 pkt 4):
#   Dwa pelne przebiegi IntegrationTests mielily przez ~17 min TE SAMA baze danych projektu,
#   psujac sobie seed i cleanup. Wynik bramki bylby przeklamany w strone FALSZYWYCH
#   NIEPOWODZEN - a bramka jest jedyna rzecza miedzy czerwonym kodem a PR-em.
#   Pulapka: TaskList pokazywal ZERO zadan, mtime logu byl 15 min stary. Wszystkie zwykle
#   sygnaly mowily "nic nie dziala", podczas gdy dwa przebiegi realnie mielily baze.
#   WIARYGODNY JEST WYLACZNIE STAN PROCESOW W SYSTEMIE - dlatego ten guard patrzy na
#   Win32_Process, a nie na TaskList / mtime logu / komunikat TaskStop.
#
#  Roznica wobec subagent-longrun-test-guard.ps1 (komplementarne, nie duplikaty):
#   - tamten: KTO odpala (subagent) i CZY pelny (bez --filter)  -> chroni przed sierota
#   - ten:    CZY BAZA JEST WOLNA (zywy testhost IT)            -> chroni przed kolizja
#   Dlatego ten guard NIE zwalnia przebiegow z '--filter': waski przebieg agenta tez pisze
#   do tej samej bazy i tez zatruje trwajaca bramke Orchestratora.
#
#  Rozpoznanie "czyj to proces": tag z -p:BaseOutputPath=obj/_lockfree_<tag>/ w CommandLine.
#  Brak taga -> 'nieznany' (zgodnie z /it-gate Krok 0: nie zgaduj, zapytaj usera).
#
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

  # Czy celuje w IntegrationTests (wprost, przez solucje, albo bez targetu = cala solucja)?
  $hitsIT = $false
  if ($cmd -match '(?i)IntegrationTests') { $hitsIT = $true }
  elseif ($cmd -match '(?i)\.slnx?\b') { $hitsIT = $true }
  elseif ($cmd -match '(?i)\bdotnet\s+test\s*(;|&&|\||$)') { $hitsIT = $true }
  if (-not $hitsIT) { exit 0 }

  # Czy zyje jakikolwiek testhost.exe nalezacy do przebiegu IntegrationTests?
  # Unit-testy (projekt .Tests, bez segmentu .IntegrationTests) nie dotykaja bazy -> NIE blokujemy przez nie.
  # Kaskada kanoniczna (H1): OH_HOOK_ROOT -> CLAUDE_PROJECT_DIR -> cwd z payloadu JSON -> $PSScriptRoot.
  # Szczebel 'cwd' JEST OBOWIAZKOWY od przenosin do warstwy wspolnej (2026-09-08): hook lezy teraz
  # w ~/.claude/hooks, wiec $PSScriptRoot daje 'C:\Users\<user>' i nazwa bazy wychodzi 'babelDB'
  # zamiast '<Projekt>DB' - guard przestaje rozpoznawac zywy testhost i NIE blokuje. Zlapane bramka, 3 FAIL.
  $root = if ($env:OH_HOOK_ROOT) { $env:OH_HOOK_ROOT }
          elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR }
          elseif ($j.cwd) { [string]$j.cwd }
          else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  $projName = Split-Path -Leaf $root
  $itTestsRx = [regex]::Escape($projName) + '\.IntegrationTests'
  # nazwa bazy: ostatni segment nazwy katalogu (po kropce) + 'DB' - dla tego repo daje ten sam
  # ciag co przed podmiana (bez zaszywania go na sztywno); OH_HOOK_DB_NAME nadpisuje wprost.
  $lastSeg = ($projName -split '\.')[-1]
  $dbName = if ($env:OH_HOOK_DB_NAME) { $env:OH_HOOK_DB_NAME } else { "${lastSeg}DB" }

  $live = @()
  foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='testhost.exe'")) {
    $cl = [string]$p.CommandLine
    if ($cl -notmatch "(?i)$itTestsRx") { continue }
    $tag = 'nieznany'
    if ($cl -match '(?i)_lockfree_([A-Za-z0-9_-]+)') { $tag = $Matches[1] }
    $live += ("PID={0} tag={1} start={2}" -f $p.ProcessId, $tag, $p.CreationDate)
  }
  if ($live.Count -eq 0) { exit 0 }

  $list = [string]::Join(' | ', $live)
  $reason = "[IT-GATE-EXCLUSIVE-GUARD] Baza $dbName jest ZAJETA - zyje juz przebieg IntegrationTests: $list. Drugi przebieg na tej samej bazie psuje seed i cleanup pierwszemu; oba wyniki staja sie niewiarygodne w strone FALSZYWYCH NIEPOWODZEN (incydent TEST.42 tego projektu, 2026-07-25). CO ZROBIC: (1) tag pasuje do TWOJEGO wczesniejszego przebiegu -> POCZEKAJ na niego, nie startuj drugiego; (2) tag obcy albo nieznany -> to sierota po agencie albo cudzy przebieg: NIE ZGADUJ - ustal czyj przez Get-CimInstance Win32_Process (Name=testhost.exe) i kolumne CommandLine, a jesli to sierota: Stop-Process -Id <PID> -Force i powtorz. Procedura pelna: /it-gate Krok 0. NIGDY nie startuj drugiego przebiegu na wszelki wypadek."
  $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $reason } } | ConvertTo-Json -Compress -Depth 6
  Write-Output $out
  exit 0
} catch { exit 0 }
