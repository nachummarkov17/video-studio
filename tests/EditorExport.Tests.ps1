# EditorExport.Tests.ps1 - the parts of the editor's render that decide whether
# you get a finished video or a corrupt one in "Your videos".
#
# Run:  powershell -ExecutionPolicy Bypass -File tests\EditorExport.Tests.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
. "$PSScriptRoot\..\EditorExport.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ExportTest_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
function Fake([string]$path, [int]$bytes) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    [System.IO.File]::WriteAllBytes($path, (New-Object byte[] $bytes))
}
function FakeResult([int]$code, [string]$err = '') {
    return [pscustomobject]@{ ExitCode = $code; StdOut = ''; StdErr = $err; Ok = ($code -eq 0) }
}

try {
    # ---- paths -------------------------------------------------------------
    $p = Get-ExportPaths $tmp 'My Clip'
    A ($p.Final -eq (Join-Path $tmp 'output\My Clip.mp4')) 'the finished file lands in output\'
    A ($p.Temp -like "*work\export\My Clip.mp4") 'the render itself goes to work\export\ first'
    A ($p.Temp -ne $p.Final) 'a render in progress is never at the published path'
    A ((Get-ExportPaths $tmp 'bad:name?').Name -eq 'bad_name_') 'the name is sanitised for the filesystem'

    # ---- progress parsing --------------------------------------------------
    $prog = Join-Path $tmp 'p.txt'
    Set-Content -LiteralPath $prog -Value @(
        'frame=30', 'out_time=00:00:01.000000', 'progress=continue'
        'frame=90', 'out_time=00:00:03.500000', 'progress=continue'
    ) -Encoding ASCII
    A ([Math]::Abs((Read-FfmpegProgressSeconds $prog) - 3.5) -lt 0.001) 'the latest out_time wins'

    # out_time_ms has meant microseconds in several ffmpeg releases, so we must
    # not depend on it; out_time_us is the fallback.
    Set-Content -LiteralPath $prog -Value @('out_time_us=7000000', 'progress=continue') -Encoding ASCII
    A ([Math]::Abs((Read-FfmpegProgressSeconds $prog) - 7.0) -lt 0.001) 'out_time_us is read as microseconds'
    A ($null -eq (Read-FfmpegProgressSeconds (Join-Path $tmp 'nope.txt'))) 'a missing progress file is null, not an error'
    Set-Content -LiteralPath $prog -Value 'frame=1' -Encoding ASCII
    A ($null -eq (Read-FfmpegProgressSeconds $prog)) 'a progress file with no timestamp yet is null'

    A ((Get-RenderPercent 30 120) -eq 25) 'quarter way is 25%'
    A ((Get-RenderPercent 0 120) -eq 0) 'nothing rendered is 0%'
    A ((Get-RenderPercent 120 120) -eq 99) 'a full bar waits for the process to exit'
    A ((Get-RenderPercent 500 120) -eq 99) 'overshoot still caps at 99%'
    A ((Get-RenderPercent 10 0) -eq 0) 'an empty timeline cannot divide by zero'

    # ---- what counts as a successful render --------------------------------
    $good = Join-Path $tmp 'good.mp4'; Fake $good 50000
    $stub = Join-Path $tmp 'stub.mp4'; Fake $stub 200
    A (Test-RenderSucceeded (FakeResult 0) $good) 'exit 0 plus a real file is a success'
    A (-not (Test-RenderSucceeded (FakeResult 1) $good)) 'a non-zero exit is a failure even with a file present'
    A (-not (Test-RenderSucceeded (FakeResult 0) $stub)) 'the stub ffmpeg creates and abandons is NOT a success'
    A (-not (Test-RenderSucceeded (FakeResult 0) (Join-Path $tmp 'missing.mp4'))) 'no file is a failure'

    # ---- publishing --------------------------------------------------------
    $paths = Get-ExportPaths $tmp 'Publish Me'
    New-Item -ItemType Directory -Force -Path $paths.WorkDir | Out-Null
    Fake $paths.Temp 60000
    Fake $paths.Progress 10
    $done = Complete-EditorRender (FakeResult 0) $paths
    A ($done.Ok) 'a good render reports Ok'
    A (Test-Path -LiteralPath $paths.Final) 'the finished file is moved into output\'
    A (-not (Test-Path -LiteralPath $paths.Temp)) 'nothing is left behind in work\export\'
    A (-not (Test-Path -LiteralPath $paths.Progress)) 'the progress file is cleaned up'

    # a FAILED render must not publish anything - this is the "it added a file
    # that will not open" bug
    $paths2 = Get-ExportPaths $tmp 'Broken One'
    Fake $paths2.Temp 60000
    $done2 = Complete-EditorRender (FakeResult 1 "x264 [error]: baseline profile doesn't support 4:4:4`nConversion failed!") $paths2
    A (-not $done2.Ok) 'a failed render reports not-Ok'
    A (-not (Test-Path -LiteralPath $paths2.Final)) 'a failed render publishes NOTHING to output\'
    A (-not (Test-Path -LiteralPath $paths2.Temp)) 'the partial file is deleted'
    A ($done2.Error -like '*Conversion failed*') "the failure says what ffmpeg said (got '$($done2.Error)')"
    A (Test-Path -LiteralPath $paths2.Log) 'the full ffmpeg output is logged'

    # ---- suggested export name --------------------------------------------
    $proj = @{
        name = 'Untitled'
        assets = @(@{ id = 'a1'; path = 'output/IMG_4923.mp4' })
        tracks = @(@{ kind = 'main'; clips = @(@{ assetId = 'a1' }) })
    }
    # " edit" is not decoration: offering the SOURCE clip's own name is what led
    # to an export being written straight over the footage it was cut from.
    A ((Get-SuggestedExportName $proj) -eq 'IMG_4923 edit') 'an unnamed project suggests its first clip PLUS " edit", never the bare source name'
    $proj.name = 'Shopping Haul'
    A ((Get-SuggestedExportName $proj) -eq 'Shopping Haul') 'a named project suggests its own name'
    A ((Get-SuggestedExportName @{ name = ''; assets = @(); tracks = @() }) -eq 'Untitled') 'an empty project falls back to Untitled'

    # ---- never export over your own footage --------------------------------
    $srcProj = @{
        assets = @(@{ id = 'a1'; path = 'output/IMG_4923.mp4' }, @{ id = 'a2'; path = 'broll/city.mp4' })
        tracks = @(@{ kind = 'main'; clips = @(@{ assetId = 'a1' }) })
    }
    A (Test-ExportOverwritesSource $srcProj (Join-Path $tmp 'output\IMG_4923.mp4') $tmp) 'exporting onto a source clip is detected'
    A (Test-ExportOverwritesSource $srcProj (Join-Path $tmp 'OUTPUT\img_4923.MP4') $tmp) 'and the check is case-insensitive, like Windows'
    A (Test-ExportOverwritesSource $srcProj (Join-Path $tmp 'broll\city.mp4') $tmp) 'b-roll counts as a source too'
    A (-not (Test-ExportOverwritesSource $srcProj (Join-Path $tmp 'output\IMG_4923 edit.mp4') $tmp)) 'a different name is fine'
    A (-not (Test-ExportOverwritesSource @{ assets = @() } (Join-Path $tmp 'output\x.mp4') $tmp)) 'a project with no assets overwrites nothing'

    # ---- timeline duration -------------------------------------------------
    $tl = @{ tracks = @(
        @{ kind = 'main';    clips = @(@{ start = 0; duration = 73.1 }, @{ start = 73.1; duration = 12.1 }) },
        @{ kind = 'overlay'; clips = @(@{ start = 2; duration = 3 }) }) }
    A ([Math]::Abs((Get-EditorTimelineDuration $tl) - 85.2) -lt 0.001) 'duration is the furthest clip end across all tracks'
    A ((Get-EditorTimelineDuration @{ tracks = @() }) -eq 0) 'an empty timeline is zero long'
}
finally {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host ''
if ($fails -eq 0) { Write-Host "All EditorExport tests passed." } else { Write-Host "$fails test(s) FAILED."; exit 1 }
