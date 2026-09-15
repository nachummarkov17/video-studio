# Update.Tests.ps1 - installing a new version onto a working copy.
#
# This is the one place in the project where a bug destroys someone's work, so
# the tests are about damage before they are about features: an update lands,
# and every video, project, setting and caption file is still byte-for-byte
# where it was. A failed update has to leave NOTHING changed at all.
#
# Run:  powershell -ExecutionPolicy Bypass -File tests\Update.Tests.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repo 'Release.ps1')
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("upd_" + [Guid]::NewGuid().ToString('N'))
function Put([string]$path, [string]$text) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    [System.IO.File]::WriteAllText($path, $text)
}
function Hash([string]$path) { if (Test-Path -LiteralPath $path) { (Get-FileSha256 $path) } else { $null } }

# A believable install: some program, some of their work.
function New-Install([string]$root) {
    Put (Join-Path $root 'VERSION.txt')            "1.0.0`r`n"
    Put (Join-Path $root 'Studio.ps1')             '# version one'
    Put (Join-Path $root 'Retired.ps1')            '# a script that later versions drop'
    Put (Join-Path $root 'editor\js\app.js')       '// version one'
    Put (Join-Path $root 'ui\main-window.xaml')    '<Window/>'
    # ...and everything that is THEIRS
    Put (Join-Path $root 'output\holiday.mp4')     'PRECIOUS FOOTAGE'
    Put (Join-Path $root 'output\holiday.srt')     '1 caption'
    Put (Join-Path $root 'output\captioned\holiday.mp4') 'BURNED'
    Put (Join-Path $root 'broll\city.mp4')         'B-ROLL'
    Put (Join-Path $root 'music\bed.mp3')          'MUSIC'
    Put (Join-Path $root 'projects\My Edit.json')  '{"name":"My Edit"}'
    Put (Join-Path $root 'studio-settings.txt')    'CaptionPosition=Middle'
    Put (Join-Path $root 'caption-colors.txt')     'Unhealthy|~|#D93025'
    Put (Join-Path $root 'update-source.txt')      'C:\some\shared\folder'
    Put (Join-Path $root 'video-order.txt')        'holiday.mp4'
    # the updater needs these to run at all
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'dist') | Out-Null
    Copy-Item (Join-Path $repo 'dist\Apply-Update.ps1') (Join-Path $root 'dist') -Force
    Copy-Item (Join-Path $repo 'Release.ps1') $root -Force
}

# The new version: one file changed, one added, one dropped.
function New-Package([string]$zip, [string]$version) {
    $src = Join-Path $tmp ('pkg_' + [Guid]::NewGuid().ToString('N'))
    Put (Join-Path $src 'VERSION.txt')          "$version`r`n"
    Put (Join-Path $src 'Studio.ps1')           '# version two'
    Put (Join-Path $src 'editor\js\app.js')     '// version two'
    Put (Join-Path $src 'editor\js\brand-new.js') '// added in version two'
    Put (Join-Path $src 'ui\main-window.xaml')  '<Window/>'
    New-Item -ItemType Directory -Force -Path (Join-Path $src 'dist') | Out-Null
    Copy-Item (Join-Path $repo 'dist\Apply-Update.ps1') (Join-Path $src 'dist\Apply-Update.ps1') -Force
    Copy-Item (Join-Path $repo 'Release.ps1') $src -Force
    [System.IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)
}

function Invoke-Apply([string]$package, [string]$root) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'dist\Apply-Update.ps1') `
        -Package $package -Root $root -NoRelaunch -Quiet 2>&1 | Out-Null
    return $LASTEXITCODE
}

try {
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null

    # ============ a normal, successful update ============
    $root = Join-Path $tmp 'install'
    New-Install $root
    $theirs = @{}
    foreach ($f in 'output\holiday.mp4', 'output\holiday.srt', 'output\captioned\holiday.mp4',
                   'broll\city.mp4', 'music\bed.mp3', 'projects\My Edit.json',
                   'studio-settings.txt', 'caption-colors.txt', 'update-source.txt', 'video-order.txt') {
        $theirs[$f] = Hash (Join-Path $root $f)
    }

    $zip = Join-Path $tmp 'VideoStudio-1.1.0.zip'
    New-Package $zip '1.1.0'
    $code = Invoke-Apply $zip $root

    A ($code -eq 0) "the update reported success (exit $code)"
    A ((Get-AppVersion $root) -eq '1.1.0') 'the installed version moved to 1.1.0'
    A ([System.IO.File]::ReadAllText((Join-Path $root 'Studio.ps1')) -eq '# version two') 'a changed program file was replaced'
    A (Test-Path -LiteralPath (Join-Path $root 'editor\js\brand-new.js')) 'a brand-new program file arrived'
    A (-not (Test-Path -LiteralPath (Join-Path $root 'Retired.ps1'))) 'a program file dropped in the new version was removed'

    # THE important one
    $intact = $true
    foreach ($f in $theirs.Keys) {
        if ((Hash (Join-Path $root $f)) -ne $theirs[$f]) { $intact = $false; Write-Host "      changed: $f" }
    }
    A $intact 'every one of their files is byte-for-byte untouched'
    A ([System.IO.File]::ReadAllText((Join-Path $root 'update-source.txt')) -eq 'C:\some\shared\folder') 'where updates come from is still their choice, not the package''s'

    $backups = @(Get-ChildItem (Join-Path $root 'work\update-backup') -Directory -ErrorAction SilentlyContinue)
    A ($backups.Count -eq 1) 'the previous version was backed up'
    A (Test-Path -LiteralPath (Join-Path $backups[0].FullName 'Studio.ps1')) 'and the backup contains the old program'
    A (-not (Test-Path -LiteralPath (Join-Path $backups[0].FullName 'output\holiday.mp4'))) 'the backup holds the PROGRAM only - it does not copy their footage'
    A (Test-Path -LiteralPath (Join-Path $root 'work\update.log')) 'and it wrote down what it did'

    # ============ a package that is not Video Studio ============
    $root2 = Join-Path $tmp 'install2'
    New-Install $root2
    $before = @{}
    foreach ($f in 'Studio.ps1', 'VERSION.txt', 'output\holiday.mp4', 'projects\My Edit.json') {
        $before[$f] = Hash (Join-Path $root2 $f)
    }
    $junkSrc = Join-Path $tmp 'junk'
    Put (Join-Path $junkSrc 'notes.txt') 'this is not an app'
    $junkZip = Join-Path $tmp 'junk.zip'
    [System.IO.Compression.ZipFile]::CreateFromDirectory($junkSrc, $junkZip)
    $code2 = Invoke-Apply $junkZip $root2

    A ($code2 -ne 0) 'a package that is not Video Studio is refused'
    $unchanged = $true
    foreach ($f in $before.Keys) { if ((Hash (Join-Path $root2 $f)) -ne $before[$f]) { $unchanged = $false } }
    A $unchanged 'and a refused update changes absolutely nothing'
    A ((Get-AppVersion $root2) -eq '1.0.0') 'the version is still the old one'

    # ============ a package that is missing / damaged ============
    $root3 = Join-Path $tmp 'install3'
    New-Install $root3
    $code3 = Invoke-Apply (Join-Path $tmp 'does-not-exist.zip') $root3
    A ($code3 -ne 0) 'a missing package is refused'
    A ((Get-AppVersion $root3) -eq '1.0.0') 'and again nothing changed'

    $torn = Join-Path $tmp 'torn.zip'
    [System.IO.File]::WriteAllBytes($torn, [byte[]](1..200))
    $code4 = Invoke-Apply $torn $root3
    A ($code4 -ne 0) 'a corrupt zip is refused'
    A ([System.IO.File]::ReadAllText((Join-Path $root3 'Studio.ps1')) -eq '# version one') 'and the working copy still runs'

    # ============ updating twice in a row ============
    $zip2 = Join-Path $tmp 'VideoStudio-1.2.0.zip'
    New-Package $zip2 '1.2.0'
    Invoke-Apply $zip2 $root | Out-Null
    A ((Get-AppVersion $root) -eq '1.2.0') 'a second update installs on top of the first'
    A ((Hash (Join-Path $root 'output\holiday.mp4')) -eq $theirs['output\holiday.mp4']) 'and their footage is STILL untouched'
    A ((@(Get-ChildItem (Join-Path $root 'work\update-backup') -Directory)).Count -eq 2) 'each update keeps its own backup'

    # ============ the publisher, for real ============
    $savedVersion = Get-AppVersion $repo
    $pubTo = Join-Path $tmp 'published'
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'dist\Publish-Update.ps1') `
            -Version '9.9.9' -Notes 'test build' -To $pubTo -SkipTests 2>&1 | Out-Null
        A (Test-Path -LiteralPath (Join-Path $pubTo 'update.json')) 'publishing writes a manifest'
        A (Test-Path -LiteralPath (Join-Path $pubTo 'VideoStudio-9.9.9.zip')) 'and the package'
        A (Test-Path -LiteralPath (Join-Path $pubTo 'Install-VideoStudio.ps1')) 'and the installer, so a new machine needs nothing else'

        $published = ConvertFrom-UpdateManifestJson ([System.IO.File]::ReadAllText((Join-Path $pubTo 'update.json')))
        A ($published.Version -eq '9.9.9') 'the manifest names the version'
        A ($published.Notes -eq 'test build') 'and carries the notes'
        A ($published.Sha256 -eq (Get-FileSha256 (Join-Path $pubTo 'VideoStudio-9.9.9.zip'))) 'and the checksum matches the package it shipped'

        # the real package must install onto a real-shaped install
        $root4 = Join-Path $tmp 'install4'
        New-Install $root4
        Put (Join-Path $root4 'output\keep.mp4') 'KEEP ME'
        $keep = Hash (Join-Path $root4 'output\keep.mp4')
        $code5 = Invoke-Apply (Join-Path $pubTo 'VideoStudio-9.9.9.zip') $root4
        A ($code5 -eq 0) 'the REAL published package installs cleanly'
        A ((Get-AppVersion $root4) -eq '9.9.9') 'and reports its version'
        A (Test-Path -LiteralPath (Join-Path $root4 'CaptionEditor.ps1')) 'and brought the whole app across'
        A (Test-Path -LiteralPath (Join-Path $root4 'editor\js\preview.js')) 'including the editor'
        A (-not (Test-Path -LiteralPath (Join-Path $root4 'tests'))) 'without shipping the tests'
        A (-not (Test-Path -LiteralPath (Join-Path $root4 'tools\whisper'))) 'and without the 2.8 GB of dependencies'
        A ((Hash (Join-Path $root4 'output\keep.mp4')) -eq $keep) 'and their footage came through untouched'
    } finally {
        Set-AppVersion $repo $savedVersion | Out-Null
        Remove-Item (Join-Path $repo 'dist\out\VideoStudio-9.9.9.zip') -Force -ErrorAction SilentlyContinue
    }
    A ((Get-AppVersion $repo) -eq $savedVersion) 'the test put the repo version back'
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails -eq 0) { Write-Host "All Update tests passed." } else { Write-Host "$fails test(s) FAILED."; exit 1 }
