# Publish-Update.ps1 - cut a new version and put it where your editor's copy
# will find it.
#
#   .\dist\Publish-Update.ps1 -Version 1.5.0 -Notes "Pop-up images" -To "C:\Users\me\OneDrive\Video Studio updates"
#
# -To is any folder: a OneDrive or Dropbox folder you've shared with them, a
# network share, or a USB stick. It ends up holding three small files:
#
#   update.json                 what the newest version is  (~300 bytes)
#   VideoStudio-1.5.0.zip       the program itself          (~0.5 MB)
#   Install-VideoStudio.ps1     first-time setup            (for a new machine)
#
# Their app reads update.json on startup and offers the update. Nothing here
# touches anyone's videos - the package contains program files only (see
# Release.ps1 for exactly which, and why).
#
# If you'd rather host it on the web later, upload those same files anywhere
# that serves them over https and point update-source.txt at the update.json
# URL. Nothing else changes.

param(
    [string]$Version,                      # omit to bump the last number
    [string]$Notes = '',
    [string]$To,                           # where to publish (a folder)
    [string]$GitHub,                       # ...or a repo, as owner/name
    [switch]$SkipTests,
    [switch]$Republish,                    # allow re-publishing the version already stamped
    [switch]$Force                         # publish even with tests failing
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $Root 'Release.ps1')

function Say([string]$m) { Write-Host $m }

# ---- what version is this? --------------------------------------------------
$current = Get-AppVersion $Root
if (-not $Version) {
    $parts = @($current -split '\.')
    while ($parts.Count -lt 3) { $parts += '0' }
    $parts[2] = [string]([int]$parts[2] + 1)
    $Version = ($parts[0..2]) -join '.'
}
if (-not (Test-VersionString $Version)) { throw "Not a version number: '$Version'" }
# Deliberately NOT covered by -Force: "let me re-publish this version" and
# "ship it even though the tests fail" are different decisions, and one should
# never quietly grant the other.
if ((Compare-AppVersion $Version $current) -lt 0) {
    throw "Version $Version is OLDER than the current $current. That would move your editor backwards."
}
if ((Compare-AppVersion $Version $current) -eq 0 -and -not $Republish) {
    throw "Version $Version is already the current version. Pass a higher -Version, or -Republish to overwrite it."
}
Say "Publishing $current -> $Version"

# ---- don't ship something broken -------------------------------------------
if (-not $SkipTests) {
    Say 'Running the test suite first...'
    $runner = Join-Path $Root 'tests\Run-All.ps1'
    if (Test-Path -LiteralPath $runner) {
        & powershell -NoProfile -STA -ExecutionPolicy Bypass -File $runner | Select-Object -Last 3 | ForEach-Object { Say ("  " + $_) }
        if ($LASTEXITCODE -ne 0 -and -not $Force) {
            throw "Tests failed - not publishing. Fix them, or pass -Force if you really mean to."
        }
    } else { Say '  (no test runner found, skipping)' }
}

# ---- stamp the version and gather the program ------------------------------
Set-AppVersion $Root $Version | Out-Null
$files = Get-ProgramFiles $Root
if ($files.Count -lt 10) { throw "Only found $($files.Count) program files - something is wrong." }

$outDir = Join-Path $Root 'dist\out'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$packageName = "VideoStudio-$Version.zip"
$packagePath = Join-Path $outDir $packageName

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ('VideoStudioPack_' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    foreach ($rel in $files) {
        $dest = Join-Path $stage $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath (Join-Path $Root $rel) -Destination $dest -Force
    }
    if (Test-Path -LiteralPath $packagePath) { Remove-Item -LiteralPath $packagePath -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $packagePath)
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

$size = (Get-Item -LiteralPath $packagePath).Length
$sha = Get-FileSha256 $packagePath
Say ("Packaged {0} files -> {1} ({2:N0} KB)" -f $files.Count, $packageName, ($size / 1KB))

# ---- the manifest their app polls ------------------------------------------
$manifest = New-UpdateManifest -Version $Version -PackageName $packageName -Notes $Notes -Sha256 $sha
$manifestPath = Join-Path $outDir 'update.json'
[System.IO.File]::WriteAllText($manifestPath,
    ($manifest | ConvertTo-Json),
    (New-Object System.Text.UTF8Encoding($false)))

# ---- put it where they'll find it ------------------------------------------
#
# GitHub gives every repo a permanent "latest release" address, so the app can
# be pointed at one URL once and never think about it again:
#
#   https://github.com/<owner>/<repo>/releases/latest/download/update.json
#
# Publishing a new release re-points that address by itself. The package sits
# beside the manifest under the same /latest/download/ path, which is exactly
# where the app looks for it, so nothing on their machine ever changes.
if ($GitHub) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "Publishing to GitHub needs the GitHub CLI. Install it with: winget install GitHub.cli"
    }
    $tag = "v$Version"
    Say "Creating release $tag in $GitHub..."
    $noteText = if ($Notes) { $Notes } else { "Video Studio $Version" }
    & gh release create $tag $packagePath $manifestPath --repo $GitHub --title "Video Studio $Version" --notes $noteText 2>&1 |
        ForEach-Object { Say ("  " + $_) }
    if ($LASTEXITCODE -ne 0) { throw "gh release create failed - see above." }
    Say ''
    Say "Published to https://github.com/$GitHub/releases/tag/$tag"
    Say ''
    Say 'Your editor gets this automatically the next time they open Video Studio.'
}

if ($To) {
    New-Item -ItemType Directory -Force -Path $To | Out-Null
    Copy-Item -LiteralPath $packagePath -Destination (Join-Path $To $packageName) -Force
    # the installer travels with it, so a brand-new machine needs nothing else
    foreach ($extra in 'dist\Install-VideoStudio.ps1', 'dist\Apply-Update.ps1', 'Release.ps1') {
        $src = Join-Path $Root $extra
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $To (Split-Path -Leaf $extra)) -Force
        }
    }
    # the manifest goes LAST: until it appears, their app won't see a half-copied
    # package as the latest version
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $To 'update.json') -Force
    Say "Published to $To"
    Say ''
    Say 'Your editor gets this automatically the next time they open Video Studio.'
} else {
    Say ''
    Say "Built in $outDir - pass -To <folder> to publish it, e.g."
    Say '  .\dist\Publish-Update.ps1 -To "$env:USERPROFILE\OneDrive\Video Studio updates"'
}
