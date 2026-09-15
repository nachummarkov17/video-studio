# Release.Tests.ps1 - what an update is allowed to touch.
#
# The stakes here are the highest in the project: get the whitelist wrong and an
# update deletes somebody's footage. Every test below is really one question -
# "is this file the program, or is it theirs?"
#
# Run:  powershell -ExecutionPolicy Bypass -File tests\Release.Tests.ps1

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\Release.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

# ---- the program ------------------------------------------------------------
foreach ($p in 'Studio.ps1', 'CaptionEditor.ps1', 'Video Studio.vbs', 'VideoStudio.ico',
                'README.txt', 'UPLOAD-GUIDE.txt', 'VERSION.txt',
                'editor\editor.html', 'editor\js\app.js', 'editor\css\base.css',
                'ui\main-window.xaml', 'tools\get-webview2.ps1', 'tools\align.py',
                'dist\Apply-Update.ps1') {
    A (Test-ProgramPath $p) "program: $p"
}

# ---- THEIRS. an update must never so much as look at these ------------------
foreach ($p in 'output\IMG_4923.mp4', 'output\captioned\clip.mp4', 'output\upload\clip.mp4',
                'output\Probe.srt', 'broll\city.mp4', 'broll\saved\punch in.mp4',
                'music\bed.mp3', 'projects\Test 1.json', 'temp\IMG_4923.mp4',
                'work\export.log', 'work\proxy-cache\abc.mp4', 'input\raw.mov',
                'studio-settings.txt', 'export-settings.txt', 'video-order.txt',
                'broll-trims.txt', 'music-map.txt', 'caption-colors.txt',
                'update-source.txt', 'cleaner.log') {
    A (-not (Test-ProgramPath $p)) "theirs: $p"
}

# ---- dependencies: installed once, never shipped ----------------------------
foreach ($p in 'tools\whisper\ggml-medium.en.bin', 'tools\whisper\Release\whisper-cli.exe',
                'tools\align-venv\Scripts\python.exe', 'tools\align-venv\Lib\site-packages\torch\x.dll',
                'tools\webview2\WebView2Loader.dll', 'tools\ffmpeg\bin\ffmpeg.exe') {
    A (-not (Test-ProgramPath $p)) "dependency, not shipped: $p"
}

# ---- development-only files stay on the dev machine -------------------------
foreach ($p in 'tests\Release.Tests.ps1', 'editor\tests\zoom.test.js', 'editor\package.json',
                'docs\design.md', '.git\config', 'editor\tests\manual\boot-check.html') {
    A (-not (Test-ProgramPath $p)) "not shipped: $p"
}

# ---- path trickery ----------------------------------------------------------
A (-not (Test-ProgramPath '..\..\Windows\System32\evil.ps1')) 'a path climbing out of the folder is refused'
A (-not (Test-ProgramPath 'output\..\Studio.ps1')) 'and so is one that climbs back in'
A (-not (Test-ProgramPath '')) 'an empty path is not a program file'
A (Test-ProgramPath 'editor/js/app.js') 'forward slashes are understood too'

# ---- the real folder --------------------------------------------------------
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$files = Get-ProgramFiles $root
A ($files.Count -gt 50) "the real app has a program file list (got $($files.Count))"
A ($files -contains 'Studio.ps1') 'including the app itself'
A ($files -contains 'editor\js\preview.js') 'and the editor'
A (-not (@($files) | Where-Object { $_ -like 'output\*' })) 'and nothing from output\'
A (-not (@($files) | Where-Object { $_ -like 'tools\whisper\*' })) 'and nothing from tools\whisper'
A (-not (@($files) | Where-Object { $_ -like 'tests\*' })) 'and no tests'
A ((@($files) | Where-Object { Test-ProgramPath $_ }).Count -eq $files.Count) 'the lister and the tester agree on every file'

$total = (@($files) | ForEach-Object { (Get-Item -LiteralPath (Join-Path $root $_)).Length } | Measure-Object -Sum).Sum
A ($total -lt 5MB) ("the whole program is {0:N1} MB - small enough to update casually" -f ($total / 1MB))

# ---- versions ---------------------------------------------------------------
A ((Compare-AppVersion '1.4.0' '1.4.0') -eq 0) 'same version compares equal'
A ((Compare-AppVersion '1.4' '1.4.0') -eq 0) "1.4 and 1.4.0 are the SAME - unpadded, [version] would call 1.4 older"
A ((Compare-AppVersion '1.4.1' '1.4.0') -eq 1) 'a later patch is newer'
A ((Compare-AppVersion '1.2.0' '1.10.0') -eq -1) 'version numbers are not decimals: 1.2 < 1.10'
A ((Compare-AppVersion '2.0.0' '1.99.99') -eq 1) 'a major bump wins'
A ((Compare-AppVersion 'rubbish' '1.0.0') -eq -1) 'junk is treated as older, so a real release still installs'

A (Test-VersionString '1.4.0') 'a plain version parses'
A (Test-VersionString '1.4') 'two parts is fine'
A (-not (Test-VersionString '1.4.0-beta')) 'suffixes are not supported, and say so'
A (-not (Test-VersionString 'v1.4.0')) "and neither is a leading 'v'"

# ---- manifest round trip ----------------------------------------------------
$m = New-UpdateManifest -Version '1.5.0' -PackageName 'VideoStudio-1.5.0.zip' -Notes 'Pop-up images' -Sha256 'abc123'
$parsed = ConvertFrom-UpdateManifestJson ($m | ConvertTo-Json)
A ($parsed.Version -eq '1.5.0') 'the version survives'
A ($parsed.Package -eq 'VideoStudio-1.5.0.zip') 'the package name survives'
A ($parsed.Notes -eq 'Pop-up images') 'the notes survive'
A ($parsed.Sha256 -eq 'abc123') 'the checksum survives'
A ($parsed.Released -match '^\d{4}-\d{2}-\d{2}$') 'it records the date'

A ($null -eq (ConvertFrom-UpdateManifestJson 'not json at all')) 'garbage is not an update'
A ($null -eq (ConvertFrom-UpdateManifestJson '')) 'nothing is not an update'
A ($null -eq (ConvertFrom-UpdateManifestJson '{"package":"x.zip"}')) 'a manifest with no version is not an update'
A ($null -eq (ConvertFrom-UpdateManifestJson '{"version":"1.0.0"}')) 'nor one with no package'
A ($null -eq (ConvertFrom-UpdateManifestJson '{"version":"tomorrow","package":"x.zip"}')) 'nor one with a nonsense version'

# ---- checksums --------------------------------------------------------------
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("rel_" + [Guid]::NewGuid().ToString('N') + '.bin')
[System.IO.File]::WriteAllText($tmp, 'hello')
try {
    A ((Get-FileSha256 $tmp) -eq '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824') 'sha256 matches the known value for "hello"'
} finally { Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue }

# ---- where an update source points -----------------------------------------
# GitHub gives a repo a permanent "latest release" address, and the package sits
# beside the manifest under the same path. That is the same rule as a folder, so
# pointing the app at one URL once is all that is ever needed.
$gh = 'https://github.com/me/video-studio/releases/latest/download/update.json'
A (Test-IsWebSource $gh) 'an https source is recognised as web'
A (-not (Test-IsWebSource 'D:\Video Studio')) 'a drive path is not'
A (-not (Test-IsWebSource '\server\share\vs')) 'and neither is a network share'

A ((Get-ManifestLocation $gh) -eq $gh) 'a source already naming update.json is used as-is'
A ((Get-ManifestLocation 'https://github.com/me/r/releases/latest/download') -eq
   'https://github.com/me/r/releases/latest/download/update.json') 'a bare web folder gets update.json appended'
A ((Get-ManifestLocation 'https://x.dev/vs/') -eq 'https://x.dev/vs/update.json') 'a trailing slash is not doubled'
A ((Get-ManifestLocation 'D:\Video Studio') -eq 'D:\Video Studio\update.json') 'a folder source joins the filename'

A ((Get-PackageLocation $gh 'VideoStudio-1.1.0.zip') -eq
   'https://github.com/me/video-studio/releases/latest/download/VideoStudio-1.1.0.zip') 'the package is a sibling of the manifest on the web'
A ((Get-PackageLocation 'D:\Video Studio' 'VideoStudio-1.1.0.zip') -eq
   'D:\Video Studio\VideoStudio-1.1.0.zip') 'and a sibling in a folder'
A ((Get-PackageLocation $gh 'x.zip' 'https://cdn.example/x.zip') -eq 'https://cdn.example/x.zip') 'an absolute url in the manifest wins over both'

# ---- a web response that isn't declared as text -----------------------------
# GitHub serves every release asset as application/octet-stream, so
# Invoke-WebRequest returns the manifest as a BYTE ARRAY. Passing that straight
# to ConvertFrom-Json fails, which made the update check come back empty and
# silently never offer anything. Caught live against a real release.
$bytes = [System.Text.Encoding]::UTF8.GetBytes('{"version":"2.0.0","package":"x.zip"}')
A ((ConvertTo-TextContent $bytes) -eq '{"version":"2.0.0","package":"x.zip"}') 'a byte-array body is decoded to text'
A ((ConvertFrom-UpdateManifestJson (ConvertTo-TextContent $bytes)).Version -eq '2.0.0') 'and then parses as a manifest'
A ((ConvertTo-TextContent 'already text') -eq 'already text') 'a string body passes through'
A ((ConvertTo-TextContent $null) -eq '') 'nothing decodes to nothing, not a crash'

Write-Host ''
if ($fails -eq 0) { Write-Host "All Release tests passed." } else { Write-Host "$fails test(s) FAILED."; exit 1 }
