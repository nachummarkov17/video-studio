# RenderE2E.Tests.ps1 - runs REAL ffmpeg. The unit tests check the shape of the
# argument vectors; this checks that ffmpeg accepts them and produces a file you
# could actually play, which is the part that was broken.
#
# Needs ffmpeg/ffprobe on PATH (the app needs them anyway). Takes ~30s.
#
# Run:  powershell -STA -ExecutionPolicy Bypass -File tests\RenderE2E.Tests.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
. "$PSScriptRoot\..\ProcessRunner.ps1"
. "$PSScriptRoot\..\VideoColor.ps1"
. "$PSScriptRoot\..\PreviewProxy.ps1"
. "$PSScriptRoot\..\EditorExport.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }
function Probe([string]$path, [string]$entries) {
    return (& ffprobe -v error -select_streams v:0 -show_entries $entries -of default=nw=1:nk=1 -- $path 2>$null)
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("RenderE2E_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'output') | Out-Null

try {
    # A portrait clip like the user's phone footage: 1080x1920 - the orientation
    # a naive "scale to 1280 wide" would have blown up to 1280x2276 - and tagged
    # HDR (bt2020 primaries, HLG transfer), which is what iPhones actually
    # produce and what every re-encode here used to silently throw away.
    $src = Join-Path $tmp 'output\source.mp4'
    # NOTE the setparams: even MAKING this clip needs it, because a lavfi source
    # is itself a filtergraph and the -color_* flags alone are dropped. That is
    # the very behaviour this test exists to pin down.
    & ffmpeg -y -hide_banner -loglevel error -f lavfi -i testsrc2=size=1080x1920:rate=30:duration=6 `
             -f lavfi -i sine=frequency=440:duration=6 `
             -vf 'setparams=range=tv:colorspace=bt2020nc:color_primaries=bt2020:color_trc=arib-std-b67' `
             -c:v libx264 -preset ultrafast -pix_fmt yuv420p `
             -colorspace bt2020nc -color_primaries bt2020 -color_trc arib-std-b67 -color_range tv `
             -c:a aac -shortest $src 2>$null | Out-Null
    A (Test-Path -LiteralPath $src) 'built a 1080x1920 test clip'

    $srcTags = Get-VideoColorTags $src
    A (Test-HdrTags $srcTags) "the test clip really is HDR-tagged (trc=$($srcTags.Transfer))"

    # ---- a proxy is really produced, and really is small -------------------
    $build = Start-ProxyBuild $tmp 'output/source.mp4'
    A ($null -ne $build) 'the proxy build started'
    $build.Tracked.Process.WaitForExit(120000) | Out-Null
    $result = Get-ProcessResult $build.Tracked
    A ($result.Ok) "ffmpeg accepted the proxy arguments (exit $($result.ExitCode)): $($result.StdErr)"
    A (Complete-ProxyBuild $build $result) 'the proxy was published to the cache'
    A (Test-ProxyReady $tmp 'output/source.mp4') 'and the app can see it'

    $proxy = Get-ProxyPath $tmp 'output/source.mp4'
    $w = [int](Probe $proxy 'stream=width')
    $h = [int](Probe $proxy 'stream=height')
    A ($w -eq 720 -and $h -eq 1280) "portrait stays portrait, long edge capped (got ${w}x${h})"
    A (((Get-Item $proxy).Length) -lt ((Get-Item $src).Length)) 'the proxy is smaller than the master'

    # The preview must look like the export, or you grade against a lie.
    $proxyTags = Get-VideoColorTags $proxy
    A ($proxyTags.Transfer -eq $srcTags.Transfer -and $proxyTags.Primaries -eq $srcTags.Primaries -and
       $proxyTags.Space -eq $srcTags.Space -and $proxyTags.Range -eq $srcTags.Range) `
       "the proxy keeps all four colour tags (got trc=$($proxyTags.Transfer) prim=$($proxyTags.Primaries))"

    # ---- the export renders, reports real progress, and publishes ----------
    $project = @{
        name = 'E2E Clip'
        canvas = @{ width = 1080; height = 1920; fps = 30 }
        assets = @(@{ id = 'a1'; path = 'output/source.mp4'; type = 'video'; duration = 6 })
        tracks = @(@{ id = 't1'; kind = 'main'; clips = @(
            @{ id = 'c1'; assetId = 'a1'; start = 0;   in = 0; duration = 2; volume = 1; muted = $false },
            @{ id = 'c2'; assetId = 'a1'; start = 2;   in = 4; duration = 2; volume = 1; muted = $false }) })
    }
    $paths = Get-ExportPaths $tmp 'E2E Clip'
    New-Item -ItemType Directory -Force -Path $paths.WorkDir | Out-Null
    $resolved = Resolve-EditorAssetPaths $project $tmp
    $duration = Get-EditorTimelineDuration $resolved
    A ([Math]::Abs($duration - 4) -lt 0.001) 'the timeline is 4s long (two 2s pieces)'

    $ffArgs = @('-y', '-hide_banner', '-nostats', '-loglevel', 'warning',
                '-progress', $paths.Progress) + (Build-EditorFilterGraph $resolved $paths.Temp $srcTags)
    $tracked = Start-TrackedProcess -FilePath 'ffmpeg' -ArgumentList $ffArgs
    $tracked.Process.WaitForExit(180000) | Out-Null
    $r2 = Get-ProcessResult $tracked
    A ($r2.Ok) "ffmpeg accepted the export arguments (exit $($r2.ExitCode)): $($r2.StdErr)"

    $secs = Read-FfmpegProgressSeconds $paths.Progress
    A ($null -ne $secs) 'ffmpeg wrote progress we can actually read'
    A ($secs -gt 0) "progress reached $secs seconds"
    A ((Get-RenderPercent $secs $duration) -gt 0) 'which turns into a real percentage'

    $done = Complete-EditorRender $r2 $paths
    A ($done.Ok) "the render was published: $($done.Error)"
    A (Test-Path -LiteralPath $paths.Final) 'the finished video is in output\'
    A (-not (Test-Path -LiteralPath $paths.Progress)) 'the progress file was tidied up'

    $outDur = [double](& ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 -- $paths.Final 2>$null)
    A ([Math]::Abs($outDur - 4) -lt 0.35) "the exported video is 4s long (got $outDur)"
    # The failure the user actually saw was a file that would not open. Decoding
    # it end to end is the only honest way to say it's fine.
    & ffmpeg -v error -i $paths.Final -f null - 2>$null | Out-Null
    A ($LASTEXITCODE -eq 0) 'the exported video decodes cleanly from start to finish'
    A (((Probe $paths.Final 'stream=width') -eq '1080')) 'and is still full resolution - the master was rendered, not the proxy'

    # THE WASHED-OUT BUG. A filtergraph drops primaries and transfer, and ffmpeg
    # takes the encoder's colour from the filter output - so without setparams
    # these two come back "unknown", the player falls back to BT.709, and HDR
    # footage plays back bright and milky with no pixel changed.
    $outTags = Get-VideoColorTags $paths.Final
    A ($outTags.Space -eq $srcTags.Space) "matrix survives the render (got $($outTags.Space))"
    A ($outTags.Range -eq $srcTags.Range) "range survives the render (got $($outTags.Range))"
    A ($outTags.Primaries -eq $srcTags.Primaries) "PRIMARIES survive the render (got $($outTags.Primaries))"
    A ($outTags.Transfer -eq $srcTags.Transfer) "TRANSFER survives the render (got $($outTags.Transfer))"
    A (Test-HdrTags $outTags) 'the exported file still declares itself HDR'
}
finally {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host ''
if ($fails -eq 0) { Write-Host "All render end-to-end tests passed." } else { Write-Host "$fails test(s) FAILED."; exit 1 }
