# Studio.ps1  -  "Video Studio": one window that runs the whole workflow.
# Launched (with no console) by  Video Studio.vbs  /  the desktop shortcut.
#
# Everything happens INSIDE this app: your videos are listed here, captions and
# music are edited here - no Explorer folders and no Notepad pop-ups.

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName Microsoft.VisualBasic

# Give this window its OWN taskbar identity (AppUserModelID) so Windows treats it
# as "Video Studio" - it groups under our icon instead of generic PowerShell, and
# a taskbar pin resolves to our shortcut/launcher instead of a bare powershell.exe
# (which is what made the pinned icon open an empty terminal).
$script:AppId = 'NachumMarkov.VideoStudio'
try {
    Add-Type -Namespace VS -Name Shell -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", PreserveSig=false)]
public static extern void SetCurrentProcessExplicitAppUserModelID(
    [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string AppID);
'@ -ErrorAction Stop
    [VS.Shell]::SetCurrentProcessExplicitAppUserModelID($script:AppId)
} catch {}

$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$OutDir       = Join-Path $Root 'output'
$UploadDir    = Join-Path $OutDir 'upload'
$CaptionedDir = Join-Path $OutDir 'captioned'
$MusicOutDir  = Join-Path $OutDir 'with-music'
$MusicDir     = Join-Path $Root 'music'
$MapFile      = Join-Path $Root 'music-map.txt'
$ExportSettingsFile = Join-Path $Root 'export-settings.txt'   # remembers your chosen export folder
$AudioExts    = @('.mp3','.wav','.m4a','.aac','.flac','.ogg','.wma')
$BrollDir     = Join-Path $Root 'broll'      # cutaway clips and photos you keep around
foreach ($d in @($OutDir, $MusicDir, $BrollDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# Shared helpers, each owning one thing. Order matters only where a file uses
# another at LOAD time; everything else resolves when it's called.
. (Join-Path $Root 'UiHelpers.ps1')        # New-Win / Utf8NoBom / Format-Clock
. (Join-Path $Root 'Release.ps1')          # what counts as a program file, versions, manifests
. (Join-Path $Root 'Updater.ps1')          # "there's a newer version" inside the app
. (Join-Path $Root 'ContentKey.ps1')       # cache keys for generated files
. (Join-Path $Root 'ProcessRunner.ps1')    # child processes that can't deadlock or lose their result
. (Join-Path $Root 'VideoOrder.ps1')       # the order "Your videos" is in (video-order.txt)
. (Join-Path $Root 'StudioSettings.ps1')   # remembered UI choices (studio-settings.txt)
. (Join-Path $Root 'CaptionMarkup.ps1')    # the *star* emphasis transform (Ctrl+B)
. (Join-Path $Root 'SrtDocument.ps1')      # .srt <-> cue objects
. (Join-Path $Root 'VideoColor.ps1')       # keep HDR/BT.2020 clips looking like themselves
. (Join-Path $Root 'ThumbCache.ps1')       # filmstrips on disk
. (Join-Path $Root 'PreviewProxy.ps1')     # small fast-seeking stand-ins for previewing
. (Join-Path $Root 'BrollLibrary.ps1')
. (Join-Path $Root 'SharedLibrary.ps1')    # b-roll/music kept in step with the other computer
. (Join-Path $Root 'SharedLibraryUi.ps1')  # ...and the toolbar button that runs it
. (Join-Path $Root 'Chime.ps1')            # the struck-bell tones a finished step plays
. (Join-Path $Root 'JobRunner.ps1')        # one pipeline step at a time + the finish chimes
. (Join-Path $Root 'VideoList.ps1')        # "Your videos" and everything you can do to a row
. (Join-Path $Root 'MusicDialog.ps1')      # the background-music picker
. (Join-Path $Root 'EditorRender.ps1')     # project -> ffmpeg filtergraph, project files
. (Join-Path $Root 'EditorExport.ps1')     # rendering the timeline into Your videos
. (Join-Path $Root 'CaptionColors.ps1')     # emphasis colours you can paint words with
. (Join-Path $Root 'CaptionUndo.ps1')       # undo/redo over caption text
. (Join-Path $Root 'CaptionPlayer.ps1')     # the caption editor's video half
. (Join-Path $Root 'CaptionEditor.ps1')     # the "Edit captions" window
. (Join-Path $Root 'EditorHost.ps1')       # the WebView2 editor screen + its bridge

# ============================================================ EDITOR ENGINE
# The in-window video editor is a WebView2 (Edge) control hosting a local HTML
# canvas + ffmpeg. Load its SDK assemblies now; prepend the folder to PATH so the
# native WebView2Loader.dll resolves without changing the process working dir.
$WebView2Dir = Join-Path $Root 'tools\webview2'
$script:EditorEngineReady = $false

# A machine that got ffmpeg from the installer has it here rather than on the
# system PATH. Putting it on THIS process's PATH is enough for every engine
# script too, because they run as child processes and inherit it.
$LocalFfmpeg = Join-Path $Root 'tools\ffmpeg\bin'
if (Test-Path -LiteralPath (Join-Path $LocalFfmpeg 'ffmpeg.exe')) { $env:Path = "$LocalFfmpeg;$env:Path" }

try {
    $env:Path = "$WebView2Dir;$env:Path"
    Add-Type -Path (Join-Path $WebView2Dir 'Microsoft.Web.WebView2.Core.dll')
    Add-Type -Path (Join-Path $WebView2Dir 'Microsoft.Web.WebView2.Wpf.dll')
    $script:EditorEngineReady = $true
} catch { $script:EditorEngineReady = $false }

# ============================================================ THIN SCROLLBARS
# Replace Windows' chunky default scrollbars (arrows + wide track) with a slim,
# rounded overlay thumb. Registered as an IMPLICIT ScrollBar style in the app's
# resources so it applies everywhere at once - the main window AND every dialog
# (caption editor, music), plus combo-box / list dropdowns.
if (-not [System.Windows.Application]::Current) { New-Object System.Windows.Application | Out-Null }
try {
    $sbXaml = @"
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Style TargetType="{x:Type ScrollBar}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Width" Value="9"/>
    <Setter Property="MinWidth" Value="9"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="{x:Type ScrollBar}">
          <Grid Background="{TemplateBinding Background}">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb x:Name="PART_Thumb" MinHeight="30">
                  <Thumb.Template>
                    <ControlTemplate TargetType="{x:Type Thumb}">
                      <Border x:Name="tb" CornerRadius="4" Background="#B4C0BC" Margin="2"/>
                      <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                          <Setter TargetName="tb" Property="Background" Value="#7FA79E"/>
                        </Trigger>
                        <Trigger Property="IsDragging" Value="True">
                          <Setter TargetName="tb" Property="Background" Value="#3D9E8E"/>
                        </Trigger>
                      </ControlTemplate.Triggers>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="Orientation" Value="Horizontal">
              <Setter Property="Width" Value="Auto"/>
              <Setter Property="MinWidth" Value="0"/>
              <Setter Property="Height" Value="9"/>
              <Setter Property="MinHeight" Value="9"/>
              <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
              <Setter TargetName="PART_Thumb" Property="MinHeight" Value="0"/>
              <Setter TargetName="PART_Thumb" Property="MinWidth" Value="30"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</ResourceDictionary>
"@
    $sbReader = New-Object System.Xml.XmlNodeReader ([xml]$sbXaml)
    $sbDict   = [Windows.Markup.XamlReader]::Load($sbReader)
    [System.Windows.Application]::Current.Resources.MergedDictionaries.Add($sbDict)
} catch {}

# ================================================================ MAIN WINDOW
# The window itself is authored as XAML in ui\main-window.xaml. Keeping ~290
# lines of markup out of here is what lets this file stay about behaviour.
$win = New-Win ([System.IO.File]::ReadAllText((Join-Path $Root 'ui\main-window.xaml')))

# app icon (title bar + taskbar)
$IconPath = Join-Path $Root 'VideoStudio.ico'
if (Test-Path $IconPath) {
    try {
        $ib = New-Object System.Windows.Media.Imaging.BitmapImage
        $ib.BeginInit()
        $ib.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $ib.UriSource   = New-Object System.Uri($IconPath)
        $ib.EndInit()
        $win.Icon = $ib
    } catch {}
}

$ctrls = @{}
foreach ($n in 'BtnAdd','BtnRefresh','BtnClearAll','BtnEditor','BtnCaptions','BtnEditCaps','CmbStyle','CmbPos','BtnBurn',
                'BtnMusic','BtnExport','BtnSendOut','BtnExportDest','LblExportDest',
                'ChkRecap','ChkReburn','ChkFourK','VidList','Log','Status',
                'EditorOverlay','EditorWebHost','BtnEditorBack','BtnUpdate','BtnSharedLib') { $ctrls[$n] = $win.FindName($n) }
$log    = $ctrls['Log']
$status = $ctrls['Status']

$script:jobButtons = @($ctrls['BtnAdd'],$ctrls['BtnEditor'],$ctrls['BtnCaptions'],$ctrls['BtnEditCaps'],
                       $ctrls['BtnBurn'],$ctrls['BtnMusic'],$ctrls['BtnExport'],
                       $ctrls['BtnSendOut'],$ctrls['BtnExportDest'],$ctrls['BtnClearAll'],
                       $ctrls['BtnSharedLib'])
# ---------------------------------------------------------------- wire buttons
$ctrls['BtnAdd'].Add_Click({ Add-Videos })
$ctrls['BtnRefresh'].Add_Click({ Refresh-Videos })
$ctrls['BtnClearAll'].Add_Click({ Clear-AllVideos })
$ctrls['BtnUpdate'].Add_Click({ Install-AvailableUpdate $Root })
$ctrls['BtnSharedLib'].Add_Click({ Sync-Library })
$ctrls['VidList'].Add_MouseDoubleClick({ Play-Selected })

# ---- reorder "Your videos" by dragging a row (or Alt+Up / Alt+Down) ----------
# The order you set here is saved to video-order.txt and is the order EVERY step
# processes clips in, so the clip at the top gets captioned/burned/mixed first.
$VidRowFormat = 'VideoStudio.VideoRow'
$ctrls['VidList'].AllowDrop = $true
$script:rowDragFrom = $null
$ctrls['VidList'].Add_PreviewMouseLeftButtonDown({ param($s,$e)
    $script:rowDragFrom = $e.GetPosition($s)
})
$ctrls['VidList'].Add_MouseMove({ param($s,$e)
    if ($e.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
    if ($null -eq $script:rowDragFrom) { return }
    $pos = $e.GetPosition($s)
    # don't start a drag on a click or a double-click - only on a real drag
    if ([math]::Abs($pos.X - $script:rowDragFrom.X) -lt [System.Windows.SystemParameters]::MinimumHorizontalDragDistance -and
        [math]::Abs($pos.Y - $script:rowDragFrom.Y) -lt [System.Windows.SystemParameters]::MinimumVerticalDragDistance) { return }
    $row = Get-RowAtPoint $s $script:rowDragFrom
    $script:rowDragFrom = $null
    if (-not $row -or -not $row.Content) { return }
    $data = New-Object System.Windows.DataObject($VidRowFormat, [string]$row.Content.Name)
    [void][System.Windows.DragDrop]::DoDragDrop($s, $data, [System.Windows.DragDropEffects]::Move)
})
$ctrls['VidList'].Add_DragOver({ param($s,$e)
    if ($e.Data.GetDataPresent($VidRowFormat)) { $e.Effects = [System.Windows.DragDropEffects]::Move }
    else { $e.Effects = [System.Windows.DragDropEffects]::None }
    $e.Handled = $true
})
$ctrls['VidList'].Add_Drop({ param($s,$e)
    if (-not $e.Data.GetDataPresent($VidRowFormat)) { return }
    $e.Handled = $true
    $name  = [string]$e.Data.GetData($VidRowFormat)
    $names = @(@($s.ItemsSource) | ForEach-Object { [string]$_.Name })
    $row   = Get-RowAtPoint $s ($e.GetPosition($s))
    if ($row -and $row.Content) {
        $ti = [array]::IndexOf($names, [string]$row.Content.Name)
        # top half of the target row = drop above it, bottom half = below it
        $insert = if (($e.GetPosition($row)).Y -gt ($row.ActualHeight / 2)) { $ti + 1 } else { $ti }
    } else {
        $insert = $names.Count      # dropped past the last row = send to the bottom
    }
    # pulling the dragged row out first shifts everything below it up one
    $from = [array]::IndexOf($names, $name)
    if ($from -ge 0 -and $from -lt $insert) { $insert-- }
    Move-VideoTo $name $insert
})
$ctrls['VidList'].Add_PreviewKeyDown({ param($s,$e)
    if (($e.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Alt) -eq 0) { return }
    $sel = $s.SelectedItem
    if (-not $sel) { return }
    # with Alt held, WPF reports Key.System and puts the real key in SystemKey
    $key = $e.Key
    if ($key -eq [System.Windows.Input.Key]::System) { $key = $e.SystemKey }
    $names = @(@($s.ItemsSource) | ForEach-Object { [string]$_.Name })
    $i = [array]::IndexOf($names, [string]$sel.Name)
    if ($i -lt 0) { return }
    if ($key -eq [System.Windows.Input.Key]::Up -and $i -gt 0) {
        Move-VideoTo ([string]$sel.Name) ($i - 1); $e.Handled = $true
    } elseif ($key -eq [System.Windows.Input.Key]::Down -and $i -lt ($names.Count - 1)) {
        Move-VideoTo ([string]$sel.Name) ($i + 1); $e.Handled = $true
    }
})
# ---------------------------------------------------------------- editor screen
# The editor lives in EditorHost.ps1; this is only the door to it.
$ctrls['BtnEditor'].Add_Click({
    if ($script:proc) { Write-LogLine "Please wait for the current step to finish."; return }
    $ctrls['EditorOverlay'].Visibility = 'Visible'
    if ($script:editorWeb -and $script:editorWeb.CoreWebView2) {
        # already open before - re-scan so newly added clips appear in the media bin
        Send-EditorMessage @{ type = 'reScan' }
    } else {
        Initialize-Editor $ctrls['EditorWebHost']
    }
})
$ctrls['BtnEditorBack'].Add_Click({
    $ctrls['EditorOverlay'].Visibility = 'Collapsed'
    try { Refresh-Videos } catch {}
})
$ctrls['BtnCaptions'].Add_Click({
    $a = @()
    if ($ctrls['ChkRecap'].IsChecked) { $a += '-Force' }
    Start-Task "Make captions" 'Make-Captions.ps1' $a $null
})
$ctrls['BtnEditCaps'].Add_Click({
    Show-CaptionEditor -Root $Root -OutDir $OutDir -Owner $win -VideoExtensions $script:VidExts
    Refresh-Videos
})
$ctrls['BtnBurn'].Add_Click({
    $style = if ($ctrls['CmbStyle'].SelectedIndex -eq 1) { 'karaoke' } else { 'highlight' }
    $pos   = if ($ctrls['CmbPos'].SelectedItem) { [string]$ctrls['CmbPos'].SelectedItem.Content } else { 'Middle' }
    $place = Get-CaptionPlacement $pos
    Set-StudioSetting $Root 'CaptionPosition' $pos      # remember it for next time
    $a = @('-Style', $style, '-Alignment', $place.Alignment, '-MarginV', $place.MarginV)
    if ($ctrls['ChkReburn'].IsChecked) { $a += '-Force' }
    Start-Task "Burn captions ($style, $pos)" 'Burn-Captions.ps1' $a $null
})
$ctrls['BtnMusic'].Add_Click({ Show-MusicDialog })
$ctrls['BtnExport'].Add_Click({
    $a = @('-SourceDir', (Export-Source))
    if ($ctrls['ChkFourK'].IsChecked) { $a += '-FourK' }
    Start-Task "Finish clips" 'Export-ForUpload.ps1' $a $null
})
$ctrls['BtnSendOut'].Add_Click({ Export-Finished })
$ctrls['BtnExportDest'].Add_Click({ Change-ExportDest })

# Refresh the video list whenever the window regains focus, so a clip exported
# from the editor (which runs as its own process/window) shows up automatically
# when the user switches back here.
$win.Add_Activated({ try { Refresh-Videos } catch {} })

# Drag files anywhere onto the window to add them
$win.Add_PreviewDragOver({ param($s,$e)
    # An internal row reorder is NOT a file drop - bail out without marking it
    # handled so the video list's own DragOver/Drop get to see it.
    if ($e.Data.GetDataPresent('VideoStudio.VideoRow')) { return }
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { $e.Effects = [System.Windows.DragDropEffects]::Copy }
    else { $e.Effects = [System.Windows.DragDropEffects]::None }
    $e.Handled = $true
})
$win.Add_PreviewDrop({ param($s,$e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $e.Handled = $true
        Import-VideoFiles ($e.Data.GetData([System.Windows.DataFormats]::FileDrop))
    }
})

# Right-click a video for Play / Rename
$menu = New-Object System.Windows.Controls.ContextMenu
$miPlay = New-Object System.Windows.Controls.MenuItem;   $miPlay.Header   = 'Play';       $miPlay.Add_Click({ Play-Selected })
$miRen  = New-Object System.Windows.Controls.MenuItem;   $miRen.Header    = 'Rename...';  $miRen.Add_Click({ Rename-Selected })
$miDel  = New-Object System.Windows.Controls.MenuItem;   $miDel.Header    = 'Remove...';  $miDel.Add_Click({ Remove-Selected })
[void]$menu.Items.Add($miPlay); [void]$menu.Items.Add($miRen)
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
[void]$menu.Items.Add($miDel)
$ctrls['VidList'].ContextMenu = $menu
# make right-click select the row under the cursor first
$ctrls['VidList'].Add_PreviewMouseRightButtonDown({ param($s,$e)
    $dep = $e.OriginalSource
    while ($dep -and -not ($dep -is [System.Windows.Controls.ListViewItem])) {
        $dep = [System.Windows.Media.VisualTreeHelper]::GetParent($dep)
    }
    if ($dep -is [System.Windows.Controls.ListViewItem]) { $dep.IsSelected = $true }
})

Write-LogLine ("Video Studio " + (Get-AppVersion $Root))
Write-LogLine "Welcome. Click '+ Add videos' to bring in your clips, then work down steps 1-6."
Write-LogLine "Your videos and their progress show in the middle. Nothing leaves your computer."
Write-LogLine ""
Update-ExportLabel
Refresh-Videos

# restore the caption position you burned with last time (default: Middle)
$savedPos = Get-StudioSetting $Root 'CaptionPosition' 'Middle'
foreach ($it in $ctrls['CmbPos'].Items) {
    if ([string]$it.Content -eq $savedPos) { $ctrls['CmbPos'].SelectedItem = $it; break }
}

# Ask - quietly, in the background - whether there's a newer version. Nothing
# is shown unless there is; see Updater.ps1.
Start-UpdateCheck $Root

[void]$win.ShowDialog()
