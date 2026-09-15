# CaptionMarkup.ps1
# The pure text transform behind the caption editor's colour buttons.
#
# Burned captions colour a word when it's wrapped in a MARKER character -
# *teal* by default, and one more character per extra colour you add (see
# CaptionColors.ps1). Typing those by hand is tedious, so: select a word (a
# double-click is enough), press the colour, and the markers are applied for
# you. Press the SAME colour again to take them off; press a DIFFERENT colour
# and the word changes colour rather than ending up wrapped twice.
#
# Kept separate from the window so it can be unit-tested.

$script:DefaultMarkers = @('*')

# A regex character class of the markers, and its negation for "punctuation
# that isn't a marker". Built rather than hard-coded so adding a colour needs no
# change here.
function Get-MarkerClass {
    param([string[]]$Markers)
    if (-not $Markers -or $Markers.Count -eq 0) { $Markers = $script:DefaultMarkers }
    return ('[' + (($Markers | ForEach-Object { [regex]::Escape($_) }) -join '') + ']')
}
function Get-NonMarkerClass {
    param([string[]]$Markers)
    if (-not $Markers -or $Markers.Count -eq 0) { $Markers = $script:DefaultMarkers }
    return ('[^\w' + (($Markers | ForEach-Object { [regex]::Escape($_) }) -join '') + ']')
}

# WHICH marker this token carries, or $null. Same rule Caption-Style.ps1 uses
# when it burns: a marker at the OUTER edge of the token, even with punctuation
# attached (*word*!  (*word*)  "*word*"), and something word-like left over.
function Get-TokenMarker {
    param([string]$Token, [string[]]$Markers = $null)
    if ($Token -notmatch '\w') { return $null }
    $cls = Get-MarkerClass $Markers
    $non = Get-NonMarkerClass $Markers
    $c = $Token
    $found = $null

    $ml = [regex]::Match($c, "^($non*)($cls)")
    if ($ml.Success) { $found = $ml.Groups[2].Value; $c = $c.Remove($ml.Groups[1].Length, 1) }
    $mt = [regex]::Match($c, "($cls)($non*)$")
    if ($mt.Success) { if (-not $found) { $found = $mt.Groups[1].Value }; $c = $c.Remove($mt.Index, 1) }
    if (-not ($c -match '\w')) { return $null }        # a stray lone marker
    return $found
}

# Kept for callers that only want a yes/no.
function Test-EmphasisMarked {
    param([string]$Token, [string[]]$Markers = $null)
    return ($null -ne (Get-TokenMarker $Token $Markers))
}

function Remove-EmphasisFromToken {
    param([string]$Token, [string[]]$Markers = $null)
    $cls = Get-MarkerClass $Markers
    $non = Get-NonMarkerClass $Markers
    $c = $Token
    $ml = [regex]::Match($c, "^($non*)($cls)")
    if ($ml.Success) { $c = $c.Remove($ml.Groups[1].Length, 1) }
    $mt = [regex]::Match($c, "($cls)($non*)$")
    if ($mt.Success) { $c = $c.Remove($mt.Index, 1) }
    return $c
}

# Wrap the WORD part only, leaving any attached punctuation outside the markers -
# "now!" becomes "*now*!", "(this)" becomes "(*this*)".
function Add-EmphasisToToken {
    param([string]$Token, [string]$Marker = '*')
    $m = [regex]::Match($Token, '^([^\w]*)(.*?)([^\w]*)$')
    if (-not $m.Success) { return $Token }
    $lead = $m.Groups[1].Value; $core = $m.Groups[2].Value; $trail = $m.Groups[3].Value
    if ($core -notmatch '\w') { return $Token }
    return ($lead + $Marker + $core + $Marker + $trail)
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

# Toggles emphasis over the selection.
#   $Text       the text being edited
#   $SelStart   selection start (a caret is length 0 - the word under it is used)
#   $SelLength  selection length
#   $Marker     the colour's marker to apply
#   $AllMarkers every marker in the palette, so a word already painted another
#               colour is RECOLOURED rather than double-wrapped
#
# Returns @{ Text; SelStart; SelLength } with the selection covering the same
# words after the change.
function Invoke-ToggleEmphasis {
    param(
        [string]$Text,
        [int]$SelStart,
        [int]$SelLength,
        [string]$Marker = '*',
        [string[]]$AllMarkers = $null
    )
    if (-not $AllMarkers -or $AllMarkers.Count -eq 0) { $AllMarkers = @($Marker) }
    if ($AllMarkers -notcontains $Marker) { $AllMarkers = @($AllMarkers) + @($Marker) }

    $unchanged = @{ Text = $Text; SelStart = $SelStart; SelLength = $SelLength }
    if ($null -eq $Text -or $Text.Length -eq 0) { return $unchanged }
    if ($SelStart -lt 0 -or $SelStart -gt $Text.Length) { return $unchanged }
    if ($SelLength -lt 0 -or ($SelStart + $SelLength) -gt $Text.Length) { return $unchanged }

    $start = $SelStart
    $end   = $SelStart + $SelLength

    # Grow out to whole words, so a double-click or a sloppy drag both work.
    # Only grow from an edge actually sitting INSIDE a word - otherwise a
    # selection of pure whitespace would swallow its neighbours.
    if ($SelLength -eq 0) {
        while ((Test-WordChar $Text ($start - 1))) { $start-- }
        while ((Test-WordChar $Text $end)) { $end++ }
    } else {
        if ((Test-WordChar $Text $start)) { while ((Test-WordChar $Text ($start - 1))) { $start-- } }
        if ((Test-WordChar $Text ($end - 1))) { while ((Test-WordChar $Text $end)) { $end++ } }
    }
    # Absorb markers already sitting against the word, so re-pressing on the
    # inner word of *hello* takes them off instead of adding a second pair.
    if ($start -gt 0 -and $AllMarkers -contains ([string]$Text[$start - 1])) { $start-- }
    if ($end -lt $Text.Length -and $AllMarkers -contains ([string]$Text[$end])) { $end++ }

    $covered = $Text.Substring($start, $end - $start)
    if ($covered -notmatch '\w') { return $unchanged }

    # Split keeping the line breaks (capturing group) so they survive the rejoin.
    $parts = [regex]::Split($covered, "(`r`n|`n|`r)")

    # Decide once for the whole selection: already all THIS colour -> take it
    # off; anything else -> make it all this colour. That is what makes pressing
    # red on a teal word recolour it, and pressing red twice clear it.
    $anyWord = $false; $allThisColor = $true
    for ($i = 0; $i -lt $parts.Count; $i += 2) {
        if (-not (Test-CaptionTextLine $parts[$i])) { continue }
        foreach ($tok in ([regex]::Matches($parts[$i], '\S+'))) {
            if ($tok.Value -notmatch '\w') { continue }
            $anyWord = $true
            if ((Get-TokenMarker $tok.Value $AllMarkers) -ne $Marker) { $allThisColor = $false }
        }
    }
    if (-not $anyWord) { return $unchanged }

    for ($i = 0; $i -lt $parts.Count; $i += 2) {
        if (-not (Test-CaptionTextLine $parts[$i])) { continue }
        $parts[$i] = [regex]::Replace($parts[$i], '\S+', {
            param($m)
            $t = $m.Value
            if ($t -notmatch '\w') { return $t }
            $bare = Remove-EmphasisFromToken $t $AllMarkers
            if ($allThisColor) { return $bare }
            return (Add-EmphasisToToken $bare $Marker)
        })
    }

    $newCovered = ($parts -join '')
    $newText = $Text.Substring(0, $start) + $newCovered + $Text.Substring($end)
    return @{ Text = $newText; SelStart = $start; SelLength = $newCovered.Length }
}
