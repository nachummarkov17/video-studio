# VideoList.ps1 - "Your videos": what's in output\, how far each clip has got,
# and everything you can do to a row (play, rename, remove, reorder, import).
#
# Split out of Studio.ps1 so the main window file is about the window. These
# functions read the module-scope paths ($Root, $OutDir, ...) that Studio.ps1
# sets up before dot-sourcing this file.


# ---------------------------------------------------------------- data helpers
function Has-Mp4([string]$dir) {
    return (Test-Path $dir) -and ((Get-ChildItem -Path $dir -Filter *.mp4 -File -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)
}
function Music-Source  { if (Has-Mp4 $CaptionedDir) { 'output\captioned' } else { 'output' } }
function Export-Source {
    if     (Has-Mp4 $MusicOutDir)  { 'output\with-music' }
    elseif (Has-Mp4 $CaptionedDir) { 'output\captioned' }
    else                           { 'output' }
}
function Get-Tracks { Get-ChildItem -Path $MusicDir -File -ErrorAction SilentlyContinue | Where-Object { $AudioExts -contains $_.Extension.ToLower() } | Sort-Object Name }

# ---------------------------------------------------------------- export-to-folder
# Remembers a destination folder (Option B: set once, then one-click). Export copies
# every finished master from output\upload\ into that folder.
function Get-ExportDest {
    if (Test-Path -LiteralPath $ExportSettingsFile) {
        $p = Get-Content -LiteralPath $ExportSettingsFile -Raw -ErrorAction SilentlyContinue
        if ($p) { return $p.Trim() }
    }
    return $null
}
function Set-ExportDest([string]$path) {
    try { [System.IO.File]::WriteAllText($ExportSettingsFile, $path, (Utf8NoBom)) } catch {}
}
function Update-ExportLabel {
    $d = Get-ExportDest
    if ($d) { $ctrls['LblExportDest'].Text = "Sends to:  $d" }
    else    { $ctrls['LblExportDest'].Text = "No folder set yet - you'll be asked to pick one the first time." }
}
function Select-Folder([string]$desc, [string]$initial) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = $desc
        $dlg.ShowNewFolderButton = $true
        if ($initial -and (Test-Path -LiteralPath $initial)) { $dlg.SelectedPath = $initial }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
        return $null
    } catch {
        try {
            $shell = New-Object -ComObject Shell.Application
            $f = $shell.BrowseForFolder(0, $desc, 0, 0)
            if ($f -and $f.Self) { return $f.Self.Path }
        } catch {}
        return $null
    }
}
function Change-ExportDest {
    if ($script:proc) { Write-LogLine "Finish the current step before changing the export folder."; return }
    $new = Select-Folder "Choose where to put your finished videos" (Get-ExportDest)
    if ($new) { Set-ExportDest $new; Update-ExportLabel; Write-LogLine "Export folder set to: $new" }
}
function Export-Finished {
    if ($script:proc) { Write-LogLine "Finish the current step before exporting."; return }
    if (-not (Has-Mp4 $UploadDir)) {
        Write-LogLine "No finished videos yet - click 'Finish clips' (step 5) first."
        [System.Windows.MessageBox]::Show(
            "No finished videos yet.`n`nClick 'Finish clips' in step 5 first, then export.",
            "Nothing to export", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }
    $dest = Get-ExportDest
    if (-not $dest) {
        $dest = Select-Folder "Choose where to put your finished videos" $null
        if (-not $dest) { return }
        Set-ExportDest $dest; Update-ExportLabel
    }
    try { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
    catch { Write-LogLine ("ERROR: can't use that folder: " + $_.Exception.Message); return }
    $files = Get-ChildItem -Path $UploadDir -Filter *.mp4 -File -ErrorAction SilentlyContinue | Sort-Object Name
    Write-LogLine "=== Export finished videos ==="
    Write-LogLine "To: $dest"
    $copied = 0; $failed = 0
    foreach ($f in $files) {
        try {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dest $f.Name) -Force
            Write-LogLine ("Exported: " + $f.Name); $copied++
        } catch {
            Write-LogLine ("Could not export " + $f.Name + " : " + $_.Exception.Message); $failed++
        }
    }
    $msg = "Exported $copied video(s) to $dest."
    if ($failed) { $msg += " $failed could not be copied (open in another program?)." }
    Write-LogLine $msg
    $status.Text = $msg
    Play-DoneSound 'export'
}
function Best-Version([string]$name) {
    foreach ($d in @($UploadDir, $MusicOutDir, $CaptionedDir, $OutDir)) {
        $p = Join-Path $d $name
        if (Test-Path $p) { return $p }
    }
    return $null
}
function Get-Mtime([string]$path) {
    if (Test-Path -LiteralPath $path) { return (Get-Item -LiteralPath $path).LastWriteTimeUtc }
    return $null
}
function Refresh-Videos {
    # Each column shows one of: "yes" (done, up to date), "redo" (done before but
    # something upstream changed, so it needs re-running), or "-" (not done).
    # Staleness = the file is older than anything it was built from, and it
    # cascades downstream: re-edit -> re-caption -> re-burn -> re-music -> re-export.
    $rows = @()
    # YOUR order (video-order.txt), not alphabetical - and the same order every
    # step script processes clips in. Drag rows in the list to change it.
    $vids = @(Get-OrderedVideos $Root $OutDir '*.mp4')
    $needy = 0
    foreach ($v in $vids) {
        $base   = $v.BaseName
        $videoM = $v.LastWriteTimeUtc
        $srtM = Get-Mtime (Join-Path $OutDir "$base.srt")
        $capM = Get-Mtime (Join-Path $CaptionedDir $v.Name)
        $musM = Get-Mtime (Join-Path $MusicOutDir  $v.Name)
        $upM  = Get-Mtime (Join-Path $UploadDir    $v.Name)
        $chainStale = $false

        # Captions (built from the working video)
        if     ($null -eq $srtM)      { $cCap = '-' }
        elseif ($srtM -lt $videoM)    { $cCap = 'redo'; $chainStale = $true }
        else                          { $cCap = 'yes' }

        # Burn (built from video + captions)
        if ($null -eq $capM) { $cBurn = '-' }
        else {
            $stale = ($capM -lt $videoM) -or ($null -ne $srtM -and $capM -lt $srtM)
            if ($chainStale -or $stale) { $cBurn = 'redo'; $chainStale = $true } else { $cBurn = 'yes' }
        }

        # Music (optional; built from the burned/plain video)
        if ($null -eq $musM) { $cMus = '-' }
        else {
            $stale = ($musM -lt $videoM) -or ($null -ne $srtM -and $musM -lt $srtM) -or ($null -ne $capM -and $musM -lt $capM)
            if ($chainStale -or $stale) { $cMus = 'redo'; $chainStale = $true } else { $cMus = 'yes' }
        }

        # Export (built from the most-finished upstream file)
        if ($null -eq $upM) { $cExp = '-' }
        else {
            $stale = ($upM -lt $videoM) -or ($null -ne $srtM -and $upM -lt $srtM) -or ($null -ne $capM -and $upM -lt $capM) -or ($null -ne $musM -and $upM -lt $musM)
            if ($chainStale -or $stale) { $cExp = 'redo' } else { $cExp = 'yes' }
        }

        if ('redo' -in @($cCap,$cBurn,$cMus,$cExp)) { $needy++ }
        $rows += [pscustomobject]@{ Name = $v.Name; Cap = $cCap; Burn = $cBurn; Music = $cMus; Export = $cExp }
    }
    $ctrls['VidList'].ItemsSource = $rows
    # Pin the arrangement so newly imported clips keep the spot they just landed
    # in and deleted ones fall out of the file. Only rewrite when it changed -
    # this runs on every window activation.
    $names = @($rows | ForEach-Object { $_.Name })
    if ((@(Read-VideoOrder $Root) -join "`n") -ne ($names -join "`n")) { Save-VideoOrder $Root $names }
    if ($rows.Count) {
        $msg = "$($rows.Count) video(s). Finished files save to output\upload."
        if ($needy) { $msg = "$($rows.Count) video(s) - $needy need a step re-done (see 'redo' in the list)." }
        $status.Text = $msg
    } else { $status.Text = "No videos yet - click '+ Add videos'." }
}

# ---------------------------------------------------------------- list reorder
# The row under a point, or $null. ContainerFromElement walks up from whatever
# was actually hit (a TextBlock in a cell) to its ListViewItem for us.
function Get-RowAtPoint($lv, $pt) {
    $hit = $lv.InputHitTest($pt)
    if (-not $hit) { return $null }
    return [System.Windows.Controls.ItemsControl]::ContainerFromElement($lv, $hit)
}

# Moves $Name to position $NewIndex in your arrangement, saves it, and keeps the
# moved row selected so you can keep nudging it with Alt+Up / Alt+Down.
function Move-VideoTo([string]$Name, [int]$NewIndex) {
    $names = @(@($ctrls['VidList'].ItemsSource) | ForEach-Object { [string]$_.Name })
    $from = [array]::IndexOf($names, $Name)
    if ($from -lt 0) { return }
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($n in $names) { $list.Add($n) }
    $list.RemoveAt($from)
    if ($NewIndex -lt 0) { $NewIndex = 0 }
    if ($NewIndex -gt $list.Count) { $NewIndex = $list.Count }
    if ($NewIndex -eq $from) { return }
    $list.Insert($NewIndex, $Name)
    Save-VideoOrder $Root $list.ToArray()
    Refresh-Videos
    foreach ($it in $ctrls['VidList'].Items) {
        if ([string]$it.Name -eq $Name) { $ctrls['VidList'].SelectedItem = $it; break }
    }
}

$script:VidExts = @('.mp4','.mov','.m4v','.avi','.mkv','.webm')
# A clip is "ready" (no conversion needed) only if it's already H.264 8-bit in an
# .mp4 container. Anything else - iPhone HEVC/10-bit .MOV, other codecs/containers -
# gets transcoded to H.264 mp4 so it shows in the list, previews in the editor, and
# runs through the pipeline.
function Test-NativeReady([string]$path) {
    if ([System.IO.Path]::GetExtension($path).ToLower() -ne '.mp4') { return $false }
    try {
        $codec = (& ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$path" 2>$null | Select-Object -First 1)
        $pix   = (& ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt   -of csv=p=0 "$path" 2>$null | Select-Object -First 1)
        return (("$codec".Trim() -eq 'h264') -and ("$pix".Trim() -eq 'yuv420p'))
    } catch { return $false }
}
function Import-VideoFiles($paths) {
    if ($script:proc) { Write-LogLine "Please wait for the current step to finish before adding files."; return }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    # expand any dropped folders into the video files they contain
    $files = @()
    foreach ($f in $paths) {
        if (Test-Path -LiteralPath $f -PathType Container) {
            $files += (Get-ChildItem -LiteralPath $f -File | Where-Object { $script:VidExts -contains $_.Extension.ToLower() } | ForEach-Object { $_.FullName })
        } else { $files += $f }
    }
    $n = 0
    $toConvert = @()
    foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $leaf = [System.IO.Path]::GetFileName($f)
        if ($script:VidExts -notcontains ([System.IO.Path]::GetExtension($f).ToLower())) { Write-LogLine "Skipped (not a video): $leaf"; continue }
        if (Test-NativeReady $f) {
            try { Copy-Item -LiteralPath $f -Destination (Join-Path $OutDir $leaf) -Force; Write-LogLine "Added: $leaf"; $n++ }
            catch { Write-LogLine ("Could not add $leaf : " + $_.Exception.Message) }
        } else {
            $toConvert += $f
            Write-LogLine "Queued for conversion to mp4: $leaf"
        }
    }
    if ($n) { Write-LogLine "$n video(s) added." }
    Refresh-Videos
    if ($toConvert.Count -gt 0) {
        $workDir = Join-Path $Root 'work'; New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        $listPath = Join-Path $workDir 'convert-list.txt'
        [System.IO.File]::WriteAllLines($listPath, [string[]]$toConvert, (Utf8NoBom))
        Write-LogLine "Converting $($toConvert.Count) clip(s) to editable mp4 (GPU)..."
        Start-Task "Convert clips" 'Convert-Imports.ps1' @('-ListFile', $listPath) $null
    } elseif ($n) { Write-LogLine "" }
}
function Add-Videos {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = "Choose video clips to add"
    $dlg.Filter = "Videos (*.mp4;*.mov;*.m4v)|*.mp4;*.mov;*.m4v|All files (*.*)|*.*"
    $dlg.Multiselect = $true
    if ($dlg.ShowDialog()) { Import-VideoFiles $dlg.FileNames }
}
function Play-Selected {
    $sel = $ctrls['VidList'].SelectedItem
    if (-not $sel) { return }
    # Play the MOST RECENTLY MADE version, not the "most finished" one - otherwise
    # an old export can shadow a clip you just re-captioned/re-burned, so you'd be
    # watching stale captions without realising it.
    $cands = @()
    foreach ($d in @($UploadDir, $MusicOutDir, $CaptionedDir, $OutDir)) {
        $p = Join-Path $d $sel.Name
        if (Test-Path $p) { $cands += (Get-Item $p) }
    }
    if ($cands.Count -eq 0) { Write-LogLine "Could not find a file to play for $($sel.Name)."; return }
    $newest = ($cands | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    $stage = switch ($newest.DirectoryName) {
        $UploadDir    { 'finished/upload' }
        $MusicOutDir  { 'with music' }
        $CaptionedDir { 'captioned' }
        default       { 'original' }
    }
    Write-LogLine "Playing newest version ($stage): $($sel.Name)"
    Start-Process $newest.FullName
}
function Rename-Selected {
    if ($script:proc) { Write-LogLine "Finish the current step before renaming."; return }
    $sel = $ctrls['VidList'].SelectedItem
    if (-not $sel) { return }
    $oldName = [string]$sel.Name
    $oldBase = [System.IO.Path]::GetFileNameWithoutExtension($oldName)
    $ext     = [System.IO.Path]::GetExtension($oldName)
    $answer  = [Microsoft.VisualBasic.Interaction]::InputBox("New name (without the file extension):", "Rename video", $oldBase)
    if ([string]::IsNullOrWhiteSpace($answer)) { return }
    $newBase = $answer.Trim()
    foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) { $newBase = $newBase.Replace([string]$ch, '') }
    if (-not $newBase -or $newBase -eq $oldBase) { return }
    $newName = $newBase + $ext
    if (Test-Path (Join-Path $OutDir $newName)) {
        [System.Windows.MessageBox]::Show("A video named '$newName' already exists.", "Rename") | Out-Null; return
    }
    # rename the video AND everything linked to it, across every stage folder
    $full = Join-Path $OutDir '_full-length'
    $pairs = @(
        @{ From = (Join-Path $OutDir $oldName);       To = (Join-Path $OutDir $newName) },
        @{ From = (Join-Path $OutDir "$oldBase.srt"); To = (Join-Path $OutDir "$newBase.srt") },
        @{ From = (Join-Path $CaptionedDir $oldName); To = (Join-Path $CaptionedDir $newName) },
        @{ From = (Join-Path $MusicOutDir  $oldName); To = (Join-Path $MusicOutDir  $newName) },
        @{ From = (Join-Path $UploadDir    $oldName); To = (Join-Path $UploadDir    $newName) },
        @{ From = (Join-Path $full         $oldName); To = (Join-Path $full         $newName) }
    )
    $moved = 0
    foreach ($p in $pairs) {
        if (Test-Path -LiteralPath $p.From) {
            try { Move-Item -LiteralPath $p.From -Destination $p.To -Force; $moved++ }
            catch { Write-LogLine ("Could not rename " + [System.IO.Path]::GetFileName($p.From) + " : " + $_.Exception.Message) }
        }
    }
    Write-LogLine "Renamed '$oldBase' to '$newBase' ($moved file(s) updated)."
    # Keep the clip where you put it: swap the name in place instead of letting
    # Refresh-Videos treat it as a brand-new file and drop it to the bottom.
    $ord = @(Read-VideoOrder $Root)
    if ($ord.Count) {
        Save-VideoOrder $Root @($ord | ForEach-Object { if ($_ -eq $oldName) { $newName } else { $_ } })
    }
    Refresh-Videos
}
# Delete one video plus every file made from it (captions, burned, music, finished
# and full-length copies). Shared by Remove (one clip) and Clear all (every clip).
# Returns @{ Removed = <count deleted>; Locked = @(<paths still open in a player>) }.
function Remove-VideoFiles([string]$name) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
    $full = Join-Path $OutDir '_full-length'
    $targets = @(
        (Join-Path $OutDir $name),
        (Join-Path $OutDir "$base.srt"),
        (Join-Path $CaptionedDir $name),
        (Join-Path $MusicOutDir  $name),
        (Join-Path $UploadDir     $name),
        (Join-Path $full          $name)
    )
    $removed = 0; $locked = @()
    foreach ($t in $targets) {
        if (Test-Path -LiteralPath $t) {
            if (Remove-FileHard $t) { $removed++ } else { $locked += $t }
        }
    }
    return @{ Removed = $removed; Locked = $locked }
}
function Remove-Selected {
    if ($script:proc) { Write-LogLine "Finish the current step before removing a video."; return }
    $sel = $ctrls['VidList'].SelectedItem
    if (-not $sel) { return }
    $name = [string]$sel.Name
    $r = [System.Windows.MessageBox]::Show(
        "Remove '$name' from the studio?`n`nThis deletes the video and its captions, plus any burned, music and finished copies. It cannot be undone.",
        "Remove video", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }
    $res     = Remove-VideoFiles $name
    $removed = $res.Removed
    $locked  = $res.Locked
    if ($locked.Count -gt 0) {
        Write-LogLine ("Removed '$name' ($removed file(s) deleted). " + $locked.Count + " file(s) are open in another program.")
        $which = ($locked | ForEach-Object { [System.IO.Path]::GetFileName((Split-Path -Parent $_)) + "\" + [System.IO.Path]::GetFileName($_) }) -join "`n  "
        [System.Windows.MessageBox]::Show(
            "These file(s) couldn't be deleted because a video player still has them open:`n`n  $which`n`nClose the video player (or the preview window), then right-click the clip and Remove again.",
            "File in use", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    } else {
        Write-LogLine "Removed '$name' ($removed file(s) deleted)."
    }
    Refresh-Videos
}

# Empty the whole studio in one go (so you don't right-click Remove each clip).
# Deletes every video and everything made from it; leaves your export folder alone.
function Clear-AllVideos {
    if ($script:proc) { Write-LogLine "Finish the current step before clearing."; return }
    $vids = Get-ChildItem -Path $OutDir -Filter *.mp4 -File -ErrorAction SilentlyContinue | Sort-Object Name
    if (-not $vids -or $vids.Count -eq 0) { $status.Text = "Nothing to clear."; Write-LogLine "Nothing to clear."; return }
    $n = $vids.Count
    $r = [System.Windows.MessageBox]::Show(
        "Remove all $n video(s) and everything made from them?`n`nThis deletes every video, its captions, and any burned, music and finished copies. It cannot be undone.`n`n(Your exported files in your chosen folder are NOT touched.)",
        "Clear all", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }
    $totRemoved = 0; $locked = @()
    foreach ($v in $vids) {
        $res = Remove-VideoFiles $v.Name
        $totRemoved += $res.Removed
        $locked     += $res.Locked
    }
    if ($locked.Count -gt 0) {
        Write-LogLine ("Cleared the studio ($totRemoved file(s) deleted). " + $locked.Count + " file(s) were open in another program and remain.")
        [System.Windows.MessageBox]::Show(
            "Some files couldn't be deleted because a video player still has them open.`n`nClose any open player or preview window, then click 'Clear all' again.",
            "File in use", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    } else {
        Write-LogLine "Cleared all $n video(s) ($totRemoved file(s) deleted)."
    }
    $status.Text = "Cleared $n video(s)."
    Refresh-Videos
}

# Delete a file even if it's marked read-only; retry a few times in case a player
# is just now releasing its lock. Returns $true on success, $false if still locked.
function Remove-FileHard([string]$path) {
    for ($i = 0; $i -lt 4; $i++) {
        try {
            $fi = New-Object System.IO.FileInfo $path
            if ($fi.IsReadOnly) { $fi.IsReadOnly = $false }
            [System.IO.File]::Delete($path)
            return $true
        } catch {
            if ($i -lt 3) { Start-Sleep -Milliseconds 250 } else { return $false }
        }
    }
    return $false
}


