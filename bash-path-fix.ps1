# bash-path-fix.ps1 - PreToolUse / Bash
#
# POWOD (zmierzone 2026-09-02, sesja 5bd65826):
# PATH powloki bywa przekazany w formacie Windows (sredniki, backslashe, C:\...)
# zamiast POSIX (dwukropki, /c/...). Bash traktuje wtedy caly lancuch jako JEDEN
# katalog i nie znajduje ZADNEGO narzedzia - ani head/grep/sed/ls, ani git,
# dotnet, gh, sqlcmd. Objaw ("command not found") lawo pomylic z bledem kodu.
# Tego dnia wywrocilo to trzech agentow z rzedu.
#
# DLACZEGO HOOK, A NIE PROFIL:
# bash w Claude Code jest NIEINTERAKTYWNY (flags=hBc) i - zmierzone - NIE czyta
# ani ~/.bashrc, ani ~/.bash_profile, ani nawet $BASH_ENV, mimo ze zmienna jest
# poprawnie ustawiona w settings.local.json. Reczny "source" tego samego pliku
# naprawia PATH natychmiast. Dlatego doklejamy source do kazdej komendy.
#
# DLACZEGO NIE LINIA W HANDOFFIE:
# handoff dziala tylko na agenta, ktory go przeczytal, i nie chroni komend
# odpalanych poza handoffem. Hook dziala zawsze.
#
# Wyjscie: hookSpecificOutput.updatedInput (dozwolone TYLKO dla PreToolUse).
# Zachowujemy wszystkie pozostale pola tool_input - podmieniamy sam "command".

$ErrorActionPreference = 'SilentlyContinue'

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }

    $j = $raw | ConvertFrom-Json
    if (-not $j) { exit 0 }
    if ($j.tool_name -ne 'Bash') { exit 0 }

    $cmd = $j.tool_input.command
    if ([string]::IsNullOrWhiteSpace($cmd)) { exit 0 }

    # Juz naprawione recznie (handoff, wczesniejszy przebieg tego hooka) - nie dubluj.
    if ($cmd -match '\.bashrc' -or $cmd -match 'Git/usr/bin' -or $cmd -match 'BASH_ENV') { exit 0 }

    # Idempotentny prefiks. Cichy, gdy pliku nie ma - nigdy nie psuje komendy.
    $prefix = 'if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc" >/dev/null 2>&1; fi'

    $newInput = @{}
    foreach ($p in $j.tool_input.PSObject.Properties) { $newInput[$p.Name] = $p.Value }
    $newInput['command'] = $prefix + "`n" + $cmd

    $out = @{
        hookSpecificOutput = @{
            hookEventName = 'PreToolUse'
            updatedInput  = $newInput
        }
    }

    $out | ConvertTo-Json -Compress -Depth 6
    exit 0
}
catch { exit 0 }
