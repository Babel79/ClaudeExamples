# PreToolUse (Bash) HARD guard: bulk rename/delete na plikach C# przez bash/sed
#  -> BLOKUJE (deny). Bulk-rename/delete C# NIE moze isc przez tekstowy sed/git rm
#  (gubi overloady, interfejsy, referencje cross-project).
# ZMIANA 2026-09-09: hook radzil wczesniej 'uzyj mcp__sharptools' - to juz NIEAKTUALNE.
#  Mutacje SharpToolsem sa ZAKAZANE (bilans: 14 uzyc mutujacych -> 21 incydentow szkody,
#  0 udokumentowanych korzysci; cust_sharptools_refactor par.0). Wlasciwa sciezka:
#  FindReferences (odczyt, dozwolony) po pelna liste call-site'ow -> Edit -> dotnet build.
# Wykrywa: sed/perl in-place na .cs, git rm wielu .cs, rename z wildcardem .cs.
# Defensive, ASCII-only (Windows PowerShell 5.1 czyta .ps1 jako ANSI). exit 0 always.
$ErrorActionPreference = 'SilentlyContinue'

# ENV.99 tego projektu (autoryzacja usera 2026-08-24): hook dopasowywal PROZE, nie komende, i przez to
# blokowal zapis dokumentacji OPISUJACEJ ten sam zakaz (heredoc do pliku .md w .claude/, ktory
# nie dotyka ani jednego pliku zrodlowego). Skutek byl odwrotny do zamierzonego: wiedza o zakazie
# nie mogla trafic tam, skad agenci ja czytaja.
#
# ROZSZERZENIE 2026-09-10 (ENV.132 + ENV.87): detektory liczyly trafienia w CALEJ komendzie, wiec
# komenda zlozona ('odczyt pliku .cs ; niepowiazana komenda z flaga -i') dawala DENY, choc zaden
# jej czlon nie byl bulk-mutacja pliku .cs. ENV.87: zwykly ODCZYT pliku .cs edytorem strumieniowym
# w trybie bez zapisu byl blokowany, bo flaga '-i' pochodzila z INNEGO czlonu.
# Normalizacja przed dopasowaniem (te same trzy kroki co w rule4-bash-nudge.ps1):
#   1) usun cialo heredoca, 2) zamaskuj literaly w cudzyslowach placeholderem @@LITn@@,
#   3) podziel komende na czlony po ';' '&&' '||' '|' '&' i nowej linii - i oceniaj kazdy OSOBNO.
#
# !! OCHRONA NIE SLABNIE - swiadomie ODRZUCONE warianty (nie odtwarzaj ich):
#   (a) zwolnienie po samej sciezce docelowej - przepuscilby '<edytor> -i plik.cs > .claude/x.md';
#   (b) BEZWARUNKOWE zdejmowanie cudzyslowow - przepusciloby realna bulk-mutacje z CYTOWANA
#       sciezka ('<edytor> -i "s/a/b/" "Foo.cs"'), bo '.cs' zniknelby razem z literalem.
# Dlatego literaly sa PRZYWRACANE w kazdym czlonie, ktorego czasownik moze mutowac plik
# (sed/perl/mv/rename/cp/rm/git rm/git mv), a maskowane tylko w czlonie, ktorego czasownik jest
# emiterem tekstu albo wyszukiwarka (echo/printf/cat/tee/Add-Content/Set-Content/Out-File/
# grep/rg/findstr/Select-String/git grep) - tam cytowana tresc jest DANYMI, nie komenda.
# Podzial po '|' domyka luke 'cat x | <edytor> -i "..." "Foo.cs"': drugi czlon ma czasownik
# mutujacy, wiec literaly wracaja i trafienie zostaje wykryte.

function Remove-HeredocBodies([string]$text) {
  $out = $text
  foreach ($m in [regex]::Matches($text, '<<-?\s*["'']?([A-Za-z_][A-Za-z0-9_]*)["'']?')) {
    $delim = $m.Groups[1].Value
    $body = [regex]::Match($out, '(?ms)<<-?\s*["'']?' + [regex]::Escape($delim) + '["'']?.*?^\s*' + [regex]::Escape($delim) + '\s*$')
    if ($body.Success) { $out = $out.Replace($body.Value, ' HEREDOC_BODY_STRIPPED ') }
  }
  return $out
}

function Get-MaskedLiterals([string]$text) {
  $lits = New-Object System.Collections.ArrayList
  $masked = $text
  $rx = [regex]'"[^"]*"|''[^'']*'''
  while ($true) {
    $m = $rx.Match($masked)
    if (-not $m.Success) { break }
    $idx = $lits.Count
    [void]$lits.Add($m.Value)
    $masked = $masked.Substring(0, $m.Index) + ('@@LIT' + $idx + '@@') + $masked.Substring($m.Index + $m.Length)
  }
  return @{ Masked = $masked; Literals = $lits }
}

function Restore-Literals([string]$seg, $lits) {
  $out = $seg
  for ($i = 0; $i -lt $lits.Count; $i++) { $out = $out.Replace('@@LIT' + $i + '@@', [string]$lits[$i]) }
  return $out
}

try {
  $raw = [Console]::In.ReadToEnd()
  if (-not $raw) { exit 0 }
  $j = $raw | ConvertFrom-Json
  $cmd = [string]$j.tool_input.command
  if (-not $cmd) { exit 0 }

  $mk = Get-MaskedLiterals (Remove-HeredocBodies $cmd)
  # separatorem jest '&&', NIE pojedynczy '&' - inaczej przekierowanie '2>&1' zostaje przeciete na pol
  $segments = [regex]::Split($mk.Masked, ';|&&|\|+|\r?\n')

  # flaga in-place: '-i', '-i.bak', klastrowane '-pi', '--in-place'.
  # Lookbehind/lookahead na [\w-] chroni przed trafieniem w '--include' / '--expression'.
  $inPlaceRx = '(?<![\w-])-[A-Za-z]*i[A-Za-z]*(?![\w-])|--in-place\b'

  $hit = $null
  $gitRmCsTotal = 0
  $normSegs = New-Object System.Collections.ArrayList

  foreach ($segRaw in $segments) {
    if ([string]::IsNullOrWhiteSpace($segRaw)) { continue }

    $isDataVerb = ($segRaw -match '(?i)^\s*(?:sudo\s+)?(echo|printf|cat|tee|type|Write-Output|Write-Host|Add-Content|Set-Content|Out-File|grep|egrep|fgrep|rg|findstr|Select-String|sls)\b') -or
                  ($segRaw -match '(?i)^\s*(?:sudo\s+)?git\s+(grep|log|show|diff|status)\b')
    $isMutVerb  = ($segRaw -match '(?i)^\s*(?:sudo\s+)?(sed|perl|mv|rename|ren|cp|rm)\b') -or
                  ($segRaw -match '(?i)^\s*(?:sudo\s+)?git\s+(rm|mv)\b')
    # siatka bezpieczenstwa dla czasownikow spoza listy: zapis prozy do .md / .claude,
    # ale NIGDY dla czlonu z czasownikiem mutujacym (to jest wariant (a) wyzej).
    $isDocWrite = (-not $isMutVerb) -and ($segRaw -match '(?i)>>?\s*["'']?[^\s"''|;&]*(\.md\b|\.claude[\\/])')

    $seg = if ($isDataVerb -or $isDocWrite) { $segRaw } else { Restore-Literals $segRaw $mk.Literals }
    [void]$normSegs.Add($seg)

    $hasCs = $seg -match '(?i)\.cs\b'
    if (-not $hasCs) { continue }

    if (-not $hit) {
      # sed/perl in-place dotykajacy .cs (flaga i plik MUSZA byc w TYM SAMYM czlonie)
      if (($seg -match '(?i)\b(sed|perl)\b') -and ($seg -match $inPlaceRx)) {
        $hit = 'sed/perl -i na plikach .cs'
      }
      # rename/mv wielu .cs z wildcardem
      elseif (($seg -match '(?i)\b(mv|rename|ren)\b') -and ($seg -match '[\*\?]')) {
        $hit = 'mv/rename z wildcardem na .cs'
      }
    }

    # git rm na .cs -> BLOKUJ WYLACZNIE bulk (glob / petla / podstawienie / >2 pliki).
    # ENV.22 tego projektu: wczesniej blokowana byla KAZDA delecja .cs, takze pojedynczego pliku
    # z jawna sciezka. W polaczeniu z zakazem mutacji SharpToolsem (stray-branch, utrata
    # plikow untracked - ENV.10 tego projektu) nie istniala ZADNA legalna sciezka skasowania pliku .cs,
    # a regula niewykonalna uczy obchodzenia regul zamiast ich przestrzegania.
    if ($seg -match '(?i)\bgit\s+rm\b') {
      if ($seg -match '(?i)\bgit\s+rm\b[^|;&]*[\*\?]') { if (-not $hit) { $hit = 'git rm z wildcardem na .cs' } }
      elseif (($seg -match '(?i)\b(for|while|xargs|find)\b') -or ($seg -match '\$\(') -or ($seg -match '`')) {
        if (-not $hit) { $hit = 'git rm na .cs w petli/podstawieniu' }
      }
      else {
        # suma po WSZYSTKICH czlonach - inaczej 'git rm A.cs ; git rm B.cs ; git rm C.cs'
        # obchodzilby bramke bulk samym rozbiciem na czlony.
        $gitRmCsTotal += ([regex]::Matches($seg, '(?i)[^\s"'']+\.cs\b')).Count
      }
    }
  }

  # KONSTRUKCJA ITERACYJNA jest z natury CROSS-CZLONOWA: w 'for f in *.cs; do <mutacja> $f; done'
  # zrodlo iteracji (*.cs) i mutacja leza w ROZNYCH czlonach, wiec sama segmentacja by je rozdzielila
  # i przepuscila realna bulk-mutacje (zmierzone: przypadek 'git rm w petli po .cs' zaczerwienil suite
  # przy pierwszym przebiegu tej wersji). Dlatego petle/xargs oceniamy na ZLACZONYCH, juz
  # znormalizowanych czlonach - literaly czlonow-danych pozostaja zamaskowane, wiec CYTAT petli
  # w 'echo "for f in *.cs; do git rm $f; done"' nadal przechodzi.
  $norm = ($normSegs -join ' ; ')
  if (-not $hit) {
    $iterCs = ($norm -match '(?i)\b(for|while)\b[^\r\n]*\bin\b[^\r\n]*\.cs\b') -or
              (($norm -match '(?i)\bxargs\b') -and ($norm -match '(?i)\.cs\b'))
    if ($iterCs) {
      if ($norm -match '(?i)\bgit\s+rm\b') { $hit = 'git rm na .cs w petli/podstawieniu' }
      elseif (($norm -match '(?i)\b(sed|perl)\b') -and ($norm -match $inPlaceRx)) { $hit = 'sed/perl -i na plikach .cs w petli/podstawieniu' }
      elseif ($norm -match '(?i)\b(mv|rename|ren)\b') { $hit = 'mv/rename na .cs w petli/podstawieniu' }
    }
  }

  if (-not $hit -and $gitRmCsTotal -gt 2) { $hit = "git rm na $gitRmCsTotal plikach .cs naraz (bulk)" }

  if ($hit) {
    $reason = "[SHARPTOOLS-FIRST] Wykryto '$hit'. Bulk rename/delete/move symboli C# NIGDY przez tekstowy bash/sed - gubi overloady, interfejsy i referencje cross-project. Wlasciwa sciezka: mcp__sharptools FindReferences (odczyt) po PELNA liste call-site'ow, potem Edit po tej liscie, potem dotnet build. UWAGA: mutujace SharpTool_* (AddMember/OverwriteMember/RenameSymbol/ManageUsings/...) sa ZAKAZANE od 2026-09-09 - patrz cust_sharptools_refactor par.0. Komenda zablokowana. UWAGA (ENV.22 tego projektu): delecja POJEDYNCZEGO pliku .cs jawna sciezka (max 2, bez wildcardu i bez petli) NIE jest blokowana - jesli kasujesz martwy typ, zrob najpierw cross-impact (find-references lub Grep per-typ po wszystkich projektach) i skasuj jawnymi sciezkami. Powyzej 2 plikow obowiazuje bramka zatwierdzenia z cust_agent_protocol 3.8."
    $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $reason } } | ConvertTo-Json -Compress -Depth 6
    Write-Output $out
  }
  exit 0
} catch { exit 0 }
