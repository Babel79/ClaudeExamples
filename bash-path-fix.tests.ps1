# bash-path-fix.tests.ps1 - suita dla bash-path-fix.ps1
# Pary: co MUSI byc zalatane / co MUSI przejsc nietkniete / regresje.

$hook = "$PSScriptRoot\bash-path-fix.ps1"
$script:fails = 0

function Test-Case($name, $inputObj, $expect) {
    # $expect: 'PATCH' (zwrocil updatedInput) | 'SILENT' (brak outputu)
    if ($inputObj -is [string]) { $json = $inputObj } else { $json = $inputObj | ConvertTo-Json -Compress -Depth 6 }
    $out = $json | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook
    $got = if ("$out" -match 'updatedInput') { 'PATCH' } elseif ($out) { 'PASS' } else { 'SILENT' }
    if ($got -eq $expect) { $v = 'OK  ' } else { $v = 'FAIL'; $script:fails++ }
    "[{0}] {1,-58} oczekiwane={2} otrzymane={3}" -f $v, $name, $expect, $got
}

function Test-Content($name, $inputObj, $mustContain) {
    # Sprawdzamy wartosc PO zdekodowaniu JSON, nie surowy string wyjscia.
    # Powod: PS 5.1 ConvertTo-Json escapuje '<', '>' i '&' jako < > &,
    # wiec porownanie do surowego literalu dawalo FAIL na poprawnym hooku
    # (zmierzone 2026-09-02). Konsument parsuje JSON, wiec liczy sie wartosc.
    $json = $inputObj | ConvertTo-Json -Compress -Depth 6
    $out = $json | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook
    $decoded = ''
    try {
        $o = "$out" | ConvertFrom-Json
        $decoded = [string]$o.hookSpecificOutput.updatedInput.command
        # pola poboczne tez musza przetrwac - skleic je do porownania
        foreach ($p in $o.hookSpecificOutput.updatedInput.PSObject.Properties) {
            $decoded = $decoded + "`n" + $p.Name + '=' + [string]$p.Value
        }
    } catch { $decoded = "$out" }
    if ($decoded -match [regex]::Escape($mustContain)) { $v = 'OK  ' } else { $v = 'FAIL'; $script:fails++ }
    "[{0}] {1,-58} zawiera '{2}'" -f $v, $name, $mustContain
}

"=== bash-path-fix ==="

# --- musi byc cisza ---
Test-Case 'pusty stdin -> cisza' '' 'SILENT'
Test-Case 'inne narzedzie (Grep) -> cisza' @{ tool_name='Grep'; tool_input=@{ pattern='x' } } 'SILENT'
Test-Case 'Bash bez command -> cisza' @{ tool_name='Bash'; tool_input=@{ description='x' } } 'SILENT'
Test-Case 'Bash z pustym command -> cisza' @{ tool_name='Bash'; tool_input=@{ command='   ' } } 'SILENT'

# --- nie dubluj, gdy juz naprawione ---
Test-Case 'komenda juz zrodluje .bashrc -> cisza' @{ tool_name='Bash'; tool_input=@{ command='. "$HOME/.bashrc"; git status' } } 'SILENT'
Test-Case 'komenda ma export Git/usr/bin -> cisza' @{ tool_name='Bash'; tool_input=@{ command='export PATH="/c/Program Files/Git/usr/bin:$PATH"; head -1 x' } } 'SILENT'
Test-Case 'komenda odwoluje sie do BASH_ENV -> cisza' @{ tool_name='Bash'; tool_input=@{ command='. "$BASH_ENV"; dotnet --version' } } 'SILENT'

# --- musi byc zalatane ---
Test-Case 'zwykla komenda git -> patch' @{ tool_name='Bash'; tool_input=@{ command='git status --short' } } 'PATCH'
Test-Case 'komenda wieloliniowa -> patch' @{ tool_name='Bash'; tool_input=@{ command="cd /c/repo`ndotnet build" } } 'PATCH'
Test-Case 'komenda z heredoc -> patch' @{ tool_name='Bash'; tool_input=@{ command="cat <<'EOF'`nabc`nEOF" } } 'PATCH'

# --- tresc patcha ---
Test-Content 'patch zawiera source .bashrc' @{ tool_name='Bash'; tool_input=@{ command='git status' } } '.bashrc'
Test-Content 'patch zachowuje oryginalna komende' @{ tool_name='Bash'; tool_input=@{ command='git status --short' } } 'git status --short'
Test-Content 'patch zachowuje pole run_in_background' @{ tool_name='Bash'; tool_input=@{ command='sleep 1'; run_in_background=$true } } 'run_in_background'
Test-Content 'patch zachowuje pole description' @{ tool_name='Bash'; tool_input=@{ command='ls'; description='listuj' } } 'listuj'
Test-Content 'patch jest cichy gdy brak pliku' @{ tool_name='Bash'; tool_input=@{ command='ls' } } '>/dev/null 2>&1'

# --- regresja: prefiks nie moze rozwalic komendy zaczynajacej sie od komentarza ---
Test-Case 'komenda zaczynajaca sie od # -> patch' @{ tool_name='Bash'; tool_input=@{ command="# komentarz`nls" } } 'PATCH'

""
if ($script:fails -eq 0) { "WYNIK: OK (0 FAIL)" } else { "WYNIK: FAIL ($script:fails)" }
