# CaptionEditor.ps1 - watch the clip, fix the words.
#
# REWRITTEN because the old one was laggy, its highlight was unreliable and its
# scrolling fought you. Every one of those had a specific cause:
#
#  * The captions lived in ONE big TextBox and the "highlight" was that box's
#    SELECTION, aimed by counting lines. Selections fight the caret, every edit
#    shifts the line numbers under them, and moving a selection makes the box
#    scroll itself. Captions are now a LIST OF CUE OBJECTS; the spoken one has
#    IsActive set and WPF repaints that row. Nothing to fall out of step with.
#
#  * A 16 ms scroll-glide timer called $scrollAnim.Stop() from inside its own
#    Tick - and a PowerShell event scriptblock CANNOT see the locals of the
#    function that made it, so $scrollAnim was $null there, Stop() threw, and
#    the timer ran at 60 fps forever, doing layout work on the same UI thread
#    that presents video. Every timer here takes its sender as $s and stops
#    THAT; all shared state lives on one $script: object.
#
#  * ScrubbingEnabled was left on permanently. It exists so a PAUSED element
#    renders the frame you seek to; leaving it on during playback makes the
#    decoder render frames it should be dropping, and the picture falls behind
#    the sound. It is now on only while paused.
#
#  * The player was pointed at the full-size master. Seeking one of those costs
#    hundreds of milliseconds. It plays a cached proxy instead (PreviewProxy.ps1),
#    falling back to the master while one is being built.
#
#  * The view scrolled whenever the spoken line left the middle 60 % of the
#    pane. It now scrolls only when the line is actually off screen.

$script:CapEd = $null
# Where this file lives, so the markup is found next to the CODE. The -Root
# parameter is the user's project folder, which is a different thing.
$script:CaptionEditorDir = $PSScriptRoot

function Show-CaptionEditor {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$OutDir,
        [object]$Owner,
        [string[]]$VideoExtensions = @('.mp4', '.mov', '.m4v', '.avi', '.mkv', '.webm')
    )

    $caps = Get-ChildItem -Path $OutDir -Filter *.srt -File -ErrorAction SilentlyContinue | Sort-Object Name
    if (-not $caps) {
        [System.Windows.MessageBox]::Show("No captions yet. Click 'Make captions' first.", "Edit captions") | Out-Null
        return
    }

    # Markup lives in ui\caption-editor.xaml, like the main window's.
    $w = New-Win ([System.IO.File]::ReadAllText((Join-Path $script:CaptionEditorDir 'ui\caption-editor.xaml')))

    if ($Owner) { $w.Owner = $Owner }

    # ONE state object, at script scope. Event scriptblocks can't see this
    # function's locals - that is not a style choice, it is the language.
    $ed = [pscustomobject]@{
        Win        = $w
        Root       = $Root
        OutDir     = $OutDir
        VidExts    = $VideoExtensions
        Vids       = $w.FindName('Vids')
        CuesCtrl   = $w.FindName('Cues')
        CueScroll  = $w.FindName('CueScroll')
        Media      = $w.FindName('Media')
        Rot        = $w.FindName('Rot')
        Seek       = $w.FindName('Seek')
        Time       = $w.FindName('Time')
        Note       = $w.FindName('Note')
        PlayPause  = $w.FindName('PlayPause')
        OpenExt    = $w.FindName('OpenExt')
        SaveBtn    = $w.FindName('Save')
        CloseBtn   = $w.FindName('Close')
        ColorPanel = $w.FindName('Colors')
        AddColorBtn = $w.FindName('AddColor')
        UndoBtn    = $w.FindName('Undo')
        RedoBtn    = $w.FindName('Redo')
        Palette    = $null      # the emphasis colours (CaptionColors.ps1)
        History    = (New-TextHistory)
        Commit     = $null      # idle timer that closes off an undo step
        Cues       = $null
        SrtPath    = $null
        MasterPath = $null      # the real clip, always what gets burned
        PlayingPath = $null     # what the MediaElement is actually loaded with
        Dirty      = $false
        Loading    = $false
        Playing    = $false
        Seeking    = $false
        ActiveIndex = -1
        FocusBox   = $null
        PendingPos = $null      # position to restore after a source swap
        PendingPlay = $false
        Ticker     = $null
        Glide      = $null
        GlideFrom  = 0.0
        GlideTo    = 0.0
        GlideP     = 1.0
        ProxyTimer = $null
    }
    $script:CapEd = $ed

    foreach ($c in $caps) { [void]$ed.Vids.Items.Add($c.BaseName) }

    # ---- timers ------------------------------------------------------------
    $ed.Ticker = New-Object System.Windows.Threading.DispatcherTimer
    $ed.Ticker.Interval = [TimeSpan]::FromMilliseconds(100)
    $ed.Ticker.Add_Tick({ param($s, $e) Update-CaptionFollow })

    $ed.Glide = New-Object System.Windows.Threading.DispatcherTimer
    $ed.Glide.Interval = [TimeSpan]::FromMilliseconds(16)
    $ed.Glide.Add_Tick({ param($s, $e) Step-CaptionGlide $s })

    # Stop typing for a moment and that burst becomes one undo step. Without a
    # boundary like this, Ctrl+Z would walk back one letter at a time.
    $ed.Commit = New-Object System.Windows.Threading.DispatcherTimer
    $ed.Commit.Interval = [TimeSpan]::FromMilliseconds(700)
    $ed.Commit.Add_Tick({ param($s, $e) $s.Stop(); Complete-CaptionEdit })

    Build-ColorButtons

    # ---- wiring ------------------------------------------------------------
    $ed.Vids.Add_SelectionChanged({ param($s, $e)
        Save-CaptionsIfAsked
        Open-CaptionClip
    })

    $ed.Media.Add_MediaOpened({ param($s, $e)
        $ed = $script:CapEd; if (-not $ed) { return }
        if ($ed.Media.NaturalDuration.HasTimeSpan) {
            $ed.Seek.Maximum = [math]::Max(0.1, $ed.Media.NaturalDuration.TimeSpan.TotalSeconds)
        }
        # a source swap (master -> proxy) puts you back exactly where you were
        if ($null -ne $ed.PendingPos) {
            $ed.Media.Position = [TimeSpan]::FromSeconds([double]$ed.PendingPos)
            $ed.PendingPos = $null
            if ($ed.PendingPlay) { $ed.PendingPlay = $false; Set-CaptionPlaying $true }
        } else {
            $ed.Media.Position = [TimeSpan]::Zero
        }
        $ed.Ticker.Start()
    })
    $ed.Media.Add_MediaEnded({ param($s, $e)
        $ed = $script:CapEd; if (-not $ed) { return }
        Set-CaptionPlaying $false
        $ed.Media.Position = [TimeSpan]::Zero
        Set-ActiveCue -1
    })
    $ed.Media.Add_MediaFailed({ param($s, $e)
        $ed = $script:CapEd; if (-not $ed) { return }
        $ed.Note.Text = "Can't preview this file - use 'Open in player'."
    })

    $ed.PlayPause.Add_Click({ param($s, $e)
        $ed = $script:CapEd; if (-not $ed -or -not $ed.Media.Source) { return }
        Set-CaptionPlaying (-not $ed.Playing)
    })
    $ed.OpenExt.Add_Click({ param($s, $e)
        $ed = $script:CapEd
        if ($ed -and $ed.MasterPath -and (Test-Path -LiteralPath $ed.MasterPath)) { Start-Process $ed.MasterPath }
    })

    # Seek on RELEASE only. Seeking on every slider move is a decoder storm.
    $ed.Seek.Add_PreviewMouseLeftButtonDown({ param($s, $e) if ($script:CapEd) { $script:CapEd.Seeking = $true } })
    $ed.Seek.Add_PreviewMouseLeftButtonUp({ param($s, $e)
        $ed = $script:CapEd; if (-not $ed) { return }
        if ($ed.Media.Source) { $ed.Media.Position = [TimeSpan]::FromSeconds($ed.Seek.Value) }
        $ed.Seeking = $false
        [void](Sync-CaptionHighlight) # light the line you landed on, even paused
    })

    # One handler for every cue row's time button - no per-row wiring, and it
    # keeps working as rows are created and destroyed.
    $ed.CuesCtrl.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [System.Windows.RoutedEventHandler]{ param($s, $e)
            $ed = $script:CapEd; if (-not $ed) { return }
            $cue = $null
            foreach ($candidate in @($e.OriginalSource, $e.Source)) {
                if ($candidate -is [System.Windows.FrameworkElement] -and $candidate.Tag) { $cue = $candidate.Tag; break }
            }
            if ($cue) {
                if ($ed.Media.Source) {
                    $ed.Media.Position = [TimeSpan]::FromSeconds([double]$cue.Start)
                    $ed.Seek.Value = [double]$cue.Start
                }
                # Light up the line you clicked and put the old one out. Clearing
                # only the INDEX left the previous line lit with nothing to turn
                # it off, so two lines glowed at once.
                Set-ActiveCue ([Array]::IndexOf(@($ed.Cues), $cue))
            }
        })

    # Typing in any cue marks the file dirty...
    $ed.CuesCtrl.AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
        [System.Windows.Controls.TextChangedEventHandler]{ param($s, $e)
            $ed = $script:CapEd
            if (-not $ed -or $ed.Loading) { return }
            $ed.Dirty = $true
            $ed.Win.Title = "Edit captions  -  unsaved changes"
            $ed.Commit.Stop(); $ed.Commit.Start()      # restart the idle countdown
        })
    # ...and whichever cue box has focus is the one the colour buttons act on.
    # Moving to another caption also closes off the current undo step.
    $ed.CuesCtrl.AddHandler([System.Windows.Input.Keyboard]::GotKeyboardFocusEvent,
        [System.Windows.Input.KeyboardFocusChangedEventHandler]{ param($s, $e)
            $ed = $script:CapEd; if (-not $ed) { return }
            if ($e.NewFocus -is [System.Windows.Controls.TextBox]) {
                if ($ed.FocusBox -and -not [Object]::ReferenceEquals($ed.FocusBox, $e.NewFocus)) { Complete-CaptionEdit }
                $ed.FocusBox = $e.NewFocus
            }
        })

    $ed.AddColorBtn.Add_Click({ param($s, $e) Add-CaptionEmphasisColor })
    $ed.UndoBtn.Add_Click({ param($s, $e) Undo-CaptionEdit })
    $ed.RedoBtn.Add_Click({ param($s, $e) Redo-CaptionEdit })

    $w.Add_PreviewKeyDown({ param($s, $e)
        $ed = $script:CapEd; if (-not $ed) { return }
        $ctrl = (($e.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0)
        if (-not $ctrl) { return }
        $shift = (($e.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0)
        $key = $e.Key

        if ($key -eq [System.Windows.Input.Key]::Z -and -not $shift) { Undo-CaptionEdit; $e.Handled = $true; return }
        if (($key -eq [System.Windows.Input.Key]::Z -and $shift) -or
             $key -eq [System.Windows.Input.Key]::Y) { Redo-CaptionEdit; $e.Handled = $true; return }

        # Ctrl+B stays the first colour, for muscle memory; Ctrl+1..6 pick by
        # position, which is what the buttons show.
        $index = -1
        if ($key -eq [System.Windows.Input.Key]::B) { $index = 0 }
        else {
            $digit = [int]$key - [int][System.Windows.Input.Key]::D1
            if ($digit -ge 0 -and $digit -le 8) { $index = $digit }
        }
        if ($index -ge 0 -and $ed.Palette -and $index -lt @($ed.Palette).Count) {
            Invoke-CaptionEmphasis $index
            $e.Handled = $true
        }
    })

    $ed.SaveBtn.Add_Click({ param($s, $e) Save-CaptionCues })
    $ed.CloseBtn.Add_Click({ param($s, $e) if ($script:CapEd) { $script:CapEd.Win.Close() } })

    $w.Add_Closing({ param($s, $e)
        $ed = $script:CapEd; if (-not $ed) { return }
        Complete-CaptionEdit
        Save-CaptionsIfAsked
        try { $ed.Ticker.Stop() } catch {}
        try { $ed.Glide.Stop() } catch {}
        try { $ed.Commit.Stop() } catch {}
        # a proxy build in flight is left to finish - it caches itself for next
        # time - but we stop caring about its result.
        try { Stop-WatchedProcess $ed.ProxyTimer } catch {}
        try { $ed.Media.Stop(); $ed.Media.Close(); $ed.Media.Source = $null } catch {}
    })
    $w.Add_Closed({ param($s, $e) $script:CapEd = $null })

    $ed.Vids.SelectedIndex = 0
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------- editing ---

# ---- undo / redo ------------------------------------------------------------

function Get-CaptionTexts {
    $ed = $script:CapEd
    if (-not $ed -or -not $ed.Cues) { return @() }
    return @(@($ed.Cues) | ForEach-Object { [string]$_.Text })
}

# Writes texts back onto the cues. Guarded by Loading so putting an undone state
# on screen doesn't look like a fresh edit and start recording all over again.
function Set-CaptionTexts([string[]]$Texts) {
    $ed = $script:CapEd; if (-not $ed -or -not $ed.Cues) { return }
    $cues = @($ed.Cues)
    if ($cues.Count -ne @($Texts).Count) { return }
    $ed.Loading = $true
    try { for ($i = 0; $i -lt $cues.Count; $i++) { $cues[$i].Text = $Texts[$i] } }
    finally { $ed.Loading = $false }
    $ed.Dirty = $true
    $ed.Win.Title = "Edit captions  -  unsaved changes"
}

function Update-UndoButtons {
    $ed = $script:CapEd; if (-not $ed) { return }
    $ed.UndoBtn.IsEnabled = [bool](Test-CanUndo $ed.History)
    $ed.RedoBtn.IsEnabled = [bool](Test-CanRedo $ed.History)
}

# Close off the current undo step. Called when you pause, move to another
# caption, press a colour, save, or close.
function Complete-CaptionEdit {
    $ed = $script:CapEd; if (-not $ed) { return }
    try { $ed.Commit.Stop() } catch {}
    if (Push-TextHistory $ed.History (Get-CaptionTexts)) { Update-UndoButtons }
}

function Undo-CaptionEdit {
    $ed = $script:CapEd; if (-not $ed) { return }
    try { $ed.Commit.Stop() } catch {}
    $prev = Undo-TextHistory $ed.History (Get-CaptionTexts)
    if ($null -eq $prev) { return }
    Set-CaptionTexts $prev
    Update-UndoButtons
}

function Redo-CaptionEdit {
    $ed = $script:CapEd; if (-not $ed) { return }
    try { $ed.Commit.Stop() } catch {}
    $next = Redo-TextHistory $ed.History (Get-CaptionTexts)
    if ($null -eq $next) { return }
    Set-CaptionTexts $next
    Update-UndoButtons
}

# ---- emphasis colours -------------------------------------------------------

# One button per colour, painted in that colour so the row reads as a palette.
# Rebuilt whenever a colour is added.
function Build-ColorButtons {
    $ed = $script:CapEd; if (-not $ed) { return }
    $ed.Palette = Get-CaptionColors $ed.Root
    $ed.ColorPanel.Children.Clear()

    $i = 0
    foreach ($c in @($ed.Palette)) {
        $shortcut = if ($i -eq 0) { 'Ctrl+B' } else { "Ctrl+$($i + 1)" }
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = $c.Name
        $btn.Tag = $i
        $btn.Padding = '10,4,10,4'
        $btn.Margin = '0,0,6,0'
        $btn.Cursor = 'Hand'
        $btn.FontWeight = 'SemiBold'
        $btn.BorderThickness = '2'
        $btn.ToolTip = "$($c.Name): select a word and press $shortcut (marker $($c.Marker)$($c.Marker))"
        try {
            $brush = New-Object System.Windows.Media.SolidColorBrush(
                [System.Windows.Media.ColorConverter]::ConvertFromString($c.Hex))
            $btn.Foreground = $brush
            $btn.BorderBrush = $brush
        } catch {}
        $btn.Background = [System.Windows.Media.Brushes]::White
        $btn.Add_Click({ param($s, $e) Invoke-CaptionEmphasis ([int]$s.Tag) })
        [void]$ed.ColorPanel.Children.Add($btn)

        $hint = New-Object System.Windows.Controls.TextBlock
        $hint.Text = $shortcut
        $hint.FontSize = 10
        $hint.Margin = '0,0,12,0'
        $hint.VerticalAlignment = 'Center'
        $hint.Foreground = [System.Windows.Media.Brushes]::Gray
        [void]$ed.ColorPanel.Children.Add($hint)
        $i++
    }
    $ed.AddColorBtn.IsEnabled = ((Get-FreeCaptionMarkers $ed.Palette).Count -gt 0)
}

function Add-CaptionEmphasisColor {
    $ed = $script:CapEd; if (-not $ed) { return }
    $name = [Microsoft.VisualBasic.Interaction]::InputBox(
        "What is this colour for? (e.g. Unhealthy, Numbers)", 'Add an emphasis colour', '')
    if ([string]::IsNullOrWhiteSpace($name)) { return }

    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.ColorDialog
    $dlg.FullOpen = $true
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $hex = ('#{0:X2}{1:X2}{2:X2}' -f $dlg.Color.R, $dlg.Color.G, $dlg.Color.B)

    $next = Add-CaptionColorTo $ed.Palette $name $hex
    if ($null -eq $next) {
        [System.Windows.MessageBox]::Show("No more emphasis colours are available - there are only $((Get-CaptionMarkerPool).Count) markers.",
                                          'Add an emphasis colour') | Out-Null
        return
    }
    Save-CaptionColors $ed.Root $next
    Build-ColorButtons
    $added = @($ed.Palette)[-1]
    $ed.Note.Text = "Added $($added.Name) - select a word and press Ctrl+$(@($ed.Palette).Count)."
}

# Paints the selection with palette colour $Index. Pressing the same colour
# again clears it; pressing a different one recolours rather than double-wraps.
function Invoke-CaptionEmphasis([int]$Index = 0) {
    $ed = $script:CapEd; if (-not $ed) { return }
    $box = $ed.FocusBox
    if (-not $box) { return }
    $palette = @($ed.Palette)
    if ($Index -lt 0 -or $Index -ge $palette.Count) { return }

    Complete-CaptionEdit          # each colour press is its own undo step
    $markers = @($palette | ForEach-Object { $_.Marker })
    $r = Invoke-ToggleEmphasis $box.Text $box.SelectionStart $box.SelectionLength $palette[$Index].Marker $markers
    if ($r.Text -ne $box.Text) {
        $box.Text = $r.Text                      # two-way bound: the cue updates
        $box.Select($r.SelStart, $r.SelLength)
        Complete-CaptionEdit
    }
    [void]$box.Focus()
}

function Save-CaptionCues {
    $ed = $script:CapEd; if (-not $ed -or -not $ed.SrtPath -or -not $ed.Cues) { return }
    [System.IO.File]::WriteAllText($ed.SrtPath, (ConvertTo-SrtText $ed.Cues), (Utf8NoBom))
    $ed.Dirty = $false
    $ed.Win.Title = "Edit captions  -  saved"
}

function Save-CaptionsIfAsked {
    $ed = $script:CapEd; if (-not $ed -or -not $ed.Dirty -or -not $ed.SrtPath) { return }
    $r = [System.Windows.MessageBox]::Show("Save your caption changes?", "Edit captions",
                                           [System.Windows.MessageBoxButton]::YesNo)
    if ($r -eq [System.Windows.MessageBoxResult]::Yes) { Save-CaptionCues } else { $ed.Dirty = $false }
}
