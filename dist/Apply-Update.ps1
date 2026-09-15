# Apply-Update.ps1 - swaps the program files for a newer set, and puts them back
# if anything goes wrong.
#
# Runs as its OWN process, from a COPY of itself in a temp folder, for two
# reasons: the app holds files open (WebView2 keeps editor\js\*.js) so it has to
# exit first, and this script is itself one of the files being replaced.
#
# Three rules keep this safe:
#   1. It only ever touches files Release.ps1 calls PROGRAM files. Videos,
#      projects, music and settings are not in that set and are never opened.
#   2. Everything about to be overwritten is copied to work\update-backup\
#      first, and any failure restores it - a half-applied update is not a state
#      you can end up in.
#   3. It writes what it did to work\update.log, whether it worked or not.

param(
    [Parameter(Mandatory = $true)][string]$Package,   # the .zip to install
    [Parameter(Mandatory = $true)][string]$Root,      # the app folder
    [int]$WaitPid = 0,                                # app process to wait for
    [switch]$NoRelaunch,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Release.ps1 is staged next to this script when it is copied to temp.
$here = Split-Path -Parent $PSCommandPath
$release = Join-Path $here 'Release.ps1'
if (-not (Test-Path -LiteralPath $release)) { $release = Join-Path $Root 'Release.ps1' }
. $release

$logPath = Join-Path $Root 'work\update.log'
function Write-UpdateLog([string]$msg) {
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
    Write-Host $line
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logPath) | Out-Null
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch {}
}

function Stop-WithFailure([string]$msg) {
    Write-UpdateLog "FAILED: $msg"
    if (-not $Quiet) {
        try {
            Add-Type -AssemblyName PresentationFramework
            $nl = [Environment]::NewLine
            [System.Windows.MessageBox]::Show(
                "The update could not be installed, so nothing was changed.$nl$nl$msg$nl$nl" +
                "Details are in work\update.log. Your videos and settings are untouched.",
                'Video Studio update', 'OK', 'Warning') | Out-Null
        } catch {}
    }
    exit 1
}

# ---- wait for the app to let go ---------------------------------------------
if ($WaitPid -gt 0) {
    Write-UpdateLog "Waiting for Video Studio (pid $WaitPid) to close..."
    $waited = 0.0
    while ($waited -lt 60) {
        if (-not (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 500
        $waited += 0.5
    }
    if (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue) {
        Stop-WithFailure "Video Studio is still running. Close it and try the update again."
    }
    Start-Sleep -Milliseconds 400        # let the file handles actually drop
}

# ---- unpack somewhere harmless first ----------------------------------------
if (-not (Test-Path -LiteralPath $Package)) { Stop-WithFailure "The downloaded update is missing: $Package" }
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ('VideoStudioUpdate_' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Package, $stage)
} catch { Stop-WithFailure "The update package could not be opened: $($_.Exception.Message)" }

# A package that doesn't contain the app is not an update - far better to notice
# that here than after replacing a working copy.
foreach ($needed in 'VERSION.txt', 'Studio.ps1') {
    if (-not (Test-Path -LiteralPath (Join-Path $stage $needed))) {
        Stop-WithFailure "That package doesn't look like Video Studio (no $needed)."
    }
}
$newVersion = Get-AppVersion $stage
$oldVersion = Get-AppVersion $Root
Write-UpdateLog "Updating $oldVersion -> $newVersion"

$incoming = Get-ProgramFiles $stage
# A sanity floor, not a version check - the real "is this the app?" test is the
# VERSION.txt/Studio.ps1 pair above plus the checksum the downloader verified.
if ($incoming.Count -lt 5) { Stop-WithFailure "The update package looks empty ($($incoming.Count) files)." }

# ---- back up everything we are about to touch -------------------------------
$backup = Join-Path $Root ('work\update-backup\{0}-{1}' -f $oldVersion, (Get-Date -Format 'yyyyMMdd-HHmmss'))
$existing = Get-ProgramFiles $Root
try {
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    foreach ($rel in $existing) {
        $dest = Join-Path $backup $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath (Join-Path $Root $rel) -Destination $dest -Force
    }
    Write-UpdateLog "Backed up $($existing.Count) files to $backup"
} catch { Stop-WithFailure "Could not back up the current version: $($_.Exception.Message)" }

function Restore-Backup {
    Write-UpdateLog 'Putting the previous version back...'
    try {
        foreach ($rel in (Get-ProgramFiles $backup)) {
            $dest = Join-Path $Root $rel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
            Copy-Item -LiteralPath (Join-Path $backup $rel) -Destination $dest -Force
        }
        Write-UpdateLog 'Previous version restored.'
    } catch { Write-UpdateLog "Restore also failed: $($_.Exception.Message). The backup is still at $backup" }
}

# ---- swap in the new files --------------------------------------------------
try {
    foreach ($rel in $incoming) {
        if (-not (Test-ProgramPath $rel)) { continue }      # belt and braces
        $dest = Join-Path $Root $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath (Join-Path $stage $rel) -Destination $dest -Force
    }
    Write-UpdateLog "Installed $($incoming.Count) files"

    # A file that WAS part of the program and isn't any more (a script that got
    # split up or retired) has to go, or the old one keeps being loaded. Only
    # program paths are ever considered, so nothing of yours can match.
    $incomingSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($rel in $incoming) { [void]$incomingSet.Add($rel.ToLowerInvariant()) }
    $removed = 0
    foreach ($rel in $existing) {
        if ($incomingSet.Contains($rel.ToLowerInvariant())) { continue }
        if (-not (Test-ProgramPath $rel)) { continue }
        Remove-Item -LiteralPath (Join-Path $Root $rel) -Force -ErrorAction SilentlyContinue
        Write-UpdateLog "Retired: $rel"
        $removed++
    }
    if ($removed) { Write-UpdateLog "Removed $removed file(s) no longer part of the app" }
} catch {
    Restore-Backup
    Stop-WithFailure "Installing the new files failed: $($_.Exception.Message)"
}

try { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue } catch {}

# Keep the three most recent backups. They are ~0.5 MB each; the point is being
# able to go back a step, not keeping every version ever released.
try {
    $backups = @(Get-ChildItem (Join-Path $Root 'work\update-backup') -Directory -ErrorAction SilentlyContinue |
                 Sort-Object Name -Descending)
    if ($backups.Count -gt 3) {
        foreach ($old in $backups[3..($backups.Count - 1)]) {
            Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} catch {}

Write-UpdateLog "Update to $newVersion complete."

if (-not $NoRelaunch) {
    $vbs = Join-Path $Root 'Video Studio.vbs'
    if (Test-Path -LiteralPath $vbs) {
        Write-UpdateLog 'Restarting Video Studio...'
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"')
    }
}
exit 0
