# Convert-Imports.ps1
# Transcodes source clips that aren't already editable H.264 8-bit mp4 (e.g. iPhone
# HEVC 10-bit .MOV) into H.264 8-bit mp4 in output\, KEEPING the original resolution.
# Uses the GPU (h264_nvenc) with a CPU (libx264) fallback. ffmpeg auto-rotates, so
# portrait phone clips come out upright. Launched by Studio's "Add videos" for any
# clip that needs converting; the already-good mp4s are copied straight in by Studio.
param([string]$ListFile)

$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$OutDir = Join-Path $Root 'output'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
. (Join-Path $Root 'VideoColor.ps1')

if (-not $ListFile -or -not (Test-Path -LiteralPath $ListFile)) {
    Write-Output "Nothing to convert."
    exit 0
}
$paths = @(Get-Content -LiteralPath $ListFile -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
if ($paths.Count -eq 0) { Write-Output "Nothing to convert."; exit 0 }

$done = 0; $failed = 0
foreach ($raw in $paths) {
    $src = $raw.Trim()
    if (-not (Test-Path -LiteralPath $src)) { Write-Output "Missing, skipped: $src"; $failed++; continue }
    $name = [System.IO.Path]::GetFileName($src)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($src)
    $dest = Join-Path $OutDir ($base + '.mp4')

    Write-Output "Converting '$name' to H.264 mp4 (keeping full resolution - 4K can take a minute)..."

    # Carry the clip's colour tags across. Phone footage is often HDR (HLG), and
    # an untagged copy of it plays back washed out and bright even though the
    # pixels are unchanged.
    $colorArgs = Get-ColorArgsForSource $src
    if ($colorArgs) { Write-Output ("  colour: " + ($colorArgs -join ' ')) }

    # GPU first (fast). h264_nvenc is 8-bit; -pix_fmt yuv420p converts 10-bit sources.
    $gpuArgs = @('-y','-hide_banner','-loglevel','error','-i',$src,
                 '-c:v','h264_nvenc','-preset','p5','-cq','20','-pix_fmt','yuv420p',
                 '-c:a','aac','-b:a','256k','-movflags','+faststart') + $colorArgs + @($dest)
    & ffmpeg @gpuArgs

    $okGpu = (Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -gt 100000)
    if (-not $okGpu) {
        Write-Output "  GPU encoder unavailable/failed - using CPU (slower)..."
        $cpuArgs = @('-y','-hide_banner','-loglevel','error','-i',$src,
                     '-c:v','libx264','-preset','medium','-crf','20','-pix_fmt','yuv420p',
                     '-c:a','aac','-b:a','256k','-movflags','+faststart') + $colorArgs + @($dest)
        & ffmpeg @cpuArgs
    }

    if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -gt 100000)) {
        Write-Output "  Done: $base.mp4"
        $done++
    } else {
        Write-Output "  FAILED to convert: $name"
        $failed++
    }
}

Write-Output ""
Write-Output "Conversion complete: $done converted, $failed failed."
