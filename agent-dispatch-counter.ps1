# agent-dispatch-counter.ps1 - PreToolUse / Agent
#
# POWOD (zmierzone 2026-09-02, sesja 5bd65826):
# Telemetria agentow opiera sie na SubagentStop. Agent, ktory PADL PRZED STARTEM
# (np. na dynamicznym preflighcie w skillu), nigdy nie emituje SubagentStop -
# wiec dla telemetrii NIE ISTNIEJE. Tego dnia bylo 8 wywolan Agent, z czego 3
# padly przed handoffem; hook [HANDOFF] raportowal 3-5 zamiast 8.
#
# Skutek jest odwrotny do zamierzonego: im gorzej dziala srodowisko, tym mniej
# awarii telemetria widzi. Licznik po stronie WYWOLANIA domyka te luke:
# liczba dispatchow minus liczba wystartowanych agentow = agenci padli na starcie.
#
# Hook tylko LOGUJE - niczego nie blokuje i nic nie wstrzykuje do kontekstu.

$ErrorActionPreference = 'SilentlyContinue'

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }

    $j = $raw | ConvertFrom-Json
    if (-not $j) { exit 0 }
    if ($j.tool_name -ne 'Agent') { exit 0 }

    $root = if ($env:OH_HOOK_ROOT) { $env:OH_HOOK_ROOT }
            elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR }
            elseif ($j.cwd) { $j.cwd }
            else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $kbDir = if ($env:OH_HOOK_KB_DIR) { $env:OH_HOOK_KB_DIR } else { Join-Path $root '.claude\knowledge-base' }
    $tsv = Join-Path $kbDir 'agents_dispatch_raw.tsv'
    $header = "ts`tsession_id`tsubagent_type`tmodel`tdescription"

    $ts      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $session = [string]$j.session_id
    $type    = [string]$j.tool_input.subagent_type
    $model   = [string]$j.tool_input.model
    $desc    = [string]$j.tool_input.description

    if (-not $type)  { $type  = 'general-purpose' }
    if (-not $model) { $model = '-' }
    if (-not $desc)  { $desc  = '-' }

    # tabulatory i nowe linie rozwalilyby uklad kolumn
    foreach ($v in @('session','type','model','desc')) {
        Set-Variable -Name $v -Value (((Get-Variable -Name $v -ValueOnly) -replace "[`t`r`n]", ' ').Trim())
    }
    if ($desc.Length -gt 120) { $desc = $desc.Substring(0, 120) }

    $enc = New-Object System.Text.UTF8Encoding($false)
    if (-not (Test-Path $tsv)) {
        [System.IO.File]::WriteAllText($tsv, $header + "`r`n", $enc)
    }

    $line = "$ts`t$session`t$type`t$model`t$desc`r`n"

    # rownolegle SubagentStart/PreToolUse moga pisac naraz - krotki retry
    for ($i = 0; $i -lt 5; $i++) {
        try {
            [System.IO.File]::AppendAllText($tsv, $line, $enc)
            break
        }
        catch { Start-Sleep -Milliseconds 40 }
    }

    exit 0
}
catch { exit 0 }
