# Xaml.Tests.ps1 - every window in Studio.ps1 is built from a XAML string at
# RUNTIME, so a bad attribute in a dialog only blows up the moment you click the
# button that opens it. This loads each of them up front instead.
#
# Run:  powershell -ExecutionPolicy Bypass -File tests\Xaml.Tests.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

$src = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Studio.ps1') -Raw

# every  @" ... "@  block whose content is a <Window ...> document
$blocks = [regex]::Matches($src, '(?s)@"\r?\n(\s*<Window\b.*?)\r?\n"@')
A ($blocks.Count -ge 3) "found the window definitions in Studio.ps1 (got $($blocks.Count))"

$i = 0
foreach ($b in $blocks) {
    $i++
    $xamlText = $b.Groups[1].Value
    $title = 'window ' + $i
    $m = [regex]::Match($xamlText, 'Title="([^"]*)"')
    if ($m.Success) { $title = $m.Groups[1].Value }

    # PowerShell would expand these before XamlReader ever sees them; if one
    # appears, this test can't judge the real markup, so say so loudly.
    if ($xamlText -match '\$\w') { A $false "$title has no PowerShell interpolation in its XAML"; continue }

    try {
        [xml]$doc = $xamlText
        $reader = New-Object System.Xml.XmlNodeReader $doc
        $win = [Windows.Markup.XamlReader]::Load($reader)
        A ($null -ne $win) "$title loads"
    } catch {
        A $false "$title loads - $($_.Exception.Message)"
    }
}

# the controls the code reaches for by name must actually exist in the markup
foreach ($name in 'CmbPos', 'Bold', 'VidList', 'BtnBurn', 'Txt', 'Rows', 'Import') {
    A ($src -match ('x:Name="' + [regex]::Escape($name) + '"')) "x:Name=$name is present in the markup"
}

if ($fails -gt 0) { Write-Host "`n$fails test(s) FAILED"; exit 1 }
Write-Host "`nAll XAML tests passed."
exit 0
