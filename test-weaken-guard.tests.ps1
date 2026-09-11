$hook = Join-Path $PSScriptRoot 'test-weaken-guard.ps1'
$fail = 0

function Test-Case($name, $toolInput, $expect) {
  # $expect: 'ASK' (test file, oslabiajacy wzorzec DODANY) | 'CTX' (app code nudge, non-blocking)
  #          | 'SILENT' (brak outputu - nie test, nie appCode, albo wzorzec juz byl w old_string)
  $json = @{ tool_input = $toolInput } | ConvertTo-Json -Compress -Depth 6
  $out  = ($json | & powershell.exe -NoProfile -File $hook) -join ''
  $got  = if ("$out" -match 'permissionDecision":"ask') { 'ASK' }
          elseif ("$out" -match 'additionalContext') { 'CTX' }
          elseif ([string]::IsNullOrWhiteSpace($out)) { 'SILENT' }
          else { 'INNE' }
  $ok = ($got -eq $expect)
  if (-not $ok) { $script:fail++ }
  $verdict = if ($ok) { 'OK  ' } else { 'FAIL' }
  Write-Output ("[{0}] {1,-58} oczekiwane={2} otrzymane={3}" -f $verdict, $name, $expect, $got)
}

# --- (A) TEST FILE: nowy wzorzec oslabiajacy -> ASK ---
Test-Case 'Edit .cs test: nowy [Skip(' `
  @{ file_path='Moricom.OneHotel.Tests\FooTests.cs'; old_string='[Fact]'; new_string='[Skip("bo padal")]' } `
  'ASK'

Test-Case 'Edit .spec.ts: nowy xit(' `
  @{ file_path='src\app\foo.spec.ts'; old_string="it('dziala', () => {"; new_string="xit('dziala', () => {" } `
  'ASK'

Test-Case 'Write .cs test: content z Assert.True(true)' `
  @{ file_path='Moricom.OneHotel.Tests\BarTests.cs'; content='public void X() { Assert.True(true); }' } `
  'ASK'

Test-Case 'MultiEdit .cs test: edits[] z fit(' `
  @{ file_path='src\app\baz.spec.ts'; edits=@(@{ old_string='it('; new_string='fit(' }) } `
  'ASK'

Test-Case 'Edit .cs test: nowy Should().NotThrow' `
  @{ file_path='Tests\QuxTests.cs'; old_string='act.Should().Throw<Exception>();'; new_string='act.Should().NotThrow();' } `
  'ASK'

# --- pulapka: wzorzec juz byl w old_string (NIE nowo dodany) -> SILENT ---
Test-Case 'Edit .cs test: [Skip juz byl w old_string (nie nowy)' `
  @{ file_path='Moricom.OneHotel.Tests\FooTests.cs'; old_string='[Skip("legacy")] [Fact]'; new_string='[Skip("legacy")] [Fact(DisplayName="x")]' } `
  'SILENT'

# --- test file bez wzorca oslabiajacego -> SILENT (nie appCode, bo isTest ma pierwszenstwo) ---
Test-Case 'Edit .cs test: zwykla zmiana asercji' `
  @{ file_path='Moricom.OneHotel.Tests\FooTests.cs'; old_string='result.Should().Be(1);'; new_string='result.Should().Be(2);' } `
  'SILENT'

# --- (B) APP CODE (nie-test) -> CTX (nudge RULE1, non-blocking) ---
# HISTORIA: pierwotny regex hooka byl [\\/]WebApi[\\/]Controllers[\\/] (bez kropki w klasie
# znakow) i NIE dopasowywal realnego folderu tego repo "Moricom.OneHotel.WebApi" (kropka
# przed "WebApi", nie separator) - zgloszone jako KNOWN-FAIL. W trakcie tej sesji hook zostal
# NAPRAWIONY przez kogos innego (linia 49 ma teraz [\\/.]WebApi... + komentarz "poprawka
# 2026-09-02") - patrz FINDINGS w raporcie koncowym. Test ponizej dowodzi POPRAWKI: dziala
# zarowno na "gola" sciezke jak i na realna sciezke tego repo z prefiksem "Moricom.OneHotel.".
Test-Case 'Controller, folder doslownie "WebApi" -> RULE1 nudge (zgodnie z regex hooka)' `
  @{ file_path='C:\repo\WebApi\Controllers\GuestController.cs'; old_string='a'; new_string='b' } `
  'CTX'

Test-Case 'Controller, REALNA sciezka Moricom.OneHotel.WebApi\Controllers -> RULE1 nudge (bug NAPRAWIONY w trakcie sesji)' `
  @{ file_path='Moricom.OneHotel.WebApi\Controllers\GuestController.cs'; old_string='a'; new_string='b' } `
  'CTX'

Test-Case 'Angular .component.ts (app code, dopasowanie po rozszerzeniu) -> RULE1 nudge' `
  @{ file_path='src\app\guest\guest.component.ts'; old_string='a'; new_string='b' } `
  'CTX'

Test-Case 'Logic/, folder doslownie "Logic" -> RULE1 nudge (zgodnie z regex hooka)' `
  @{ file_path='C:\repo\Logic\Handlers\FooHandler.cs'; content='class FooHandler {}' } `
  'CTX'

# Regresja 2026-09-02: byl KNOWN-FAIL (regex [\\/]Logic[\\/] nie lapal realnego "Moricom.OneHotel.Logic" - kropka przed nazwa);
# hook poprawiony na [\\/.] dla wszystkich warstw w tej samej sesji, przypadek zostaje jako straznik regresji.
Test-Case 'regresja: realna sciezka Moricom.OneHotel.Logic -> RULE1 nudge' `
  @{ file_path='Moricom.OneHotel.Logic\Handlers\FooHandler.cs'; content='class FooHandler {}' } `
  'CTX'

# --- wylaczenia: .claude/, .md/.json/.yaml/.txt -> SILENT nawet gdyby content wygladal jak app code ---
Test-Case '.claude/ path -> zawsze SILENT' `
  @{ file_path='.claude\skills\foo\SKILL.md'; content='WebApi/Controllers/Foo.cs' } `
  'SILENT'

Test-Case '.md rozszerzenie -> SILENT' `
  @{ file_path='Moricom.OneHotel.WebApi\Controllers\README.md'; content='opis kontrolera' } `
  'SILENT'

# --- plik nie-app, nie-test (np. .csproj bez matcha) -> SILENT ---
Test-Case 'plik neutralny (nie test, nie appCode) -> SILENT' `
  @{ file_path='Moricom.OneHotel.WebApi\Moricom.OneHotel.WebApi.csproj'; content='<Project />' } `
  'SILENT'

# --- brzeg: brak file_path / brak tool_input / pusty stdin ---
Test-Case 'brak file_path -> SILENT' @{ content='cokolwiek' } 'SILENT'

$noTi = ('{}' | & powershell.exe -NoProfile -File $hook) -join ''
if ([string]::IsNullOrWhiteSpace($noTi)) { Write-Output '[OK  ] brak tool_input ({}) -> brak outputu' }
else { $fail++; Write-Output '[FAIL] brak tool_input ({}) -> jest output' }

$empty = ('' | & powershell.exe -NoProfile -File $hook) -join ''
if ([string]::IsNullOrWhiteSpace($empty)) { Write-Output '[OK  ] pusty stdin -> brak outputu' }
else { $fail++; Write-Output '[FAIL] pusty stdin -> jest output' }

Write-Output ''
if ($fail -eq 0) { Write-Output 'WYNIK: PASS (0 bledow)' } else { Write-Output "WYNIK: FAIL ($fail bledow)" }
