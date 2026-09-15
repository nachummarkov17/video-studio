# CaptionStyle.Tests.ps1 - what actually gets BURNED when you paint words.
#
# Run:  powershell -ExecutionPolicy Bypass -File tests\CaptionStyle.Tests.ps1

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\Caption-Style.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("CapStyle_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function Burn([string]$srtText, $colors, [string]$style = 'highlight') {
    $in = Join-Path $tmp 'in.srt'; $out = Join-Path $tmp 'out.ass'
    [System.IO.File]::WriteAllText($in, $srtText, (New-Object System.Text.UTF8Encoding($false)))
    Convert-SrtToAss -InPath $in -OutPath $out -Style $style -Colors $colors -VideoW 1080 -VideoH 1920
    return [System.IO.File]::ReadAllText($out)
}

try {
    $teal = '&H8E9E3D&'          # #3D9E8E
    $red  = '&H2530D9&'          # #D93025
    $palette = @(
        [pscustomobject]@{ Name = 'Good';      Marker = '*'; Hex = '#3D9E8E' },
        [pscustomobject]@{ Name = 'Unhealthy'; Marker = '~'; Hex = '#D93025' }
    )

    # ---- two colours in one caption ----------------------------------------
    $srt = "1`r`n00:00:00,000 --> 00:00:02,000`r`nI eat *protein* not ~seed~ oils`r`n`r`n"
    $ass = Burn $srt $palette
    A ($ass -like "*$teal*") 'the teal word is burned teal'
    A ($ass -like "*$red*") 'the red word is burned red - in the SAME caption'
    A ($ass -notlike '*`*protein`**') 'the markers themselves never reach the screen'
    A ($ass -notlike '*~seed~*') 'and neither do the tilde ones'
    A ($ass -like '*protein*' -and $ass -like '*seed*') 'but the words do'
    A ($ass -like '*I eat*' -and $ass -like '*oils*') 'unmarked words come through plain'

    # ---- the marker decides the colour, not the position -------------------
    $swapped = Burn "1`r`n00:00:00,000 --> 00:00:02,000`r`n~seed~ oils and *protein*`r`n`r`n" $palette
    $redFirst = $swapped.IndexOf($red)
    $tealFirst = $swapped.IndexOf($teal)
    A ($redFirst -gt 0 -and $tealFirst -gt $redFirst) 'reordering the words reorders the colours with them'

    # ---- old files keep working, with or without a palette -----------------
    $legacy = "1`r`n00:00:00,000 --> 00:00:02,000`r`nsome *starred* text`r`n`r`n"
    $noPalette = Burn $legacy $null
    A ($noPalette -like "*$teal*") 'a .srt from before the palette existed still burns teal'
    A ($noPalette -notlike '*`*starred`**') 'with its stars stripped'
    $withPalette = Burn $legacy $palette
    A ($withPalette -like "*$teal*") 'and the same file burns the same way WITH a palette'

    # ---- a marker that is not in the palette is just a character -----------
    $unknown = Burn "1`r`n00:00:00,000 --> 00:00:02,000`r`na ^word^ here`r`n`r`n" $palette
    A ($unknown -like '*^word^*') 'an unclaimed marker is left alone as literal text'

    # ---- a stray marker is not emphasis -------------------------------------
    $stray = Burn "1`r`n00:00:00,000 --> 00:00:02,000`r`nfive * three`r`n`r`n" $palette
    A ($stray -notlike "*$teal*") 'a lone star is not treated as a colour'

    # ---- punctuation stays outside ------------------------------------------
    $punct = Burn "1`r`n00:00:00,000 --> 00:00:02,000`r`ngive it ~everything~!`r`n`r`n" $palette
    A ($punct -like "*$red*") 'a marked word with punctuation attached still colours'
    A ($punct -like '*everything*' -and $punct -notlike '*~*') 'and no marker survives'

    # ---- plain style paints nothing ----------------------------------------
    $plain = Burn $srt $palette 'plain'
    A ($plain -notlike "*$red*" -and $plain -notlike "*$teal*") 'the plain style burns no colour at all'
    A ($plain -like '*protein*') 'but keeps the words'

    # ---- karaoke still works, and respects a word's own colour -------------
    $kar = Burn $srt $palette 'karaoke'
    A (([regex]::Matches($kar, 'Dialogue:')).Count -ge 6) 'karaoke emits one event per word'
    A ($kar -like "*$red*") 'and the red word is red as it pops'

    # ---- the file is still a valid .ass -------------------------------------
    A ($ass -like '*[Script Info]*' -and $ass -like '*[V4+ Styles]*' -and $ass -like '*[Events]*') 'the .ass structure is intact'
    A ($ass -like '*PlayResX: 162*') 'PlayRes matches the 9:16 frame so libass does not stretch it'
}
finally {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host ''
if ($fails -eq 0) { Write-Host "All CaptionStyle tests passed." } else { Write-Host "$fails test(s) FAILED."; exit 1 }
