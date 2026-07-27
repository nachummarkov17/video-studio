# Srt-Chunk.ps1
# Shared helper used by the caption + burn scripts.
#
# Re-wraps an .srt so each on-screen caption is SHORT and readable:
#   * starts a new caption at every comma / period (and ? ! : ;)
#   * if a run has MORE than -MaxWords words with no such break, it cuts in the
#     middle so no caption ever shows more than MaxWords words
#   * tiny leftover pieces (1-2 words) are pulled back onto the previous caption
#     when they still fit, so you don't get one-word flashes
#
# The new timings are spread across the original cue in proportion to text
# length - approximate, but reads naturally. It's non-destructive and
# idempotent: re-chunking an already-short .srt changes nothing.

function ConvertTo-SrtSeconds([string]$ts) {
    # accepts HH:MM:SS,mmm  or  HH:MM:SS.mmm
    if ($ts -match '(\d+):(\d{2}):(\d{2})[,.](\d{1,3})') {
        return ([int]$Matches[1])*3600 + ([int]$Matches[2])*60 + [int]$Matches[3] + ([int]($Matches[4].PadRight(3,'0')))/1000.0
    }
    return 0.0
}

function ConvertFrom-SrtSeconds([double]$sec) {
    if ($sec -lt 0) { $sec = 0 }
    $ms = [int][math]::Round($sec * 1000)
    $h  = [math]::Floor($ms/3600000); $ms -= $h*3600000
    $m  = [math]::Floor($ms/60000);   $ms -= $m*60000
    $s  = [math]::Floor($ms/1000);    $ms -= $s*1000
    return ('{0:00}:{1:00}:{2:00},{3:000}' -f [int]$h,[int]$m,[int]$s,[int]$ms)
}

function Get-CaptionMaxDuration([int]$wordCount, [double]$tail) {
    # How long a caption of N words is allowed to stay on screen. This is a
    # SAFETY CAP that trims trailing silence: a caption should never outstay the
    # time it takes to say its words plus a short readable tail. Used so a
    # silent/breathing stretch doesn't leave the last caption frozen on screen.
    return [math]::Max(1.2, $wordCount * 0.5) + $tail
}

# Sentence vs clause punctuation. A caption may NEVER span a sentence ender, so
# two different sentences can't share one caption; clause enders are softer.
$script:SentEnders = @('.', '!', '?')
$script:ClauseOnly = @(',', ';', ':')

function Get-WordLastChar([string]$w) {
    # last meaningful char of a token, ignoring a trailing quote/bracket
    $t = $w -replace '["'')\]”’]+$',''
    if ($t.Length -eq 0) { return '' }
    return [string]$t[$t.Length-1]
}

function Convert-WhisperJsonToWordSrt {
    # Turns whisper.cpp FULL json (-ojf) into a WORD-level .srt whose end times are
    # the TRUE end of each word (when the sound stops), not the next word's onset.
    # The plain -ml 1 -sow SRT stretches each word's end to the next word's start,
    # so a word before a pause holds the screen through the whole pause; the token
    # offsets in the full json keep the real end, which is what keeps captions tight.
    param(
        [Parameter(Mandatory=$true)][string]$InPath,
        [Parameter(Mandatory=$true)][string]$OutPath
    )
    $j = (Get-Content -LiteralPath $InPath -Raw -Encoding UTF8) | ConvertFrom-Json
    $words = New-Object System.Collections.Generic.List[object]
    foreach ($seg in $j.transcription) {
        if (-not $seg.tokens) { continue }
        foreach ($tok in $seg.tokens) {
            $txt = [string]$tok.text
            if ($null -eq $txt) { continue }
            if ($txt -match '^\s*\[_') { continue }        # special tokens e.g. [_BEG_]
            $stripped = $txt.Trim()
            if ($stripped -eq '') { continue }
            $from = ([double]$tok.offsets.from) / 1000.0
            $to   = ([double]$tok.offsets.to)   / 1000.0
            $hasAlnum  = ($stripped -match '[\p{L}\p{Nd}]')
            $startsWord = $txt.StartsWith(' ') -and $hasAlnum
            if (-not $hasAlnum -and $words.Count -gt 0) {
                # punctuation ("." "," "?"): glue to the previous word's TEXT but
                # keep that word's real end time (the punctuation token's span is
                # the following silence, which we don't want to hold on screen).
                $words[$words.Count-1].Word += $stripped
                continue
            }
            if ($startsWord -or $words.Count -eq 0) {
                $words.Add([pscustomobject]@{ Word = $stripped; Start = $from; End = $to })
            } else {
                # sub-word continuation (e.g. "'t", "-ping"): extend the same word
                $words[$words.Count-1].Word += $stripped
                $words[$words.Count-1].End   = $to
            }
        }
    }
    $out = New-Object System.Collections.Generic.List[string]
    $idx = 0
    foreach ($w in $words) {
        if ($w.End -le $w.Start) { $w.End = $w.Start + 0.02 }
        $idx++
        $out.Add([string]$idx)
        $out.Add((ConvertFrom-SrtSeconds $w.Start) + ' --> ' + (ConvertFrom-SrtSeconds $w.End))
        $out.Add([string]$w.Word)
        $out.Add('')
    }
    $outText = ($out -join "`r`n").TrimEnd() + "`r`n"
    [System.IO.File]::WriteAllText($OutPath, $outText, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-TargetFps([string]$VideoPath) {
    # Pick a CONSTANT output frame rate = the source's AVERAGE rate (its true
    # cadence) rounded to a standard. Phone clips are VFR with a high NOMINAL rate
    # (e.g. 60) but ~30 real fps; encoding at a constant average rate keeps motion
    # natural AND stops players/Instagram/YouTube from drifting video behind audio
    # (which makes burned captions look late).
    $fps = 30.0
    $afr = (& ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=nw=1:nk=1 -- $VideoPath 2>$null) | Select-Object -First 1
    if ($afr -match '^\s*(\d+)\s*/\s*(\d+)\s*$') { if ([double]$Matches[2] -ne 0) { $fps = [double]$Matches[1] / [double]$Matches[2] } }
    elseif ($afr -match '^\s*([\d.]+)\s*$') { $fps = [double]$Matches[1] }
    if ($fps -lt 1 -or [double]::IsNaN($fps)) { $fps = 30.0 }
    if     ($fps -gt 45) { return 60 }
    elseif ($fps -ge 26) { return 30 }
    elseif ($fps -ge 23) { return 24 }
    else { return [int][math]::Max(1, [math]::Round($fps)) }
}

function Get-SilenceIntervals {
    # Runs ffmpeg silencedetect on a wav and returns the silence spans as objects
    # {Start; End} in seconds. Speech happens BETWEEN these: a silence End is a
    # speech ONSET, a silence Start is a speech OFFSET. Used to snap caption edges
    # to real speech boundaries (like YouTube) instead of whisper's soft guesses.
    param(
        [Parameter(Mandatory=$true)][string]$WavPath,
        [double]$NoiseDb = 40.0,   # quieter than this counts as silence (-40 dB avoids clipping soft word-tails)
        [double]$MinSil  = 0.18    # ignore silences shorter than this (keeps mid-phrase micro-gaps out)
    )
    $list = New-Object System.Collections.Generic.List[object]
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { return ,$list.ToArray() }
    if (-not (Test-Path $WavPath)) { return ,$list.ToArray() }
    $af = "silencedetect=noise=-${NoiseDb}dB:d=$MinSil"
    $raw = (& ffmpeg -hide_banner -nostats -i $WavPath -af $af -f null - 2>&1 | Out-String)
    $curStart = $null
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match 'silence_start:\s*(-?[0-9.]+)') {
            $curStart = [double]$Matches[1]; if ($curStart -lt 0) { $curStart = 0.0 }
        } elseif ($line -match 'silence_end:\s*(-?[0-9.]+)') {
            $e = [double]$Matches[1]
            $s = if ($null -ne $curStart) { $curStart } else { 0.0 }
            if ($e -gt $s) { $list.Add([pscustomobject]@{ Start = $s; End = $e }) }
            $curStart = $null
        }
    }
    return ,$list.ToArray()
}

function Split-SrtFile {
    param(
        [Parameter(Mandatory=$true)][string]$InPath,
        [Parameter(Mandatory=$true)][string]$OutPath,
        [int]$MaxWords   = 5,     # never show more than this many words at once
        [int]$MergeUnder = 3,     # pull a trailing piece with fewer than this many words back onto the previous caption when it still fits (same sentence only)
        [double]$MaxHold = 1.4    # extra seconds a caption may linger past its spoken length (safety net that trims silence held by an old .srt)
    )
    $raw = Get-Content -LiteralPath $InPath -Raw -Encoding UTF8
    if (-not $raw) { return }
    $raw = ($raw -replace "`r`n","`n") -replace "`r","`n"
    $blocks = [regex]::Split($raw.Trim(), "`n[ \t]*`n+")

    $out = New-Object System.Collections.Generic.List[string]
    $idx = 0
    $SoftMin = 3   # don't break at a comma until the caption has at least this many words

    foreach ($b in $blocks) {
        $lines = $b -split "`n"
        $tsIdx = -1
        for ($i=0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '(\d+:\d{2}:\d{2}[,.]\d{1,3})\s*-->\s*(\d+:\d{2}:\d{2}[,.]\d{1,3})') { $tsIdx = $i; break }
        }
        if ($tsIdx -lt 0) { continue }
        $sTs = $Matches[1]; $eTs = $Matches[2]
        $start = ConvertTo-SrtSeconds $sTs
        $end   = ConvertTo-SrtSeconds $eTs

        $textLines = @()
        if (($tsIdx + 1) -le ($lines.Count - 1)) { $textLines = $lines[($tsIdx+1)..($lines.Count-1)] }
        $cueText = (($textLines -join ' ') -replace '\s+',' ').Trim()
        if (-not $cueText) { continue }

        # --- break into chunks: short cues pass through untouched (this keeps the
        #     word-accurate timing from Group-WordSrtFile); only genuinely long
        #     lines are re-split, one sentence max, <= MaxWords per chunk ---
        $words  = $cueText -split '\s+'
        $chunks = New-Object System.Collections.Generic.List[string]
        if ($words.Count -le $MaxWords) {
            $chunks.Add(($words -join ' '))
        } else {
            $cur = New-Object System.Collections.Generic.List[string]
            foreach ($w in $words) {
                $cur.Add($w)
                $lc = Get-WordLastChar $w
                if ($script:SentEnders -contains $lc) {
                    $chunks.Add(($cur -join ' ')); $cur = New-Object System.Collections.Generic.List[string]
                } elseif ($cur.Count -ge $MaxWords) {
                    $chunks.Add(($cur -join ' ')); $cur = New-Object System.Collections.Generic.List[string]
                } elseif (($script:ClauseOnly -contains $lc) -and $cur.Count -ge $SoftMin) {
                    $chunks.Add(($cur -join ' ')); $cur = New-Object System.Collections.Generic.List[string]
                }
            }
            if ($cur.Count -gt 0) { $chunks.Add(($cur -join ' ')) }

            # --- merge a tiny trailing piece back onto the previous caption, but
            #     ONLY within the same sentence (never if the previous chunk ends
            #     a sentence - that would put two sentences in one caption) ---
            if ($MergeUnder -gt 0 -and $chunks.Count -gt 1) {
                $merged = New-Object System.Collections.Generic.List[string]
                foreach ($c in $chunks) {
                    $wc = ($c -split '\s+').Count
                    if ($merged.Count -gt 0) {
                        $prev   = $merged[$merged.Count-1]
                        $prevWc = ($prev -split '\s+').Count
                        $prevLast = Get-WordLastChar (($prev -split '\s+')[-1])
                        $prevEndsSentence = ($script:SentEnders -contains $prevLast)
                        if ($wc -lt $MergeUnder -and ($prevWc + $wc) -le $MaxWords -and -not $prevEndsSentence) {
                            $merged[$merged.Count-1] = "$prev $c"
                            continue
                        }
                    }
                    $merged.Add($c)
                }
                $chunks = $merged
            }
        }

        # --- spread the cue's time across the chunks by text length ---
        $totalLen = 0
        foreach ($c in $chunks) { $totalLen += [math]::Max(1, $c.Length) }
        $dur = $end - $start
        if ($dur -lt 0) { $dur = 0 }
        $t = $start
        for ($k=0; $k -lt $chunks.Count; $k++) {
            $c = $chunks[$k]
            if ($k -eq ($chunks.Count - 1)) {
                $cEnd = $end
            } else {
                $cEnd = $t + $dur * ([math]::Max(1,$c.Length) / $totalLen)
            }
            # trim trailing silence: don't let this caption sit on screen longer
            # than its words justify (protects against an old .srt whose last cue
            # was stretched over a quiet stretch)
            $capDur = Get-CaptionMaxDuration ($c -split '\s+').Count $MaxHold
            if (($cEnd - $t) -gt $capDur) { $cEnd = $t + $capDur }
            if ($cEnd -le $t) { $cEnd = $t + 0.001 }
            $idx++
            $out.Add([string]$idx)
            $out.Add((ConvertFrom-SrtSeconds $t) + ' --> ' + (ConvertFrom-SrtSeconds $cEnd))
            $out.Add($c)
            $out.Add('')
            $t = $cEnd
        }
    }

    $outText = ($out -join "`r`n").TrimEnd() + "`r`n"
    [System.IO.File]::WriteAllText($OutPath, $outText, (New-Object System.Text.UTF8Encoding($false)))
}

function Group-WordSrtFile {
    # Takes a WORD-LEVEL .srt (whisper -ml 1 -sow: one word per cue, each with a
    # real start/end time) and groups the words into short, readable captions
    # using their ACTUAL timings - so sync stays tight no matter your pacing.
    # Same break rules as Split-SrtFile (comma/period, cap at MaxWords), but each
    # caption's start = its first word's start and end = its last word's end.
    param(
        [Parameter(Mandatory=$true)][string]$InPath,
        [Parameter(Mandatory=$true)][string]$OutPath,
        [int]$MaxWords      = 5,
        [int]$MergeUnder    = 3,
        [double]$MaxGap     = 1.3,   # a silent gap longer than this between two words starts a NEW caption (so a long/breathing pause shows no caption); short thinking-pauses keep the caption together
        [double]$MaxWordHold = 1.4,  # a caption's last word may stay at most this long after it starts - trims silence whisper stretched onto it
        [object[]]$Silences = @()    # optional ffmpeg silencedetect spans ({Start;End}); when given, caption edges snap to real speech boundaries
    )
    $raw = Get-Content -LiteralPath $InPath -Raw -Encoding UTF8
    if (-not $raw) { return }
    $raw = ($raw -replace "`r`n","`n") -replace "`r","`n"
    $blocks = [regex]::Split($raw.Trim(), "`n[ \t]*`n+")

    $SoftMin = 3   # don't break at a comma until the caption has at least this many words

    # 1) parse word cues -> list of {Start,End,Word}
    $words = New-Object System.Collections.Generic.List[object]
    foreach ($b in $blocks) {
        $lines = $b -split "`n"
        $tsIdx = -1
        for ($i=0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '(\d+:\d{2}:\d{2}[,.]\d{1,3})\s*-->\s*(\d+:\d{2}:\d{2}[,.]\d{1,3})') { $tsIdx = $i; break }
        }
        if ($tsIdx -lt 0) { continue }
        $sTs = $Matches[1]; $eTs = $Matches[2]
        $textLines = @()
        if (($tsIdx + 1) -le ($lines.Count - 1)) { $textLines = $lines[($tsIdx+1)..($lines.Count-1)] }
        $wtext = (($textLines -join ' ') -replace '\s+',' ').Trim()
        if (-not $wtext) { continue }
        $words.Add([pscustomobject]@{
            Start = (ConvertTo-SrtSeconds $sTs)
            End   = (ConvertTo-SrtSeconds $eTs)
            Word  = $wtext
        })
    }
    if ($words.Count -eq 0) { return }

    # 2) group words into captions. Rules, in order:
    #      * a long silence (> MaxGap) closes the caption, so a breathing/demo
    #        pause shows NO caption; short thinking-pauses keep it together.
    #      * a sentence ender (. ! ?) always closes the caption -> one sentence
    #        max per caption, so the next sentence never bleeds in.
    #      * MaxWords caps the length.
    #      * a comma only breaks once the caption already has SoftMin words
    #        (avoids a lone leading word flashing on its own).
    $groups = New-Object System.Collections.Generic.List[object]
    $cur = New-Object System.Collections.Generic.List[object]
    $prevEnd = $null
    foreach ($wd in $words) {
        if ($cur.Count -gt 0 -and $null -ne $prevEnd -and ($wd.Start - $prevEnd) -gt $MaxGap) {
            $groups.Add($cur)
            $cur = New-Object System.Collections.Generic.List[object]
        }
        $cur.Add($wd)
        $prevEnd = $wd.End
        $lc = Get-WordLastChar $wd.Word
        if ($script:SentEnders -contains $lc) {
            $groups.Add($cur); $cur = New-Object System.Collections.Generic.List[object]
        } elseif ($cur.Count -ge $MaxWords) {
            $groups.Add($cur); $cur = New-Object System.Collections.Generic.List[object]
        } elseif (($script:ClauseOnly -contains $lc) -and $cur.Count -ge $SoftMin) {
            $groups.Add($cur); $cur = New-Object System.Collections.Generic.List[object]
        }
    }
    if ($cur.Count -gt 0) { $groups.Add($cur) }

    # 3) fix a 1-word trailing caption by pulling a word back from the previous
    #    one - but ONLY within the same sentence (never across a sentence ender,
    #    so a real short sentence like "Okay." keeps its own caption).
    for ($i=1; $i -lt $groups.Count; $i++) {
        $g = $groups[$i]
        if ($g.Count -ne 1) { continue }
        $p = $groups[$i-1]
        if ($p.Count -lt 2) { continue }
        $pLast = Get-WordLastChar $p[$p.Count-1].Word
        if ($script:SentEnders -contains $pLast) { continue }
        $moved = $p[$p.Count-1]
        $p.RemoveAt($p.Count-1)
        $g.Insert(0, $moved)
    }

    # 4) Work out each caption's on-screen window. Base times come from the words'
    #    real timings (accurate when fed from the json token offsets). When silence
    #    spans are supplied, snap the edges to true speech boundaries:
    #      START - if whisper anchored the first word inside/just before detected
    #              silence, move it to the speech ONSET (silence end), so the caption
    #              appears exactly as you start talking, never during silence.
    #      END   - only pull the last word's end back to a pause if whisper stretched
    #              it PAST the whole silence gap (a clear over-run). A quiet word-tail
    #              stays inside its silence span and is left alone, so words are
    #              never cut short.
    $EndPad = 0.10
    $SnapGrace    = 0.30
    $SnapGraceEnd = 0.35
    $useSil = ($Silences -and $Silences.Count -gt 0)

    $spans = New-Object System.Collections.Generic.List[object]
    foreach ($g in $groups) {
        if ($g.Count -eq 0) { continue }
        $ws  = $g[0].Start
        $we  = $g[$g.Count-1].End
        $wls = $g[$g.Count-1].Start
        if ($useSil) {
            # START -> speech onset
            $inSil = $null
            foreach ($s in $Silences) { if ($ws -ge $s.Start -and $ws -le $s.End) { $inSil = $s; break } }
            if ($null -ne $inSil) {
                $ws = $inSil.End
            } else {
                $bestE = $null; $bestD = $SnapGrace
                foreach ($s in $Silences) { $d = [math]::Abs($ws - $s.End); if ($d -le $bestD) { $bestD = $d; $bestE = $s.End } }
                if ($null -ne $bestE) { $ws = $bestE }
            }
            # END -> pull back only on a clear stretch past a real pause
            $bestS = $null; $bestD2 = $SnapGraceEnd
            foreach ($s in $Silences) {
                if ($we -gt $s.End -and ($we - $s.End) -le $SnapGraceEnd -and $s.Start -ge $wls) {
                    $d = $we - $s.End
                    if ($d -le $bestD2) { $bestD2 = $d; $bestS = $s.Start }
                }
            }
            if ($null -ne $bestS) { $we = $bestS }
        }
        $textParts = @(); foreach ($x in $g) { $textParts += $x.Word }
        $spans.Add([pscustomobject]@{ Start = $ws; End = $we; WLS = $wls; Text = ($textParts -join ' ') })
    }

    # emit: tiny readable tail, capped by MaxWordHold and by the next caption's
    # start so one caption is always gone before the next appears.
    $out = New-Object System.Collections.Generic.List[string]
    $idx = 0
    for ($k=0; $k -lt $spans.Count; $k++) {
        $start = $spans[$k].Start
        if ($start -lt 0) { $start = 0 }
        $end = $spans[$k].End + $EndPad
        $cap = $spans[$k].WLS + $MaxWordHold
        if ($end -gt $cap) { $end = $cap }
        if ($k -lt ($spans.Count - 1)) {
            $nextStart = $spans[$k+1].Start
            if ($end -gt $nextStart) { $end = $nextStart }
        }
        if ($end -le $start) { $end = $start + 0.3 }
        $idx++
        $out.Add([string]$idx)
        $out.Add((ConvertFrom-SrtSeconds $start) + ' --> ' + (ConvertFrom-SrtSeconds $end))
        $out.Add($spans[$k].Text)
        $out.Add('')
    }

    $outText = ($out -join "`r`n").TrimEnd() + "`r`n"
    [System.IO.File]::WriteAllText($OutPath, $outText, (New-Object System.Text.UTF8Encoding($false)))
}
