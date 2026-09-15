# CaptionPlayer.ps1 - the LEFT half of the caption editor: the video, where it
# is up to, and which caption line is lit because of that.
#
# Split from CaptionEditor.ps1 (which owns the words) so each file is about one
# thing. Both work on the same $script:CapEd state object, because a WPF event
# handler cannot see anything else.

# ---- which line is lit ------------------------------------------------------

# THE one place a cue's highlight changes. Setting only the index (and leaving
# the old cue's IsActive alone) is what left the line you were on still glowing
# after you clicked somewhere else.
function Set-ActiveCue([int]$Index) {
    $ed = $script:CapEd; if (-not $ed -or -not $ed.Cues) { return }
    $count = @($ed.Cues).Count
    if ($ed.ActiveIndex -ge 0 -and $ed.ActiveIndex -lt $count) { $ed.Cues[$ed.ActiveIndex].IsActive = $false }
    $ed.ActiveIndex = -1
    if ($Index -lt 0 -or $Index -ge $count) { return }
    $ed.Cues[$Index].IsActive = $true
    $ed.ActiveIndex = $Index
}

# ---------------------------------------------------------------- playback ---

function Set-CaptionPlaying([bool]$Playing) {
    $ed = $script:CapEd; if (-not $ed) { return }
    if ($Playing) {
        # OFF while playing: it makes the decoder render frames it should be
        # dropping, and the picture drifts behind the sound.
        $ed.Media.ScrubbingEnabled = $false
        $ed.Media.Play()
    } else {
        $ed.Media.Pause()
        $ed.Media.ScrubbingEnabled = $true      # back on so seeking shows frames
    }
    $ed.Playing = $Playing
    $ed.PlayPause.Content = if ($Playing) { 'Pause' } else { 'Play' }
}

# Phone clips store portrait video sideways with a rotation flag WPF ignores.
# ffmpeg bakes the rotation in when it writes a proxy, so only a master ever
# needs straightening.
function Get-VideoRotation([string]$Path) {
    try {
        $out = & ffprobe -loglevel error -select_streams v:0 -show_entries stream_side_data=rotation `
                -read_intervals "%+#1" -of default=nw=1:nk=1 -- $Path 2>$null | Select-Object -First 1
        if (-not $out) {
            $out = & ffprobe -loglevel error -select_streams v:0 -show_entries stream_tags=rotate `
                    -of default=nw=1:nk=1 -- $Path 2>$null | Select-Object -First 1
            if ($out) { return ((([int]$out % 360) + 360) % 360) }
            return 0
        }
        return ((((-([int]$out)) % 360) + 360) % 360)   # display angle = -(side data)
    } catch { return 0 }
}

function Set-CaptionSource([string]$Path, [bool]$IsProxy) {
    $ed = $script:CapEd; if (-not $ed) { return }
    $ed.PlayingPath = $Path
    $ed.Rot.Angle = if ($IsProxy) { 0 } else { Get-VideoRotation $Path }
    $ed.Media.Source = New-Object System.Uri($Path)
}

# Loads the selected clip's captions and video. Plays the cached proxy when
# there is one; otherwise plays the master now and builds a proxy in the
# background, swapping it in - at the same position - when it's ready.
function Open-CaptionClip {
    $ed = $script:CapEd; if (-not $ed) { return }
    $sel = $ed.Vids.SelectedItem
    if (-not $sel) { return }

    # Reset first, then load - otherwise the reset wipes whatever the load has
    # to say about a file it couldn't read.
    $ed.ActiveIndex = -1
    $ed.FocusBox = $null
    $ed.PendingPos = $null
    $ed.PendingPlay = $false
    try { $ed.Media.Stop() } catch {}
    Set-CaptionPlaying $false
    $ed.Seek.Value = 0
    $ed.Time.Text = '0:00 / 0:00'
    $ed.Note.Text = ''
    $ed.Win.Title = "Edit captions  -  $sel"

    $ed.Loading = $true
    $ed.SrtPath = Join-Path $ed.OutDir "$sel.srt"
    try {
        $ed.Cues = Read-SrtCues ([System.IO.File]::ReadAllText($ed.SrtPath))
    } catch {
        $ed.Cues = New-Object System.Collections.Generic.List[VideoStudio.CaptionCue]
        $ed.Note.Text = "Couldn't read this caption file: " + $_.Exception.Message
        $ed.SrtPath = $null                   # nothing to save back over
    }
    $ed.CuesCtrl.ItemsSource = $ed.Cues
    $ed.Loading = $false
    $ed.Dirty = $false
    # one clip's edits are not the next clip's history
    Reset-TextHistory $ed.History (Get-CaptionTexts)
    Update-UndoButtons

    $vfile = Get-ChildItem -Path $ed.OutDir -File -ErrorAction SilentlyContinue |
             Where-Object { $_.BaseName -eq $sel -and $ed.VidExts -contains $_.Extension.ToLower() } |
             Select-Object -First 1
    if (-not $vfile) {
        $ed.MasterPath = $null; $ed.Rot.Angle = 0; $ed.Media.Source = $null
        $ed.Note.Text = 'No video file found for these captions.'
        return
    }
    $ed.MasterPath = $vfile.FullName

    if (Test-ProxyReady $ed.Root $ed.MasterPath) {
        Set-CaptionSource (Get-ProxyPath $ed.Root $ed.MasterPath) $true
        return
    }

    Set-CaptionSource $ed.MasterPath $false
    Start-CaptionProxy
}

function Start-CaptionProxy {
    $ed = $script:CapEd; if (-not $ed -or -not $ed.MasterPath) { return }
    try { Stop-WatchedProcess $ed.ProxyTimer } catch {}
    $ed.ProxyTimer = $null

    $build = $null
    try { $build = Start-ProxyBuild $ed.Root $ed.MasterPath } catch {}
    if (-not $build) { return }

    $ed.Note.Text = 'Preparing a smooth preview of this clip...'
    $ed.ProxyTimer = Watch-Process -Tracked $build.Tracked -IntervalMs 500 -Context $build -OnExit {
        param($result, $build)
        $ok = Complete-ProxyBuild $build $result
        $ed = $script:CapEd
        if (-not $ed) { return }
        $ed.ProxyTimer = $null
        if (-not $ok) { $ed.Note.Text = ''; return }
        # the user may have switched clips while it built
        if ($ed.MasterPath -ne $build.Source) { $ed.Note.Text = ''; return }
        $ed.Note.Text = 'Smooth preview ready.'
        $ed.PendingPos = $ed.Media.Position.TotalSeconds
        $ed.PendingPlay = $ed.Playing
        Set-CaptionPlaying $false
        Set-CaptionSource $build.Dest $true
    }
}

# ------------------------------------------------------------ follow-along ---

function Update-CaptionFollow {
    $ed = $script:CapEd; if (-not $ed) { return }
    if (-not $ed.Media.Source -or -not $ed.Media.NaturalDuration.HasTimeSpan) { return }

    $pos = $ed.Media.Position.TotalSeconds
    if (-not $ed.Seeking) { $ed.Seek.Value = $pos }
    $ed.Time.Text = (Format-Clock $pos) + ' / ' + (Format-Clock $ed.Media.NaturalDuration.TimeSpan.TotalSeconds)

    if (-not $ed.Playing -or $ed.Seeking) { return }
    if (-not (Sync-CaptionHighlight)) { return }          # nothing moved

    # Don't yank the view around while someone is typing in it.
    if ($ed.FocusBox -and $ed.FocusBox.IsKeyboardFocused) { return }
    Show-CueIfOffscreen $ed.ActiveIndex
}

# Light the caption for wherever the video is now. Returns $true when the lit
# line actually changed, so callers know whether it is worth scrolling.
function Sync-CaptionHighlight {
    $ed = $script:CapEd; if (-not $ed -or -not $ed.Cues) { return $false }
    if (@($ed.Cues).Count -eq 0) { return $false }
    if (-not $ed.Media.Source) { return $false }
    $active = Find-ActiveCueIndex $ed.Cues $ed.Media.Position.TotalSeconds
    if ($active -eq $ed.ActiveIndex) { return $false }
    Set-ActiveCue $active
    return $true
}

# Scroll ONLY when the row is actually out of sight. The old rule moved the pane
# whenever the line left the middle 60 % of it, which is why it scrolled
# constantly.
function Show-CueIfOffscreen([int]$Index) {
    $ed = $script:CapEd; if (-not $ed) { return }
    $sv = $ed.CueScroll
    $container = $null
    try { $container = $ed.CuesCtrl.ItemContainerGenerator.ContainerFromIndex($Index) } catch {}
    if (-not $container) { return }

    $y = 0.0; $h = 0.0
    try {
        $pt = $container.TransformToAncestor($sv).Transform([System.Windows.Point]::new(0, 0))
        $y = $pt.Y
        $h = $container.ActualHeight
    } catch { return }

    $viewport = $sv.ViewportHeight
    if ($viewport -le 0) { return }
    if ($y -ge 0 -and ($y + $h) -le $viewport) { return }      # already visible: leave it alone

    Start-CueGlide ($sv.VerticalOffset + $y - ($viewport * 0.33))
}

function Start-CueGlide([double]$Target) {
    $ed = $script:CapEd; if (-not $ed) { return }
    $sv = $ed.CueScroll
    $max = [math]::Max(0, $sv.ScrollableHeight)
    if ($Target -lt 0) { $Target = 0 }
    if ($Target -gt $max) { $Target = $max }
    if ([math]::Abs($Target - $sv.VerticalOffset) -lt 1) { return }
    $ed.GlideFrom = $sv.VerticalOffset
    $ed.GlideTo = $Target
    $ed.GlideP = 0.0
    $ed.Glide.Start()
}

# $s is the timer itself - the ONLY reliable handle a Tick has to it.
function Step-CaptionGlide($s) {
    $ed = $script:CapEd
    if (-not $ed) { $s.Stop(); return }
    $ed.GlideP += (16.0 / 220.0)
    if ($ed.GlideP -gt 1) { $ed.GlideP = 1 }
    $eased = 1 - [math]::Pow(1 - $ed.GlideP, 3)
    $ed.CueScroll.ScrollToVerticalOffset($ed.GlideFrom + ($ed.GlideTo - $ed.GlideFrom) * $eased)
    if ($ed.GlideP -ge 1) { $s.Stop() }
}

