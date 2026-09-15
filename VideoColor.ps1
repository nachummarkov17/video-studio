# VideoColor.ps1 - keeping a clip looking like itself.
#
# THE BUG THIS EXISTS TO FIX. Phone footage is often HDR: the user's clips are
# tagged bt2020 primaries, bt2020nc matrix and the arib-std-b67 (HLG) transfer.
# Those four tags are not decoration - they tell the player how to turn the
# stored numbers into light. Every re-encode in this app used to drop them,
# because ffmpeg only carries them over if you ASK.
#
# The pixels came out byte-for-byte the same (measured), but with the tags gone
# a player falls back to plain BT.709 gamma, and HLG shown as BT.709 looks
# exactly like the complaint: "so much brighter, really washed out". Nothing was
# filtering the picture; the file had simply stopped saying what it was.
#
# So: read what the source says, and say the same thing on the way out. We never
# CONVERT anything here - converting is what would change the picture.

# What this file claims to be. Missing/unknown entries come back as $null, which
# is the honest answer for a file that never said.
function Get-VideoColorTags {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tags = [ordered]@{ Range = $null; Space = $null; Primaries = $null; Transfer = $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $tags }

    $lines = @()
    try {
        $lines = @(& ffprobe -v error -select_streams v:0 `
            -show_entries stream=color_range,color_space,color_primaries,color_transfer `
            -of default=nw=1 -- $Path 2>$null)
    } catch { return $tags }

    $useful = { param($v) $v -and $v -ne 'unknown' -and $v -ne 'reserved' -and $v -ne 'N/A' }
    foreach ($line in $lines) {
        $parts = [string]$line -split '=', 2
        if ($parts.Count -ne 2) { continue }
        $value = $parts[1].Trim()
        if (-not (& $useful $value)) { continue }
        switch ($parts[0].Trim()) {
            'color_range'     { $tags.Range = $value }
            'color_space'     { $tags.Space = $value }
            'color_primaries' { $tags.Primaries = $value }
            'color_transfer'  { $tags.Transfer = $value }
        }
    }
    return $tags
}

# The ffmpeg OUTPUT flags that stamp those tags back onto the encode. Anything
# the source didn't say, we don't say either - inventing a tag is as wrong as
# dropping one.
function Get-ColorOutputArgs {
    param([object]$Tags)
    $out = @()
    if (-not $Tags) { return $out }
    if ($Tags.Space)     { $out += '-colorspace', $Tags.Space }
    if ($Tags.Primaries) { $out += '-color_primaries', $Tags.Primaries }
    if ($Tags.Transfer)  { $out += '-color_trc', $Tags.Transfer }
    if ($Tags.Range)     { $out += '-color_range', $Tags.Range }
    return $out
}

# The `setparams` filter that stamps these tags onto the frames themselves.
#
# Needed because a filtergraph carries `range` and `colorspace` through but
# DROPS primaries and transfer, and ffmpeg then takes the encoder's colour from
# the filter output - so the -color_* flags alone are silently ignored behind
# any -vf / -filter_complex. Returns '' when there is nothing to say, so the
# graph is left exactly as it was for untagged clips.
function Get-SetParamsFilter {
    param([object]$Tags)
    if (-not $Tags) { return '' }
    $parts = @()
    if ($Tags.Range)     { $parts += "range=$($Tags.Range)" }
    if ($Tags.Space)     { $parts += "colorspace=$($Tags.Space)" }
    if ($Tags.Primaries) { $parts += "color_primaries=$($Tags.Primaries)" }
    if ($Tags.Transfer)  { $parts += "color_trc=$($Tags.Transfer)" }
    if ($parts.Count -eq 0) { return '' }
    return ('setparams=' + ($parts -join ':'))
}

# Convenience: source path in, flags out.
function Get-ColorArgsForSource {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-ColorOutputArgs (Get-VideoColorTags $Path))
}

# True when this clip carries an HDR transfer. Worth knowing because an HDR
# clip that loses its tags is the washed-out case, so it's the one to shout
# about if a re-encode ever drops them again.
function Test-HdrTags {
    param([object]$Tags)
    if (-not $Tags -or -not $Tags.Transfer) { return $false }
    return @('arib-std-b67', 'smpte2084') -contains $Tags.Transfer
}
