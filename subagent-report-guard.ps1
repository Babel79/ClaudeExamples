# subagent-report-guard.ps1 - SubagentStop hook.  (N-3 z RAPORT_2026-09-02 par.6.2)
#
# PO CO: ZASADA 2 (CLAUDE.md) - "agent ZAWSZE zwraca PELEN, ustrukturyzowany raport" - do dzis
# nie miala ZADNEGO mechanizmu. Orchestrator mial pamietac, ze ma odrzucic niepelny raport, w
# momencie, w ktorym wlasnie dostal duzy tekst i chce isc dalej. Regula adresowana wylacznie do
# czytelnika jest nieegzekwowalna (ta sama klasa co ENV.48 / ENV.70).
# Dodatkowo: raport uciety przez maxTurns wyglada jak normalny raport, tylko konczy sie w polowie -
# i wlasnie w nim BRAKUJE koncowych sekcji (NOT DONE / RECOMMENDATIONS / TOOLS USED), bo agent nie
# mial tury, zeby je napisac ([[feedback_agent_maxturns_truncated_returns]]).
#
# CO ROBI: na SubagentStop sprawdza ostatnia wiadomosc agenta pod katem TRZECH kluczy kontraktu
# (cust_agent_protocol par.3): VERIFICATION, NOT DONE (lub NOT_DONE / DEFERRED), TOOLS USED.
# Brakuje ktoregokolwiek -> jedna linia do Orchestratora. Komplet -> CISZA.
#
# ZAKRES: tylko agenci projektu, typ pasujacy do ^(0[1-9]|1[0-4])-  (01-github ... 14-vps-deploy).
# Explore / Plan / general-purpose / claude-code-guide NIE maja tego kontraktu i sa pomijane -
# inaczej hook halasowalby na kazdym skanie (pitfall "nudge na kazdym zdarzeniu" ze skilla).
#
# KANAL WYJSCIA: hookSpecificOutput.additionalContext dla zdarzenia SubagentStop.
# Zrodlo: cust_hook_authoring par.2 - wiersz SubagentStop dopuszcza "additionalContext -> do
# Orchestratora; decision: block". Swiadomie NIE uzywamy decision:"block" - komunikat ma byc
# podpowiedzia przy ocenie raportu, a nie zatrzymaniem pracy. Kanal plikowy (jak w
# mutation-leftover-detector) odpada z powodu momentu dostarczenia: marker odbierany na
# UserPromptSubmit dociera dopiero przy nastepnym prompcie USERA, czyli PO tym, jak Orchestrator
# juz zaufal raportowi - a ten hook ma trafic dokladnie w chwile oceny.
#
# ZASADA: NIGDY nie blokuj agenta. Kazdy blad -> exit 0 po cichu. ASCII-only (PS 5.1 czyta ANSI).

$ErrorActionPreference = 'SilentlyContinue'

try {
  $raw = [Console]::In.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
  $j = $null
  try { $j = $raw | ConvertFrom-Json } catch { exit 0 }
  if ($null -eq $j) { exit 0 }

  # --- tylko agenci projektu (01..14) ---
  $agentType = [string]$j.agent_type
  if ([string]::IsNullOrWhiteSpace($agentType)) { exit 0 }
  if ($agentType -notmatch '^(0[1-9]|1[0-4])-') { exit 0 }

  # --- tekst koncowego raportu ---
  $finalText = [string]$j.last_assistant_message
  if ([string]::IsNullOrWhiteSpace($finalText)) {
    # fallback: ostatni blok tekstu asystenta z wlasnego transcriptu agenta.
    # Docs ostrzegaja, ze transcript "is written asynchronously and may lag" - dlatego to fallback,
    # a nie zrodlo pierwszego wyboru.
    try {
      $atp = [string]$j.agent_transcript_path
      if ($atp -and (Test-Path -LiteralPath $atp)) {
        foreach ($line in [System.IO.File]::ReadLines($atp)) {
          if ([string]::IsNullOrWhiteSpace($line)) { continue }
          $o = $null; try { $o = $line | ConvertFrom-Json } catch { continue }
          $m = $o.message
          if ($null -eq $m -or $m.role -ne 'assistant') { continue }
          foreach ($c in $m.content) {
            if ($c -and $c.type -eq 'text' -and $c.text) { $finalText = [string]$c.text }
          }
        }
      }
    } catch {}
  }
  # Nadal pusto = nie wiemy nic o raporcie (pole nieobecne w tej wersji harnessu). Cisza jest
  # tansza niz falszywy alarm na KAZDYM agencie.
  if ([string]::IsNullOrWhiteSpace($finalText)) { exit 0 }

  # --- trzy klucze kontraktu; ASCII, niewrazliwe na wielkosc liter, '_' albo spacja ---
  $missing = @()
  if ($finalText -notmatch '(?i)VERIFICATION')          { $missing += 'VERIFICATION' }
  if ($finalText -notmatch '(?i)(NOT[ _]DONE|DEFERRED)') { $missing += 'NOT DONE' }
  if ($finalText -notmatch '(?i)TOOLS[ _]USED')         { $missing += 'TOOLS USED' }

  # --- telemetria (tam, gdzie leza pozostale tsv: .claude/knowledge-base) ---
  try {
    $root = if ($env:OH_HOOK_ROOT) { $env:OH_HOOK_ROOT }
            elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR }
            elseif ($j.cwd) { $j.cwd }
            else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $kbDir = if ($env:OH_HOOK_KB_DIR) { $env:OH_HOOK_KB_DIR } else { Join-Path $root '.claude\knowledge-base' }
    if (-not (Test-Path -LiteralPath $kbDir)) { New-Item -ItemType Directory -Path $kbDir -Force | Out-Null }
    $log = Join-Path $kbDir 'report_guard.tsv'
    $enc = [System.Text.UTF8Encoding]::new($false)
    if (-not (Test-Path -LiteralPath $log)) {
      [System.IO.File]::WriteAllText($log, "utc`tsession8`tagent_type`tverdict`tmissing`treport_chars`r`n", $enc)
    }
    $sid = [string]$j.session_id
    if ($sid.Length -gt 8) { $sid = $sid.Substring(0, 8) }
    $verdict = if ($missing.Count -eq 0) { 'OK' } else { 'INCOMPLETE' }
    $nowUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    [System.IO.File]::AppendAllText($log, "$nowUtc`t$sid`t$agentType`t$verdict`t$($missing -join ',')`t$($finalText.Length)`r`n", $enc)
  } catch {}

  if ($missing.Count -eq 0) { exit 0 }

  $msg = "[REPORT-GUARD] Raport agenta $agentType niepelny - brak: $($missing -join ', '). ZASADA 2: odrzuc i zazadaj pelnego (SendMessage do tego samego agenta), albo zrob verify-on-disk sam. Uciety return = maxTurns, sprawdz pliki."
  $out = @{ hookSpecificOutput = @{ hookEventName = 'SubagentStop'; additionalContext = $msg } } | ConvertTo-Json -Compress -Depth 5
  Write-Output $out
  exit 0
}
catch { exit 0 }
