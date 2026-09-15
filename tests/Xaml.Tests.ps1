# Xaml.Tests.ps1 - every window in the app is built from markup at RUNTIME, so a
# bad attribute in a dialog only blows up the moment you click the button that
# opens it. This loads each of them up front instead.
#
# Run:  powershell -STA -ExecutionPolicy Bypass -File tests\Xaml.Tests.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

$root = Join-Path $PSScriptRoot '..'

# Markup lives in two places since the split: the main window is a real .xaml
# file, the dialogs are here-strings in whichever script owns them. Gather both
# rather than naming files here and going stale.
$markup = @()
foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File | Sort-Object Name)) {
    $src = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($b in [regex]::Matches($src, '(?s)@"\r?\n(\s*<Window\b.*?)\r?\n"@')) {
        $markup += [pscustomobject]@{ Source = $file.Name; Xaml = $b.Groups[1].Value }
    }
}
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'ui') -Filter '*.xaml' -File -ErrorAction SilentlyContinue)) {
    $markup += [pscustomobject]@{ Source = ('ui\' + $file.Name); Xaml = (Get-Content -LiteralPath $file.FullName -Raw) }
}

$loaded = 0
foreach ($item in $markup) {
    $xamlText = $item.Xaml
    $title = $item.Source
    $m = [regex]::Match($xamlText, 'Title="([^"]*)"')
    if ($m.Success) { $title = $item.Source + ' / ' + $m.Groups[1].Value }

    # PowerShell would expand these before XamlReader ever saw them; if one
    # appears, this test can't judge the real markup, so say so loudly.
    if ($xamlText -match '\$\w') { A $false "$title has no PowerShell interpolation in its XAML"; continue }

    try {
        [xml]$doc = $xamlText
        $reader = New-Object System.Xml.XmlNodeReader $doc
        $window = [Windows.Markup.XamlReader]::Load($reader)
        A ($null -ne $window) "$title loads"
        $loaded++
    } catch {
        A $false "$title loads - $($_.Exception.Message)"
    }
}
# main window + caption editor + music picker
A ($loaded -ge 3) "found and loaded the app's windows (got $loaded)"

# the controls the code reaches for by name must actually exist in the markup
$allXaml = ($markup | ForEach-Object { $_.Xaml }) -join "`n"
foreach ($name in 'CmbPos', 'VidList', 'BtnBurn', 'Cues', 'CueScroll', 'Rows', 'Import',
                  'Colors', 'AddColor', 'Undo', 'Redo',
                  'EditorOverlay', 'EditorWebHost', 'Log', 'Status') {
    A ($allXaml -match ('x:Name="' + [regex]::Escape($name) + '"')) "x:Name=$name is present in the markup"
}

if ($fails -gt 0) { Write-Host "`n$fails test(s) FAILED"; exit 1 }
Write-Host "`nAll XAML tests passed."
exit 0
