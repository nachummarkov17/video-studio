# Caption-Style.ps1
# Turns a plain .srt into a styled .ass subtitle so burned captions can have
# COLORED / EMPHASIZED words (the modern Reels/TikTok look) instead of flat text.
#
# Styles:
#   plain      - white text (same as before)
#   highlight  - key word(s) in each caption pop in an accent colour + slightly
#                bigger. Auto-picks the strongest word; you can also force any
#                word by wrapping it in *asterisks* when you edit the .srt.
#   karaoke    - the word being spoken pops in the accent colour, moving word to
#                word across the caption (approximate timing within each caption).
#
# The base look (font, size, outline, position) is passed in so it matches the
# rest of Burn-Captions. PlayRes is 384x288 to match how the .srt was styled
# before (libass scales it to the real video size), so nothing else shifts.

function Get-AssColor([string]$name) {
    # ASS colour is &H<BB><GG><RR>&  (blue-green-red)
    switch ($name.ToLower()) {
        'teal'   { '&H8E9E3D&' }   # brand teal #3d9e8e
        'yellow' { '&H00FFFF&' }
        'gold'   { '&H00D7FF&' }
        'green'  { '&H00FF00&' }
        'lime'   { '&H00FF7F&' }
        'cyan'   { '&HFFFF00&' }
        'orange' { '&H00A5FF&' }
        'pink'   { '&HFF00FF&' }
        'red'    { '&H0000FF&' }
        'white'  { '&HFFFFFF&' }
        default  { '&H8E9E3D&' }   # teal
    }
}

function ConvertTo-AssTime([double]$sec) {
    if ($sec -lt 0) { $sec = 0 }
    $cs = [int][math]::Round($sec * 100)
    $h  = [math]::Floor($cs/360000); $cs -= $h*360000
    $m  = [math]::Floor($cs/6000);   $cs -= $m*6000
    $s  = [math]::Floor($cs/100);    $cs -= $s*100
    return ('{0}:{1:00}:{2:00}.{3:00}' -f [int]$h,[int]$m,[int]$s,[int]$cs)
}

function Get-EmphasisIndices($words) {
    # Emphasise ONLY words the user marked with *stars* in the .srt. Nothing is
    # auto-highlighted - a caption with no *marked* words stays plain white.
    $marked = New-Object System.Collections.Generic.List[int]
    for ($i=0; $i -lt $words.Count; $i++) {
        if ($words[$i].Marked) { $marked.Add($i) }
    }
    return $marked
}

function Format-AssLine($words, $emphIdx, [string]$accent, [bool]$pop) {
    # builds the caption text with the given word indices coloured
    $reset = '{\1c&HFFFFFF&' + $(if ($pop) { '\fscx100\fscy100' } else { '' }) + '}'
    $on    = '{\1c' + $accent + $(if ($pop) { '\fscx115\fscy115' } else { '' }) + '}'
    $parts = @()
    for ($i=0; $i -lt $words.Count; $i++) {
        $t = $words[$i].Clean
        if ($emphIdx -contains $i) { $parts += ($on + $t + $reset) } else { $parts += $t }
    }
    return ($parts -join ' ')
}

function Convert-SrtToAss {
    param(
        [Parameter(Mandatory=$true)][string]$InPath,
        [Parameter(Mandatory=$true)][string]$OutPath,
        [int]$FontSize = 12, [string]$FontName = "Arial",
        [int]$Outline = 2, [int]$Shadow = 1, [int]$MarginV = 70, [int]$Alignment = 2,
        [string]$Style = "highlight",
        [string]$HighlightColor = "teal",
        [int]$VideoW = 0, [int]$VideoH = 0    # so PlayRes matches the frame's aspect (no distortion)
    )
    $accent = Get-AssColor $HighlightColor
    $raw = Get-Content -LiteralPath $InPath -Raw -Encoding UTF8
    if (-not $raw) { return }
    $raw = ($raw -replace "`r`n","`n") -replace "`r","`n"
    $blocks = [regex]::Split($raw.Trim(), "`n[ \t]*`n+")

    $ev = New-Object System.Collections.Generic.List[string]
    foreach ($b in $blocks) {
        $lines = $b -split "`n"
        $tsIdx = -1
        for ($i=0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '(\d+):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d+):(\d{2}):(\d{2})[,.](\d{1,3})') { $tsIdx = $i; break }
        }
        if ($tsIdx -lt 0) { continue }
        $start = [int]$Matches[1]*3600 + [int]$Matches[2]*60 + [int]$Matches[3] + [int]($Matches[4].PadRight(3,'0'))/1000.0
        $end   = [int]$Matches[5]*3600 + [int]$Matches[6]*60 + [int]$Matches[7] + [int]($Matches[8].PadRight(3,'0'))/1000.0

        $textLines = @()
        if (($tsIdx + 1) -le ($lines.Count - 1)) { $textLines = $lines[($tsIdx+1)..($lines.Count-1)] }
        $text = (($textLines -join ' ') -replace '\s+',' ').Trim()
        $text = $text -replace '[{}]',''          # strip ASS override braces if any
        if (-not $text) { continue }

        # tokenise, capturing *marked* words then stripping the asterisks
        $raws = $text -split '\s+'
        $words = New-Object System.Collections.Generic.List[object]
        foreach ($rw in $raws) {
            $marked = $false
            $c = $rw
            # Strip a marking * at the outer edge of the word even when punctuation
            # is attached to it (e.g. *everything*!  (*word*)  phrase*.  "*word*").
            # Leading: optional opening punctuation, then a *  ->  drop that *
            $ml = [regex]::Match($c, '^([^\w*]*)\*')
            if ($ml.Success) { $marked = $true; $c = $c.Remove($ml.Groups[1].Length, 1) }
            # Trailing: a *, then optional closing punctuation at the end  ->  drop that *
            $mt = [regex]::Match($c, '\*([^\w*]*)$')
            if ($mt.Success) { $marked = $true; $c = $c.Remove($mt.Index, 1) }
            if ($marked -and $c -notmatch '\w') { $marked = $false; $c = $rw }  # was a stray lone *
            $words.Add([pscustomobject]@{ Clean = $c; Marked = $marked })
        }
        if ($words.Count -eq 0) { continue }

        $sAss = ConvertTo-AssTime $start
        $eAss = ConvertTo-AssTime $end

        if ($Style -eq 'karaoke') {
            # one event per word: the active word pops, timed proportionally
            $dur = $end - $start
            if ($dur -lt 0) { $dur = 0 }
            $totLen = 0
            foreach ($wd in $words) { $totLen += [math]::Max(1, $wd.Clean.Length) }
            $t = $start
            for ($k=0; $k -lt $words.Count; $k++) {
                if ($k -eq $words.Count-1) { $wEnd = $end } else { $wEnd = $t + $dur * ([math]::Max(1,$words[$k].Clean.Length)/$totLen) }
                if ($wEnd -le $t) { $wEnd = $t + 0.05 }
                $line = Format-AssLine $words @($k) $accent $true
                $ev.Add(('Dialogue: 0,{0},{1},Def,,0,0,0,{2}' -f (ConvertTo-AssTime $t), (ConvertTo-AssTime $wEnd), $line))
                $t = $wEnd
            }
        }
        elseif ($Style -eq 'highlight') {
            $emph = Get-EmphasisIndices $words
            $line = Format-AssLine $words $emph $accent $true
            $ev.Add(('Dialogue: 0,{0},{1},Def,,0,0,0,{2}' -f $sAss, $eAss, $line))
        }
        else {
            $line = Format-AssLine $words @() $accent $false
            $ev.Add(('Dialogue: 0,{0},{1},Def,,0,0,0,{2}' -f $sAss, $eAss, $line))
        }
    }

    # Keep PlayResY at 288 (so the passed-in FontSize/MarginV keep their tuned
    # meaning) but set PlayResX to match the video's aspect ratio - otherwise
    # libass stretches the text and leaves a doubled "ghost".
    $playResY = 288
    $playResX = 384
    if ($VideoW -gt 0 -and $VideoH -gt 0) { $playResX = [int][math]::Round($playResY * $VideoW / $VideoH) }

    $header = @(
        '[Script Info]'
        'ScriptType: v4.00+'
        "PlayResX: $playResX"
        "PlayResY: $playResY"
        'ScaledBorderAndShadow: yes'
        ''
        '[V4+ Styles]'
        'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding'
        ("Style: Def,{0},{1},&H00FFFFFF,&H000000FF,&H00000000,&H00000000,1,0,0,0,100,100,0,0,1,{2},{3},{4},20,20,{5},1" -f $FontName,$FontSize,$Outline,$Shadow,$Alignment,$MarginV)
        ''
        '[Events]'
        'Format: Layer, Start, End, Style, Name, MarginL, MarginR, Effect, Text'
    )
    $all = ($header + $ev) -join "`r`n"
    [System.IO.File]::WriteAllText($OutPath, $all + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}
