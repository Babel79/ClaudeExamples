# sharptools-mutation-guard.ps1 - PreToolUse hook (matcher: mcp__sharptools__.*)
# Karta GM.ENV.155 (Moricom.OneHotel), zadanie 2026-09-10.
#
# POWOD: skill cust_sharptools_refactor par.0 zakazuje mutujacych SharpTool_* od 2026-09-09,
# ale to jest TEKST - agent moze go przeoczyc pod presja kontekstu. To JUZ 22. udokumentowany
# incydent tej klasy. Ostatni, zmierzony 2026-09-10: agent wywolal SharpTool_FindAndReplace,
# ktore auto-utworzylo branch 'sharptools/<ts>', zacommitowalo zmiane i PRZELACZYLO HEAD
# calego WSPOLDZIELONEGO drzewa roboczego siedmiu rownolegle pracujacych agentow. Pozostali
# pracowali dalej na obcej galezi, nieswiadomi - wykryto dopiero po zejsciu fali. Wczesniejsze
# incydenty tej samej rodziny: nadpisanie calej klasy + cicha kasacja 8 testow, oraz zabranie
# cudzej niezacommitowanej pracy.
#
# CO ROBI: DENY na wywolania mutujacych SharpTool_* (lista w $mutating nizej). Narzedzia
# ODCZYTOWE (FindReferences/ViewDefinition/GetMembers/SearchDefinitions/ListImplementations/
# ReadRawFromRoslynDocument/ReadTypesFromRoslynDocument/LoadSolution/LoadProject/
# AnalyzeComplexity) oraz wszystko spoza mcp__sharptools__ PRZECHODZA bez zmian.
#
# DOPASOWANIE WYLACZNIE PO tool_name Z PAYLOADU (nazwa wywolywanego narzedzia), NIGDY po
# tresci komendy/promptu/tool_input. Ta sama wada wystapila w tym srodowisku juz 4 razy
# (GM.ENV.142, .145, .132, .154 tego projektu): hook dopasowywal wzorzec do CALEGO TEKSTU
# komendy, wiec blokowal komendy ktore nazwe tylko CYTUJA (np. dokumentacja opisujaca zakaz,
# albo komenda Bash ktora w swojej tresci wspomina nazwe narzedzia). tool_name jest polem
# strukturalnym ustawianym przez harness na podstawie REALNIE wywolywanego narzedzia - nie da
# sie go "zacytowac" tak, zeby stalo sie faktycznym wywolaniem tego narzedzia. Ten hook nigdy
# nie zaglada do tool_input ani do zadnego innego pola tekstowego.
#
# ASCII-only (PS 5.1 czyta .ps1 jako ANSI). Kazdy blad -> exit 0 (fail-open: hook nie moze
# zablokowac calej sesji, tylko celowo wskazana klase wywolan).
$ErrorActionPreference = 'SilentlyContinue'

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $j = $raw | ConvertFrom-Json
    if ($null -eq $j) { exit 0 }

    $toolName = [string]$j.tool_name
    if ([string]::IsNullOrWhiteSpace($toolName)) { exit 0 }

    # Lista mutujacych narzedzi wprost z handoffu (Optymalizacja A, 2026-09-10). Dopasowanie
    # jest PELNE (^...$) na samej nazwie narzedzia - zaden fragment tresci nie wchodzi do gry.
    $mutating = 'FindAndReplace|AddMember|OverwriteMember|OverwriteRoslynDocument|RenameSymbol|MoveMember|CreateRoslynDocument|ManageAttributes|ManageUsings'
    if ($toolName -notmatch "^mcp__sharptools__SharpTool_($mutating)$") { exit 0 }

    $reason = "[SHARPTOOLS-MUTATION-BLOCK] '$toolName' jest ZABLOKOWANY (GM.ENV.155). Mutujace SharpTool_* auto-commituja i moga PRZELACZYC HEAD calego wspoldzielonego drzewa roboczego (zmierzone: 7 rownoleglych agentow, incydent 2026-09-10) albo nadpisac/skasowac cudzy kod bez ostrzezenia. Zamiast tego: SharpTool_FindReferences (odczyt) po pelna liste call-site'ow, potem mutuj narzedziem Edit, potem dotnet build."
    $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $reason } } | ConvertTo-Json -Compress -Depth 6
    Write-Output $out
    exit 0
} catch { exit 0 }
