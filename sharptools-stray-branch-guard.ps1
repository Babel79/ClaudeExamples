# sharptools-stray-branch-guard.ps1 - PostToolUse hook (matcher: mcp__sharptools__.*)
# Cel: ADHERENCE nudge (nie dokumentacja). cust_sharptools_refactor MA regule+recovery
#   (auto-branch pitfall), a telemetria i tak pokazuje 2x "recovery stray sharptools branch"
#   w jednej sesji. Dominujacy failure-mode = nieprzestrzeganie znanej reguly pod presja
#   kontekstu - prozą sie tego nie naprawi, tylko hookiem.
# Mechanizm: SharpTool AddMember/OverwriteMember/RenameSymbol/... AUTO-tworzy branch
#   'sharptools/<ts>' + commit tam + przelacza HEAD (memory feedback_sharptools_addmember_...).
#   Po mutacji sprawdzamy biezacy branch; jesli sharptools/* -> nudge z procedura konsolidacji.
# Tylko MUTUJACE narzedzia (read-only ViewDefinition/GetMembers/FindReferences/... -> skip).
# ZASADA: NIGDY nie blokuj (nudge = additionalContext, nie deny). Blad -> exit 0 cicho.
# ASCII-only (Windows PowerShell 5.1 czyta .ps1 jako ANSI).

$ErrorActionPreference = 'SilentlyContinue'

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $j = $raw | ConvertFrom-Json

    $toolName = [string]$j.tool_name
    if ([string]::IsNullOrWhiteSpace($toolName)) { exit 0 }

    # Tylko mutujace sharptools. Read-only -> nic nas nie obchodzi.
    $mutating = 'AddMember|OverwriteMember|RenameSymbol|MoveMember|FindAndReplace|ManageUsings|ManageAttributes|OverwriteRoslynDocument|CreateRoslynDocument|Undo'
    if ($toolName -notmatch "mcp__sharptools__SharpTool_($mutating)\b") { exit 0 }

    # repo root = .claude/hooks/../.. (override for tests / after future move outside project)
    $repo = if ($env:OH_HOOK_ROOT) { $env:OH_HOOK_ROOT }
            elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR }
            elseif ($j.cwd) { $j.cwd }
            else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    if (-not (Test-Path -LiteralPath $repo)) { exit 0 }

    $branch = (& git -C "$repo" rev-parse --abbrev-ref HEAD 2>$null)
    $branch = [string]$branch
    if ([string]::IsNullOrWhiteSpace($branch)) { exit 0 }
    if ($branch -notmatch '^sharptools/') { exit 0 }

    $reason = "[SHARPTOOLS-STRAY-BRANCH] HEAD jest na '$branch' - SharpTool $toolName auto-utworzyl branch sharptools/* + tam zacommitowal + przelaczyl HEAD. NIE pracuj dalej na tym branchu (twoja zmiana wyladuje poza feature-branchem). KONSOLIDACJA: 1) sprawdz co tam wpadlo: git -C $repo log --oneline -3 $branch  2) wroc na swoj branch: git checkout <feature-branch>  3) przenies zmiane (cherry-pick lub re-apply Editem)  4) skasuj stray: git branch -D $branch. Prewencja: mutacje rob Editem, SharpTool tylko READ (memory feedback_sharptools_addmember_auto_commits_branch)."
    $out = @{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = $reason } } | ConvertTo-Json -Compress -Depth 6
    Write-Output $out
}
catch { }

exit 0
