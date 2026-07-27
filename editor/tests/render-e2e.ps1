# render-e2e.ps1 - synthetic end-to-end render verification.
#
# Builds a real project (two main clips, an overlay video + overlay image,
# one audio clip) out of ffmpeg-synthesized inputs, runs it through
# Build-EditorFilterGraph + a real ffmpeg render (exactly what Editor.ps1's
# 'export' handler does), then verifies the OUTPUT file itself:
#   - resolution matches the project canvas (1080x1920)
#   - duration matches the expected timeline length (within 0.3s)
#   - the overlay is actually visible during its time window and actually
#     absent outside it (proves the filter graph, not just its text, works)
#
# Prints "E2E PASS" on success; otherwise prints a FAIL line per problem and
# exits 1.

. "$PSScriptRoot\..\..\EditorRender.ps1"

$ErrorActionPreference = 'Stop'
$fails = 0
function A($cond, $msg) {
  if ($cond) { Write-Host "PASS: $msg" } else { Write-Host "FAIL: $msg"; $script:fails++ }
}

$scratch = Join-Path $env:TEMP ("editor-e2e-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
Write-Host "scratch dir: $scratch"

function Invoke-Synth([string[]]$ffArgs) {
  # NOTE: must not be named "ffmpeg"/"Ffmpeg" - PowerShell command lookup is
  # case-insensitive, so a same-named function would shadow the real ffmpeg.exe
  # and "& ffmpeg" inside it would recurse into itself (call depth overflow).
  & ffmpeg -y -v error @ffArgs
  if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed: $($ffArgs -join ' ')" }
}

try {
  # ---- synthesize inputs -----------------------------------------------
  $main1  = Join-Path $scratch 'main1.mp4'   # 4s testsrc, main track clip 1
  $main2  = Join-Path $scratch 'main2.mp4'   # 3s solid blue, main track clip 2
  $broll  = Join-Path $scratch 'broll.mp4'   # 3s solid yellow, overlay clip
  $image  = Join-Path $scratch 'image.png'   # still image, overlay clip
  $tone   = Join-Path $scratch 'tone.wav'    # 8s sine tone, audio track clip
  $out    = Join-Path $scratch 'e2e-out.mp4'

  Invoke-Synth @('-f','lavfi','-i','testsrc=size=1080x1920:rate=30','-t','4', $main1)
  Invoke-Synth @('-f','lavfi','-i','color=c=blue:size=1080x1920:rate=30','-t','3', $main2)
  Invoke-Synth @('-f','lavfi','-i','color=c=yellow:size=640x360:rate=30','-t','3', $broll)
  Invoke-Synth @('-f','lavfi','-i','color=c=green:size=400x400','-frames:v','1', $image)
  Invoke-Synth @('-f','lavfi','-i','sine=frequency=440:duration=8', $tone)

  # ---- build the project -------------------------------------------------
  # main:    [main1: 0-4s][main2: 4-7s]                     -> total 7s
  # overlay: [broll: 1-3s @ x100,y200 scale0.3][image: 3-5s @ x300,y600 scale0.4]
  # audio:   [tone: 0-7s]
  $project = @{
    version = 1
    name    = 'e2e test'
    canvas  = @{ width = 1080; height = 1920; fps = 30 }
    assets  = @(
      @{ id='aMain1'; path=$main1; type='video'; naturalW=1080; naturalH=1920; duration=4 }
      @{ id='aMain2'; path=$main2; type='video'; naturalW=1080; naturalH=1920; duration=3 }
      @{ id='aBroll'; path=$broll; type='video'; naturalW=640;  naturalH=360;  duration=3 }
      @{ id='aImage'; path=$image; type='image'; naturalW=400;  naturalH=400;  duration=2 }
      @{ id='aTone';  path=$tone;  type='audio'; duration=8 }
    )
    tracks = @(
      @{ kind='main'; clips=@(
          @{ id='c1'; assetId='aMain1'; start=0; in=0; duration=4; opacity=1; volume=1; muted=$true }
          @{ id='c2'; assetId='aMain2'; start=4; in=0; duration=3; opacity=1; volume=1; muted=$true }
        ) }
      @{ kind='overlay'; clips=@(
          @{ id='c3'; assetId='aBroll'; start=1; in=0; duration=2; x=100; y=200; scale=0.3; opacity=1; muted=$true }
          @{ id='c4'; assetId='aImage'; start=3; in=0; duration=2; x=300; y=600; scale=0.4; opacity=1; muted=$false }
        ) }
      @{ kind='audio'; clips=@(
          @{ id='c5'; assetId='aTone'; start=0; in=0; duration=7; volume=1; muted=$false }
        ) }
    )
  }

  $expectedDur = 7.0

  $ffArgs = Build-EditorFilterGraph $project $out
  & ffmpeg -y -v error @ffArgs
  A ($LASTEXITCODE -eq 0) 'ffmpeg render exited 0'
  A (Test-Path $out) 'output file exists'
  if (-not (Test-Path $out)) { throw 'no output file - cannot continue verification' }

  # ---- ffprobe: resolution + duration ------------------------------------
  $probeJson = & ffprobe -v error -select_streams v:0 -show_entries stream=width,height -show_entries format=duration -of json $out
  $probe = ($probeJson -join "`n") | ConvertFrom-Json
  $width  = [int]$probe.streams[0].width
  $height = [int]$probe.streams[0].height
  $duration = [double]$probe.format.duration

  Write-Host "ffprobe: width=$width height=$height duration=$duration (expected ~$expectedDur)"
  A ($width -eq 1080) "width is 1080 (got $width)"
  A ($height -eq 1920) "height is 1920 (got $height)"
  A ([Math]::Abs($duration - $expectedDur) -le 0.3) "duration ~$expectedDur s (got $duration)"

  # audio stream sanity: an audio track exists in the output
  $aProbeJson = & ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of json $out
  $aProbe = ($aProbeJson -join "`n") | ConvertFrom-Json
  A ($aProbe.streams.Count -ge 1) 'output has an audio stream'

  # ---- pixel sampling: overlay present vs absent -------------------------
  function Grab-AvgColor([double]$t, [int]$x, [int]$y, [int]$w, [int]$h) {
    $raw = Join-Path $scratch ("px_" + [Math]::Round($t*100) + "_" + $x + "_" + $y + ".raw")
    & ffmpeg -y -v error -ss $t -i $out -frames:v 1 -vf "crop=${w}:${h}:${x}:${y}" -f rawvideo -pix_fmt rgb24 $raw
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $raw)) { throw "pixel grab failed at t=$t" }
    $bytes = [System.IO.File]::ReadAllBytes($raw)
    $n = [Math]::Floor($bytes.Length / 3)
    if ($n -le 0) { throw "no pixel data at t=$t" }
    $rSum=0.0; $gSum=0.0; $bSum=0.0
    for ($i=0; $i -lt ($n*3); $i+=3) { $rSum += $bytes[$i]; $gSum += $bytes[$i+1]; $bSum += $bytes[$i+2] }
    return [pscustomobject]@{ r = $rSum/$n; g = $gSum/$n; b = $bSum/$n }
  }
  function ColorDist($c1, $c2) {
    [Math]::Sqrt([Math]::Pow($c1.r-$c2.r,2) + [Math]::Pow($c1.g-$c2.g,2) + [Math]::Pow($c1.b-$c2.b,2))
  }

  # broll overlay box is roughly x100..292, y200..308 (640*.3->192, 360*.3->108,
  # both truncated to even) - sample a small patch well inside it.
  $brollIn  = Grab-AvgColor 2.0 150 230 20 20   # inside broll window (1-3s)
  $brollOut = Grab-AvgColor 6.0 150 230 20 20   # outside every overlay window -> plain main2 (blue)
  Write-Host "broll patch @t=2.0 (overlay window): rgb($($brollIn.r),$($brollIn.g),$($brollIn.b))"
  Write-Host "broll patch @t=6.0 (no overlay):      rgb($($brollOut.r),$($brollOut.g),$($brollOut.b))"
  A ((ColorDist $brollIn $brollOut) -gt 40) 'overlay video is visible in its window and absent outside it'

  # image overlay box is roughly x300..460, y600..760 (400*.4->160, both even) -
  # sample a small patch well inside it.
  $imageIn  = Grab-AvgColor 4.0 340 640 20 20   # inside image window (3-5s)
  $imageOut = Grab-AvgColor 6.0 340 640 20 20   # outside every overlay window -> plain main2 (blue)
  Write-Host "image patch @t=4.0 (overlay window): rgb($($imageIn.r),$($imageIn.g),$($imageIn.b))"
  Write-Host "image patch @t=6.0 (no overlay):      rgb($($imageOut.r),$($imageOut.g),$($imageOut.b))"
  A ((ColorDist $imageIn $imageOut) -gt 40) 'overlay image is visible in its window and absent outside it'

} finally {
  # Best-effort cleanup; leave the dir behind on failure for inspection.
  if ($fails -eq 0) { Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue }
}

if ($fails -gt 0) {
  Write-Host "FAILS=$fails"
  exit 1
} else {
  Write-Host 'E2E PASS'
}
