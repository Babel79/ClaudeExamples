# PreToolUse (Bash) HARD guard: impl-subagent (04/05/07/08) NIE stawia dev-servera.
#  BLOKUJE (deny) 'ng serve' / 'npm start' / 'npm run start' / 'yarn start'
#  gdy komende odpala IMPL-subagent (agentType matchuje 0[4578]-).
#  Powod: USER VERIFY / bring-up robi Orchestrator (/live-verify-up, /fullflow-up)
#  albo Playwright - impl-agent tego nie robi, zwiesza sie (07-angular S4 killed 34min).
#  Detekcja subagenta: transcript_path wskazuje <sesja>\subagents\agent-<id>.jsonl
#  (main-agent/Orchestrator ma inny transcript). agentType z agent-<id>.meta.json.
#  Orchestrator (main) i testerzy (11/13, brak match 0[4578]-) -> przepuszczone.
# Defensive, ASCII-only (Windows PowerShell 5.1 czyta .ps1 jako ANSI). exit 0 always.
$ErrorActionPreference = 'SilentlyContinue'
try {
  $raw = [Console]::In.ReadToEnd()
  if (-not $raw) { exit 0 }
  $j = $raw | ConvertFrom-Json

  $cmd = [string]$j.tool_input.command
  if (-not $cmd) { exit 0 }

  # Czy to komenda stawiajaca dev-server? Jesli nie -> nic nas nie obchodzi.
  $isDevServer = $false
  if ($cmd -match '(?i)\bng(\.exe)?\b[^\r\n]*\bserve\b') { $isDevServer = $true }
  elseif ($cmd -match '(?i)\bnpm\s+start\b') { $isDevServer = $true }
  elseif ($cmd -match '(?i)\bnpm\s+run\s+start\b') { $isDevServer = $true }
  elseif ($cmd -match '(?i)\byarn\s+start\b') { $isDevServer = $true }
  if (-not $isDevServer) { exit 0 }

  # Czy caller to subagent? transcript_path -> <sesja>\subagents\agent-<id>.jsonl
  $transcript = [string]$j.transcript_path
  if (-not $transcript) { exit 0 }
  if ($transcript -notmatch '(?i)subagents[\\/](agent-[^\\/.]+)') { exit 0 }  # main/Orchestrator -> pass
  $agentId = $matches[1]

  # agentType z meta.json obok transcriptu; brak meta -> konserwatywnie przepusc (nie lam testerow)
  $subDir = Split-Path -Parent $transcript
  $metaPath = Join-Path $subDir ($agentId + '.meta.json')
  if (-not (Test-Path -LiteralPath $metaPath)) { exit 0 }
  $agentType = ''
  try { $meta = (Get-Content -LiteralPath $metaPath -Raw) | ConvertFrom-Json
        if ($meta.agentType) { $agentType = [string]$meta.agentType } } catch { exit 0 }

  # Tylko impl-agenci: 04-mssql / 05-api / 07-angular / 08-maui
  if ($agentType -notmatch '0[4578]-') { exit 0 }

  $reason = "[IMPL-LIVESERVER-GUARD] Komenda dev-server zablokowana dla $agentType. USER VERIFY / bring-up (ng serve, npm start) robi Orchestrator (/live-verify-up, /fullflow-up) albo Playwright - NIE Ty. Dev-server zwiesza impl-agenta (killed po 30+ min). Zrob swoj vertical-slice (code+test), zwroc raport i oddaj kontrole Orchestratorowi do weryfikacji."
  $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $reason } } | ConvertTo-Json -Compress -Depth 6
  Write-Output $out
  exit 0
} catch { exit 0 }
