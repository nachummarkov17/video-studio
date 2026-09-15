# PreviewProxy.Tests.ps1 - the cache that decides which file the previews play.
#
# Getting the key wrong in either direction is bad: too eager and every session
# re-encodes every clip, too lazy and you edit against a stale picture of a clip
# you have since replaced.
#
# Run:  powershell -STA -ExecutionPolicy Bypass -File tests\PreviewProxy.Tests.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
. "$PSScriptRoot\..\ProcessRunner.ps1"
. "$PSScriptRoot\..\PreviewProxy.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ProxyTest_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'output') | Out-Null
function Write-Fake([string]$path, [int]$bytes) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    [System.IO.File]::WriteAllBytes($path, (New-Object byte[] $bytes))
}

try {
    $clip = Join-Path $tmp 'output\clip.mp4'
    Write-Fake $clip 5000

    # ---- which files get a proxy at all -----------------------------------
    A (Test-ProxyApplies 'a.mp4') 'video gets a proxy'
    A (Test-ProxyApplies 'A.MOV') 'extension test is case-insensitive'
    A (-not (Test-ProxyApplies 'photo.png')) 'a still does not - encoding one would make a one-frame film'
    A (-not (Test-ProxyApplies 'track.mp3')) 'audio does not need one'
    A (-not (Test-ProxyApplies '')) 'nothing is not a video'

    # ---- the cache key -----------------------------------------------------
    $p1 = Get-ProxyPath $tmp 'output/clip.mp4'
    $p2 = Get-ProxyPath $tmp $clip
    A ($p1 -eq $p2) 'a relative and an absolute path name the same cache entry'
    A ($p1 -eq (Get-ProxyPath $tmp 'output/clip.mp4')) 'the key is stable for an unchanged file'
    A ($p1 -like (Join-Path $tmp 'work\proxy-cache\*.mp4')) "the proxy lives in work\proxy-cache ($p1)"

    Start-Sleep -Milliseconds 20
    Write-Fake $clip 9000                      # same name, different content
    A ((Get-ProxyPath $tmp 'output/clip.mp4') -ne $p1) 'editing the clip invalidates its proxy'

    $other = Join-Path $tmp 'output\other.mp4'
    Write-Fake $other 5000
    A ((Get-ProxyPath $tmp 'output/other.mp4') -ne (Get-ProxyPath $tmp 'output/clip.mp4')) 'two clips get two entries'

    # ---- readiness ---------------------------------------------------------
    $target = Get-ProxyPath $tmp 'output/clip.mp4'
    A (-not (Test-ProxyReady $tmp 'output/clip.mp4')) 'nothing built yet is not ready'
    Write-Fake $target 300
    A (-not (Test-ProxyReady $tmp 'output/clip.mp4')) 'an abandoned stub does NOT count as ready'
    Write-Fake $target 50000
    A (Test-ProxyReady $tmp 'output/clip.mp4') 'a real file is ready'
    A ((Get-ProxyUrl $tmp 'output/clip.mp4') -like 'https://studio.media/work/proxy-cache/*.mp4') 'the page gets a studio.media URL'
    A ($null -eq (Get-ProxyUrl $tmp 'output/other.mp4')) 'no proxy, no URL'

    # ---- the ffmpeg command ------------------------------------------------
    $enc = @('-c:v', 'libx264', '-preset', 'veryfast', '-crf', '26')
    $ffArgs = Get-ProxyBuildArgs 'C:\in.mp4' 'C:\out.mp4' $enc
    $line = $ffArgs -join ' '
    A ($ffArgs[-1] -eq 'C:\out.mp4') 'the destination is the last argument'
    A ($line -like '*-i C:\in.mp4*') 'the source is an input'
    A ($line -like '*force_original_aspect_ratio=decrease*') 'the long edge is capped whichever way up the clip is'
    A ($line -like '*1280:1280*') 'capped at 1280'
    A ($line -like '*trunc(iw/2)*2*') 'dimensions are forced even for yuv420p'
    A ($line -like '*-movflags +faststart*') 'the proxy is seekable from the first byte'
    A ($line -like '*-c:v libx264*') 'the encoder passed in is the one used'
    A ($line -like '*-loglevel error*') 'it does not chatter down the pipe'

    $defaults = Get-ProxyEncoderArgs
    A (($defaults -join ' ') -like '*-g 30*') 'a keyframe every second, which is what makes it seek instantly'

    # ---- a build is only published when it worked --------------------------
    $dest = Join-Path $tmp 'work\proxy-cache\built.mp4'
    $temp = $dest + '.part'
    Write-Fake $temp 60000
    $good = [pscustomobject]@{ ExitCode = 0; Ok = $true; StdOut = ''; StdErr = '' }
    $bad = [pscustomobject]@{ ExitCode = 1; Ok = $false; StdOut = ''; StdErr = 'boom' }
    A (Complete-ProxyBuild ([pscustomobject]@{ Temp = $temp; Dest = $dest }) $good) 'a good build reports success'
    A (Test-Path -LiteralPath $dest) 'and is moved into the cache'
    A (-not (Test-Path -LiteralPath $temp)) 'leaving no .part behind'

    Write-Fake $temp 60000
    $dest2 = Join-Path $tmp 'work\proxy-cache\failed.mp4'
    A (-not (Complete-ProxyBuild ([pscustomobject]@{ Temp = $temp; Dest = $dest2 }) $bad)) 'a failed build reports failure'
    A (-not (Test-Path -LiteralPath $dest2)) 'and publishes nothing'
    A (-not (Test-Path -LiteralPath $temp)) 'and cleans up after itself'

    # ---- never build one for something that cannot have one ---------------
    $png = Join-Path $tmp 'output\photo.png'
    Write-Fake $png 5000
    A ($null -eq (Start-ProxyBuild $tmp 'output/photo.png')) 'no ffmpeg is launched for a photo'
    A ($null -eq (Start-ProxyBuild $tmp 'output/missing.mp4')) 'no ffmpeg is launched for a file that is not there'
    A ($null -eq (Start-ProxyBuild $tmp 'output/clip.mp4')) 'no ffmpeg is launched when the proxy already exists'
}
finally {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host ''
if ($fails -eq 0) { Write-Host "All PreviewProxy tests passed." } else { Write-Host "$fails test(s) FAILED."; exit 1 }
