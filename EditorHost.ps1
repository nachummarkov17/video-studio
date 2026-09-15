# EditorHost.ps1 - the bridge between the in-window editor page and the app.
#
# The editor is a WebView2 (Edge) control shown OVER the studio in the same
# window - no separate process, no terminal. It is created and initialised
# LAZILY the first time you open it, which is AFTER the window's event loop is
# running: that timing is exactly why EnsureCoreWebView2Async is called from the
# click handler and not at startup.
#
# Everything below runs on the WINDOW'S UI THREAD. Nothing here may block it:
# ffmpeg work goes out of process through ProcessRunner.ps1 and reports back on
# a timer.

$script:editorWeb = $null
$script:exportBusy = $false

function Send-EditorMessage {
    param([Parameter(Mandatory = $true)][hashtable]$Message, [int]$Depth = 5)
    if (-not $script:editorWeb -or -not $script:editorWeb.CoreWebView2) { return }
    try { $script:editorWeb.CoreWebView2.PostWebMessageAsJson(($Message | ConvertTo-Json -Depth $Depth)) } catch {}
}

# $Root is read from SCRIPT scope on purpose, never taken as a parameter: the
# initialisation callback below runs long after this function has returned, and
# a parameter would be $null by then. That exact mistake once made the editor
# page fail to load at all (ERR_FILE_NOT_FOUND).
function Initialize-Editor {
    param([Parameter(Mandatory = $true)][object]$HostControl)
    if ($script:editorWeb) { return }
    if (-not $script:EditorEngineReady) {
        Write-LogLine "Editor engine isn't installed. Run 'tools\get-webview2.ps1' once, then reopen."
        return
    }
    try { $web = New-Object Microsoft.Web.WebView2.Wpf.WebView2 }
    catch { Write-LogLine ("Editor engine failed to load: " + $_.Exception.Message); return }
    $script:editorWeb = $web
    $HostControl.Content = $web

    # WebView2 needs a writable data folder; powershell.exe's own folder
    # (System32) isn't writable, so point it at the app's work\ dir.
    $udf = Join-Path $Root 'work\webview2-data'
    New-Item -ItemType Directory -Force -Path $udf | Out-Null
    $env:WEBVIEW2_USER_DATA_FOLDER = $udf

    $web.add_CoreWebView2InitializationCompleted({ param($s, $e)
        if (-not $e.IsSuccess) { Write-LogLine "Editor failed to start (WebView2 init). See the exception log."; return }
        $core = $script:editorWeb.CoreWebView2
        # Paths are computed from $Root at SCRIPT scope here on purpose: this
        # callback runs long after Initialize-Editor returned, so any local it
        # had would be $null by now.
        $core.SetVirtualHostNameToFolderMapping('studio.editor', (Join-Path $Root 'editor'), 'Allow')
        $core.SetVirtualHostNameToFolderMapping('studio.media',  $Root,                     'Allow')
        $core.add_WebMessageReceived({ param($s2, $e2)
            $msg = $null
            try { $msg = $e2.WebMessageAsJson | ConvertFrom-Json } catch { return }
            try { Invoke-EditorMessage $msg } catch {
                Write-LogLine ("Editor bridge error on '" + $msg.type + "': " + $_.Exception.Message)
            }
        })
        $script:editorWeb.Source = [Uri]'https://studio.editor/editor.html'
    })
    $null = $web.EnsureCoreWebView2Async($null)
}

# ------------------------------------------------------------- dispatch -----

function Invoke-EditorMessage {
    param([Parameter(Mandatory = $true)][object]$Msg)
    switch ($Msg.type) {
        'ping'           { Send-EditorMessage @{ type = 'pong'; echo = $Msg.echo } }
        'listAssets'     { Send-EditorAssetList }
        'importAssets'   { Import-EditorAssets }
        'importBroll'    { Import-EditorBroll $Msg }
        'pasteBroll'     { Add-EditorPastedBroll $Msg }
        'saveBrollClip'  { Save-EditorBrollClip $Msg }
        'openBrollFolder' { try { New-Item -ItemType Directory -Force -Path $BrollDir | Out-Null; Start-Process explorer.exe $BrollDir } catch {} }
        'brollTrimsGet'  { $t = @{}; try { $t = Get-BrollTrims $Root } catch {}; Send-EditorMessage @{ type = 'brollTrims'; rid = $Msg.rid; trims = $t } }
        'brollTrimSet'   { try { Set-BrollTrim $Root $Msg.path $Msg.in $Msg.out } catch {} }
        'thumbGet'       { $u = $null; try { $u = Get-CachedThumbUrl $Root $Msg.path $Msg.kind } catch {}; Send-EditorMessage @{ type = 'thumbCache'; rid = $Msg.rid; url = $u } }
        'thumbPut'       { $u = $null; try { $u = Save-CachedThumb $Root $Msg.path $Msg.kind $Msg.dataUrl } catch {}; Send-EditorMessage @{ type = 'thumbCache'; rid = $Msg.rid; url = $u } }
        'proxyGet'       { Resolve-EditorProxy $Msg }
        'saveProject'    { Save-EditorProjectFromEditor $Msg }
        'listProjects'   { $n = @(); try { $n = @(Get-EditorProjectNames $Root) } catch {}; Send-EditorMessage @{ type = 'projects'; names = $n } }
        'loadProject'    { Open-EditorProject $Msg }
        'export'         { Start-EditorExportJob $Msg }
    }
}

# ------------------------------------------------------------- media bin ----

function Send-EditorAssetList {
    $vidExt = '.mp4', '.mov', '.m4v', '.avi', '.mkv', '.webm'
    $imgExt = '.png', '.jpg', '.jpeg', '.webp'
    $audExt = '.mp3', '.wav', '.m4a', '.aac', '.flac', '.ogg'
    $scan = {
        param($dir, $rel)
        if (-not (Test-Path $dir)) { return }
        Get-ChildItem $dir -File | ForEach-Object {
            $x = $_.Extension.ToLower()
            $type = if ($vidExt -contains $x) { 'video' } elseif ($imgExt -contains $x) { 'image' } elseif ($audExt -contains $x) { 'audio' } else { $null }
            if ($type) { [pscustomobject]@{ path = ($rel + '/' + $_.Name); type = $type; name = $_.Name } }
        }
    }
    # NOTE: music\ is deliberately NOT scanned. Background music is applied in
    # step 4 only (batch mix, under the voice); listing the music library here
    # too made it ambiguous where music comes from. Audio you want ON the
    # timeline (stings, voiceover) still arrives via Import, into editor-imports\.
    $items = @()
    $items += @(& $scan (Join-Path $Root 'output') 'output')
    $items += @(& $scan (Join-Path $Root 'editor-imports') 'editor-imports')
    $items += @(Get-BrollAssets $Root)
    Send-EditorMessage @{ type = 'assets'; items = @($items) } 5
}

function Import-EditorAssets {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Multiselect = $true
    $dlg.Filter = 'Media|*.mp4;*.mov;*.m4v;*.mkv;*.webm;*.png;*.jpg;*.jpeg;*.webp;*.mp3;*.wav;*.m4a;*.aac;*.flac;*.ogg'
    if ($dlg.ShowDialog() -eq 'OK') {
        $imp = Join-Path $Root 'editor-imports'
        New-Item -ItemType Directory -Force -Path $imp | Out-Null
        foreach ($f in $dlg.FileNames) { Copy-Item $f (Join-Path $imp ([IO.Path]::GetFileName($f))) -Force }
    }
    Send-EditorMessage @{ type = 'reScan' }
}

function Import-EditorBroll {
    param($Msg)
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Multiselect = $true
    $dlg.Title = 'Choose b-roll clips and photos'
    $dlg.Filter = 'B-roll (video + photos)|*.mp4;*.mov;*.m4v;*.mkv;*.webm;*.avi;*.png;*.jpg;*.jpeg;*.webp;*.gif;*.bmp|All files (*.*)|*.*'
    if ($dlg.ShowDialog() -eq 'OK') { Add-BrollFiles $Root $dlg.FileNames $Msg.group | Out-Null }
    Send-EditorMessage @{ type = 'reScan' }
}

# Ctrl+V in the editor: take whatever is on the Windows clipboard. Copy files in
# Explorer and paste them straight into the library - or paste an image copied
# from anywhere and it's saved as a PNG.
function Add-EditorPastedBroll {
    param($Msg)
    $added = 0
    try {
        if ([System.Windows.Clipboard]::ContainsFileDropList()) {
            $added = Add-BrollFiles $Root @([System.Windows.Clipboard]::GetFileDropList()) $Msg.group
        } elseif ([System.Windows.Clipboard]::ContainsImage()) {
            $img = [System.Windows.Clipboard]::GetImage()
            if ($img) {
                New-Item -ItemType Directory -Force -Path $BrollDir | Out-Null
                $file = Join-Path $BrollDir ("pasted " + (Get-Date -Format 'yyyy-MM-dd HHmmss') + ".png")
                $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
                $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($img))
                $fs = [System.IO.File]::Open($file, 'Create')
                try { $enc.Save($fs) } finally { $fs.Dispose() }
                $added = 1
            }
        }
    } catch {}
    Send-EditorMessage @{ type = 'pasted'; rid = $Msg.rid; count = $added }
    Send-EditorMessage @{ type = 'reScan' }
}

# Cut the selected seconds out of a b-roll shot and keep it as its own small
# file, so next time it's a select-and-drag with no trimming to redo.
function Save-EditorBrollClip {
    param($Msg)
    try {
        $srcFull = Join-Path $Root ([string]$Msg.path -replace '/', '\')
        $inSec = [double]$Msg.in
        $durSec = [double]$Msg.out - $inSec
        if (-not (Test-Path -LiteralPath $srcFull) -or $durSec -le 0.05) { throw 'nothing to cut' }

        New-Item -ItemType Directory -Force -Path (Get-BrollSavedDir $Root) | Out-Null
        $target = Get-BrollClipTarget $Root $Msg.name
        $tracked = Start-TrackedProcess -FilePath 'ffmpeg' -ArgumentList (Get-BrollCutArgs $srcFull $inSec $durSec $target)
        Watch-Process -Tracked $tracked -IntervalMs 300 `
            -Context ([pscustomobject]@{ Rid = $Msg.rid; Target = $target }) -OnExit {
                param($result, $ctx)
                if ($result.StdErr) {
                    try { Add-Content -LiteralPath (Join-Path $Root 'work\broll.log') -Value $result.StdErr -Encoding UTF8 } catch {}
                }
                $made = $result.Ok -and (Test-Path -LiteralPath $ctx.Target)
                Send-EditorMessage @{ type = 'brollSaved'; rid = $ctx.Rid; ok = $made
                                      name = [System.IO.Path]::GetFileNameWithoutExtension($ctx.Target) }
                Send-EditorMessage @{ type = 'reScan' }
            } | Out-Null
    } catch {
        Send-EditorMessage @{ type = 'brollSaved'; rid = $Msg.rid; ok = $false }
    }
}

# ------------------------------------------------------------- proxies ------

# The page asks for a small stand-in before it plays a clip. Answer immediately
# with whatever exists; if there's nothing yet, queue a build and tell the page
# when it lands so it can swap over mid-session.
#
# ONE AT A TIME. A timeline with ten clips would otherwise ask for ten proxies
# in the same breath and launch ten ffmpegs, which would bring the machine to a
# halt exactly when the user is trying to edit. They queue instead, so the clip
# you are looking at gets its proxy first and the rest arrive quietly.
$script:proxyQueue = New-Object System.Collections.Generic.Queue[string]
$script:proxyBusy = $false

function Resolve-EditorProxy {
    param($Msg)
    $rel = [string]$Msg.path
    $url = $null
    try { $url = Get-ProxyUrl $Root $rel } catch {}
    Send-EditorMessage @{ type = 'proxy'; rid = $Msg.rid; path = $rel; url = $url }
    if ($url) { return }
    if (-not (Test-ProxyApplies $rel)) { return }
    if ($script:proxyQueue -notcontains $rel) { $script:proxyQueue.Enqueue($rel) }
    Start-NextProxy
}

function Start-NextProxy {
    if ($script:proxyBusy) { return }
    while ($script:proxyQueue.Count -gt 0) {
        $rel = $script:proxyQueue.Dequeue()
        $build = $null
        try { $build = Start-ProxyBuild $Root $rel } catch {}
        if (-not $build) { continue }          # already built, or gone: take the next
        $script:proxyBusy = $true
        Watch-Process -Tracked $build.Tracked -IntervalMs 700 `
            -Context ([pscustomobject]@{ Build = $build; Rel = $rel }) -OnExit {
                param($result, $ctx)
                $script:proxyBusy = $false
                if (Complete-ProxyBuild $ctx.Build $result) {
                    Send-EditorMessage @{ type = 'proxyReady'; path = $ctx.Rel; url = (Get-ProxyUrl $Root $ctx.Rel) }
                }
                Start-NextProxy
            } | Out-Null
        return
    }
}

# ------------------------------------------------------------- projects -----

function Save-EditorProjectFromEditor {
    param($Msg)
    try {
        $safeName = Get-SafeProjectName $Msg.name
        Save-EditorProject $Msg.name $Msg.project $Root | Out-Null
        Send-EditorMessage @{ type = 'projectSaved'; name = $safeName; ok = $true }
    } catch {
        Send-EditorMessage @{ type = 'projectSaved'; ok = $false; error = $_.Exception.Message }
    }
}

function Open-EditorProject {
    param($Msg)
    try {
        $proj = Read-EditorProject $Msg.name $Root
        if ($null -eq $proj) { Send-EditorMessage @{ type = 'projectLoaded'; project = $null; ok = $false }; return }
        Send-EditorMessage @{ type = 'projectLoaded'; project = $proj; ok = $true } 25
    } catch {
        Send-EditorMessage @{ type = 'projectLoaded'; project = $null; ok = $false }
    }
}

# ------------------------------------------------------------- export -------

# Naming and the overwrite question are handled HERE, with the app's own
# dialogs, so "Export" is one decision instead of a round trip through the page.
function Start-EditorExportJob {
    param($Msg)
    if ($script:exportBusy) { return }

    $suggested = Get-SuggestedExportName $Msg.project
    $name = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Name the finished video. It joins 'Your videos', ready for captions, music and finishing.",
        'Export video', $suggested)
    if ([string]::IsNullOrWhiteSpace($name)) {
        Send-EditorMessage @{ type = 'exportDone'; ok = $false; cancelled = $true }
        return
    }

    $paths = Get-ExportPaths $Root $name
    if (Test-ExportOverwritesSource $Msg.project $paths.Final $Root) {
        [System.Windows.MessageBox]::Show(
            "'$($paths.Name)' is one of the clips this edit is made from." + [Environment]::NewLine + [Environment]::NewLine +
            "Exporting over it would destroy the footage and leave the edit unopenable. Pick a different name.",
            'Export video', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Stop) | Out-Null
        Send-EditorMessage @{ type = 'exportDone'; ok = $false; cancelled = $true }
        Write-LogLine "Export refused: '$($paths.Name)' is a source clip of this edit."
        return
    }
    if (Test-Path -LiteralPath $paths.Final) {
        $answer = [System.Windows.MessageBox]::Show(
            "'$($paths.Name)' is already in Your videos. Replace it?", 'Export video',
            [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
            Send-EditorMessage @{ type = 'exportDone'; ok = $false; cancelled = $true }
            return
        }
    }

    try {
        $script:exportBusy = $true
        Send-EditorMessage @{ type = 'exportProgress'; pct = 0 }
        Start-EditorRender -Root $Root -Project $Msg.project -Name $name -OnProgress {
            param($pct, $ctx)
            Send-EditorMessage @{ type = 'exportProgress'; pct = $pct }
        } -OnDone {
            param($done, $ctx)
            $script:exportBusy = $false
            Send-EditorMessage @{ type = 'exportDone'; ok = $done.Ok; name = $done.Name
                                  path = $done.Path; error = $done.Error }
            if ($done.Ok) {
                Write-LogLine "Editor export finished: $($done.Name).mp4 is now in Your videos."
                try { Refresh-Videos } catch {}
            } else {
                Write-LogLine "Editor export FAILED: $($done.Error)"
            }
        } | Out-Null
    } catch {
        $script:exportBusy = $false
        Send-EditorMessage @{ type = 'exportDone'; ok = $false; error = $_.Exception.Message }
        Write-LogLine ("Editor export could not start: " + $_.Exception.Message)
    }
}
