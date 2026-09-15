# CaptionColors.ps1 - the palette of emphasis colours you can paint words with.
#
# A caption word is emphasised by wrapping it in a MARKER character, and each
# marker maps to a colour when the captions are burned:
#
#     I eat *protein* and no ~seed oils~
#      ->      teal            red
#
# `*` is the original and always stays first, so every .srt written before this
# existed keeps meaning exactly what it meant. Extra colours claim the next free
# marker from a small pool of characters that essentially never appear in
# speech, so nothing you actually say gets swallowed as markup.
#
# The palette lives in caption-colors.txt next to your videos, one colour per
# line: Name|Marker|#RRGGBB

$script:CaptionColorFile = 'caption-colors.txt'

# Rare-in-speech, and each is a single character so the tokeniser stays simple.
# Six is a lot of colours for a caption; if that pool is ever exhausted the
# honest answer is "you have too many", not a bigger pool.
# PowerShell array-return rules, which this file has to get right in BOTH
# directions:
#   * A function returning a 1-element array UNROLLS it to a bare object, so a
#     one-colour palette would arrive with no .Count and no foreach. Functions
#     that can return 0 or 1 items therefore end with `return ,$arr`.
#   * But `,$arr` emits the array as a SINGLE pipeline object, so such a
#     function must never be piped or wrapped in @() - that just re-nests it.
# This one always returns six, so it returns plainly and is safe to pipe.
function Get-CaptionMarkerPool { return @('*', '~', '^', '=', '+', '|') }

# The one that must never change: existing .srt files are full of *stars*.
function Get-DefaultCaptionColor {
    return [pscustomobject]@{ Name = 'Teal'; Marker = '*'; Hex = '#3D9E8E' }
}

function Get-CaptionColorPath {
    param([Parameter(Mandatory = $true)][string]$Root)
    return (Join-Path $Root $script:CaptionColorFile)
}

function Test-HexColor {
    param([string]$Hex)
    return ($Hex -match '^#[0-9A-Fa-f]{6}$')
}

# ASS wants &H<BB><GG><RR>& - blue first, which is the reverse of hex.
function ConvertTo-AssColor {
    param([Parameter(Mandatory = $true)][string]$Hex)
    if (-not (Test-HexColor $Hex)) { return '&HFFFFFF&' }
    $r = $Hex.Substring(1, 2); $g = $Hex.Substring(3, 2); $b = $Hex.Substring(5, 2)
    return ('&H{0}{1}{2}&' -f $b.ToUpper(), $g.ToUpper(), $r.ToUpper())
}

# PURE: parse the file's text into colours. Bad lines are skipped rather than
# fatal - this is a plain text file a user might well open and edit.
#
# The first colour is ALWAYS the '*' default, whatever the file says, because
# every existing caption depends on that marker meaning something.
function ConvertFrom-CaptionColorText {
    param([AllowEmptyString()][string]$Text)
    # Plain arrays, not a List: `,@($list)` trips PowerShell up, and a palette
    # is six items at most so the copying costs nothing.
    $out = @((Get-DefaultCaptionColor))
    if ([string]::IsNullOrWhiteSpace($Text)) { return ,$out }

    $pool = Get-CaptionMarkerPool
    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
        $parts = $line -split '\|'
        if ($parts.Count -lt 3) { continue }
        $name = $parts[0].Trim()
        $marker = $parts[1].Trim()
        $hex = $parts[2].Trim()
        if (-not $name -or $marker.Length -ne 1 -or -not (Test-HexColor $hex)) { continue }
        if ($pool -notcontains $marker) { continue }
        if ($marker -eq '*') { $out[0] = [pscustomobject]@{ Name = $name; Marker = '*'; Hex = $hex }; continue }
        if ($out | Where-Object { $_.Marker -eq $marker }) { continue }      # first claim wins
        $out += [pscustomobject]@{ Name = $name; Marker = $marker; Hex = $hex }
    }
    return ,$out
}

function ConvertTo-CaptionColorText {
    param([Parameter(Mandatory = $true)][object]$Colors)
    $lines = @('# Emphasis colours for burned captions: Name|Marker|#RRGGBB',
               '# Wrap a word in its marker to paint it, e.g.  *protein*  ~seed oils~')
    foreach ($c in $Colors) { $lines += ('{0}|{1}|{2}' -f $c.Name, $c.Marker, $c.Hex) }
    return (($lines -join "`r`n") + "`r`n")
}

function Get-CaptionColors {
    param([Parameter(Mandatory = $true)][string]$Root)
    $path = Get-CaptionColorPath $Root
    $text = ''
    if (Test-Path -LiteralPath $path) {
        try { $text = [System.IO.File]::ReadAllText($path) } catch { $text = '' }
    }
    # assigned, not wrapped in @(): ConvertFrom already guarantees an array, and
    # @() around it would nest it one deeper
    $colors = ConvertFrom-CaptionColorText $text
    return ,$colors
}

function Save-CaptionColors {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Colors
    )
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Get-CaptionColorPath $Root), (ConvertTo-CaptionColorText $Colors), $enc)
}

# Markers still going spare, in pool order.
function Get-FreeCaptionMarkers {
    param([object]$Colors)
    $used = @()
    if ($Colors) { $used = @($Colors | ForEach-Object { $_.Marker }) }
    return ,@(Get-CaptionMarkerPool | Where-Object { $used -notcontains $_ })
}

# PURE: returns the palette WITH the new colour, or $null when it can't be added
# (no name, bad hex, or every marker already claimed).
function Add-CaptionColorTo {
    param(
        [Parameter(Mandatory = $true)][object]$Colors,
        [string]$Name,
        [string]$Hex
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    if (-not (Test-HexColor $Hex)) { return $null }
    $free = Get-FreeCaptionMarkers $Colors
    if ($free.Count -eq 0) { return $null }
    $next = @($Colors) + @([pscustomobject]@{ Name = $Name.Trim(); Marker = $free[0]; Hex = $Hex.ToUpper() })
    return ,$next
}

# PURE: the palette WITHOUT this marker. '*' can never be removed - captions
# already on disk depend on it.
function Remove-CaptionColorFrom {
    param(
        [Parameter(Mandatory = $true)][object]$Colors,
        [string]$Marker
    )
    if ($Marker -eq '*') { return $null }
    $next = @()
    $found = $false
    foreach ($c in $Colors) {
        if ($c.Marker -eq $Marker) { $found = $true; continue }
        $next += $c
    }
    if (-not $found) { return $null }
    return ,$next
}
