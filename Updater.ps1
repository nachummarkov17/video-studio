# Updater.ps1 - "there's a newer version" inside the app.
#
# The flow, from the editor's point of view, is: open Video Studio, see a button
# saying an update is ready, click it, the app restarts on the new version. They
# never see a zip, a folder, or a command line.
#
# Everything slow happens in a child process (see dist\Check-Update.ps1) and
# reports back on a timer, so a shared folder that has gone offline delays
# nothing and freezes nothing.
#
# Where updates come from is one line in update-source.txt - a folder or an
# https URL. That file is YOURS, not part of the program, so an update can never
# rewrite where updates come from.

$script:PendingUpdate = $null
$script:UpdateBusy = $false
$script:UpdateSourceFile = 'update-source.txt'

# Where updates come from unless a machine says otherwise. This is part of the
# PROGRAM, so it travels with every release and a future release can move it -
# which means a fresh install already knows where to look and there is nothing
# to configure per machine.
#
# GitHub keeps this address pointing at the newest release forever; publishing
# a new one re-points it automatically.
$script:DefaultUpdateSource = 'https://github.com/nachummarkov17/video-studio/releases/latest/download/update.json'

# update-source.txt is an OVERRIDE, not the normal case: it exists for a machine
# that takes updates from somewhere unusual (a shared folder, a USB stick).
# Without one, the address built into this release is used.
function Get-UpdateSource {
    param([Parameter(Mandatory = $true)][string]$Root)
    $path = Join-Path $Root $script:UpdateSourceFile
    if (Test-Path -LiteralPath $path) {
        try {
            foreach ($line in [System.IO.File]::ReadAllLines($path)) {
                $t = $line.Trim()
                if ($t -and -not $t.StartsWith('#')) { return $t }
            }
        } catch {}
    }
    return $script:DefaultUpdateSource
}

function Set-UpdateSource {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Source
    )
    $text = @(
        '# Where Video Studio looks for updates.'
        '# Either a folder (a shared OneDrive/Dropbox folder, a network share, a USB stick)'
        '# or an https address ending in update.json. One line, that is all.'
        $Source.Trim()
    ) -join "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $Root $script:UpdateSourceFile), $text + "`r`n",
                                   (New-Object System.Text.UTF8Encoding($false)))
}

# PURE: is this manifest worth telling the user about?
function Test-ShouldOfferUpdate {
    param([string]$CurrentVersion, [object]$Manifest)
    if (-not $Manifest) { return $false }
    return ((Compare-AppVersion $Manifest.Version $CurrentVersion) -gt 0)
}

# ---- checking ---------------------------------------------------------------

# Asks the source what the latest version is. Silent: if there is no source
# configured, or the folder is offline, nothing is said and nothing is shown -
# an update check failing is not news.
function Start-UpdateCheck {
    param([Parameter(Mandatory = $true)][string]$Root)
    $source = Get-UpdateSource $Root
    if (-not $source) { return }
    $checker = Join-Path $Root 'dist\Check-Update.ps1'
    if (-not (Test-Path -LiteralPath $checker)) { return }

    try {
        $tracked = Start-TrackedProcess -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $checker, '-Source', $source)
    } catch { return }

    Watch-Process -Tracked $tracked -IntervalMs 500 -Context ([pscustomobject]@{ Root = $Root }) -OnExit {
        param($result, $ctx)
        if (-not $result.Ok) { return }
        $manifest = ConvertFrom-UpdateManifestJson $result.StdOut
        if (-not (Test-ShouldOfferUpdate (Get-AppVersion $ctx.Root) $manifest)) { return }
        $script:PendingUpdate = $manifest
        Show-UpdateAvailable
    } | Out-Null
}

function Show-UpdateAvailable {
    $m = $script:PendingUpdate
    if (-not $m) { return }
    try {
        $btn = $ctrls['BtnUpdate']
        if ($btn) {
            $btn.Content = "Update to $($m.Version)"
            $btn.ToolTip = if ($m.Notes) { "What's new: $($m.Notes)" } else { "Install version $($m.Version)" }
            $btn.Visibility = 'Visible'
        }
    } catch {}
    Write-LogLine ""
    Write-LogLine "An update is ready: version $($m.Version)$(if ($m.Notes) { " - $($m.Notes)" })"
    Write-LogLine "Click 'Update to $($m.Version)' in the toolbar to install it."
}

# ---- installing -------------------------------------------------------------

function Install-AvailableUpdate {
    param([Parameter(Mandatory = $true)][string]$Root)
    $m = $script:PendingUpdate
    if (-not $m -or $script:UpdateBusy) { return }

    $nl = [Environment]::NewLine
    $answer = [System.Windows.MessageBox]::Show(
        "Install version $($m.Version)?$nl$nl" +
        $(if ($m.Notes) { "What's new: $($m.Notes)$nl$nl" } else { '' }) +
        "Video Studio will close and reopen. Your videos, projects and settings are not affected.",
        'Video Studio update', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $source = Get-UpdateSource $Root
    if (-not $source) { return }
    $dest = Join-Path $Root ('work\update\' + $m.Package)
    try { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null } catch {}

    $script:UpdateBusy = $true
    try { $ctrls['BtnUpdate'].IsEnabled = $false; $ctrls['BtnUpdate'].Content = 'Downloading...' } catch {}
    Write-LogLine "Downloading version $($m.Version)..."

    $checker = Join-Path $Root 'dist\Check-Update.ps1'
    $ffArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $checker,
                '-Source', $source, '-Package', $m.Package, '-Out', $dest)
    if ($m.Url) { $ffArgs += @('-Url', $m.Url) }

    try {
        $tracked = Start-TrackedProcess -FilePath 'powershell.exe' -ArgumentList $ffArgs
    } catch {
        $script:UpdateBusy = $false
        Write-LogLine "Could not start the download: $($_.Exception.Message)"
        return
    }

    Watch-Process -Tracked $tracked -IntervalMs 400 `
        -Context ([pscustomobject]@{ Root = $Root; Dest = $dest; Manifest = $m }) -OnExit {
            param($result, $ctx)
            Complete-UpdateDownload $result $ctx
        } | Out-Null
}

function Complete-UpdateDownload {
    param([object]$Result, [object]$Ctx)
    $script:UpdateBusy = $false
    $m = $Ctx.Manifest

    $ok = $Result.Ok -and (Test-Path -LiteralPath $Ctx.Dest)
    if ($ok -and $m.Sha256) {
        # A truncated or tampered download must never be unzipped over a working
        # install - this is the one check that makes the swap safe to automate.
        $actual = (Get-FileSha256 $Ctx.Dest).ToLowerInvariant()
        if ($actual -ne $m.Sha256) {
            $ok = $false
            Write-LogLine "The download didn't match its checksum, so it was discarded."
        }
    }
    if (-not $ok) {
        try { $ctrls['BtnUpdate'].IsEnabled = $true; $ctrls['BtnUpdate'].Content = "Update to $($m.Version)" } catch {}
        Write-LogLine "The update could not be downloaded. Nothing was changed."
        if ($Result.StdErr) { Write-LogLine ($Result.StdErr.Trim()) }
        return
    }

    # Run the updater from a COPY in temp: it is about to replace the originals,
    # including itself.
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ('VideoStudioApply_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Copy-Item -LiteralPath (Join-Path $Ctx.Root 'dist\Apply-Update.ps1') -Destination $stage -Force
    Copy-Item -LiteralPath (Join-Path $Ctx.Root 'Release.ps1') -Destination $stage -Force

    Write-LogLine "Installing version $($m.Version) - Video Studio will reopen in a moment."
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $stage 'Apply-Update.ps1'),
        '-Package', $Ctx.Dest, '-Root', $Ctx.Root, '-WaitPid', $PID)

    # Closing lets go of editor\js\* (WebView2 holds them) so they can be replaced.
    try { $win.Close() } catch {}
}
