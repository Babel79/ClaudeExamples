# PreToolUse (Bash) HARD guard: masowe destrukcyjne komendy bez jawnej listy plikow
#  -> BLOKUJE (deny). Cel: nigdy wiecej "sed po WSZYSTKICH .ts" (R7: 331 plikow -> revert).
# Blokuje 4 klasy:
#  (A) sed/perl -i z wildcardem lub przez find -exec (operacja in-place na wielu plikach)
#  (B) rm / git rm z wildcardem (*.ext, -r .) bez jawnej sciezki
#  (C) git checkout/restore -- .  (twardy revert calego drzewa)
#  (D) git clean -f (nieodwracalne kasowanie untracked; -n/--dry-run przepuszczamy)
# Wyjatek: komenda z jawna lista konkretnych plikow (bez * i bez 'find ... -exec').
#
# WERSJA 2 (2026-09-02) - DOPASOWANIE DO CZASOWNIKA, NIE DO TEKSTU.
#   Pomiar audytu: falszywe alarmy w 6 z 14 sesji, wszystkie na tej samej klasie - CYTAT komendy
#   w TRESCI pisanego pliku (heredoc do .md, echo prozy o zakazie do dokumentacji, wpis do
#   change-loga opisujacy incydent). v1 dopasowywala wzorce do calego stringa komendy, wiec
#   'cat >> notes.md <<EOF ... git checkout -- . ... EOF' czytala jako revert drzewa.
#   Teraz: (1) wycinamy CIALA heredocow, (2) wycinamy argumenty echo/printf, (3) tniemy reszte na
#   segmenty po ; && || | i nowej linii, (4) wzorca szukamy TYLKO na pozycji czasownika (poczatek
#   segmentu). Ta sama poprawka co w sharptools-first-guard, gdzie zdala egzamin.
#   Cztery klasy deny zachowane bez zmian w zakresie.
# Defensive, ASCII-only (Windows PowerShell 5.1 czyta .ps1 jako ANSI). exit 0 always.
$ErrorActionPreference = 'SilentlyContinue'
try {
  $raw = [Console]::In.ReadToEnd()
  if (-not $raw) { exit 0 }
  $j = $raw | ConvertFrom-Json
  $cmd = [string]$j.tool_input.command
  if (-not $cmd) { exit 0 }

  # --- (1) wytnij ciala heredocow: <<EOF / <<'EOF' / <<-"EOF" ... EOF ---
  $scan = [regex]::Replace($cmd, '(?sm)<<-?\s*([''"]?)([A-Za-z_][A-Za-z0-9_]*)\1.*?^\s*\2\s*$', ' HEREDOC ')
  # heredoc bez domykajacego znacznika w tej samej komendzie (ucieta tresc) - wytnij do konca
  $scan = [regex]::Replace($scan, '(?s)<<-?\s*([''"]?)[A-Za-z_][A-Za-z0-9_]*\1.*$', ' HEREDOC ')

  # --- (2) wytnij argumenty echo/printf (proza o zakazach trafia do .md, a nie do shella) ---
  $scan = [regex]::Replace($scan, '(?i)\b(echo|printf)\s+("(?:[^"\\]|\\.)*"|''[^'']*''|[^;&|<>\r\n]*)', ' echo ')

  # --- (3) tnij na segmenty; czasownik = pierwszy token segmentu ---
  $segments = [regex]::Split($scan, '(?:;|&&|\|\||\||\r?\n)')

  $hit = $null
  foreach ($seg in $segments) {
    if ($null -ne $hit) { break }
    $s = [string]$seg
    if ([string]::IsNullOrWhiteSpace($s)) { continue }
    $s = $s.Trim()
    # zdejmij prefiksy, ktore nie sa czasownikiem docelowym
    $s = $s -replace '^\(+\s*', ''
    $s = $s -replace '^(?i)(sudo|env|time|nohup|xargs)\s+', ''
    $s = $s -replace '^[A-Za-z_][A-Za-z0-9_]*=\S*\s+', ''
    if ([string]::IsNullOrWhiteSpace($s)) { continue }

    # (A1) sed/perl in-place z wildcardem
    if ($s -match '(?i)^(sed|perl)\b' -and $s -match '(?i)(^|\s)-[a-z]*i' -and $s -match '\*') {
      $hit = 'sed/perl -i na wielu plikach (wildcard)'
    }
    # (A2) find ... -exec sed/perl -i
    elseif ($s -match '(?i)^find\b' -and $s -match '(?i)-exec\b' -and $s -match '(?i)\b(sed|perl)\b' -and $s -match '(?i)(^|\s)-[a-z]*i') {
      $hit = 'sed/perl -i przez find -exec (operacja na wielu plikach)'
    }
    # (B) rm / git rm z wildcardem lub rekurencja kropki
    elseif ($s -match '(?i)^(git\s+rm|rm)\b' -and ($s -match '\*' -or $s -match '(?i)^rm\s+-[a-z]*r[a-z]*\s+\.(\s|$)')) {
      $hit = 'rm/git rm z wildcardem lub rekurencja (.)'
    }
    # (C) git checkout/restore -- . (revert calego drzewa)
    elseif ($s -match '(?i)^git\s+(checkout|restore)\b' -and $s -match '(?i)--\s+\.(\s|$)') {
      $hit = 'git checkout/restore -- . (revert calego drzewa)'
    }
    # (D) git clean -f (nieodwracalne kasowanie untracked)
    elseif ($s -match '(?i)^git\s+clean\b' -and $s -notmatch '(?i)(\s-[a-z]*n[a-z]*(\s|$)|--dry-run)') {
      $hit = 'git clean -f (nieodwracalne kasowanie untracked)'
    }
  }

  if ($hit) {
    $reason = "[DESTRUCTIVE-BULK] Wykryto '$hit' na pozycji czasownika komendy. Komendy masowe-destrukcyjne MUSZA dzialac na JAWNEJ liscie konkretnych plikow, nie na wildcard/rekurencji (R7: sed po wszystkich .ts ruszyl 331 plikow -> revert). Dla 'git clean': untracked pliki NIE sa w historii - skasowanych nie odzyskasz (incydent ENV.10 tego projektu). Jesli naprawde chcesz sprzatnac: najpierw 'git clean -nd' (dry-run) i pokaz liste userowi. Wypisz dokladne sciezki. Dla C#: NIE uzywaj mutujacych SharpTool_* (zakazane od 2026-09-09) - zrob FindReferences po liste, potem Edit. Komenda zablokowana."
    $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $reason } } | ConvertTo-Json -Compress -Depth 6
    Write-Output $out
  }
  exit 0
} catch { exit 0 }
