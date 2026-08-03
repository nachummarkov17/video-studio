# CaptionMarkup.Tests.ps1 - unit tests for Invoke-ToggleEmphasis, the pure text
# transform behind the caption editor's *Bold* button / Ctrl+B: select a word,
# press the key, and the *stars* that turn it teal when burned are applied for
# you (press again to take them off).
#
# Run:  powershell -ExecutionPolicy Bypass -File tests\CaptionMarkup.Tests.ps1

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\CaptionMarkup.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }
function Show($s) { return ($s -replace "`r", '\r' -replace "`n", '\n') }

try {
    # --- wrapping -----------------------------------------------------------
    $r = Invoke-ToggleEmphasis 'give it everything' 8 10          # "everything"
    A ($r.Text -eq 'give it *everything*') "wraps a single selected word (got '$(Show $r.Text)')"

    # each word gets its OWN stars: Caption-Style strips one star per token, so a
    # single *a b c* would leave the middle word un-teal.
    $r = Invoke-ToggleEmphasis 'a b c' 0 5
    A ($r.Text -eq '*a* *b* *c*') "wraps each word of a multi-word selection separately (got '$(Show $r.Text)')"

    $r = Invoke-ToggleEmphasis 'hello world' 2 5                   # "llo w"
    A ($r.Text -eq '*hello* *world*') "expands a partial selection out to whole words (got '$(Show $r.Text)')"

    $r = Invoke-ToggleEmphasis 'hello world' 3 0                   # caret inside "hello"
    A ($r.Text -eq '*hello* world') "acts on the word under the caret when nothing is selected (got '$(Show $r.Text)')"

    $r = Invoke-ToggleEmphasis 'go now!' 3 4                       # "now!"
    A ($r.Text -eq 'go *now*!') "keeps trailing punctuation outside the stars (got '$(Show $r.Text)')"

    $r = Invoke-ToggleEmphasis 'say (this) loud' 4 6               # "(this)"
    A ($r.Text -eq 'say (*this*) loud') "keeps wrapping punctuation outside the stars (got '$(Show $r.Text)')"

    # --- unwrapping ---------------------------------------------------------
    $r = Invoke-ToggleEmphasis '*a* *b*' 0 7
    A ($r.Text -eq 'a b') "unwraps when every selected word is already marked (got '$(Show $r.Text)')"

    $r = Invoke-ToggleEmphasis '*hello*' 1 5                       # inner word only
    A ($r.Text -eq 'hello') "absorbs the surrounding stars and unwraps (got '$(Show $r.Text)')"

    $r = Invoke-ToggleEmphasis 'go *now*!' 4 3
    A ($r.Text -eq 'go now!') "unwrapping restores the punctuation (got '$(Show $r.Text)')"

    # a mixed selection ends up fully marked, not toggled off
    $r = Invoke-ToggleEmphasis '*a* b' 0 5
    A ($r.Text -eq '*a* *b*') "a partly-marked selection becomes fully marked (got '$(Show $r.Text)')"

    # --- srt structure is never touched ------------------------------------
    $srt = "1`n00:00:01,000 --> 00:00:02,000`nhello"
    $r = Invoke-ToggleEmphasis $srt 0 $srt.Length
    A ($r.Text -eq "1`n00:00:01,000 --> 00:00:02,000`n*hello*") "leaves cue numbers and timestamps alone (got '$(Show $r.Text)')"

    $srt = "2`r`n00:00:03,000 --> 00:00:04,500`r`nsay it now"
    $r = Invoke-ToggleEmphasis $srt 0 $srt.Length
    A ($r.Text -eq "2`r`n00:00:03,000 --> 00:00:04,500`r`n*say* *it* *now*") "handles CRLF line endings (got '$(Show $r.Text)')"

    # --- selection handling -------------------------------------------------
    $r = Invoke-ToggleEmphasis 'hello world' 0 5
    A ($r.Text.Substring($r.SelStart, $r.SelLength) -eq '*hello*') "returns a selection covering the transformed words"

    $r = Invoke-ToggleEmphasis 'a  b' 1 2                          # only whitespace
    A ($r.Text -eq 'a  b') "is a no-op on a whitespace-only selection (got '$(Show $r.Text)')"

    $r = Invoke-ToggleEmphasis '' 0 0
    A ($r.Text -eq '') "is a no-op on empty text"

    $r = Invoke-ToggleEmphasis 'hello' 99 5
    A ($r.Text -eq 'hello') "is a no-op when the selection is out of range"
}
catch {
    Write-Host "FAIL: unexpected error - $($_.Exception.Message)"
    $fails++
}

if ($fails -gt 0) { Write-Host "`n$fails test(s) FAILED"; exit 1 }
Write-Host "`nAll CaptionMarkup tests passed."
exit 0
