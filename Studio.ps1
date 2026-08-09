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

# Shared helpers: the order you arrange "Your videos" in (video-order.txt), the
# remembered UI choices (studio-settings.txt), and the *star* emphasis transform
# used by the caption editor's Ctrl+B.
. (Join-Path $Root 'VideoOrder.ps1')
. (Join-Path $Root 'StudioSettings.ps1')
. (Join-Path $Root 'CaptionMarkup.ps1')
. (Join-Path $Root 'ThumbCache.ps1')
. (Join-Path $Root 'BrollLibrary.ps1')

# ============================================================ EDITOR ENGINE
# The in-window video editor is a WebView2 (Edge) control hosting a local HTML
# canvas + ffmpeg. Load its SDK assemblies now; prepend the folder to PATH so the
# native WebView2Loader.dll resolves without changing the process working dir.
$WebView2Dir = Join-Path $Root 'tools\webview2'
$script:EditorEngineReady = $false
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
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Video Studio" Height="780" Width="1180" MinHeight="660" MinWidth="1040"
        WindowStartupLocation="CenterScreen" Background="#FFFFFF" FontFamily="Segoe UI" AllowDrop="True">
  <Window.Resources>
    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="#3D9E8E"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6"
                    Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#348778"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Background" Value="#BFD6D0"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Secondary" TargetType="Button" BasedOn="{StaticResource Primary}">
      <Setter Property="Foreground" Value="#2C6B60"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6"
                    BorderBrush="#3D9E8E" BorderThickness="1"
                    Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#EAF4F1"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Background" Value="#F0F0F0"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#F7F9F9"/>
      <Setter Property="BorderBrush" Value="#E3E8E7"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="14"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="StepTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#1A1A1A"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="StepDesc" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Foreground" Value="#5B6A66"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,3,0,9"/>
    </Style>
    <Style x:Key="Badge" TargetType="Border">
      <Setter Property="Background" Value="#3D9E8E"/>
      <Setter Property="Width" Value="24"/><Setter Property="Height" Value="24"/>
      <Setter Property="CornerRadius" Value="12"/><Setter Property="Margin" Value="0,0,9,0"/>
    </Style>
    <Style x:Key="BadgeText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="White"/><Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="HorizontalAlignment" Value="Center"/><Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <!-- status column cell: green "yes", orange bold "redo", grey "-" -->
    <Style x:Key="StatusCell" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#9AA6A3"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding Text, RelativeSource={RelativeSource Self}}" Value="yes">
          <Setter Property="Foreground" Value="#2E9E63"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Text, RelativeSource={RelativeSource Self}}" Value="redo">
          <Setter Property="Foreground" Value="#D9822B"/>
          <Setter Property="FontWeight" Value="Bold"/>
        </DataTrigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Grid>
  <DockPanel>
    <!-- Header -->
    <Border DockPanel.Dock="Top" Background="#3D9E8E" Padding="20,14">
      <StackPanel>
        <TextBlock Text="Video Studio" Foreground="White" FontSize="22" FontWeight="Bold"/>
        <TextBlock Text="Add your clips, then work down the steps. Everything happens right here."
                   Foreground="#E8F5F1" FontSize="12" Margin="0,2,0,0"/>
      </StackPanel>
    </Border>

    <!-- Toolbar -->
    <Border DockPanel.Dock="Top" Background="#EEF3F2" Padding="16,10">
      <StackPanel Orientation="Horizontal">
        <Button x:Name="BtnAdd" Style="{StaticResource Primary}" Content="+  Add videos"/>
        <Button x:Name="BtnRefresh" Style="{StaticResource Secondary}" Content="Refresh"/>
        <Button x:Name="BtnClearAll" Style="{StaticResource Secondary}" Content="Clear all" Margin="24,0,0,0"/>
      </StackPanel>
    </Border>

    <!-- Status bar -->
    <Border DockPanel.Dock="Bottom" Background="#F2F2F2" Padding="16,8">
      <TextBlock x:Name="Status" Text="Ready" Foreground="#444444" FontSize="12"/>
    </Border>

    <!-- Body: steps | videos | log -->
    <Grid Margin="16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="360"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="300"/>
      </Grid.ColumnDefinitions>

      <!-- STEPS -->
      <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto">
        <StackPanel>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <Border Style="{StaticResource Badge}"><TextBlock Style="{StaticResource BadgeText}" Text="1"/></Border>
                <TextBlock Style="{StaticResource StepTitle}" Text="1. Edit / Assemble"/>
              </StackPanel>
              <TextBlock Style="{StaticResource StepDesc}"
                Text="Cut, trim, split and layer your video (B-roll, photos, audio) in the editor."/>
              <Button x:Name="BtnEditor" Style="{StaticResource Primary}" Content="Open editor" HorizontalAlignment="Left"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <Border Style="{StaticResource Badge}"><TextBlock Style="{StaticResource BadgeText}" Text="2"/></Border>
                <TextBlock Style="{StaticResource StepTitle}" Text="Make captions"/>
              </StackPanel>
              <TextBlock Style="{StaticResource StepDesc}"
                Text="Transcribes each video on your computer, in sync with your voice. Then fix the wording here."/>
              <StackPanel Orientation="Horizontal">
                <Button x:Name="BtnCaptions" Style="{StaticResource Primary}" Content="Make captions"/>
                <Button x:Name="BtnEditCaps" Style="{StaticResource Secondary}" Content="Edit captions"/>
              </StackPanel>
              <CheckBox x:Name="ChkRecap" Foreground="#444" Margin="0,8,0,0">
                <TextBlock Text="Re-make captions (redo already-captioned clips)" TextWrapping="Wrap"/>
              </CheckBox>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <Border Style="{StaticResource Badge}"><TextBlock Style="{StaticResource BadgeText}" Text="3"/></Border>
                <TextBlock Style="{StaticResource StepTitle}" Text="Burn captions onto the video"/>
              </StackPanel>
              <TextBlock Style="{StaticResource StepDesc}"
                Text="Prints the captions onto the picture (Reels / TikTok style)."/>
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="Style:" VerticalAlignment="Center" Margin="0,0,8,0" Foreground="#444"/>
                <ComboBox x:Name="CmbStyle" Width="215" VerticalContentAlignment="Center">
                  <ComboBoxItem Content="Regular (white, *starred* teal)" IsSelected="True"/>
                  <ComboBoxItem Content="Karaoke (each word pops teal)"/>
                </ComboBox>
              </StackPanel>
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="0,8,0,0">
                <TextBlock Text="Position:" VerticalAlignment="Center" Margin="0,0,8,0" Foreground="#444"/>
                <ComboBox x:Name="CmbPos" Width="120" VerticalContentAlignment="Center">
                  <ComboBoxItem Content="Bottom"/>
                  <ComboBoxItem Content="Middle" IsSelected="True"/>
                  <ComboBoxItem Content="Top"/>
                </ComboBox>
                <TextBlock Text="  Middle puts the words on your chest, not your legs." VerticalAlignment="Center" Foreground="#5B6A66" FontSize="11.5"/>
              </StackPanel>
              <WrapPanel Margin="0,10,0,0">
                <Button x:Name="BtnBurn" Style="{StaticResource Primary}" Content="Burn"/>
                <CheckBox x:Name="ChkReburn" Content="Re-burn already-burned clips" VerticalAlignment="Center" Foreground="#444" Margin="4,4,0,0"/>
              </WrapPanel>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <Border Style="{StaticResource Badge}"><TextBlock Style="{StaticResource BadgeText}" Text="4"/></Border>
                <TextBlock Style="{StaticResource StepTitle}" Text="Background music  (optional)"/>
              </StackPanel>
              <TextBlock Style="{StaticResource StepDesc}"
                Text="Pick a track for each video and mix a quiet bed under your voice - all in one window."/>
              <Button x:Name="BtnMusic" Style="{StaticResource Primary}" Content="Background music" HorizontalAlignment="Left"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <Border Style="{StaticResource Badge}"><TextBlock Style="{StaticResource BadgeText}" Text="5"/></Border>
                <TextBlock Style="{StaticResource StepTitle}" Text="Finish for social media"/>
              </StackPanel>
              <TextBlock Style="{StaticResource StepDesc}"
                Text="Finishes each clip with the best YouTube / Instagram upload settings, using your most finished version of each clip."/>
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="BtnExport" Style="{StaticResource Primary}" Content="Finish clips"/>
                <CheckBox x:Name="ChkFourK" Content="Upscale to 4K" VerticalAlignment="Center" Foreground="#444" Margin="4,0,0,0"/>
              </StackPanel>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <Border Style="{StaticResource Badge}"><TextBlock Style="{StaticResource BadgeText}" Text="6"/></Border>
                <TextBlock Style="{StaticResource StepTitle}" Text="Export to your folder"/>
              </StackPanel>
              <TextBlock Style="{StaticResource StepDesc}"
                Text="Copies all your finished videos to a folder you choose (the originals stay here). Set the folder once, then it's one click."/>
              <Button x:Name="BtnSendOut" Style="{StaticResource Primary}" Content="Export finished videos" HorizontalAlignment="Left"/>
              <TextBlock x:Name="LblExportDest" TextWrapping="Wrap" FontSize="11.5" Foreground="#5B6A66" Margin="0,8,0,0" Text="No folder set yet."/>
              <Button x:Name="BtnExportDest" Style="{StaticResource Secondary}" Content="Change folder..." HorizontalAlignment="Left" Margin="0,6,0,0"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- VIDEO LIST -->
      <DockPanel Grid.Column="2">
        <TextBlock DockPanel.Dock="Top" Text="Your videos" FontSize="15" FontWeight="Bold" Foreground="#1A1A1A" Margin="0,0,0,2"/>
        <TextBlock DockPanel.Dock="Top" x:Name="VidHint" Text="Drag video files onto this window to add them.  Double-click to play (opens your newest version), right-click to rename.  Drag a row (or Alt+Up / Alt+Down) to re-order - every step runs top to bottom in this order.  In each step column: yes = done, redo = something changed upstream so re-run it, - = not done yet."
                   TextWrapping="Wrap" FontSize="11.5" Foreground="#5B6A66" Margin="0,0,0,8"/>
        <Border BorderBrush="#E3E8E7" BorderThickness="1" CornerRadius="8">
          <ListView x:Name="VidList" BorderThickness="0" Background="Transparent" FontSize="13">
            <ListView.View>
              <GridView>
                <GridViewColumn Header="Video" Width="260" DisplayMemberBinding="{Binding Name}"/>
                <GridViewColumn Header="Captions" Width="80">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Cap}" Style="{StaticResource StatusCell}"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="Burned" Width="70">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Burn}" Style="{StaticResource StatusCell}"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="Music" Width="70">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Music}" Style="{StaticResource StatusCell}"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="Finished" Width="80">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Export}" Style="{StaticResource StatusCell}"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
              </GridView>
            </ListView.View>
          </ListView>
        </Border>
      </DockPanel>

      <!-- LOG -->
      <Border Grid.Column="4" CornerRadius="8" Background="#1E1E1E" Padding="2">
        <DockPanel>
          <TextBlock DockPanel.Dock="Top" Text="  Progress" Foreground="#8FBFB6" FontWeight="SemiBold" Margin="6,6,0,4"/>
          <TextBox x:Name="Log" Background="#1E1E1E" Foreground="#DCDCDC" BorderThickness="0"
                   FontFamily="Consolas" FontSize="12" IsReadOnly="True" TextWrapping="Wrap"
                   VerticalScrollBarVisibility="Auto" Padding="6"/>
        </DockPanel>
      </Border>
    </Grid>
  </DockPanel>

  <!-- EDITOR (opens as a full-window screen inside this same app) -->
  <Grid x:Name="EditorOverlay" Visibility="Collapsed" Background="#0F1512" Panel.ZIndex="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>
    <Border Grid.Row="0" Background="#13201C" Padding="12,8">
      <StackPanel Orientation="Horizontal">
        <Button x:Name="BtnEditorBack" Style="{StaticResource Secondary}" Content="&#8592;  Back to Studio"/>
        <TextBlock Text="Editor" Foreground="#E8F5F1" FontSize="15" FontWeight="Bold" VerticalAlignment="Center" Margin="14,0,0,0"/>
      </StackPanel>
    </Border>
    <ContentControl x:Name="EditorWebHost" Grid.Row="1"/>
  </Grid>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win    = [Windows.Markup.XamlReader]::Load($reader)

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
                'EditorOverlay','EditorWebHost','BtnEditorBack') { $ctrls[$n] = $win.FindName($n) }
$log    = $ctrls['Log']
$status = $ctrls['Status']

$script:jobButtons = @($ctrls['BtnAdd'],$ctrls['BtnEditor'],$ctrls['BtnCaptions'],$ctrls['BtnEditCaps'],
                       $ctrls['BtnBurn'],$ctrls['BtnMusic'],$ctrls['BtnExport'],
                       $ctrls['BtnSendOut'],$ctrls['BtnExportDest'],$ctrls['BtnClearAll'])

# ---------------------------------------------------------------- helpers (XAML)
function New-Win([string]$xamlStr) {
    [xml]$x = $xamlStr
    $r = New-Object System.Xml.XmlNodeReader $x
    return [Windows.Markup.XamlReader]::Load($r)
}
function Utf8NoBom { New-Object System.Text.UTF8Encoding($false) }
function Format-Clock([double]$sec) {
    if ($sec -lt 0 -or [double]::IsNaN($sec)) { $sec = 0 }
    $m = [math]::Floor($sec / 60); $s = [math]::Floor($sec - $m * 60)
    return ('{0}:{1:00}' -f [int]$m, [int]$s)
}

# ---------------------------------------------------------------- finish sounds
# Each step plays its own short chime when it finishes, so you can tell by ear
# which one completed. Tones are synthesised (no sound files needed) and played
# asynchronously so they never hold up the window.
function New-ToneWav([object[]]$notes) {
    $rate = 22050; $amp = 0.33
    $data = New-Object System.Collections.Generic.List[double]
    foreach ($n in $notes) {
        $freq = [double]$n[0]; $count = [int]($rate * ([double]$n[1]) / 1000.0)
        $atk = 0.008 * $rate; $rel = 0.045 * $rate
        for ($i = 0; $i -lt $count; $i++) {
            $env = 1.0
            if ($i -lt $atk) { $env = $i / $atk }
            elseif ($i -gt ($count - $rel)) { $env = [math]::Max(0.0, ($count - $i) / $rel) }
            $data.Add([math]::Sin(2 * [math]::PI * $freq * ($i / $rate)) * $amp * $env)
        }
    }
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $dataSize = $data.Count * 2
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF')); $bw.Write([uint32](36 + $dataSize))
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes('WAVE'))
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes('fmt ')); $bw.Write([uint32]16)
    $bw.Write([uint16]1); $bw.Write([uint16]1); $bw.Write([uint32]$rate)
    $bw.Write([uint32]($rate * 2)); $bw.Write([uint16]2); $bw.Write([uint16]16)
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes('data')); $bw.Write([uint32]$dataSize)
    foreach ($s in $data) {
        $v = [int][math]::Round($s * 32767)
        if ($v -gt 32767) { $v = 32767 } elseif ($v -lt -32768) { $v = -32768 }
        $bw.Write([int16]$v)
    }
    $bw.Flush(); $ms.Position = 0
    return $ms
}
$script:Melodies = @{
    captions = @(@(523,80), @(659,80), @(784,150))               # C-E-G, rising
    burn     = @(@(392,70), @(523,70), @(784,170))               # warm build-up
    music    = @(@(659,90), @(988,90), @(784,150))               # lilt
    export   = @(@(523,90), @(784,90), @(1046,200))              # triumphant C-G-C'
    generic  = @(@(700,90), @(940,150))
}
$script:SoundPlayers = @{}
function Play-DoneSound([string]$key) {
    if (-not $key -or -not $script:Melodies.ContainsKey($key)) { $key = 'generic' }
    try {
        if (-not $script:SoundPlayers.ContainsKey($key)) {
            $p = New-Object System.Media.SoundPlayer
            $p.Stream = (New-ToneWav $script:Melodies[$key])
            $p.Load()
            $script:SoundPlayers[$key] = $p
        }
        $script:SoundPlayers[$key].Play()   # asynchronous
    } catch {}
}

# ---------------------------------------------------------------- job runner
$script:proc = $null; $script:outFile = $null; $script:errFile = $null
$script:outPos = 0; $script:errPos = 0; $script:onDone = $null; $script:jobTitle = ''; $script:jobSound = ''

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(350)

function Write-LogText([string]$t) { if (-not [string]::IsNullOrEmpty($t)) { $log.AppendText($t); $log.ScrollToEnd() } }
function Write-LogLine([string]$t) { Write-LogText ($t + "`r`n") }

function Read-New([string]$path, [ref]$pos) {
    if (-not (Test-Path $path)) { return '' }
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        [void]$fs.Seek($pos.Value, [System.IO.SeekOrigin]::Begin)
        $sr = New-Object System.IO.StreamReader($fs)
        $txt = $sr.ReadToEnd(); $pos.Value = $fs.Position
        $sr.Dispose(); $fs.Dispose(); return $txt
    } catch { return '' }
}
function Set-Busy([bool]$busy) {
    foreach ($b in $script:jobButtons) { $b.IsEnabled = -not $busy }
    $status.Text = if ($busy) { "Working... please wait (details on the right)" } else { "Ready" }
    $win.Cursor  = if ($busy) { [System.Windows.Input.Cursors]::Wait } else { [System.Windows.Input.Cursors]::Arrow }
}
$timer.Add_Tick({
    Write-LogText (Read-New $script:outFile ([ref]$script:outPos))
    Write-LogText (Read-New $script:errFile ([ref]$script:errPos))
    if ($script:proc -and $script:proc.HasExited) {
        $timer.Stop()
        Write-LogText (Read-New $script:outFile ([ref]$script:outPos))
        Write-LogText (Read-New $script:errFile ([ref]$script:errPos))
        Write-LogLine ""; Write-LogLine "--- $($script:jobTitle): finished ---"; Write-LogLine ""
        $od = $script:onDone
        try { [System.IO.File]::Delete($script:outFile) } catch {}
        try { [System.IO.File]::Delete($script:errFile) } catch {}
        $script:proc = $null
        Set-Busy $false
        Play-DoneSound $script:jobSound
        Refresh-Videos
        if ($od) { & $od }
    }
})
function Start-Task([string]$title, [string]$scriptName, [string[]]$argList, [scriptblock]$onDone) {
    if ($script:proc) { return }
    $file = Join-Path $Root $scriptName
    if (-not (Test-Path $file)) { Write-LogLine "ERROR: missing $scriptName"; return }
    $script:jobTitle = $title; $script:onDone = $onDone
    $script:jobSound = switch -Wildcard ($scriptName) {
        'Make-Captions*' { 'captions'; break }
        'Burn-Captions*' { 'burn';     break }
        'Apply-Music*'   { 'music';    break }
        'Export-*'       { 'export';   break }
        default          { 'generic' }
    }
    Write-LogLine "=== $title ==="
    Set-Busy $true
    $script:outFile = [System.IO.Path]::GetTempFileName()
    $script:errFile = [System.IO.Path]::GetTempFileName()
    $script:outPos = 0; $script:errPos = 0
    $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $file) + $argList
    try {
        $script:proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -WindowStyle Hidden -PassThru `
                        -RedirectStandardOutput $script:outFile -RedirectStandardError $script:errFile
    } catch { Write-LogLine ("ERROR launching: " + $_.Exception.Message); Set-Busy $false; $script:proc = $null; return }
    $timer.Start()
}

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

# ================================================================ CAPTION EDITOR
function Show-CaptionEditor {
    $caps = Get-ChildItem -Path $OutDir -Filter *.srt -File -ErrorAction SilentlyContinue | Sort-Object Name
    if (-not $caps) { [System.Windows.MessageBox]::Show("No captions yet. Click 'Make captions' first.","Edit captions") | Out-Null; return }

    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Edit captions" Height="680" Width="1060" WindowStartupLocation="CenterOwner"
        Background="#FFFFFF" FontFamily="Segoe UI">
  <DockPanel Margin="14">
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,10">
      <TextBlock Text="Video:" VerticalAlignment="Center" Margin="0,0,8,0" Foreground="#444"/>
      <ComboBox x:Name="Vids" Width="300" VerticalContentAlignment="Center"/>
      <Button x:Name="Bold" Content="*Bold*" ToolTip="Select a word and click (or press Ctrl+B) to make it teal when burned"
              Background="#FFFFFF" Foreground="#2C6B60" Padding="12,5" BorderBrush="#3D9E8E" BorderThickness="1"
              Cursor="Hand" FontWeight="SemiBold" Margin="10,0,0,0"/>
      <TextBlock Text="   Watch on the left, fix the words on the right. Select a word and press Ctrl+B to make it teal."
                 VerticalAlignment="Center" Foreground="#5B6A66" FontSize="12"/>
    </StackPanel>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="Save"  Content="Save"  Background="#3D9E8E" Foreground="White" FontWeight="SemiBold" Padding="16,7" BorderThickness="0" Cursor="Hand" Margin="0,0,8,0"/>
      <Button x:Name="Close" Content="Close" Background="#FFFFFF" Foreground="#2C6B60" Padding="16,7" BorderBrush="#3D9E8E" BorderThickness="1" Cursor="Hand"/>
    </StackPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="1.2*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions>
      <DockPanel Grid.Column="0">
        <Grid DockPanel.Dock="Bottom" Margin="0,8,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Button x:Name="PlayPause" Grid.Column="0" Content="Play" Width="80" Background="#3D9E8E" Foreground="White" Padding="14,6" BorderThickness="0" Cursor="Hand"/>
          <Slider x:Name="Seek" Grid.Column="1" Minimum="0" Maximum="1" IsMoveToPointEnabled="True" VerticalAlignment="Center" Margin="12,0,10,0"/>
          <TextBlock x:Name="Time" Grid.Column="2" Text="0:00 / 0:00" VerticalAlignment="Center" Foreground="#444" FontSize="12" Margin="0,0,10,0"/>
          <Button x:Name="OpenExt" Grid.Column="3" Content="Open in player" Background="#FFFFFF" Foreground="#2C6B60" Padding="12,6" BorderBrush="#3D9E8E" BorderThickness="1" Cursor="Hand"/>
        </Grid>
        <Border Background="#000000" CornerRadius="6">
          <MediaElement x:Name="Media" LoadedBehavior="Manual" UnloadedBehavior="Manual" ScrubbingEnabled="True" Stretch="Uniform" RenderTransformOrigin="0.5,0.5">
            <MediaElement.LayoutTransform><RotateTransform x:Name="Rot" Angle="0"/></MediaElement.LayoutTransform>
          </MediaElement>
        </Border>
      </DockPanel>
      <TextBox x:Name="Txt" Grid.Column="2" AcceptsReturn="True" AcceptsTab="True" FontFamily="Consolas" FontSize="13"
               VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" Padding="6"
               SelectionBrush="#3D9E8E" SelectionOpacity="0.45"/>
    </Grid>
  </DockPanel>
</Window>
"@
    $w = New-Win $x; $w.Owner = $win
    $vids = $w.FindName('Vids'); $txt = $w.FindName('Txt'); $save = $w.FindName('Save'); $close = $w.FindName('Close')
    $media = $w.FindName('Media'); $playPause = $w.FindName('PlayPause'); $rot = $w.FindName('Rot')
    $seek = $w.FindName('Seek'); $time = $w.FindName('Time'); $openExt = $w.FindName('OpenExt')
    $bold = $w.FindName('Bold')
    foreach ($c in $caps) { [void]$vids.Items.Add($c.BaseName) }
    $script:capPath = $null; $script:capDirty = $false; $script:capLoading = $false
    $script:capSeeking = $false; $script:capVideoPath = $null; $script:capPlaying = $false
    $script:capActiveCue = -1
    $script:capCues = $null                           # parsed on load / on edit, not every tick
    $script:capScroll = $null                         # the TextBox's own ScrollViewer (found on Loaded)
    $txt.IsInactiveSelectionHighlightEnabled = $true  # keep the spoken-line highlight visible while playing

    # parse the .srt text into cues: each cue's start-second plus the TextBox line
    # index + line count of its caption TEXT, so we can highlight/scroll the line
    # being spoken. Re-run each tick so it tracks live edits.
    $parseCues = {
        param($text)
        $cues = New-Object System.Collections.ArrayList
        $lines = $text -split "`n"
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '(\d\d):(\d\d):(\d\d)[,\.](\d{1,3})\s*-->') {
                $start = [int]$Matches[1]*3600 + [int]$Matches[2]*60 + [int]$Matches[3] + ([int]$Matches[4]/1000.0)
                $tStart = $i + 1; $j = $tStart
                while ($j -lt $lines.Count -and ($lines[$j].TrimEnd("`r")).Trim() -ne '') { $j++ }
                if (($j - $tStart) -gt 0) { [void]$cues.Add(@{ Start = $start; Line = $tStart; Count = ($j - $tStart) }) }
            }
        }
        return ,$cues
    }

    # phone clips store portrait video sideways with a rotation flag WPF ignores;
    # read it so we can straighten the preview to match the final burned video.
    $getRotation = {
        param($path)
        try {
            $out = & ffprobe -loglevel error -select_streams v:0 -show_entries stream_side_data=rotation `
                    -read_intervals "%+#1" -of default=nw=1:nk=1 -- $path 2>$null | Select-Object -First 1
            if (-not $out) {
                $out = & ffprobe -loglevel error -select_streams v:0 -show_entries stream_tags=rotate `
                        -of default=nw=1:nk=1 -- $path 2>$null | Select-Object -First 1
                if ($out) { return ((([int]$out % 360) + 360) % 360) }  # tag = clockwise display angle
                return 0
            }
            # display-matrix rotation: clockwise angle to show = -(side data)
            return ((((-([int]$out)) % 360) + 360) % 360)
        } catch { return 0 }
    }

    $setPlayGlyph = {
        param($playing)
        $script:capPlaying = $playing
        $playPause.Content = if ($playing) { 'Pause' } else { 'Play' }
    }

    # ---- smooth follow-along scrolling -------------------------------------
    # ScrollToLine jumps, which is what made following along feel jerky. Drive
    # the TextBox's own ScrollViewer instead and ease into the new position.
    $txt.Add_Loaded({
        try { $script:capScroll = $txt.Template.FindName('PART_ContentHost', $txt) } catch { $script:capScroll = $null }
    })
    $script:capScrollFrom = 0.0; $script:capScrollTo = 0.0; $script:capScrollP = 0.0
    $scrollAnim = New-Object System.Windows.Threading.DispatcherTimer
    $scrollAnim.Interval = [TimeSpan]::FromMilliseconds(16)
    $scrollAnim.Add_Tick({
        if (-not $script:capScroll) { $scrollAnim.Stop(); return }
        $script:capScrollP += (16.0 / 250.0)                       # 250ms glide
        if ($script:capScrollP -gt 1) { $script:capScrollP = 1 }
        $e = 1 - [math]::Pow(1 - $script:capScrollP, 3)            # ease-out cubic
        $script:capScroll.ScrollToVerticalOffset($script:capScrollFrom + ($script:capScrollTo - $script:capScrollFrom) * $e)
        if ($script:capScrollP -ge 1) { $scrollAnim.Stop() }
    })
    # Ease to an absolute offset. A new target simply re-aims from wherever the
    # glide currently is, so back-to-back cues never fight each other.
    $smoothScrollTo = {
        param($target)
        if (-not $script:capScroll) { return }
        $max = [math]::Max(0, $script:capScroll.ScrollableHeight)
        if ($target -lt 0)    { $target = 0 }
        if ($target -gt $max) { $target = $max }
        if ([math]::Abs($target - $script:capScroll.VerticalOffset) -lt 1) { return }
        $script:capScrollFrom = $script:capScroll.VerticalOffset
        $script:capScrollTo   = [double]$target
        $script:capScrollP    = 0
        $scrollAnim.Start()
    }

    $ticker = New-Object System.Windows.Threading.DispatcherTimer
    $ticker.Interval = [TimeSpan]::FromMilliseconds(200)
    $ticker.Add_Tick({
        if ($media.Source -and $media.NaturalDuration.HasTimeSpan) {
            if (-not $script:capSeeking) { $seek.Value = $media.Position.TotalSeconds }
            $time.Text = (Format-Clock $media.Position.TotalSeconds) + ' / ' + (Format-Clock $media.NaturalDuration.TimeSpan.TotalSeconds)
            # follow-along: highlight + scroll to the caption line being spoken (while
            # playing, and only when the user isn't typing in the text box).
            if ($script:capPlaying -and -not $script:capSeeking -and -not $txt.IsKeyboardFocused) {
                $pos = $media.Position.TotalSeconds
                if ($null -eq $script:capCues) { $script:capCues = & $parseCues $txt.Text }
                $cues = $script:capCues
                $active = -1
                for ($k = 0; $k -lt $cues.Count; $k++) { if ($cues[$k].Start -le ($pos + 0.05)) { $active = $k } else { break } }
                if ($active -ge 0 -and $active -ne $script:capActiveCue) {
                    $script:capActiveCue = $active
                    $cue = $cues[$active]
                    try {
                        $startCh = $txt.GetCharacterIndexFromLineIndex($cue.Line)
                        $endLine = $cue.Line + $cue.Count - 1
                        $endCh   = $txt.GetCharacterIndexFromLineIndex($endLine) + $txt.GetLineLength($endLine)
                        if ($startCh -ge 0 -and $endCh -ge $startCh) {
                            $txt.Select($startCh, $endCh - $startCh)
                            # Only move the pane when the spoken line has drifted out of the
                            # comfortable middle band - lines already in view stay put, which
                            # is most of what made the old scroll feel jumpy.
                            if ($script:capScroll) {
                                $rect = $txt.GetRectFromCharacterIndex($startCh)
                                $vh = $script:capScroll.ViewportHeight
                                if ($rect.IsEmpty) {
                                    # far off screen (e.g. straight after a seek) - jump there
                                    $txt.ScrollToLine($cue.Line)
                                } elseif ($vh -gt 0) {
                                    $band = $vh * 0.2
                                    if ($rect.Y -lt $band -or ($rect.Y + $rect.Height) -gt ($vh - $band)) {
                                        & $smoothScrollTo ($script:capScroll.VerticalOffset + $rect.Y - ($vh / 2))
                                    }
                                }
                            } else {
                                $txt.ScrollToLine($cue.Line)
                            }
                        }
                    } catch {}
                }
            }
        }
    })

    $doSave = {
        if ($script:capPath) {
            [System.IO.File]::WriteAllText($script:capPath, $txt.Text, (Utf8NoBom))
            $script:capDirty = $false; $w.Title = "Edit captions  -  saved"
        }
    }
    $loadSel = {
        $sel = $vids.SelectedItem
        if (-not $sel) { return }
        $script:capPath = Join-Path $OutDir "$sel.srt"
        $script:capLoading = $true
        $txt.Text = [System.IO.File]::ReadAllText($script:capPath)
        $script:capLoading = $false
        $script:capCues = & $parseCues $txt.Text
        $script:capDirty = $false
        $w.Title = "Edit captions  -  $sel"
        # load the matching video (any supported extension) into the player
        try { $media.Stop() } catch {}
        $vfile = Get-ChildItem -Path $OutDir -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.BaseName -eq $sel -and $script:VidExts -contains $_.Extension.ToLower() } | Select-Object -First 1
        if ($vfile) {
            $script:capVideoPath = $vfile.FullName
            $rot.Angle = (& $getRotation $vfile.FullName)
            $media.Source = New-Object System.Uri($vfile.FullName)
        }
        else { $script:capVideoPath = $null; $rot.Angle = 0; $media.Source = $null }
        & $setPlayGlyph $false
        $seek.Value = 0
        $time.Text = "0:00 / 0:00"
        $script:capActiveCue = -1
    }

    $media.Add_MediaOpened({
        if ($media.NaturalDuration.HasTimeSpan) { $seek.Maximum = [math]::Max(0.1, $media.NaturalDuration.TimeSpan.TotalSeconds) }
        $media.Position = [TimeSpan]::Zero
        $ticker.Start()
    })
    $media.Add_MediaEnded({ $media.Pause(); $media.Position = [TimeSpan]::Zero; & $setPlayGlyph $false; $script:capActiveCue = -1 })
    $media.Add_MediaFailed({ $time.Text = "(can't preview this file)" })
    # seek ONCE, when the user releases the slider (seeking on every move was the lag)
    $seek.Add_PreviewMouseLeftButtonDown({ $script:capSeeking = $true })
    $seek.Add_PreviewMouseLeftButtonUp({
        if ($media.Source) { $media.Position = [TimeSpan]::FromSeconds($seek.Value) }
        $script:capSeeking = $false
    })
    # one button toggles play/pause
    $playPause.Add_Click({
        if (-not $media.Source) { return }
        if ($script:capPlaying) { $media.Pause(); & $setPlayGlyph $false }
        else { $media.Play(); & $setPlayGlyph $true }
    })
    $openExt.Add_Click({ if ($script:capVideoPath -and (Test-Path $script:capVideoPath)) { Start-Process $script:capVideoPath } })

    $vids.Add_SelectionChanged({
        if ($script:capDirty -and $script:capPath) {
            $r = [System.Windows.MessageBox]::Show("Save changes to the previous caption?","Edit captions",[System.Windows.MessageBoxButton]::YesNo)
            if ($r -eq [System.Windows.MessageBoxResult]::Yes) { & $doSave }
        }
        & $loadSel
    })
    $txt.Add_TextChanged({
        if (-not $script:capLoading) { $script:capDirty = $true }
        $script:capCues = $null      # re-parse lazily so follow-along tracks your edits
    })

    # ---- *Bold* / Ctrl+B: apply the star markers to the selection -----------
    $applyEmph = {
        $r = Invoke-ToggleEmphasis $txt.Text $txt.SelectionStart $txt.SelectionLength
        if ($r.Text -ne $txt.Text) {
            $txt.Text = $r.Text
            $txt.Select($r.SelStart, $r.SelLength)
        }
        [void]$txt.Focus()
    }
    $bold.Add_Click($applyEmph)
    $txt.Add_PreviewKeyDown({ param($s,$e)
        if ($e.Key -eq [System.Windows.Input.Key]::B -and
            (($e.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0)) {
            & $applyEmph
            $e.Handled = $true
        }
    })

    $save.Add_Click($doSave)
    $close.Add_Click({ $w.Close() })
    $w.Add_Closing({
        if ($script:capDirty -and $script:capPath) {
            $r = [System.Windows.MessageBox]::Show("Save your changes before closing?","Edit captions",[System.Windows.MessageBoxButton]::YesNo)
            if ($r -eq [System.Windows.MessageBoxResult]::Yes) { & $doSave }
        }
        try { $ticker.Stop() } catch {}
        try { $scrollAnim.Stop() } catch {}
        try { $media.Stop(); $media.Close(); $media.Source = $null } catch {}
    })
    $vids.SelectedIndex = 0
    [void]$w.ShowDialog()
    Refresh-Videos
}

# ================================================================ MUSIC PICKER
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

# ---------------------------------------------------------------- wire buttons
$ctrls['BtnAdd'].Add_Click({ Add-Videos })
$ctrls['BtnRefresh'].Add_Click({ Refresh-Videos })
$ctrls['BtnClearAll'].Add_Click({ Clear-AllVideos })
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
# ---------------------------------------------------------------- in-window editor
# The editor is a WebView2 screen shown OVER the studio in this same window - no
# separate process, no terminal. It's created + initialised LAZILY the first time you
# open it, which is AFTER the window's event loop is running: that timing is exactly
# why EnsureCoreWebView2Async is called from the click handler, not at startup.
$script:editorWeb = $null
function Initialize-Editor {
    if ($script:editorWeb) { return }                       # already created
    if (-not $script:EditorEngineReady) {
        Write-LogLine "Editor engine isn't installed. Run 'tools\get-webview2.ps1' once, then reopen."
        return
    }
    try { $web = New-Object Microsoft.Web.WebView2.Wpf.WebView2 }
    catch { Write-LogLine ("Editor engine failed to load: " + $_.Exception.Message); return }
    $script:editorWeb = $web
    $ctrls['EditorWebHost'].Content = $web
    # WebView2 needs a writable data folder; powershell.exe's own folder (System32)
    # isn't writable, so point it at the app's work\ dir.
    $udf = Join-Path $Root 'work\webview2-data'
    New-Item -ItemType Directory -Force -Path $udf | Out-Null
    $env:WEBVIEW2_USER_DATA_FOLDER = $udf
    $web.add_CoreWebView2InitializationCompleted({ param($s,$e)
        if (-not $e.IsSuccess) { Write-LogLine "Editor failed to start (WebView2 init). See the exception log."; return }
        $core = $script:editorWeb.CoreWebView2
        # compute paths from $Root (script-scope, resolves in this async callback);
        # a function-local var would be $null here after Initialize-Editor returned.
        $core.SetVirtualHostNameToFolderMapping('studio.editor', (Join-Path $Root 'editor'), 'Allow')
        $core.SetVirtualHostNameToFolderMapping('studio.media',   $Root,                     'Allow')
        $core.add_WebMessageReceived({ param($s2,$e2)
            try { $msg = $e2.WebMessageAsJson | ConvertFrom-Json } catch { return }
            $c = $script:editorWeb.CoreWebView2
            switch ($msg.type) {
              'ping' { $c.PostWebMessageAsJson((@{ type='pong'; echo=$msg.echo } | ConvertTo-Json)) }
              'listAssets' {
                $vidExt='.mp4','.mov','.m4v','.avi','.mkv','.webm'; $imgExt='.png','.jpg','.jpeg','.webp'; $audExt='.mp3','.wav','.m4a','.aac','.flac','.ogg'
                $scan = { param($dir,$rel)
                  if (Test-Path $dir) { Get-ChildItem $dir -File | ForEach-Object {
                    $x=$_.Extension.ToLower(); $type = if($vidExt -contains $x){'video'}elseif($imgExt -contains $x){'image'}elseif($audExt -contains $x){'audio'}else{$null}
                    if ($type){ [pscustomobject]@{ path = ($rel + '/' + $_.Name); type=$type; name=$_.Name } } } } }
                # NOTE: music\ is deliberately NOT scanned. Background music is applied
                # in step 4 only (batch mix, ducked under the voice) - listing the music
                # library here too made it ambiguous where music comes from. Audio you
                # want ON the timeline (stings, voiceover) still arrives via Import,
                # which lands in editor-imports\.
                $items = @()
                $items += @(& $scan (Join-Path $Root 'output') 'output')
                $items += @(& $scan (Join-Path $Root 'editor-imports') 'editor-imports')
                # the b-roll library, carrying its own group so the bin can
                # show it under the folder you filed it in
                $items += @(Get-BrollAssets $Root)
                $c.PostWebMessageAsJson((@{ type='assets'; items=@($items) } | ConvertTo-Json -Depth 5))
              }
              'importBroll' {
                Add-Type -AssemblyName System.Windows.Forms
                $dlg = New-Object System.Windows.Forms.OpenFileDialog; $dlg.Multiselect=$true
                $dlg.Title = 'Choose b-roll clips and photos'
                $dlg.Filter='B-roll (video + photos)|*.mp4;*.mov;*.m4v;*.mkv;*.webm;*.avi;*.png;*.jpg;*.jpeg;*.webp;*.gif;*.bmp|All files (*.*)|*.*'
                if ($dlg.ShowDialog() -eq 'OK') { Add-BrollFiles $Root $dlg.FileNames $msg.group | Out-Null }
                $c.PostWebMessageAsJson((@{ type='reScan' } | ConvertTo-Json))
              }
              # Ctrl+V in the editor: take whatever is on the Windows clipboard.
              # Copy files in Explorer and paste them straight into the library -
              # or paste an image copied from anywhere and it's saved as a PNG.
              'pasteBroll' {
                $added = 0
                try {
                  if ([System.Windows.Clipboard]::ContainsFileDropList()) {
                    $files = @([System.Windows.Clipboard]::GetFileDropList())
                    $added = Add-BrollFiles $Root $files $msg.group
                  }
                  elseif ([System.Windows.Clipboard]::ContainsImage()) {
                    $img = [System.Windows.Clipboard]::GetImage()
                    if ($img) {
                      $dest = $BrollDir
                      New-Item -ItemType Directory -Force -Path $dest | Out-Null
                      $stamp = Get-Date -Format 'yyyy-MM-dd HHmmss'
                      $file = Join-Path $dest "pasted $stamp.png"
                      $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
                      $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($img))
                      $fs = [System.IO.File]::Open($file, 'Create')
                      try { $enc.Save($fs) } finally { $fs.Dispose() }
                      $added = 1
                    }
                  }
                } catch {}
                $c.PostWebMessageAsJson((@{ type='pasted'; rid=$msg.rid; count=$added } | ConvertTo-Json))
                $c.PostWebMessageAsJson((@{ type='reScan' } | ConvertTo-Json))
              }
              # Cut the selected seconds out of a b-roll shot and keep it as its
              # own small file, so next time it's a select-and-drag with no
              # trimming to redo. Runs ffmpeg OUT OF PROCESS - this handler is on
              # the window's UI thread.
              'saveBrollClip' {
                $started = $false
                try {
                  $srcRel = [string]$msg.path
                  $srcFull = Join-Path $Root ($srcRel -replace '/', '')
                  $inSec = [double]$msg.in
                  $durSec = [double]$msg.out - $inSec
                  if ((Test-Path -LiteralPath $srcFull) -and $durSec -gt 0.05) {
                    New-Item -ItemType Directory -Force -Path (Get-BrollSavedDir $Root) | Out-Null
                    $target = Get-BrollClipTarget $Root $msg.name
                    $cutArgs = Get-BrollCutArgs $srcFull $inSec $durSec $target
                    $psi2 = New-Object System.Diagnostics.ProcessStartInfo
                    $psi2.FileName = 'ffmpeg'
                    $psi2.Arguments = ($cutArgs | ForEach-Object {
                        $a = [string]$_
                        if ($a -match '[\s"]') { '"' + ($a -replace '"','\"') + '"' } else { $a }
                    }) -join ' '
                    $psi2.UseShellExecute = $false
                    $psi2.CreateNoWindow = $true
                    $psi2.RedirectStandardError = $true
                    $script:brollProc = [System.Diagnostics.Process]::Start($psi2)
                    $script:brollOut = $target
                    $script:brollRid = $msg.rid
                    $w2 = New-Object System.Windows.Threading.DispatcherTimer
                    $w2.Interval = [TimeSpan]::FromMilliseconds(300)
                    $w2.Add_Tick({
                        if (-not $script:brollProc -or -not $script:brollProc.HasExited) { return }
                        $w2.Stop()
                        $pr = $script:brollProc; $script:brollProc = $null
                        try { $errTxt = $pr.StandardError.ReadToEnd(); if ($errTxt) { Add-Content -Path (Join-Path $Root 'workroll.log') -Value $errTxt -Encoding UTF8 } } catch {}
                        $made = Test-Path -LiteralPath $script:brollOut
                        try {
                            $cw = $script:editorWeb.CoreWebView2
                            $cw.PostWebMessageAsJson((@{ type='brollSaved'; rid=$script:brollRid; ok=$made;
                                                         name=[System.IO.Path]::GetFileNameWithoutExtension($script:brollOut) } | ConvertTo-Json))
                            $cw.PostWebMessageAsJson((@{ type='reScan' } | ConvertTo-Json))
                        } catch {}
                    })
                    $w2.Start()
                    $started = $true
                  }
                } catch {}
                if (-not $started) {
                  $c.PostWebMessageAsJson((@{ type='brollSaved'; rid=$msg.rid; ok=$false } | ConvertTo-Json))
                }
              }
              'openBrollFolder' {
                try { New-Item -ItemType Directory -Force -Path $BrollDir | Out-Null; Start-Process explorer.exe $BrollDir } catch {}
              }
              'brollTrimsGet' {
                $trims = @{}
                try { $trims = Get-BrollTrims $Root } catch {}
                $c.PostWebMessageAsJson((@{ type='brollTrims'; rid=$msg.rid; trims=$trims } | ConvertTo-Json -Depth 5))
              }
              'brollTrimSet' {
                try { Set-BrollTrim $Root $msg.path $msg.in $msg.out } catch {}
              }
              'importAssets' {
                Add-Type -AssemblyName System.Windows.Forms
                $dlg = New-Object System.Windows.Forms.OpenFileDialog; $dlg.Multiselect=$true
                $dlg.Filter='Media|*.mp4;*.mov;*.m4v;*.mkv;*.webm;*.png;*.jpg;*.jpeg;*.webp;*.mp3;*.wav;*.m4a;*.aac;*.flac;*.ogg'
                if ($dlg.ShowDialog() -eq 'OK') {
                  $imp = Join-Path $Root 'editor-imports'; New-Item -ItemType Directory -Force -Path $imp | Out-Null
                  foreach($f in $dlg.FileNames){ Copy-Item $f (Join-Path $imp ([IO.Path]::GetFileName($f))) -Force }
                }
                $c.PostWebMessageAsJson((@{ type='reScan' } | ConvertTo-Json))
              }
              # ---- filmstrip cache on disk -------------------------------
              # Clip filmstrips used to be rebuilt from scratch every time the
              # editor opened: each one is a full decode pass over the source,
              # so a project with several clips meant a decode storm on startup.
              # They're generated once now and kept in work\thumb-cache\, keyed
              # by the file's path + last-write time so an edited clip
              # regenerates but an untouched one never does.
              'thumbGet' {
                $url = $null
                try { $url = Get-CachedThumbUrl $Root $msg.path $msg.kind } catch {}
                $c.PostWebMessageAsJson((@{ type='thumbCache'; rid=$msg.rid; url=$url } | ConvertTo-Json))
              }
              'thumbPut' {
                $url = $null
                try { $url = Save-CachedThumb $Root $msg.path $msg.kind $msg.dataUrl } catch {}
                $c.PostWebMessageAsJson((@{ type='thumbCache'; rid=$msg.rid; url=$url } | ConvertTo-Json))
              }
              'saveProject' {
                try {
                  . (Join-Path $Root 'EditorRender.ps1')
                  $safeName = Get-SafeProjectName $msg.name
                  Save-EditorProject $msg.name $msg.project $Root | Out-Null
                  $c.PostWebMessageAsJson((@{ type='projectSaved'; name=$safeName; ok=$true } | ConvertTo-Json))
                } catch {
                  $c.PostWebMessageAsJson((@{ type='projectSaved'; ok=$false; error=$_.Exception.Message } | ConvertTo-Json))
                }
              }
              'listProjects' {
                try {
                  . (Join-Path $Root 'EditorRender.ps1')
                  $c.PostWebMessageAsJson((@{ type='projects'; names=@(Get-EditorProjectNames $Root) } | ConvertTo-Json))
                } catch {
                  $c.PostWebMessageAsJson((@{ type='projects'; names=@() } | ConvertTo-Json))
                }
              }
              'loadProject' {
                try {
                  . (Join-Path $Root 'EditorRender.ps1')
                  $proj = Read-EditorProject $msg.name $Root
                  if ($null -eq $proj) {
                    $c.PostWebMessageAsJson((@{ type='projectLoaded'; project=$null; ok=$false } | ConvertTo-Json))
                  } else {
                    $c.PostWebMessageAsJson((@{ type='projectLoaded'; project=$proj; ok=$true } | ConvertTo-Json -Depth 25))
                  }
                } catch {
                  $c.PostWebMessageAsJson((@{ type='projectLoaded'; project=$null; ok=$false } | ConvertTo-Json))
                }
              }
              'export' {
                $out = $null; $ok = $false
                $workDir = Join-Path $Root 'work'; $logPath = Join-Path $workDir 'export.log'
                try {
                  New-Item -ItemType Directory -Force -Path $workDir | Out-Null
                  . (Join-Path $Root 'EditorRender.ps1')
                  $outDir = Join-Path $Root 'output'; New-Item -ItemType Directory -Force -Path $outDir | Out-Null
                  $name = Get-SafeProjectName $msg.project.name
                  $out = Join-Path $Root ("output\" + $name + '.mp4')
                  $project = Resolve-EditorAssetPaths $msg.project $Root
                  $ffArgs = Build-EditorFilterGraph $project $out
                  $c.PostWebMessageAsJson((@{ type='exportProgress'; pct=0 } | ConvertTo-Json))
                  # Run ffmpeg OUT OF PROCESS and watch it on a timer. Calling it
                  # inline here blocked this handler - which runs on the window's
                  # UI thread - so the whole studio froze for the length of the
                  # render and no progress could be posted back.
                  $psi = New-Object System.Diagnostics.ProcessStartInfo
                  $psi.FileName = 'ffmpeg'
                  $psi.Arguments = (@('-y') + $ffArgs | ForEach-Object {
                      $a = [string]$_
                      if ($a -match '[\s"]') { '"' + ($a -replace '"','\"') + '"' } else { $a }
                  }) -join ' '
                  $psi.UseShellExecute = $false
                  $psi.CreateNoWindow = $true
                  $psi.RedirectStandardError = $true
                  $psi.RedirectStandardOutput = $true
                  $proc = [System.Diagnostics.Process]::Start($psi)
                  $script:exportProc = $proc
                  $script:exportOut  = $out
                  $watch = New-Object System.Windows.Threading.DispatcherTimer
                  $watch.Interval = [TimeSpan]::FromMilliseconds(400)
                  $watch.Add_Tick({
                      if (-not $script:exportProc -or -not $script:exportProc.HasExited) { return }
                      $watch.Stop()
                      $p = $script:exportProc; $script:exportProc = $null
                      $done = $script:exportOut
                      try {
                          $err = $p.StandardError.ReadToEnd()
                          if ($err) { Add-Content -Path (Join-Path $Root 'work\export.log') -Value $err -Encoding UTF8 }
                      } catch {}
                      $good = (Test-Path -LiteralPath $done)
                      try {
                          $script:editorWeb.CoreWebView2.PostWebMessageAsJson(
                              (@{ type='exportDone'; path=$done; ok=$good } | ConvertTo-Json))
                      } catch {}
                      if ($good) { try { Refresh-Videos } catch {} }
                  })
                  $watch.Start()
                  $ok = $true          # handed off; the timer reports the result
                } catch {
                  $ok = $false
                  try { New-Item -ItemType Directory -Force -Path $workDir | Out-Null; Add-Content -Path $logPath -Value ("EXCEPTION: " + $_.Exception.Message) } catch {}
                  $c.PostWebMessageAsJson((@{ type='exportDone'; path=$out; ok=$false } | ConvertTo-Json))
                }
              }
            }
        })
        $script:editorWeb.Source = [Uri]'https://studio.editor/editor.html'
    })
    $null = $web.EnsureCoreWebView2Async($null)
}

$ctrls['BtnEditor'].Add_Click({
    if ($script:proc) { Write-LogLine "Please wait for the current step to finish."; return }
    $ctrls['EditorOverlay'].Visibility = 'Visible'
    if ($script:editorWeb -and $script:editorWeb.CoreWebView2) {
        # already open before - re-scan so newly added clips appear in the media bin
        try { $script:editorWeb.CoreWebView2.PostWebMessageAsJson((@{ type='reScan' } | ConvertTo-Json)) } catch {}
    } else {
        Initialize-Editor
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
$ctrls['BtnEditCaps'].Add_Click({ Show-CaptionEditor })
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

[void]$win.ShowDialog()
