# Export-ForUpload.ps1
# Renders an upload-ready "master" of each finished video, encoded to exactly the
# settings YouTube and Instagram ask for - so it survives their re-compression
# with as little quality loss as possible.
#
# What it sets (from YouTube's + Instagram's official recommendations):
#   - H.264 High profile, yuv420p, 2 B-frames, closed GOP  (their preferred codec)
#   - "Fast start" (moov atom at front) so it streams/processes cleanly
#   - AAC audio, 48 kHz, 384 kbps
#   - CRF 18 = a high-quality master (well above the platforms' delivery bitrate,
#     which gives their encoder clean data to work from)
#   - Keeps your original resolution and aspect ratio (no letterboxing).
#
# It does NOT crop or change framing. Vertical stays vertical, landscape stays
# landscape. (For Shorts/Reels you want vertical 9:16 - see UPLOAD-GUIDE.txt.)
#
# Reads:  <SourceDir>\<name>.mp4        (default SourceDir = output)
# Writes: <SourceDir>\upload\<name>.mp4

[CmdletBinding()]
param(
    [string]$Root       = $PSScriptRoot,
    [string]$SourceDir  = "output",   # which finished videos to export (e.g. output, output\captioned, output\with-music)
    [int]   $Crf        = 18,         # master quality (lower = better/bigger). 18 is visually near-perfect.
    [string]$Preset     = "slow",     # x264 effort: slow = better compression/quality (slower). Use "medium" for speed.
    [switch]$FourK,                   # upscale ~1080p footage to 4K (helps YouTube Shorts pick its better codec - see guide)
    [double]$MaxBitrateM = 0,         # optional cap in Mbps (Instagram likes ~12; 0 = no cap, pure CRF)
    [switch]$Force
)

if (-not $Root -or -not (Test-Path (Join-Path $Root "Srt-Chunk.ps1"))) {
    if ($PSCommandPath) { $Root = Split-Path -Parent $PSCommandPath }
}
$src  = Join-Path $Root $SourceDir
$dest = Join-Path (Join-Path $Root "output") "upload"   # finished masters always land here, whatever the source stage
$log  = Join-Path $Root "cleaner.log"

. (Join-Path $Root "Srt-Chunk.ps1")   # for Get-TargetFps (constant-frame-rate helper)

function Write-Log($m) {
    $line = ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m)
    Write-Host $line
    Add-Content -Path $log -Value $line -Encoding UTF8
}

if (-not (Get-Command ffmpeg  -ErrorAction SilentlyContinue)) { Write-Log "ERROR: ffmpeg not on PATH";  exit 1 }
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) { Write-Log "ERROR: ffprobe not on PATH"; exit 1 }
if (-not (Test-Path $src)) { Write-Log "No '$SourceDir' folder found."; exit 1 }
New-Item -ItemType Directory -Force -Path $dest | Out-Null

# Shared clip ordering - "Your videos" order, top to bottom.
. (Join-Path $Root "VideoOrder.ps1")

$inv  = [System.Globalization.CultureInfo]::InvariantCulture
$vids = @(Get-OrderedVideos $Root $src '*.mp4')
if (-not $vids) { Write-Log "No videos in $src to export."; exit 0 }

Write-Log ("=== Export for upload (CRF $Crf, $Preset, H.264 High) from $SourceDir ===")
$made = 0; $skipped = 0; $failed = 0
foreach ($v in $vids) {
    $outFile = Join-Path $dest $v.Name
    if ((Test-Path $outFile) -and -not $Force) { Write-Log "Already exported, skipping: upload\$($v.Name)"; $skipped++; continue }

    try {
        # source dimensions (for the 4K upscale) + a CONSTANT output frame rate
        # (VFR phone footage otherwise drifts video behind audio on playback/upload)
        $w = 0; $h = 0
        $dims = (& ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 $v.FullName) | Select-Object -First 1
        if ($dims) {
            $d = $dims -split ','
            if ($d.Count -ge 2) { [void][int]::TryParse($d[0], [ref]$w); [void][int]::TryParse($d[1], [ref]$h) }
        }
        $fps = Get-TargetFps $v.FullName
        $gop = [int]($fps * 2)

        $args = @('-y','-loglevel','error','-i', $v.FullName)

        # Optional 4K upscale (only if the footage isn't already ~4K), orientation-agnostic
        if ($FourK) {
            $maxDim = [math]::Max($w, $h)
            if ($maxDim -gt 0 -and $maxDim -lt 2160) {
                $args += @('-vf','scale=iw*2:ih*2:flags=lanczos')
                Write-Log "  upscaling ${w}x${h} -> $([int]($w*2))x$([int]($h*2)) (4K master for Shorts)"
            } else {
                Write-Log "  -FourK ignored: $($v.Name) is already high-res (${w}x${h})"
            }
        }

        $args += @(
            '-vsync','cfr','-r',"$fps",
            '-c:v','libx264','-profile:v','high','-preset',$Preset,'-crf',"$Crf",
            '-pix_fmt','yuv420p','-bf','2','-flags','+cgop','-g',"$gop",
            '-c:a','aac','-b:a','384k','-ar','48000',
            '-movflags','+faststart'
        )
        if ($MaxBitrateM -gt 0) {
            $mb  = $MaxBitrateM.ToString($inv)
            $buf = ($MaxBitrateM * 1.5).ToString($inv)
            $args += @('-maxrate',"${mb}M",'-bufsize',"${buf}M")
        }
        $args += $outFile

        Write-Log "Exporting: $($v.Name)"
        & ffmpeg @args
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg export failed" }
        Write-Log "EXPORTED: upload\$($v.Name)"
        $made++
    }
    catch {
        Write-Log "EXPORT FAILED: $($v.Name) - $($_.Exception.Message)"
        if (Test-Path $outFile) { [System.IO.File]::Delete($outFile) }
        $failed++
    }
}
Write-Log ("Export complete. Made {0}, skipped {1}, failed {2}. Upload-ready files are in {3}" -f $made, $skipped, $failed, $dest)
