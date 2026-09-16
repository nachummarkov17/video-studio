# GetFfmpeg.Tests.ps1 - the video engine arriving without a download.
#
# The handover that went wrong went wrong here: the installer asked winget for
# ffmpeg, winget wanted administrator rights, and the prompt appeared somewhere
# nobody could see it. The step sat for an hour with its output piped to
# nowhere. So what matters now is that the copy-from-the-stick path works and
# is taken FIRST - a file copy cannot hang on a prompt or a slow line.
#
# Only the local paths are exercised. A test that downloads 80 MB every run is
# a test nobody will keep, and the download is the part we are trying not to
# depend on.
#
# Run:  powershell -ExecutionPolicy Bypass -File tests\GetFfmpeg.Tests.ps1

$ErrorActionPreference = 'Stop'
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

$script = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\get-ffmpeg.ps1')).Path
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("getff_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function Fake-Ffmpeg([string]$dir) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($exe in 'ffmpeg.exe', 'ffprobe.exe') {
        [System.IO.File]::WriteAllText((Join-Path $dir $exe), "not really $exe")
    }
}
function Run([string[]]$argList) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script @argList 2>&1 | Out-String
    return [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}

try {
    # ---- straight from a folder that has it --------------------------------
    $stick = Join-Path $tmp 'stick'
    Fake-Ffmpeg (Join-Path $stick 'ffmpeg\bin')
    $to = Join-Path $tmp 'app\tools\ffmpeg\bin'

    $r = Run @('-To', $to, '-From', $stick)
    A ($r.Code -eq 0) 'copying from the stick succeeds'
    A (Test-Path (Join-Path $to 'ffmpeg.exe')) 'and ffmpeg.exe lands where the app looks for it'
    A (Test-Path (Join-Path $to 'ffprobe.exe')) 'with ffprobe alongside it'
    A ($r.Out -notmatch 'Downloading') 'without going near the internet'

    # ---- already installed --------------------------------------------------
    $r2 = Run @('-To', $to, '-From', $stick)
    A ($r2.Code -eq 0) 'running it again is harmless'
    A ($r2.Out -match 'Already installed') 'and it says so rather than copying again'

    # ---- the shapes of folder someone might point it at ---------------------
    foreach ($shape in @('bin', 'ffmpeg\bin', '', 'deep\inside\here')) {
        $src = Join-Path $tmp ("shape_" + [Guid]::NewGuid().ToString('N'))
        $leaf = if ($shape) { Join-Path $src $shape } else { $src }
        Fake-Ffmpeg $leaf
        $dest = Join-Path $tmp ("out_" + [Guid]::NewGuid().ToString('N'))
        $r3 = Run @('-To', $dest, '-From', $src)
        $label = if ($shape) { $shape } else { 'the folder itself' }
        A ((Test-Path (Join-Path $dest 'ffmpeg.exe')) -and $r3.Code -eq 0) "a copy found in $label is used"
    }

    # ---- a copy already on this computer -----------------------------------
    # Downloading 80 MB of a file the machine already has was the real waste
    # here: this repo had ffmpeg installed the whole time the script sat on a
    # 20 KB/s download of the very same build.
    if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
        $dest = Join-Path $tmp 'from-this-machine'
        $began = Get-Date
        $r4 = Run @('-To', $dest)
        A ($r4.Out -match 'already on this computer') 'an ffmpeg already installed here is used'
        A (Test-Path (Join-Path $dest 'ffmpeg.exe')) 'and copied into the app folder'
        A ((Get-Item (Join-Path $dest 'ffmpeg.exe')).Length -gt 1MB) 'as the real binary, not a few-KB shim'
        A (((Get-Date) - $began).TotalSeconds -lt 60) 'in seconds, because nothing was downloaded'
        A ($r4.Out -notmatch 'Downloading') 'and no download was even started'
    } else {
        Write-Host 'SKIP: no ffmpeg installed on this machine to copy from'
    }

    # ---- two sources to try, smallest first --------------------------------
    $text = Get-Content -LiteralPath $script -Raw
    A ($text -match 'gyan\.dev' -and $text -match 'BtbN') 'there are two download sources, not one'
    A ($text.IndexOf('gyan.dev') -lt $text.IndexOf('BtbN')) 'and the smaller one is tried first'
    # The word appears in the header explaining why it is gone; what matters is
    # that no line of CODE calls it.
    $code = @(Get-Content -LiteralPath $script | Where-Object { $_.TrimStart() -notlike '#*' })
    # RUNNING winget is what hung. Reading the folder winget installs links
    # into is just another place a copy might already be sitting.
    A (@($code | Where-Object { $_ -match '&\s*winget|winget\s+install' }).Count -eq 0) 'no code path runs winget - that is what hung'
    A ($text -match 'ReadTimeout') 'a stalled read gives up instead of waiting forever'
    A ($text -match 'MaxMinutes') 'and no single attempt can run all afternoon'
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails -eq 0) { Write-Host "All get-ffmpeg tests passed." } else { Write-Host "$fails test(s) FAILED."; exit 1 }
