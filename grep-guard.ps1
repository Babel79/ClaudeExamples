# grep-guard.ps1 - PreToolUse hook, matcher: Grep.  (N-4 z RAPORT_2026-09-02 par.6.2)
#
# PO CO: ZASADA 4b (CLAUDE.md) mowi, ze wynik wlasnego Grepa Orchestratora zostaje w kontekscie NA
# STALE. Pomiar sesji 849f6ef6: 55 wywolan Grepa = 31k tokenow kontekstu, w tym JEDNO wywolanie
# = 17k. Regula nie miala mechanizmu. Hook blokuje dwa wzorce, ktore ten koszt generuja:
#   - output_mode=content bez head_limit (nieograniczona ilosc linii do kontekstu),
#   - brak path i brak glob (skan calego repo; do tego w .claude sa worktrees = 5 kopii repo).
# Poprawka jest podana w komunikacie, wiec deny nie kosztuje tury na zgadywanie.
#
# ZAKRES: TYLKO glowny watek. U subagenta wynik Grepa ginie razem z jego kontekstem, wiec ten koszt
# nie wystepuje - dla subagenta hook milczy. Rozpoznanie: docs (code.claude.com/docs/en/hooks.md,
# "Common input fields") - pole agent_id jest "Present only when the hook fires inside a subagent
# call. Use this to distinguish subagent hook calls from main-thread calls". Dodatkowo fallback na
# transcript_path zawierajacy \subagents\.
# ASCII-only (PS 5.1 czyta .ps1 jako ANSI). exit 0 always.
$ErrorActionPreference = 'SilentlyContinue'
try {
  $raw = [Console]::In.ReadToEnd()
  if (-not $raw) { exit 0 }
  $j = $raw | ConvertFrom-Json

  # --- tylko glowny watek ---
  if ($j.agent_id) { exit 0 }
  $tp = [string]$j.transcript_path
  if ($tp -match '[\\/]subagents[\\/]') { exit 0 }

  $ti = $j.tool_input
  if ($null -eq $ti) { exit 0 }

  $mode = [string]$ti.output_mode
  $hasHead = ($null -ne $ti.head_limit)
  $hasPath = -not [string]::IsNullOrWhiteSpace([string]$ti.path)
  $hasGlob = -not [string]::IsNullOrWhiteSpace([string]$ti.glob)

  $problems = @()
  if ($mode -eq 'content' -and -not $hasHead) {
    $problems += "output_mode=content bez head_limit"
  }
  if (-not $hasPath -and -not $hasGlob) {
    $problems += "brak path i brak glob (skan calego repo)"
  }

  if ($problems.Count -gt 0) {
    $reason = "[GREP-GUARD] " + ($problems -join '; ') + ". Grep bez head_limit/path u Orchestratora kosztowal 17k tok za jedno wywolanie (55x=31k, sesja 849f6ef6) i ten koszt zostaje w kontekscie na stale. Dodaj path/glob + head_limit (dla content) albo uzyj output_mode=count / files_with_matches; skan nieznanego terenu -> Agent(Explore), nie wlasny Grep (CLAUDE.md zasada 4b)."
    $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $reason } } | ConvertTo-Json -Compress -Depth 6
    Write-Output $out
  }
  exit 0
} catch { exit 0 }
