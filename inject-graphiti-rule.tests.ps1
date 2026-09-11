$hook = Join-Path $PSScriptRoot 'inject-graphiti-rule.ps1'
$fail = 0
# Throttling stan zyje w $env:TEMP\claude-hookstate\<sess8>.graphiti (hardcoded w hooku,
# brak env-override) - uzywamy UNIKALNEGO session_id per test i sprzatamy plik na koniec.
$stateDir = Join-Path $env:TEMP 'claude-hookstate'

# Katalog projektu podawany w payloadzie jako 'cwd' - tak jak robi to realne wywolanie
# Claude Code. DO 2026-09-08 suita go NIE podawala i hook trafial na ostatni szczebel kaskady
# ($PSScriptRoot). Dzialalo tylko dlatego, ze hook lezal WEWNATRZ repo; po przenosinach do
# ~/.claude/hooks ten szczebel daje 'C:\Users\<konto>' i prefiks wychodzil jako nazwa konta.
# Nazwa jest SYNTETYCZNA i celowo NIE jest nazwa tego repo: asercje sprawdzaja teraz, ze prefiks
# PODAZA za katalogiem projektu, a nie ze jest zaszyty w hooku. To wzmocnienie, nie poluzowanie.
$fakeProjDir = Join-Path $env:TEMP 'Firma.ProduktX'
$prefix      = 'produktx'

function Invoke-Hook($sessionId) {
  if ($sessionId) {
    $json = @{ session_id = $sessionId; cwd = $fakeProjDir } | ConvertTo-Json -Compress
    return ($json | & powershell.exe -NoProfile -File $hook) -join ''
  } else {
    return ('' | & powershell.exe -NoProfile -File $hook) -join ''
  }
}

function Assert($name, $cond, $extra) {
  if ($cond) { Write-Output ("[OK  ] {0}" -f $name) } else { $script:fail++; Write-Output ("[FAIL] {0} {1}" -f $name, $extra) }
}

# UWAGA: hook obcina session_id do PIERWSZYCH 8 znakow dla nazwy pliku stanu (sid.Substring(0,8)) -
# $sess MUSI miec DOKLADNIE 8 znakow, inaczej test i hook licza na DWOCH ROZNYCH plikach
# (zlapane w praniu: preseed do 10 na 9-znakowym $sess nie mial zadnego wplywu na hook -
# hook czytal/pisal do INNEGO pliku o nazwie obcietej do 8 znakow).
$sess = ('tg' + [guid]::NewGuid().ToString('N').Substring(0,6))
if ($sess.Length -ne 8) { throw "test setup: sess musi miec 8 znakow, ma $($sess.Length)" }
$stateFile = Join-Path $stateDir "$sess.graphiti"

try {
  # --- tura 1 (brak pliku stanu) -> MUSI wstrzyknac ---
  $out1 = Invoke-Hook $sess
  Assert 'tura 1: wstrzykuje additionalContext' ($out1 -match 'additionalContext') $out1
  Assert 'tura 1: tresc zawiera "GRAPHITI"' ($out1 -match 'GRAPHITI')
  # Asercja WZMOCNIONA 2026-09-04: do tej pory sprawdzala tylko obecnosc 'moricom-onehotel'.
  # Po podziale wiedzy na 7 kategorii ten ciag nadal wystepuje (jako ARCHIWUM), wiec stara
  # asercja przechodzilaby nawet gdyby hook wstrzykiwal calkowicie nieaktualny kanon.
  # Teraz test wymaga WSZYSTKICH 7 kategorii - to jest rzecz, ktorej sesja ma sie dowiedziec.
  # Kategorie budowane z prefiksu wyprowadzonego z 'cwd' - dowodza, ze hook czyta katalog
  # projektu, zamiast cytowac zaszyta nazwe. Sila asercji bez zmian: nadal WSZYSTKIE 7.
  $kategorie = @("$prefix-tech","$prefix-domain","$prefix-history","$prefix-tasks","$prefix-env","$prefix-hints","$prefix-stats")
  foreach ($k in $kategorie) {
    Assert ("tura 1: tresc wymienia kategorie '{0}'" -f $k) ($out1 -match [regex]::Escape($k)) $out1
  }
  # ODWROCONA 2026-09-04 po rozdzieleniu archiwum do 7 kategorii.
  # Stara asercja wymagala samej OBECNOSCI ciagu 'moricom-onehotel' i przechodzila
  # nadal - bo nowy komunikat tez go zawiera, tyle ze w zdaniu "NIE ISTNIEJE".
  # Test swiecil wiec na zielono przy odwroconej intencji. Teraz sprawdzamy to,
  # co sesja ma naprawde wiedziec: ze tej grupy juz nie ma i nie wolno o nia pytac.
  # ZMIENIONA 2026-09-08 (H2, portabilizacja hookow): hook juz nie cytuje literalu
  # 'moricom-onehotel' (projekt-specyficzny archiwum-name nie ma sensu w 4 innych
  # projektach), wiec asercja sprawdza sam fakt ostrzezenia o brakujacym archiwum.
  Assert 'tura 1: ostrzega, ze stare (jednoworkowe) archiwum NIE ISTNIEJE' `
    ($out1 -match 'archiwum' -and $out1 -match 'NIE ISTNIEJE') $out1
  Assert ("tura 1: wymienia techniczna grupe {0}-canary jako zakazana" -f $prefix) `
    ($out1 -match [regex]::Escape("$prefix-canary")) $out1
  Assert 'tura 1: tresc zawiera "group_id"' ($out1 -match 'group_id')
  # Pulapka kosztujaca wiedze: add_memory zwraca "queued" takze wtedy, gdy zaraz porzuci epizod.
  Assert 'tura 1: ostrzega, ze "queued" nie znaczy zapisane' ($out1 -match 'queued') $out1
  Assert 'tura 1: wyjscie jest poprawnym JSON' ($null -ne ($out1 | ConvertFrom-Json))

  # --- tura 2: throttled (Every=10, emit tylko na 1,11,21,...) -> CISZA ---
  $out2 = Invoke-Hook $sess
  Assert 'tura 2: throttled -> brak outputu' ([string]::IsNullOrWhiteSpace($out2)) $out2

  # --- pre-seed licznika do 10, kolejne wywolanie robi n=11 -> (11-1)%10=0 -> MUSI wstrzyknac ---
  if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
  Set-Content -LiteralPath $stateFile -Value '10' -Encoding ascii
  $out11 = Invoke-Hook $sess
  Assert 'tura 11 (n preseed=10 -> 11): znow wstrzykuje (co 10-ta)' ($out11 -match 'additionalContext') $out11

  # tura 12 -> znow cisza
  $out12 = Invoke-Hook $sess
  Assert 'tura 12: throttled -> brak outputu' ([string]::IsNullOrWhiteSpace($out12)) $out12

  # --- pusty stdin / brak session_id -> emit ZAWSZE (brak liczenia tur) ---
  $outNoSess1 = Invoke-Hook $null
  $outNoSess2 = Invoke-Hook $null
  Assert 'brak session_id, wywolanie 1: emit (nie liczy tur)' ($outNoSess1 -match 'additionalContext') $outNoSess1
  Assert 'brak session_id, wywolanie 2: emit (nie liczy tur)' ($outNoSess2 -match 'additionalContext') $outNoSess2
}
finally {
  Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
