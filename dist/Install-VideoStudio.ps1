# Install-VideoStudio.ps1 - set Video Studio up on a new machine.
#
# Run it once. After that the app updates itself.
#
#   powershell -ExecutionPolicy Bypass -File Install-VideoStudio.ps1 -Source "<the shared folder>"
#
# WHAT GOES WHERE
#   The program        ~0.5 MB, from the shared folder. Replaced by updates.
#   Your videos        output\, broll\, music\, projects\ - created empty here,
#                      and never touched by an update again.
#   ffmpeg             the video engine. Installed automatically.
#   WebView2 SDK       the editor's display engine. Downloaded automatically.
#   Captions engine    whisper + its 1.5 GB speech model, and optionally the
#                      1.3 GB timing aligner. Too big to download sensibly, so
#                      they are COPIED from -DependenciesFrom (see
#                      Export-Dependencies.ps1). Skip it and everything works
#                      except "Make captions".

param(
    [Parameter(Mandatory = $true)][string]$Source,          # folder or https url holding update.json
    [string]$InstallTo = (Join-Path $env:USERPROFILE 'Video Studio'),
    [string]$DependenciesFrom,                              # folder made by Export-Dependencies.ps1
    [string]$UpdateSource,                                  # where FUTURE updates come from, if not -Source
    [switch]$NoShortcuts
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Step([string]$m) { Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Info([string]$m) { Write-Host "    $m" }
function Warn([string]$m) { Write-Host "    ! $m" -ForegroundColor Yellow }

$here = Split-Path -Parent $PSCommandPath
# Beside this script when it ships on a stick; one level up when run from the
# repo's own dist\ folder.
$release = Join-Path $here 'Release.ps1'
if (-not (Test-Path -LiteralPath $release)) { $release = Join-Path (Split-Path -Parent $here) 'Release.ps1' }
. $release                                 # Get-ManifestLocation / Get-PackageLocation
$isWeb = Test-IsWebSource $Source

# ---- 1. fetch the program ---------------------------------------------------
Step 'Fetching Video Studio'
$manifestAt = Get-ManifestLocation $Source
$manifestText = if ($isWeb) { ConvertTo-TextContent (Invoke-WebRequest -Uri $manifestAt -UseBasicParsing -TimeoutSec 30).Content }
                else {
                    if (-not (Test-Path -LiteralPath $manifestAt)) { throw "Can't find update.json in $Source" }
                    [System.IO.File]::ReadAllText($manifestAt)
                }
$manifest = $manifestText | ConvertFrom-Json
Info "Version $($manifest.version)"

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('VideoStudioSetup_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$package = Join-Path $temp $manifest.package
$packageAt = Get-PackageLocation $Source $manifest.package $manifest.url
if ($isWeb) { Invoke-WebRequest -Uri $packageAt -UseBasicParsing -TimeoutSec 600 -OutFile $package }
else        { Copy-Item -LiteralPath $packageAt -Destination $package -Force }

if ($manifest.sha256) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($package)
    try { $actual = (($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $fs.Dispose(); $sha.Dispose() }
    if ($actual -ne ([string]$manifest.sha256).ToLowerInvariant()) { throw 'The download is damaged (checksum mismatch).' }
    Info 'Checksum verified'
}

Step "Installing to $InstallTo"
New-Item -ItemType Directory -Force -Path $InstallTo | Out-Null
[System.IO.Compression.ZipFile]::ExtractToDirectory($package, $InstallTo)
Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
Info 'Program files installed'

# the folders your work lives in
foreach ($d in 'output', 'broll', 'music', 'projects', 'work') {
    New-Item -ItemType Directory -Force -Path (Join-Path $InstallTo $d) | Out-Null
}

# Remember where updates come from. Installing off a USB stick but taking
# updates from a shared folder is the normal case, so the two are separable -
# a stick that isn't plugged in would otherwise mean no updates at all.
. (Join-Path $InstallTo 'Updater.ps1')
if ($UpdateSource) {
    Set-UpdateSource $InstallTo $UpdateSource
    Info "Updates will come from: $UpdateSource"
} else {
    # No override written on purpose: the app then uses the address built
    # into the release, so installing off a USB stick does NOT tie future
    # updates to that stick ever being plugged in again.
    Info "Updates will come from: $(Get-UpdateSource $InstallTo)"
}


# ---- the shared b-roll library ----------------------------------------------
# If any part of this install came off a USB stick, the shared library belongs
# on that stick, beside the installer. Setting it here means the first click of
# "Shared library" just works instead of asking which folder to use - and if the
# stick comes up as a different letter next time, it is found by what is on it.
. (Join-Path $InstallTo 'LibraryLocation.ps1')
$stick = $null
foreach ($c in @($Source, $DependenciesFrom)) {
    if (-not $c) { continue }
    if ($c -match '^https?://') { continue }
    $folder = if (Test-Path -LiteralPath $c -PathType Container) { $c } else { Split-Path -Parent $c }
    # captions-engine\ sits inside the handover folder; the library goes beside it
    if ($folder -and (Split-Path -Leaf $folder) -eq 'captions-engine') { $folder = Split-Path -Parent $folder }
    if ($folder -and (Test-Path -LiteralPath $folder)) { $stick = $folder; break }
}
if ($stick) {
    $lib = Join-Path $stick 'shared-library'
    try {
        New-Item -ItemType Directory -Force -Path $lib | Out-Null
        Set-LibraryLocation $InstallTo $lib
        Info "Shared b-roll library: $lib"
    } catch { Warn "Couldn't set up the shared library folder: $($_.Exception.Message)" }
} else {
    Info 'Shared library: click "Shared library" in the app to choose a folder'
}

# ---- 2. ffmpeg --------------------------------------------------------------
Step 'Video engine (ffmpeg)'
$localFfmpeg = Join-Path $InstallTo 'tools\ffmpeg\bin\ffmpeg.exe'
if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    Info 'Already installed'
} elseif (Test-Path -LiteralPath $localFfmpeg) {
    Info 'Already installed (local copy)'
} else {
    $done = $false
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Info 'Installing with winget...'
        try {
            & winget install --id Gyan.FFmpeg -e --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-Null
            $done = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue)
        } catch {}
    }
    if (-not $done) {
        Info 'Downloading a local copy...'
        try {
            $zip = Join-Path ([System.IO.Path]::GetTempPath()) 'ffmpeg.zip'
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 900 -OutFile $zip `
                -Uri 'https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip'
            $x = Join-Path ([System.IO.Path]::GetTempPath()) ('ff_' + [Guid]::NewGuid().ToString('N'))
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $x)
            $binDir = (Get-ChildItem $x -Recurse -Filter 'ffmpeg.exe' | Select-Object -First 1).Directory
            New-Item -ItemType Directory -Force -Path (Join-Path $InstallTo 'tools\ffmpeg\bin') | Out-Null
            Copy-Item (Join-Path $binDir.FullName '*.exe') (Join-Path $InstallTo 'tools\ffmpeg\bin') -Force
            Remove-Item $zip, $x -Recurse -Force -ErrorAction SilentlyContinue
            $done = Test-Path -LiteralPath $localFfmpeg
        } catch { Warn "Could not download ffmpeg: $($_.Exception.Message)" }
    }
    if ($done) { Info 'Installed' }
    else { Warn 'ffmpeg is missing. Video Studio needs it - install it and re-run this script.' }
}

# ---- 3. the editor's display engine ----------------------------------------
Step 'Editor engine (WebView2 SDK)'
$getWv = Join-Path $InstallTo 'tools\get-webview2.ps1'
if (Test-Path -LiteralPath (Join-Path $InstallTo 'tools\webview2\WebView2Loader.dll')) {
    Info 'Already present'
} elseif (Test-Path -LiteralPath $getWv) {
    try { & powershell -NoProfile -ExecutionPolicy Bypass -File $getWv | Out-Null; Info 'Downloaded' }
    catch { Warn "Could not fetch it: $($_.Exception.Message). The editor screen will say so." }
} else { Warn 'tools\get-webview2.ps1 is missing from the package.' }

# ---- 4. the captions engine (copied, not downloaded) -----------------------
Step 'Captions engine'
if ($DependenciesFrom) {
    foreach ($part in 'whisper', 'align-venv') {
        $src = Join-Path $DependenciesFrom $part
        if (-not (Test-Path -LiteralPath $src)) { Warn "$part not found in $DependenciesFrom - skipping"; continue }
        Info "Copying $part (this is the big one, give it a few minutes)..."
        Copy-Item -LiteralPath $src -Destination (Join-Path $InstallTo 'tools') -Recurse -Force
    }
    if (Test-Path -LiteralPath (Join-Path $InstallTo 'tools\whisper\ggml-medium.en.bin')) { Info 'Speech recognition ready' }
    else { Warn 'The speech model did not come across - "Make captions" will not work.' }

    # The timing aligner is a Python venv, and a venv only holds a POINTER to
    # the Python it was built from. On this machine that pointer is wrong, so
    # find a Python 3.12 (installing one if there isn't one) and re-point it.
    # Without this the aligner silently fails and captions quietly fall back to
    # less precise timing, with nothing visibly broken.
    $venv = Join-Path $InstallTo 'tools\align-venv'
    if (Test-Path -LiteralPath $venv) {
        . (Join-Path $InstallTo 'PythonEnv.ps1')
        $py = Find-PythonBase
        if (-not $py) {
            Info 'Installing Python 3.12 (needed by the caption timer)...'
            $py = Install-Python312
        }
        if ($py) {
            Info "Using Python at $py"
            if (Repair-VenvBase $venv $py) {
                if (Test-AlignerWorks $venv) { Info 'Precise caption timing ready' }
                else { Warn 'The caption timer did not start. Captions still work, timed slightly less precisely.' }
            } else {
                Warn 'Could not point the caption timer at that Python. Captions still work, timed slightly less precisely.'
            }
        } else {
            Warn 'No Python 3.12 found and it could not be installed automatically.'
            Warn 'Captions still work - just timed slightly less precisely. To fix it later,'
            Warn 'install Python 3.12 and run this installer again.'
        }
    }
} else {
    Warn 'Skipped (no -DependenciesFrom given).'
    Warn 'Everything works except "Make captions". To add it later, run'
    Warn 'Export-Dependencies.ps1 on the machine that has it, then re-run this with'
    Warn '-DependenciesFrom <that folder>.'
}

# ---- 5. shortcuts -----------------------------------------------------------
if (-not $NoShortcuts) {
    Step 'Desktop and Start menu shortcuts'
    $mk = Join-Path $InstallTo 'tools\install-shortcuts.ps1'
    if (Test-Path -LiteralPath $mk) {
        try { & powershell -NoProfile -ExecutionPolicy Bypass -File $mk | Out-Null; Info 'Created' }
        catch { Warn "Could not create them: $($_.Exception.Message)" }
    }
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host "Video Studio is installed at $InstallTo"
Write-Host 'Open it from the Desktop shortcut. When a new version is published you will'
Write-Host 'see an Update button in the toolbar - that is all you need to do.'
