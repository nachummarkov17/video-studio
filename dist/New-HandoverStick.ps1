# New-HandoverStick.ps1 - make (or refresh) the USB stick you hand to your editor.
#
#   .\dist\New-HandoverStick.ps1 -To "D:\Video Studio"
#
# Everything the other computer needs, in one folder:
#
#   INSTALL - double-click me.cmd   what they double-click
#   Install-VideoStudio.ps1         what it runs
#   VideoStudio-<version>.zip       an offline copy of the program
#   update.json                     ...and what version that is
#   Apply-Update.ps1, Release.ps1   used by the updater afterwards
#   captions-engine\                speech + timing models (2.8 GB, copied once)
#   shared-library\                 where you swap b-roll and music
#   START HERE.txt                  the three sentences they actually read
#
# The stick used to be assembled by hand, and drifted: it still said version
# 1.0.0 two releases later. Everything here is written from the repo, so the
# stick always matches what was published.
#
# Publish first (dist\Publish-Update.ps1), then run this - it picks up whatever
# is in dist\out.

param(
    [Parameter(Mandatory = $true)][string]$To,
    [switch]$SkipCaptionsEngine,     # it is 2.8 GB and never changes - skip if already there
    [switch]$NoLibrary               # don't create the shared-library folder
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $Root 'Release.ps1')

function Step($m) { Write-Host ''; Write-Host "== $m" -ForegroundColor Cyan }
function Info($m) { Write-Host "   $m" }
function Warn($m) { Write-Host "   $m" -ForegroundColor Yellow }

$version = Get-AppVersion $Root
$out = Join-Path $Root 'dist\out'
$package = Join-Path $out "VideoStudio-$version.zip"
if (-not (Test-Path -LiteralPath $package)) {
    throw "No package for version $version in dist\out. Run dist\Publish-Update.ps1 first."
}

New-Item -ItemType Directory -Force -Path $To | Out-Null

# ---- the program ------------------------------------------------------------
Step "Program files (version $version)"
foreach ($f in @($package, (Join-Path $out 'update.json'))) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing $f - publish first." }
    Copy-Item -LiteralPath $f -Destination $To -Force
    Info (Split-Path -Leaf $f)
}
foreach ($f in @('dist\Install-VideoStudio.ps1', 'dist\Apply-Update.ps1', 'Release.ps1')) {
    Copy-Item -LiteralPath (Join-Path $Root $f) -Destination $To -Force
    Info (Split-Path -Leaf $f)
}
# An older package on the stick is just a way to install the wrong version.
foreach ($old in @(Get-ChildItem -LiteralPath $To -Filter 'VideoStudio-*.zip' -File)) {
    if ($old.Name -ne "VideoStudio-$version.zip") {
        Remove-Item -LiteralPath $old.FullName -Force
        Info "removed old $($old.Name)"
    }
}

# ---- what they double-click -------------------------------------------------
Step 'Installer'
$gh = 'https://github.com/nachummarkov17/video-studio/releases/latest/download/update.json'
$cmd = @"
@echo off
REM Installs Video Studio on this computer. Just double-click this file.
REM %~dp0 is the folder this file sits in, so the drive letter does not matter.
setlocal
set HERE=%~dp0
set GH=$gh

echo.
echo   Installing Video Studio
echo   ----------------------------------------------------------
echo   The program comes from the internet so you get the newest
echo   version. The captions engine (2.8 GB) comes off this stick.
echo   This takes a few minutes.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%Install-VideoStudio.ps1" -Source "%GH%" -DependenciesFrom "%HERE%captions-engine"

if errorlevel 1 (
  echo.
  echo   Could not reach the internet - installing the copy on this
  echo   stick instead. It will update itself once you are online.
  echo.
  powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%Install-VideoStudio.ps1" -Source "%HERE%." -DependenciesFrom "%HERE%captions-engine"
)

echo.
pause
"@
[System.IO.File]::WriteAllText((Join-Path $To 'INSTALL - double-click me.cmd'),
                               ($cmd -replace "`r?`n", "`r`n"), (New-Object System.Text.ASCIIEncoding))
Info 'INSTALL - double-click me.cmd'

# ---- the note they actually read -------------------------------------------
$readme = @"
VIDEO STUDIO - INSTALLING IT ON THIS COMPUTER
=============================================

Double-click:   INSTALL - double-click me.cmd

That is the whole thing. It takes a few minutes, mostly because
of the captions engine (2.8 GB) being copied off this stick.

It installs to:   C:\Users\<you>\Video Studio
and puts a "Video Studio" icon on your Desktop.

If Windows warns about running it, choose "More info" then
"Run anyway" - it is a plain text script and you can open it in
Notepad to read exactly what it does.


UPDATES
-------
These arrive on their own. When a new version is ready you will
see an orange "Update to ..." button in the toolbar. Click it,
and the app closes and reopens on the new version. Your videos,
projects and settings are never touched by an update.


SHARING B-ROLL AND MUSIC
------------------------
Keep this stick. The shared-library folder on it is how the two
computers swap b-roll clips, pop-up pictures and music.

With the stick plugged in, click "Shared library" at the top of
the window. It copies both ways, so you both end up with
everything. Your own videos and saved edits stay on your computer.

It does not matter which drive letter the stick gets - the app
finds the folder by what is on it.


WHAT IS ON THIS STICK
---------------------
  INSTALL - double-click me.cmd   the installer
  Install-VideoStudio.ps1         what it actually runs
  captions-engine\                speech recognition + timing (2.8 GB)
  shared-library\                 b-roll and music you both share
  VideoStudio-$version.zip        an offline copy of the program,
  update.json                     used only if there is no internet
  Apply-Update.ps1, Release.ps1   used by the updater later
"@
[System.IO.File]::WriteAllText((Join-Path $To 'START HERE.txt'),
                               ($readme -replace "`r?`n", "`r`n") + "`r`n",
                               (New-Object System.Text.UTF8Encoding($false)))
Info 'START HERE.txt'

# ---- the shared library -----------------------------------------------------
if (-not $NoLibrary) {
    Step 'Shared library folder'
    $lib = Join-Path $To 'shared-library'
    New-Item -ItemType Directory -Force -Path $lib | Out-Null
    $libNote = @"
SHARED LIBRARY
==============

This folder is how the two Video Studio computers swap material.

You do not need to move anything in here by hand. In Video Studio,
click "Shared library" at the top of the window. It copies both ways:

    broll\               b-roll clips and the pictures you pop up over
                         the video, subfolders (groups) and all
    music\               background tracks
    broll-trims.txt      the piece of each b-roll clip you use
    caption-colors.txt   your emphasis colours

Whatever either computer has added since last time, both end up with.

NOT in here, on purpose: your videos (output\) and your saved edits
(projects\). Those are personal to whoever is cutting, and a saved
edit points at clips that only exist on that machine.

Nothing is ever overwritten. If a clip with the same name is different
on the two computers, both are left exactly as they are and the app
says so.

The drive letter of this stick does not matter - it can be D: on one
computer and E: on the other, and the app still finds this folder.
"@
    [System.IO.File]::WriteAllText((Join-Path $lib 'README.txt'),
                                   ($libNote -replace "`r?`n", "`r`n") + "`r`n",
                                   (New-Object System.Text.UTF8Encoding($false)))
    Info $lib
    Info 'Both computers point at this folder; the installer sets it up on theirs.'
}

# ---- the video engine -------------------------------------------------------
# ffmpeg rides on the stick too. It is 180 MB from GitHub, and the one time that
# download was left to the other computer it sat for an hour on a slow link with
# nothing on screen. A file copy has no such failure mode.
Step 'Video engine (ffmpeg)'
$ffHere = Join-Path $Root 'tools\ffmpeg\bin'
$ffStick = Join-Path $To 'ffmpeg\bin'
if (Test-Path -LiteralPath (Join-Path $ffStick 'ffmpeg.exe')) {
    Info 'Already on the stick'
} else {
    if (-not (Test-Path -LiteralPath (Join-Path $ffHere 'ffmpeg.exe'))) {
        Info 'Not on this machine yet - fetching it once...'
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\get-ffmpeg.ps1') -To $ffHere
    }
    if (Test-Path -LiteralPath (Join-Path $ffHere 'ffmpeg.exe')) {
        New-Item -ItemType Directory -Force -Path $ffStick | Out-Null
        Copy-Item (Join-Path $ffHere '*.exe') $ffStick -Force
        Info $ffStick
    } else {
        Warn 'Could not get ffmpeg - their computer will download it instead.'
    }
}

# ---- the heavy parts --------------------------------------------------------
Step 'Captions engine'
$engine = Join-Path $To 'captions-engine'
if ($SkipCaptionsEngine) {
    Info 'Skipped (-SkipCaptionsEngine).'
} elseif (Test-Path -LiteralPath (Join-Path $engine 'whisper')) {
    Info 'Already on the stick - it never changes, so it is left alone.'
} else {
    Info 'Copying 2.8 GB. This is the slow part; it only happens once.'
    & (Join-Path $Root 'dist\Export-Dependencies.ps1') -To $engine
}

Write-Host ''
Write-Host "Stick ready: $To" -ForegroundColor Green
Write-Host "Hand it over. They double-click 'INSTALL - double-click me.cmd'."
