# CaptionEditor.Tests.ps1 - opens the REAL caption editor window against a real
# clip and a real .srt, pokes it, and closes it.
#
# The unit tests cover the .srt round trip; this covers the part that actually
# broke before - the window: that the cue rows are built, that marking a cue
# active repaints THAT row (the old selection-based highlight is what was
# "extremely janky, sometimes not even on the text"), that the timers stop when
# the window closes, and that saving writes back what you typed.
#
# A window really does open for about two seconds and then close itself.
#
# Run:  powershell -STA -ExecutionPolicy Bypass -File tests\CaptionEditor.Tests.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $root 'UiHelpers.ps1')
. (Join-Path $root 'ContentKey.ps1')
. (Join-Path $root 'ProcessRunner.ps1')
. (Join-Path $root 'CaptionMarkup.ps1')
. (Join-Path $root 'SrtDocument.ps1')
. (Join-Path $root 'CaptionColors.ps1')
. (Join-Path $root 'CaptionUndo.ps1')
. (Join-Path $root 'PreviewProxy.ps1')
. (Join-Path $root 'CaptionPlayer.ps1')
. (Join-Path $root 'CaptionEditor.ps1')

$script:results = @()
function A($cond, $m) { $script:results += ,@($cond, $m) }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("CapEd_" + [Guid]::NewGuid().ToString('N'))
$out = Join-Path $tmp 'output'
New-Item -ItemType Directory -Force -Path $out | Out-Null

try {
    # a real (tiny) clip, so the MediaElement has something genuine to open
    & ffmpeg -y -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x568:rate=30:duration=3 `
             -c:v libx264 -preset ultrafast -pix_fmt yuv420p (Join-Path $out 'Probe.mp4') 2>$null | Out-Null

    $srt = @(
        '1', '00:00:00,000 --> 00:00:01,000', 'first line'
        '', '2', '00:00:01,200 --> 00:00:02,000', 'second *line*'
        '', '3', '00:00:02,100 --> 00:00:03,000', 'third line', ''
    ) -join "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $out 'Probe.srt'), $srt, (Utf8NoBom))

    # Runs INSIDE the window's own message pump, which is the only place the
    # visual tree exists.
    $probe = New-Object System.Windows.Threading.DispatcherTimer
    $probe.Interval = [TimeSpan]::FromMilliseconds(1400)
    $probe.Add_Tick({
        param($s, $e)
        $s.Stop()
        try {
            $ed = $script:CapEd
            A ($null -ne $ed) 'the editor built its state'
            if (-not $ed) { return }

            A ($ed.Cues.Count -eq 3) "three cues were parsed (got $($ed.Cues.Count))"
            A ($ed.CuesCtrl.Items.Count -eq 3) 'and three rows are on screen'
            A ($ed.Cues[1].Text -eq 'second *line*') 'the starred word survives into the row'

            $ed.CuesCtrl.UpdateLayout()
            $cp = $ed.CuesCtrl.ItemContainerGenerator.ContainerFromIndex(1)
            A ($null -ne $cp) 'the row has a real container we can scroll to'

            # The highlight: set IsActive and the ROW repaints. No selection, no
            # line counting, nothing that an edit can knock out of step.
            $border = $null
            if ($cp) {
                $child = [System.Windows.Media.VisualTreeHelper]::GetChild($cp, 0)
                if ($child -is [System.Windows.Controls.Border]) { $border = $child }
            }
            A ($null -ne $border) 'the row is a Border we can paint'
            if ($border) {
                $before = $border.BorderBrush.ToString()
                Set-ActiveCue 1
                $ed.CuesCtrl.UpdateLayout()
                $after = $border.BorderBrush.ToString()
                A ($before -ne $after) "marking a cue active repaints its row ($before -> $after)"
                A ($after -match '3D9E8E') 'and paints it the brand teal'
            }

            # Typing in a row writes through to the cue, and saving writes the
            # cue back to disk with its timing untouched.
            $ed.Cues[0].Text = 'corrected words'
            Save-CaptionCues
            $reread = Read-SrtCues ([System.IO.File]::ReadAllText($ed.SrtPath))
            A ($reread[0].Text -eq 'corrected words') 'an edit is saved back to the .srt'
            A ([Math]::Abs($reread[0].End - 1.0) -lt 0.001) 'and its timing is untouched'
            A ($reread.Count -eq 3) 'with no cues lost'

            # Scrubbing support has to be OFF while playing or the picture drifts
            # behind the sound; it goes back on when paused so seeking shows frames.
            Set-CaptionPlaying $true
            A ($ed.Media.ScrubbingEnabled -eq $false) 'scrubbing support is off while playing (the A/V sync fix)'
            Set-CaptionPlaying $false
            A ($ed.Media.ScrubbingEnabled -eq $true) 'and back on when paused, so seeking shows a frame'

            # ---- ONE line lit at a time -----------------------------------
            # Clicking a caption's time used to leave the PREVIOUS line glowing:
            # only the index was cleared, so nothing ever turned the old row off.
            Set-ActiveCue 0
            Set-ActiveCue 2
            $lit = @(@($ed.Cues) | Where-Object { $_.IsActive })
            A ($lit.Count -eq 1) "exactly one caption is lit after moving (got $($lit.Count))"
            A ($ed.Cues[2].IsActive -and -not $ed.Cues[0].IsActive) 'and it is the one you moved to'
            Set-ActiveCue -1
            A ((@(@($ed.Cues) | Where-Object { $_.IsActive })).Count -eq 0) 'and nothing is lit when nothing is playing'

            # ---- the colour palette ---------------------------------------
            A (@($ed.Palette).Count -ge 1) 'the editor loaded an emphasis palette'
            A (@($ed.Palette)[0].Marker -eq '*') 'starting with the original star colour'
            A ($ed.ColorPanel.Children.Count -ge 2) 'and built a button for it'

            # ---- undo / redo ----------------------------------------------
            Complete-CaptionEdit                      # close off everything above
            $wasEnabled = $ed.UndoBtn.IsEnabled
            $before = @(Get-CaptionTexts)
            $ed.Cues[0].Text = 'typed something new'
            Complete-CaptionEdit
            A ($ed.UndoBtn.IsEnabled) 'after an edit, Undo lights up'
            Undo-CaptionEdit
            A ($ed.Cues[0].Text -eq $before[0]) "undo puts the previous words back (got '$($ed.Cues[0].Text)')"
            A ($ed.RedoBtn.IsEnabled) 'and Redo lights up'
            Redo-CaptionEdit
            A ($ed.Cues[0].Text -eq 'typed something new') 'redo puts the edit back'
            Undo-CaptionEdit
        } catch {
            A $false ("the probe itself threw: " + $_.Exception.Message)
        } finally {
            # Leave nothing unsaved: closing with edits pending pops a modal
            # "save your changes?" box, and nobody is here to click it.
            try { $script:CapEd.Dirty = $false } catch {}
            try { $script:CapEd.Win.Close() } catch {}
        }
    })
    $probe.Start()

    Show-CaptionEditor -Root $tmp -OutDir $out -VideoExtensions @('.mp4')

    # After the window has gone, nothing of it may still be ticking. A timer that
    # cannot stop itself is what quietly ran at 60fps for the life of the app.
    A ($null -eq $script:CapEd) 'the editor let go of its state on close'
}
finally {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

$fails = 0
foreach ($r in $script:results) {
    if ($r[0]) { Write-Host "PASS: $($r[1])" } else { Write-Host "FAIL: $($r[1])"; $fails++ }
}
Write-Host ''
if ($fails -eq 0) { Write-Host "All caption editor tests passed." } else { Write-Host "$fails test(s) FAILED."; exit 1 }
