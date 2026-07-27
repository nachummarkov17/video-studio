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
    }
  })
  $web.Source = [Uri]'https://studio.editor/editor.html'
}
$web.add_CoreWebView2InitializationCompleted($onReady)
$null = $web.EnsureCoreWebView2Async($null)
[void]$win.ShowDialog()
