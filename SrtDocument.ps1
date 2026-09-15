# SrtDocument.ps1 - captions as DATA, not as lines of a text box.
#
# The caption editor used to hold the raw .srt in one big TextBox and work out,
# on every timer tick, which LINE of that text was being spoken - then highlight
# it by making it the box's SELECTION. That is where the jank came from: the
# selection fights the caret, an edit shifts every line index under it, and the
# box scrolls itself whenever the selection moves. None of that can happen once
# a cue is an object with a start, an end and some text.
#
# This file owns the .srt format and nothing else: parse, serialise, and find
# the cue being spoken. It is pure - no UI, no files - so it can be tested.

if (-not ([System.Management.Automation.PSTypeName]'VideoStudio.CaptionCue').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Globalization;

namespace VideoStudio
{
    // One caption. Start/End are seconds. Text is the caption body; a caption
    // that was written across two lines keeps its newline.
    //
    // Implements INotifyPropertyChanged so the editor can simply set IsActive
    // on the cue being spoken and let WPF repaint that one row - no selection,
    // no line arithmetic, nothing to fall out of step with an edit.
    public class CaptionCue : INotifyPropertyChanged
    {
        private string _text = "";
        private bool _isActive;
        private double _start;
        private double _end;

        public double Start
        {
            get { return _start; }
            set { if (_start != value) { _start = value; OnChanged("Start"); OnChanged("TimeLabel"); } }
        }

        public double End
        {
            get { return _end; }
            set { if (_end != value) { _end = value; OnChanged("End"); } }
        }

        public string Text
        {
            get { return _text; }
            set
            {
                string v = value ?? "";
                if (_text != v) { _text = v; OnChanged("Text"); }
            }
        }

        public bool IsActive
        {
            get { return _isActive; }
            set { if (_isActive != value) { _isActive = value; OnChanged("IsActive"); } }
        }

        // What the row's time chip shows, and what you click to jump there.
        // TRUNCATED, not rounded: the label must never read later than the cue
        // actually starts, or clicking it looks like it seeks to the wrong spot.
        public string TimeLabel
        {
            get
            {
                double s = _start < 0 ? 0 : _start;
                int mins = (int)(s / 60);
                double secs = Math.Floor((s - (mins * 60)) * 10.0) / 10.0;
                return mins.ToString(CultureInfo.InvariantCulture) + ":" +
                       secs.ToString("00.0", CultureInfo.InvariantCulture);
            }
        }

        public event PropertyChangedEventHandler PropertyChanged;

        private void OnChanged(string name)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) { h(this, new PropertyChangedEventArgs(name)); }
        }
    }
}
'@
}

# "00:01:02,500" / "00:01:02.500" -> 62.5. Returns $null for anything else.
function ConvertFrom-SrtTime {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value -notmatch '^\s*(\d+):([0-5]?\d):([0-5]?\d)[,\.](\d{1,3})\s*$') { return $null }
    $ms = $Matches[4].PadRight(3, '0')
    return ([double]$Matches[1] * 3600) + ([double]$Matches[2] * 60) + [double]$Matches[3] + ([double]$ms / 1000.0)
}

function ConvertTo-SrtTime {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $total = [Math]::Round($Seconds * 1000.0)
    $ms = [int]($total % 1000); $totalSec = [int][Math]::Floor($total / 1000)
    $h = [int][Math]::Floor($totalSec / 3600)
    $m = [int][Math]::Floor(($totalSec % 3600) / 60)
    $s = [int]($totalSec % 60)
    return ('{0:00}:{1:00}:{2:00},{3:000}' -f $h, $m, $s, $ms)
}

# Parses .srt text into CaptionCue objects.
#
# Deliberately forgiving, because these files are hand-edited: the numeric index
# line is optional, either decimal separator is accepted, blank-line separation
# may be missing between the last cue and EOF, and a cue whose timing line is
# unreadable is skipped rather than aborting the whole file.
function Read-SrtCues {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $cues = New-Object System.Collections.Generic.List[VideoStudio.CaptionCue]
    if ([string]::IsNullOrWhiteSpace($Text)) { return $cues }

    $lines = ($Text -replace "`r`n", "`n") -replace "`r", "`n"
    $lines = $lines -split "`n"

    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        if ($line -notmatch '-->') { $i++; continue }

        $parts = $line -split '-->', 2
        $start = ConvertFrom-SrtTime $parts[0]
        $end = if ($parts.Count -gt 1) { ConvertFrom-SrtTime $parts[1] } else { $null }
        if ($null -eq $start) { $i++; continue }
        if ($null -eq $end) { $end = $start }

        $i++
        $body = New-Object System.Collections.Generic.List[string]
        while ($i -lt $lines.Count -and $lines[$i].Trim() -ne '') {
            # a bare number followed by a timing line is the NEXT cue's index,
            # not this cue's text
            if ($lines[$i].Trim() -match '^\d+$' -and
                ($i + 1) -lt $lines.Count -and $lines[$i + 1] -match '-->') { break }
            $body.Add($lines[$i])
            $i++
        }

        $cue = New-Object VideoStudio.CaptionCue
        $cue.Start = $start
        $cue.End = $end
        $cue.Text = ($body -join "`n")
        $cues.Add($cue)
    }
    return $cues
}

# Serialises cues back to .srt. Emits CRLF and a trailing blank line, which is
# what every player and our own burner expect.
function ConvertTo-SrtText {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object]$Cues)
    $sb = New-Object System.Text.StringBuilder
    $n = 0
    foreach ($c in $Cues) {
        $n++
        $body = ([string]$c.Text) -replace "`r`n", "`n"
        [void]$sb.Append($n).Append("`r`n")
        [void]$sb.Append((ConvertTo-SrtTime $c.Start)).Append(' --> ').Append((ConvertTo-SrtTime $c.End)).Append("`r`n")
        foreach ($l in ($body -split "`n")) { [void]$sb.Append($l).Append("`r`n") }
        [void]$sb.Append("`r`n")
    }
    return $sb.ToString()
}

# Index of the cue to highlight at $Seconds, or -1 before the first one.
#
# The LAST cue that has started wins, so the line stays lit through a pause
# instead of blinking off between captions - following along is the whole point.
function Find-ActiveCueIndex {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object]$Cues,
        [double]$Seconds,
        [double]$Tolerance = 0.05
    )
    $active = -1
    $i = 0
    foreach ($c in $Cues) {
        if ($c.Start -le ($Seconds + $Tolerance)) { $active = $i } else { break }
        $i++
    }
    return $active
}
