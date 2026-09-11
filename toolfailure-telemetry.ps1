# toolfailure-telemetry.ps1 - PostToolUseFailure hook.  (N-8 z RAPORT_2026-09-02 par.6.2)
#
# PO CO: dzis NIE mierzymy awarii narzedzi. Sesje zglaszaly niezaleznie: Glob timeout 20 s na
# .claude/** (worktrees), sharptools "No such tool" (zimny load Roslyn), MCP graphiti bez odpowiedzi.
# Kazda taka awaria to re-dispatch albo decyzja podjeta bez danych (D6), a nie mamy zadnej podstawy,
# zeby powiedziec KTORE narzedzie zawodzi najczesciej i jak czesto.
#
# Docs (code.claude.com/docs/en/hooks.md, sekcja "PostToolUseFailure"): "Runs when a tool that
# started executing fails". Wejscie: tool_name, tool_input, tool_use_id oraz pola najwyzszego
# poziomu error (string), is_interrupt (bool, opcjonalne), duration_ms (opcjonalne).
# UWAGA z docs: to zdarzenie NIE odpala sie przy odrzuceniu przed wykonaniem (nieznane narzedzie,
# blad schematu, odmowa uprawnien) - takie przypadki tu nie trafia i to jest zgodne z zamiarem.
#
# Nie wstrzykuje niczego do kontekstu (czysta telemetria).
# ASCII-only (PS 5.1 czyta .ps1 jako ANSI). exit 0 always.
$ErrorActionPreference = 'SilentlyContinue'

function ConvertTo-OneLine {
  param([string]$Text, [int]$Max)
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $t = $Text -replace "`t", ' ' -replace "`r", ' ' -replace "`n", ' '
  $t = $t -replace '\s+', ' '
  $t = $t.Trim()
  if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }
  return $t
}

try {
  $raw = [Console]::In.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
  $j = $raw | ConvertFrom-Json

  $tool = [string]$j.tool_name
  if (-not $tool) { exit 0 }

  $sid = [string]$j.session_id
  if ($sid.Length -gt 8) { $sid = $sid.Substring(0, 8) }

  $caller = 'orchestrator'
  if ($j.agent_id) { $caller = 'subagent' }
  else {
    $tp = [string]$j.transcript_path
    if ($tp -match '[\\/]subagents[\\/]') { $caller = 'subagent' }
  }
  if ($j.agent_type) { $caller = $caller + ':' + ([string]$j.agent_type) }

  $err = ConvertTo-OneLine -Text ([string]$j.error) -Max 200

  # skrot wejscia: preferuj to, co identyfikuje operacje (command / pattern / file_path), inaczej caly obiekt
  $snip = ''
  foreach ($k in @('command', 'pattern', 'file_path', 'path', 'query', 'url')) {
    $v = [string]$j.tool_input.$k
    if (-not [string]::IsNullOrWhiteSpace($v)) { $snip = $v; break }
  }
  if (-not $snip) { try { $snip = ($j.tool_input | ConvertTo-Json -Compress -Depth 4) } catch {} }
  $snip = ConvertTo-OneLine -Text $snip -Max 120

  $root = if ($env:OH_HOOK_ROOT) { $env:OH_HOOK_ROOT }
          elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR }
          elseif ($j.cwd) { $j.cwd }
          else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  $kbDir = if ($env:OH_HOOK_KB_DIR) { $env:OH_HOOK_KB_DIR } else { Join-Path $root '.claude\knowledge-base' }
  if (-not (Test-Path -LiteralPath $kbDir)) { New-Item -ItemType Directory -Path $kbDir -Force | Out-Null }

  $log = Join-Path $kbDir 'tool_failures.tsv'
  $enc = [System.Text.UTF8Encoding]::new($false)
  if (-not (Test-Path -LiteralPath $log)) {
    [System.IO.File]::WriteAllText($log, "utc`tsession8`tcaller`ttool_name`terror`tinput_snippet`r`n", $enc)
  }
  $nowUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  [System.IO.File]::AppendAllText($log, "$nowUtc`t$sid`t$caller`t$tool`t$err`t$snip`r`n", $enc)
}
catch {
  # celowo cicho - telemetria nie moze nigdy przeszkodzic w pracy
}

exit 0
