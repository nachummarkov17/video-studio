# Apply-Music.ps1
# Mixes a steady, quiet background-music bed under each video, using the
# assignments in music-map.txt. Your voice is left at full level; the music sits
# well underneath it (auto-leveled so different tracks all sound equally subtle),
# loops to fill the whole video, and fades in/out.
#
# Reads:  <SourceDir>\<name>.mp4  +  music\<track>   (per music-map.txt)
# Writes: <SourceDir>\with-music\<name>.mp4          (originals are left alone)

[CmdletBinding()]
param(
    [string]$Root      = $PSScriptRoot,
    [string]$SourceDir = "output",   # folder holding the videos (relative to Root)
    [double]$MusicLUFS = -30,        # music loudness: MORE negative = quieter. Your voice is ~-14.
    [double]$FadeSec   = 2,          # fade the music in at the start / out at the end
    [int]   $AudioKbps = 192,
    [switch]$Force                   # re-do videos already in with-music\
)

if (-not $Root -or -not (Test-Path (Join-Path $Root "Srt-Chunk.ps1"))) {
    if ($PSCommandPath) { $Root = Split-Path -Parent $PSCommandPath }
}
$src   = Join-Path $Root $SourceDir
$dest  = Join-Path (Join-Path $Root "output") "with-music"   # always land here, whatever the source stage
$music = Join-Path $Root "music"
$map   = Join-Path $Root "music-map.txt"
$log   = Join-Path $Root "cleaner.log"

function Write-Log($m) {
    $line = ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m)
    Write-Host $line
    Add-Content -Path $log -Value $line -Encoding UTF8
}

if (-not (Get-Command ffmpeg  -ErrorAction SilentlyContinue)) { Write-Log "ERROR: ffmpeg not on PATH";  exit 1 }
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) { Write-Log "ERROR: ffprobe not on PATH"; exit 1 }
if (-not (Test-Path $map)) { Write-Log "No music-map.txt found - run Find-Music.bat first."; exit 1 }
New-Item -ItemType Directory -Force -Path $dest | Out-Null

$inv = [System.Globalization.CultureInfo]::InvariantCulture
$skipWords = @('none','skip','no','-','')

$made = 0; $skipped = 0; $failed = 0
foreach ($line in Get-Content -LiteralPath $map -Encoding UTF8) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    $parts = $t -split '\|', 2
    $vName = $parts[0].Trim()
    $tName = ''
    if ($parts.Count -ge 2) { $tName = $parts[1].Trim() }
    if (-not $vName) { continue }

    $video = Join-Path $src $vName
    if (-not (Test-Path $video)) { Write-Log "SKIP (no video): $vName"; $skipped++; continue }
    if ($skipWords -contains $tName.ToLower()) { Write-Log "No music assigned, skipping: $vName"; $skipped++; continue }

    $track = Join-Path $music $tName
    if (-not (Test-Path $track)) { Write-Log "SKIP (track '$tName' not in music\): $vName"; $skipped++; continue }

    $outFile = Join-Path $dest $vName
    if ((Test-Path $outFile) -and -not $Force) { Write-Log "Already done, skipping: with-music\$vName (delete it or use -Force to redo)"; $skipped++; continue }

    try {
        # length of the video, so we can time the fade-out
        $durRaw = (& ffprobe -v error -show_entries format=duration -of csv=p=0 $video) | Select-Object -First 1
        $dur = 0.0; [void][double]::TryParse([string]$durRaw, [System.Globalization.NumberStyles]::Float, $inv, [ref]$dur)
        $foStart = $dur - $FadeSec
        if ($foStart -lt 0) { $foStart = 0 }
        $foStr = $foStart.ToString($inv)

        # [1:a] = music: level it to a quiet target, fade in/out.  Then mix under the
        # voice [0:a] WITHOUT amix's auto-halving (normalize=0), and limit any peaks.
        $af = "[1:a]loudnorm=I=${MusicLUFS}:TP=-3:LRA=11,afade=t=in:d=${FadeSec},afade=t=out:st=${foStr}:d=${FadeSec}[m];" +
              "[0:a][m]amix=inputs=2:normalize=0:duration=first,alimiter=limit=0.95[a]"

        Write-Log "Adding music ($tName) to: $vName"
        & ffmpeg -y -loglevel error -i $video -stream_loop -1 -i $track `
            -filter_complex $af -map 0:v:0 -map "[a]" `
            -c:v copy -c:a aac -b:a "$($AudioKbps)k" -movflags +faststart $outFile
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg mix failed" }

        Write-Log "MUSIC ADDED: with-music\$vName"
        $made++
    }
    catch {
        Write-Log "MUSIC FAILED: $vName - $($_.Exception.Message)"
        if (Test-Path $outFile) { [System.IO.File]::Delete($outFile) }
        $failed++
    }
}
Write-Log ("Background music done. Made {0}, skipped {1}, failed {2}. Videos with music are in {3}" -f $made, $skipped, $failed, $dest)
