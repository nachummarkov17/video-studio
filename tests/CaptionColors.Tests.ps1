# CaptionColors.Tests.ps1 - the emphasis palette, and painting words with it.
#
# Run:  powershell -ExecutionPolicy Bypass -File tests\CaptionColors.Tests.ps1

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\CaptionColors.ps1"
. "$PSScriptRoot\..\CaptionMarkup.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

# ---- the palette -----------------------------------------------------------
$defaults = ConvertFrom-CaptionColorText ''
A ($defaults.Count -eq 1) 'an empty palette is just the original colour'
A ($defaults[0].Marker -eq '*') 'and its marker is the star every existing .srt already uses'
A ($defaults[0].Hex -eq '#3D9E8E') 'in the brand teal'

$two = Add-CaptionColorTo $defaults 'Unhealthy' '#D93025'
A ($two.Count -eq 2) 'a colour can be added'
A ($two[0].Marker -eq '*') 'the star colour stays first, always'
A ($two[1].Marker -eq '~') 'the new one claims the next free marker'
A ($two[1].Name -eq 'Unhealthy') 'with the name you gave it'

A ($null -eq (Add-CaptionColorTo $defaults '' '#FF0000')) 'a colour with no name is refused'
A ($null -eq (Add-CaptionColorTo $defaults 'Bad' 'red')) 'a colour that is not #RRGGBB is refused'

# fill the pool and check it says no rather than overwriting something
$full = $defaults
for ($n = 1; $n -le 20; $n++) {
    $more = Add-CaptionColorTo $full "C$n" '#112233'
    if ($null -eq $more) { break }
    $full = $more
}
A ($full.Count -eq (Get-CaptionMarkerPool).Count) "the palette fills up to the marker pool and stops (got $($full.Count))"
A ($null -eq (Add-CaptionColorTo $full 'OneMore' '#445566')) 'and refuses one more rather than reusing a marker'
A ((@($full | ForEach-Object { $_.Marker } | Sort-Object -Unique)).Count -eq $full.Count) 'every marker in a full palette is distinct'

$back = Remove-CaptionColorFrom $two '~'
A ($back.Count -eq 1) 'a colour can be removed'
A ($null -eq (Remove-CaptionColorFrom $two '*')) 'but never the star - captions on disk depend on it'
A ($null -eq (Remove-CaptionColorFrom $two '^')) 'removing one that is not there is a no-op'

# ---- round trip through the file format ------------------------------------
$text = ConvertTo-CaptionColorText $two
$reread = ConvertFrom-CaptionColorText $text
A ($reread.Count -eq 2) 'the palette survives a save/load round trip'
A ($reread[1].Marker -eq '~' -and $reread[1].Hex -eq '#D93025') 'with marker and colour intact'
A ($text -like '*#*') 'the file explains itself with a comment'

$messy = @('', '   ', '# a comment', 'NoPipes', 'Bad|toolong|#FFFFFF', 'Bad|~|nothex',
           'Good|^|#0000FF', 'Dup|^|#00FF00') -join "`r`n"
$parsed = ConvertFrom-CaptionColorText $messy
A ($parsed.Count -eq 2) 'junk lines are skipped, not fatal'
A ($parsed[1].Name -eq 'Good') 'the one good line is kept'
A ($parsed[1].Hex -eq '#0000FF') 'and a duplicate marker does not overwrite it'

$restyled = ConvertFrom-CaptionColorText 'My Green|*|#00AA55'
A ($restyled.Count -eq 1 -and $restyled[0].Hex -eq '#00AA55') 'the star colour itself can be recoloured'

# ---- ASS conversion (blue-green-red, backwards from hex) -------------------
A ((ConvertTo-AssColor '#3D9E8E') -eq '&H8E9E3D&') 'brand teal converts to the ASS byte order'
A ((ConvertTo-AssColor '#FF0000') -eq '&H0000FF&') 'red converts'
A ((ConvertTo-AssColor 'nonsense') -eq '&HFFFFFF&') 'a broken colour falls back to white, not a crash'

# ---- painting words --------------------------------------------------------
$markers = @('*', '~')

$r = Invoke-ToggleEmphasis 'I eat protein daily' 6 7 '*' $markers
A ($r.Text -eq 'I eat *protein* daily') 'the first colour still wraps in stars'

$r2 = Invoke-ToggleEmphasis $r.Text $r.SelStart $r.SelLength '~' $markers
A ($r2.Text -eq 'I eat ~protein~ daily') 'a different colour RECOLOURS - it does not wrap twice'

$r3 = Invoke-ToggleEmphasis $r2.Text $r2.SelStart $r2.SelLength '~' $markers
A ($r3.Text -eq 'I eat protein daily') 'the same colour again clears it'

$r4 = Invoke-ToggleEmphasis 'no seed oils here' 3 9 '~' $markers
A ($r4.Text -eq 'no ~seed~ ~oils~ here') 'a phrase gets each word painted'

$r5 = Invoke-ToggleEmphasis 'eat *everything*! now' 5 12 '~' $markers
A ($r5.Text -eq 'eat ~everything~! now') 'punctuation stays outside the markers when recolouring'

# a caret with no selection paints the word it is sitting in
$r6 = Invoke-ToggleEmphasis 'sugar is bad' 2 0 '~' $markers
A ($r6.Text -eq '~sugar~ is bad') 'a caret inside a word is enough'

# a part-painted selection goes fully to the new colour
$r7 = Invoke-ToggleEmphasis 'a *one* two b' 2 9 '~' $markers
A ($r7.Text -eq 'a ~one~ ~two~ b') 'a part-marked selection ends up all one colour'

# ---- which marker is a word wearing? --------------------------------------
A ((Get-TokenMarker '*word*' $markers) -eq '*') 'a starred word reports the star'
A ((Get-TokenMarker '~word~' $markers) -eq '~') 'a tilde word reports the tilde'
A ((Get-TokenMarker '(~word~)' $markers) -eq '~') 'even inside brackets'
A ($null -eq (Get-TokenMarker 'word' $markers)) 'a plain word reports nothing'
A ($null -eq (Get-TokenMarker '***' $markers)) 'a run of markers with no word is not emphasis'
A ($null -eq (Get-TokenMarker '~word~' @('*'))) 'a marker not in the palette is just a character'

Write-Host ''
if ($fails -eq 0) { Write-Host "All CaptionColors tests passed." } else { Write-Host "$fails test(s) FAILED."; exit 1 }
