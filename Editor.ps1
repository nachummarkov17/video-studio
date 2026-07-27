# Editor.ps1 - the Video Studio Editor host window (WebView2 + PowerShell/ffmpeg bridge)
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$Root = $PSScriptRoot; if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$wv2 = Join-Path $Root 'tools\webview2'
Add-Type -Path (Join-Path $wv2 'Microsoft.Web.WebView2.Core.dll')
Add-Type -Path (Join-Path $wv2 'Microsoft.Web.WebView2.Wpf.dll')
# WebView2Loader.dll must be resolvable: add tools\webview2 to the DLL search path
[System.IO.Directory]::SetCurrentDirectory($wv2)

$win = New-Object System.Windows.Window
$win.Title = 'Video Studio Editor'; $win.Width = 1280; $win.Height = 800
$win.WindowStartupLocation = 'CenterScreen'
$web = New-Object Microsoft.Web.WebView2.Wpf.WebView2
$win.Content = $web

$editorDir = Join-Path $Root 'editor'
$script:core = $null
$onReady = {
  $script:core = $web.CoreWebView2
  $script:core.SetVirtualHostNameToFolderMapping('studio.editor', $editorDir, 'Allow')
  $script:core.SetVirtualHostNameToFolderMapping('studio.media',   $Root,      'Allow')
  $script:core.add_WebMessageReceived({ param($s,$e)
    try { $msg = $e.WebMessageAsJson | ConvertFrom-Json } catch { return }
    switch ($msg.type) {
      'ping' { $script:core.PostWebMessageAsJson((@{ type='pong'; echo=$msg.echo } | ConvertTo-Json)) }
      'listAssets' {
        $vidExt='.mp4','.mov','.m4v','.avi','.mkv','.webm'; $imgExt='.png','.jpg','.jpeg','.webp'; $audExt='.mp3','.wav','.m4a','.aac','.flac','.ogg'
        $scan = { param($dir,$rel)
          if (Test-Path $dir) { Get-ChildItem $dir -File | ForEach-Object {
            $x=$_.Extension.ToLower(); $type = if($vidExt -contains $x){'video'}elseif($imgExt -contains $x){'image'}elseif($audExt -contains $x){'audio'}else{$null}
            if ($type){ [pscustomobject]@{ path = ($rel + '/' + $_.Name); type=$type; name=$_.Name } } } } }
        $items = @()
        $items += @(& $scan (Join-Path $Root 'output') 'output')
        $items += @(& $scan (Join-Path $Root 'music') 'music')
        $items += @(& $scan (Join-Path $Root 'editor-imports') 'editor-imports')
        $script:core.PostWebMessageAsJson((@{ type='assets'; items=@($items) } | ConvertTo-Json -Depth 5))
      }
      'importAssets' {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.OpenFileDialog; $dlg.Multiselect=$true
        $dlg.Filter='Media|*.mp4;*.mov;*.m4v;*.mkv;*.webm;*.png;*.jpg;*.jpeg;*.mp3;*.wav;*.m4a;*.aac'
        if ($dlg.ShowDialog() -eq 'OK') {
          $imp = Join-Path $Root 'editor-imports'; New-Item -ItemType Directory -Force -Path $imp | Out-Null
          foreach($f in $dlg.FileNames){ Copy-Item $f (Join-Path $imp ([IO.Path]::GetFileName($f))) -Force }
        }
        $script:core.PostWebMessageAsJson((@{ type='reScan' } | ConvertTo-Json))
      }
      'export' {
        # try/finally: exportDone is ALWAYS posted, even if dot-sourcing or
        # Build-EditorFilterGraph throws - otherwise the Export button stays
        # stuck on "Rendering..." forever with no way for the UI to recover.
        $out = $null
        $ok = $false
        $workDir = Join-Path $Root 'work'
        $logPath = Join-Path $workDir 'export.log'
        try {
          New-Item -ItemType Directory -Force -Path $workDir | Out-Null
          . (Join-Path $Root 'EditorRender.ps1')
          $outDir = Join-Path $Root 'output'
          New-Item -ItemType Directory -Force -Path $outDir | Out-Null

          $name = Get-SafeProjectName $msg.project.name
          $out = Join-Path $Root ("output\" + $name + '.mp4')

          # Asset paths arrive root-relative with forward slashes (e.g. "output/clip.mp4",
          # "editor-imports/x.png") - ffmpeg needs real filesystem paths, so resolve each
          # to absolute under $Root before building the filter graph.
          $project = Resolve-EditorAssetPaths $msg.project $Root

          $ffArgs = Build-EditorFilterGraph $project $out
          $script:core.PostWebMessageAsJson((@{ type='exportProgress'; pct=0 } | ConvertTo-Json))

          # Capture ffmpeg's combined stdout+stderr to a log instead of discarding
          # it, so a failed real export is diagnosable after the fact.
          & ffmpeg -y @ffArgs 2>&1 | Out-File -FilePath $logPath -Encoding utf8

          $ok = Test-Path $out
        } catch {
          $ok = $false
          try {
            New-Item -ItemType Directory -Force -Path $workDir | Out-Null
            Add-Content -Path $logPath -Value ("EXCEPTION: " + $_.Exception.Message)
          } catch {}
        } finally {
          $script:core.PostWebMessageAsJson((@{ type='exportDone'; path=$out; ok=$ok } | ConvertTo-Json))
        }
      }
    }
  })
  $web.Source = [Uri]'https://studio.editor/editor.html'
}
$web.add_CoreWebView2InitializationCompleted($onReady)
$null = $web.EnsureCoreWebView2Async($null)
[void]$win.ShowDialog()
