# CaptionMarkup.ps1
# The pure text transform behind the caption editor's *Bold* button (Ctrl+B).
#
# Burned captions colour a word teal when it's wrapped in *stars*. Typing those
# by hand is tedious, so: select a word (a double-click is enough), press the
# button, and the stars are applied for you. Press again to take them off.
#
# Kept separate from Studio.ps1 so it can be unit-tested without a window.

# The same "is this word marked?" rule Caption-Style.ps1 uses when it burns:
# a star at the OUTER edge of the token, even with punctuation attached
# (*word*!  (*word*)  "*word*"), and something word-like left over.
function Test-EmphasisMarked([string]$Token) {
    if ($Token -notmatch '\w') { return $false }
    $c = $Token
    $marked = $false
    $ml = [regex]::Match($c, '^([^\w*]*)\*')
    if ($ml.Success) { $marked = $true; $c = $c.Remove($ml.Groups[1].Length, 1) }
    $mt = [regex]::Match($c, '\*([^\w*]*)$')
    if ($mt.Success) { $marked = $true; $c = $c.Remove($mt.Index, 1) }
    if (-not ($c -match '\w')) { return $false }        # a stray lone *
    return $marked
}

function Remove-EmphasisFromToken([string]$Token) {
    $c = $Token
    $ml = [regex]::Match($c, '^([^\w*]*)\*')
    if ($ml.Success) { $c = $c.Remove($ml.Groups[1].Length, 1) }
    $mt = [regex]::Match($c, '\*([^\w*]*)$')
    if ($mt.Success) { $c = $c.Remove($mt.Index, 1) }
    return $c
}

# Wrap the WORD part only, leaving any attached punctuation outside the stars -
# "now!" becomes "*now*!", "(this)" becomes "(*this*)".
function Add-EmphasisToToken([string]$Token) {
    $m = [regex]::Match($Token, '^([^\w]*)(.*?)([^\w]*)$')
    if (-not $m.Success) { return $Token }
    $lead = $m.Groups[1].Value; $core = $m.Groups[2].Value; $trail = $m.Groups[3].Value
    if ($core -notmatch '\w') { return $Token }
    return ($lead + '*' + $core + '*' + $trail)
}

function Test-WordChar([string]$Text, [int]$Index) {
    if ($Index -lt 0 -or $Index -ge $Text.Length) { return $false }
    return ([string]$Text[$Index] -match '\w')
}

# A cue number line ("7") or a timing line ("00:00:01,000 --> 00:00:02,000") is
# .srt structure, not words you'd ever emphasise - never touch those.
function Test-CaptionTextLine([string]$Line) {
    if ($Line -match '-->') { return $false }
    if ($Line -match '^\s*\d+\s*$') { return $false }
    return $true
}

# Toggles *star* emphasis over the selection.
#   $Text       the whole caption document
#   $SelStart   selection start (a caret is length 0 - the word under it is used)
#   $SelLength  selection length
# Returns @{ Text = <new document>; SelStart = <int>; SelLength = <int> } where
# the returned selection covers the same words after the change.
function Invoke-ToggleEmphasis([string]$Text, [int]$SelStart, [int]$SelLength) {
    $unchanged = @{ Text = $Text; SelStart = $SelStart; SelLength = $SelLength }
    if ($null -eq $Text -or $Text.Length -eq 0) { return $unchanged }
    if ($SelStart -lt 0 -or $SelStart -gt $Text.Length) { return $unchanged }
    if ($SelLength -lt 0 -or ($SelStart + $SelLength) -gt $Text.Length) { return $unchanged }

    $start = $SelStart
    $end   = $SelStart + $SelLength

    # Grow out to whole words, so a double-click or a sloppy drag both work.
    # Only grow from an edge that is actually sitting INSIDE a word - otherwise
    # a selection of pure whitespace would swallow its neighbours.
    if ($SelLength -eq 0) {
        while ((Test-WordChar $Text ($start - 1))) { $start-- }
        while ((Test-WordChar $Text $end)) { $end++ }
    } else {
        if ((Test-WordChar $Text $start)) { while ((Test-WordChar $Text ($start - 1))) { $start-- } }
        if ((Test-WordChar $Text ($end - 1))) { while ((Test-WordChar $Text $end)) { $end++ } }
    }
    # Absorb stars already sitting against the word, so re-pressing on the inner
    # word of *hello* takes them off instead of adding a second pair.
    if ($start -gt 0 -and $Text[$start - 1] -eq '*') { $start-- }
    if ($end -lt $Text.Length -and $Text[$end] -eq '*') { $end++ }

    $covered = $Text.Substring($start, $end - $start)
    if ($covered -notmatch '\w') { return $unchanged }

    # Split keeping the line breaks (capturing group) so they survive the rejoin.
    $parts = [regex]::Split($covered, "(`r`n|`n|`r)")

    # Decide once for the whole selection: all marked -> take them off, otherwise
    # mark everything (so a part-marked selection ends up fully marked).
    $anyWord = $false; $allMarked = $true
    for ($i = 0; $i -lt $parts.Count; $i += 2) {
        if (-not (Test-CaptionTextLine $parts[$i])) { continue }
        foreach ($tok in ([regex]::Matches($parts[$i], '\S+'))) {
            if ($tok.Value -notmatch '\w') { continue }
            $anyWord = $true
            if (-not (Test-EmphasisMarked $tok.Value)) { $allMarked = $false }
        }
    }
    if (-not $anyWord) { return $unchanged }

    for ($i = 0; $i -lt $parts.Count; $i += 2) {
        if (-not (Test-CaptionTextLine $parts[$i])) { continue }
        $parts[$i] = [regex]::Replace($parts[$i], '\S+', {
            param($m)
            $t = $m.Value
            if ($t -notmatch '\w') { return $t }
            if ($allMarked) { return (Remove-EmphasisFromToken $t) }
            if (Test-EmphasisMarked $t) { return $t }
            return (Add-EmphasisToToken $t)
        })
    }

    $newCovered = ($parts -join '')
    $newText = $Text.Substring(0, $start) + $newCovered + $Text.Substring($end)
    return @{ Text = $newText; SelStart = $start; SelLength = $newCovered.Length }
}
