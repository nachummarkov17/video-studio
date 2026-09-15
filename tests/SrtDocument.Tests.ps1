# SrtDocument.Tests.ps1 - the .srt parse/serialise round trip the caption editor
# now depends on. If this breaks, edits get written back to disk wrong.
#
# Run:  powershell -ExecutionPolicy Bypass -File tests\SrtDocument.Tests.ps1

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\SrtDocument.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

$crlf = "`r`n"
$sample = @(
    '1'
    '00:00:00,000 --> 00:00:02,610'
    'Nine days shopping haul.'
    ''
    '2'
    '00:00:02,960 --> 00:00:05,810'
    'We eat *healthy* food'
    'every single day.'
    ''
    '3'
    '00:01:07,440 --> 00:01:08,080'
    'our protein.'
    ''
) -join $crlf

# ---- parsing ---------------------------------------------------------------
$cues = Read-SrtCues $sample
A ($cues.Count -eq 3) "parses three cues (got $($cues.Count))"
A ([Math]::Abs($cues[0].Start - 0.0) -lt 0.001) 'first cue starts at 0'
A ([Math]::Abs($cues[0].End - 2.61) -lt 0.001) 'first cue ends at 2.61'
A ($cues[0].Text -eq 'Nine days shopping haul.') 'first cue text'
A ($cues[1].Text -eq "We eat *healthy* food`nevery single day.") 'two-line cue keeps its newline'
A ([Math]::Abs($cues[2].Start - 67.44) -lt 0.001) 'minutes are parsed (67.44s)'

# ---- round trip ------------------------------------------------------------
$out = ConvertTo-SrtText $cues
$again = Read-SrtCues $out
A ($again.Count -eq 3) 'round trip keeps the cue count'
A ($again[1].Text -eq $cues[1].Text) 'round trip keeps multi-line text'
A ([Math]::Abs($again[2].Start - $cues[2].Start) -lt 0.001) 'round trip keeps timings'
A ($out -match "1`r`n00:00:00,000 --> 00:00:02,610`r`n") 'writes CRLF and renumbers from 1'

# ---- editing a cue's words does not disturb its timing ---------------------
$cues[1].Text = 'We eat healthy food'
$edited = Read-SrtCues (ConvertTo-SrtText $cues)
A ($edited[1].Text -eq 'We eat healthy food') 'edited text survives the write'
A ([Math]::Abs($edited[1].Start - 2.96) -lt 0.001) 'editing text leaves the start alone'
A ([Math]::Abs($edited[1].End - 5.81) -lt 0.001) 'editing text leaves the end alone'

# ---- forgiving input -------------------------------------------------------
$lfOnly = "00:00:01.500 --> 00:00:02.000`nJust one line"
$c2 = Read-SrtCues $lfOnly
A ($c2.Count -eq 1) 'accepts LF-only, no index line, dot decimals, no trailing blank'
A ([Math]::Abs($c2[0].Start - 1.5) -lt 0.001) 'dot decimal separator parses'

$broken = "1`r`nnot a timing line`r`ntext`r`n`r`n2`r`n00:00:03,000 --> 00:00:04,000`r`nreal`r`n"
$c3 = Read-SrtCues $broken
A ($c3.Count -eq 1) 'a malformed cue is skipped, the rest still parse'
A ($c3[0].Text -eq 'real') 'the surviving cue is the well-formed one'

A ((Read-SrtCues '').Count -eq 0) 'empty text gives no cues'
A ((ConvertTo-SrtText @()) -eq '') 'no cues serialise to empty text'

# ---- non-ASCII -------------------------------------------------------------
# Built from code points so this test file itself stays pure ASCII - PowerShell
# 5.1 reads a BOM-less script as ANSI, and a literal accent here would mojibake
# the whole file before the test ever ran.
$fancy = "Caf$([char]0xE9) $([char]0x2014) na$([char]0xEF)ve $([char]0x201C)quotes$([char]0x201D)"
$uni = "00:00:00,000 --> 00:00:01,000`r`n$fancy`r`n"
A ((Read-SrtCues $uni)[0].Text -eq $fancy) 'non-ASCII text survives parsing'

# ---- time formatting -------------------------------------------------------
A ((ConvertTo-SrtTime 0) -eq '00:00:00,000') 'formats zero'
A ((ConvertTo-SrtTime 3661.5) -eq '01:01:01,500') 'formats hours/minutes/seconds/millis'
A ((ConvertTo-SrtTime -5) -eq '00:00:00,000') 'negative times clamp to zero'
A ((ConvertFrom-SrtTime 'nonsense') -eq $null) 'unparseable time is null'

# ---- follow-along ----------------------------------------------------------
A ((Find-ActiveCueIndex $cues 0.0) -eq 0) 'cue 0 is active at t=0'
A ((Find-ActiveCueIndex $cues 3.0) -eq 1) 'cue 1 is active mid-cue'
A ((Find-ActiveCueIndex $cues 30.0) -eq 1) 'the last started cue stays lit through a pause'
A ((Find-ActiveCueIndex $cues 99.0) -eq 2) 'the final cue is active past its end'
A ((Find-ActiveCueIndex @() 5.0) -eq -1) 'no cues means nothing active'

# ---- the cue object notifies ----------------------------------------------
$cue = New-Object VideoStudio.CaptionCue
$cue.Start = 65.29
A ($cue.TimeLabel -eq '1:05.2') "TimeLabel truncates rather than rounding up (got '$($cue.TimeLabel)')"
$script:notified = @()
$handler = [System.ComponentModel.PropertyChangedEventHandler] {
    param($s, $e) $script:notified += $e.PropertyName
}
$cue.add_PropertyChanged($handler)
$cue.IsActive = $true
$cue.Text = 'hello'
$cue.Text = 'hello'          # unchanged: must not re-notify
A ($script:notified -contains 'IsActive') 'IsActive raises PropertyChanged'
A ((@($script:notified | Where-Object { $_ -eq 'Text' }).Count) -eq 1) 'setting the same text does not re-notify'

Write-Host ''
if ($fails -eq 0) { Write-Host "All SrtDocument tests passed." } else { Write-Host "$fails test(s) FAILED."; exit 1 }
