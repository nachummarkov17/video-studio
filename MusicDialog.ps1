# MusicDialog.ps1 - the "Background music" picker.
#
# One row per video: pick a track, preview it, then write music-map.txt and let
# Apply-Music.ps1 mix them in. Split out of Studio.ps1 so the main window file
# is about the main window.

function Show-MusicDialog {
    $srcRel = Music-Source
    $src = Join-Path $Root $srcRel
    # Same order as "Your videos" - and music-map.txt is written in this order,
    # which is the order Apply-Music.ps1 then mixes them in.
    $vids = @(Get-OrderedVideos $Root $src '*.mp4')
    if (-not $vids) { [System.Windows.MessageBox]::Show("No videos to add music to yet.","Background music") | Out-Null; return }

    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Background music" Height="600" Width="760" WindowStartupLocation="CenterOwner"
        Background="#FFFFFF" FontFamily="Segoe UI">
  <DockPanel Margin="14">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,10">
      <TextBlock TextWrapping="Wrap" Foreground="#5B6A66" FontSize="12"
        Text="Choose a track for each video. Use 'Import music files' to bring .mp3s in. Leave a video on (none) for no music. Click &#9654; to hear a track before you commit to it."/>
      <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
        <Button x:Name="Import" Content="Import music files..." Background="#FFFFFF" Foreground="#2C6B60" Padding="14,7" BorderBrush="#3D9E8E" BorderThickness="1" Cursor="Hand" Margin="0,0,8,0"/>
        <TextBlock x:Name="TrackCount" VerticalAlignment="Center" Foreground="#5B6A66" FontSize="12"/>
      </StackPanel>
    </StackPanel>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="Apply" Content="Add music to videos" Background="#3D9E8E" Foreground="White" FontWeight="SemiBold" Padding="16,7" BorderThickness="0" Cursor="Hand" Margin="0,0,8,0"/>
      <Button x:Name="Close" Content="Close" Background="#FFFFFF" Foreground="#2C6B60" Padding="16,7" BorderBrush="#3D9E8E" BorderThickness="1" Cursor="Hand"/>
    </StackPanel>
    <ScrollViewer VerticalScrollBarVisibility="Auto">
      <StackPanel x:Name="Rows"/>
    </ScrollViewer>
  </DockPanel>
</Window>
"@
    $w = New-Win $x; $w.Owner = $win
    $rows = $w.FindName('Rows'); $import = $w.FindName('Import'); $apply = $w.FindName('Apply')
    $close = $w.FindName('Close'); $trackCount = $w.FindName('TrackCount')

    # existing assignments
    $prev = @{}
    if (Test-Path $MapFile) {
        foreach ($line in Get-Content -LiteralPath $MapFile -Encoding UTF8) {
            $t = $line.Trim(); if (-not $t -or $t.StartsWith('#')) { continue }
            $p = $t -split '\|', 2; $vn = $p[0].Trim(); $tn = ''; if ($p.Count -ge 2) { $tn = $p[1].Trim() }
            if ($vn) { $prev[$vn] = $tn }
        }
    }

    # ---- track preview -----------------------------------------------------
    # One shared player for the whole dialog, so two tracks can never overlap.
    # MediaPlayer (not MediaElement) because it needs no place in the visual tree.
    $player   = New-Object System.Windows.Media.MediaPlayer
    $playMap  = @{}                      # video name -> its play/stop button
    $glyphPlay = [string][char]0x25B6    # play
    $glyphStop = [string][char]0x25A0    # stop
    $script:musPlayingRow = $null

    $stopPreview = {
        try { $player.Stop() } catch {}
        if ($script:musPlayingRow -and $playMap.ContainsKey($script:musPlayingRow)) {
            $playMap[$script:musPlayingRow].Content = $glyphPlay
        }
        $script:musPlayingRow = $null
    }
    $onPlayClick = {
        $name = [string]$this.Tag
        $wasPlaying = ($script:musPlayingRow -eq $name)
        & $stopPreview
        if ($wasPlaying) { return }                       # second click = stop
        $cb = $comboMap[$name]
        $sel = if ($cb -and $cb.SelectedItem) { [string]$cb.SelectedItem } else { '(none)' }
        if ($sel -eq '(none)') { return }
        $track = Join-Path $MusicDir $sel
        if (-not (Test-Path -LiteralPath $track)) { return }
        try {
            $player.Open((New-Object System.Uri($track)))
            $player.Play()
            $script:musPlayingRow = $name
            $this.Content = $glyphStop
        } catch { & $stopPreview }
    }
    $player.Add_MediaEnded({ & $stopPreview })
    $onComboChanged = {
        $name = [string]$this.Tag
        if ($script:musPlayingRow -eq $name) { & $stopPreview }   # picked a different track
        if ($playMap.ContainsKey($name)) {
            $sel = if ($this.SelectedItem) { [string]$this.SelectedItem } else { '(none)' }
            $playMap[$name].IsEnabled = ($sel -ne '(none)')
        }
    }

    $comboMap = @{}
    $fillCombos = {
        $tracks = @(Get-Tracks | ForEach-Object { $_.Name })
        $trackCount.Text = "$($tracks.Count) track(s) in your music folder"
        foreach ($vn in $comboMap.Keys) {
            $cb = $comboMap[$vn]
            $keep = if ($cb.SelectedItem) { [string]$cb.SelectedItem } else { '(none)' }
            $cb.Items.Clear(); [void]$cb.Items.Add('(none)')
            foreach ($tr in $tracks) { [void]$cb.Items.Add($tr) }
            if ($cb.Items.Contains($keep)) { $cb.SelectedItem = $keep } else { $cb.SelectedIndex = 0 }
        }
    }

    foreach ($v in $vids) {
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'; $row.Margin = '0,0,0,7'
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $v.Name; $lbl.Width = 330; $lbl.VerticalAlignment = 'Center'; $lbl.FontSize = 13
        $cb = New-Object System.Windows.Controls.ComboBox
        $cb.Width = 320; $cb.FontSize = 13; $cb.Tag = $v.Name
        $cb.Add_SelectionChanged($onComboChanged)
        $btnPlay = New-Object System.Windows.Controls.Button
        $btnPlay.Content = $glyphPlay; $btnPlay.Width = 34; $btnPlay.Margin = '8,0,0,0'
        $btnPlay.Padding = '0,2,0,2'; $btnPlay.Cursor = 'Hand'; $btnPlay.Tag = $v.Name
        $btnPlay.ToolTip = 'Listen to this track'
        $btnPlay.Background = [System.Windows.Media.Brushes]::White
        $btnPlay.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#2C6B60')))
        $btnPlay.BorderBrush = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#3D9E8E')))
        $btnPlay.Add_Click($onPlayClick)
        $row.Children.Add($lbl) | Out-Null
        $row.Children.Add($cb)  | Out-Null
        $row.Children.Add($btnPlay) | Out-Null
        $rows.Children.Add($row) | Out-Null
        $comboMap[$v.Name] = $cb
        $playMap[$v.Name]  = $btnPlay
    }
    & $fillCombos
    # preselect from previous map
    foreach ($v in $vids) {
        if ($prev.ContainsKey($v.Name)) {
            $want = $prev[$v.Name]
            if ($want -and $comboMap[$v.Name].Items.Contains($want)) { $comboMap[$v.Name].SelectedItem = $want }
        }
    }
    # nothing to listen to on a row that's set to (none)
    foreach ($v in $vids) {
        $sel = if ($comboMap[$v.Name].SelectedItem) { [string]$comboMap[$v.Name].SelectedItem } else { '(none)' }
        $playMap[$v.Name].IsEnabled = ($sel -ne '(none)')
    }
    $w.Add_Closing({
        & $stopPreview
        try { $player.Close() } catch {}
    })

    $import.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title = "Choose music files to import"
        $dlg.Filter = "Audio (*.mp3;*.wav;*.m4a;*.aac;*.flac;*.ogg)|*.mp3;*.wav;*.m4a;*.aac;*.flac;*.ogg|All files (*.*)|*.*"
        $dlg.Multiselect = $true
        if ($dlg.ShowDialog()) {
            New-Item -ItemType Directory -Force -Path $MusicDir | Out-Null
            foreach ($f in $dlg.FileNames) {
                try { Copy-Item -LiteralPath $f -Destination (Join-Path $MusicDir ([System.IO.Path]::GetFileName($f))) -Force } catch {}
            }
            & $fillCombos
        }
    })
    $apply.Add_Click({
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("# MUSIC MAP  -  which background track plays under which video.")
        foreach ($v in $vids) {
            $cb = $comboMap[$v.Name]
            $sel = if ($cb.SelectedItem) { [string]$cb.SelectedItem } else { '(none)' }
            $track = if ($sel -eq '(none)') { '' } else { $sel }
            $lines.Add(("{0} | {1}" -f $v.Name, $track))
        }
        [System.IO.File]::WriteAllText($MapFile, (($lines -join "`r`n") + "`r`n"), (Utf8NoBom))
        $w.Close()
        Start-Task "Add background music" 'Apply-Music.ps1' @('-SourceDir', $srcRel) $null
    })
    $close.Add_Click({ $w.Close() })
    [void]$w.ShowDialog()
}
