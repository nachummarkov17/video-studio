# Apply-Trims.ps1
# Reads trim-points.txt and actually cuts each video to its START..END.
# - Keeps a full-length backup in output\_full-length\ (so you can re-edit the
#   times and re-run this anytime, cutting fresh from the full version).
# - Clears that video's .srt caption and any burned copy, because their timings
#   no longer match the shorter video - just re-run captions afterwards.

[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,
    [int]   $Crf  = 18     # trimmed-video quality (lower = better/bigger)
)

if (-not $Root -or -not (Test-Path (Join-Path $Root "Srt-Chunk.ps1"))) {
    if ($PSCommandPath) { $Root = Split-Path -Parent $PSCommandPath }
}
$out     = Join-Path $Root "output"
$full    = Join-Path $out  "_full-length"
$burned  = Join-Path $out  "captioned"
$work    = Join-Path $Root "work"
$ptsFile = Join-Path $Root "trim-points.txt"
$log     = Join-Path $Root "cleaner.log"
New-Item -ItemType Directory -Force -Path $full,$work | Out-Null

function Write-Log($m) {
    $line = ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m)
    Write-Host $line
    Add-Content -Path $log -Value $line -Encoding UTF8
}

if (-not (Test-Path $ptsFile)) { Write-Log "No trim-points.txt found. Run Find-Trims.bat first."; exit 1 }
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { Write-Log "ERROR: ffmpeg not on PATH"; exit 1 }

$entries = Get-Content $ptsFile | Where-Object { $_ -and ($_ -notmatch '^\s*#') -and ($_ -match '\|') }
if (-not $entries) { Write-Log "No trim lines in trim-points.txt (nothing to do)."; exit 0 }

$done = 0; $failed = 0
foreach ($line in $entries) {
    $parts = $line -split '\|'
    if ($parts.Count -lt 3) { continue }
    $name  = $parts[0].Trim()
    $start = $parts[1].Trim()
    $end   = $parts[2].Trim()
    $target = Join-Path $out $name
    $backup = Join-Path $full $name

    if (-not (Test-Path $target) -and -not (Test-Path $backup)) { Write-Log "SKIP (no such video): $name"; continue }

    try {
        # First time we trim this file, stash the full-length version. Always cut
        # from that full version so re-runs start clean.
        if (-not (Test-Path $backup)) { Copy-Item $target $backup -Force }
        $src = $backup

        Write-Log "Trimming $name  ->  $start .. $end"
        $tmp = Join-Path $work $name
        & ffmpeg -y -loglevel error -i $src -ss $start -to $end -c:v libx264 -profile:v high -preset veryfast -crf $Crf -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 256k -ar 48000 $tmp
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg trim failed" }
        Move-Item $tmp $target -Force

        # Stale captions / burned copy no longer match -> remove so they get remade.
        $srt = Join-Path $out ([System.IO.Path]::GetFileNameWithoutExtension($name) + ".srt")
        if (Test-Path $srt)             { Remove-Item $srt -Force -ErrorAction SilentlyContinue }
        if (Test-Path (Join-Path $burned $name)) { Remove-Item (Join-Path $burned $name) -Force -ErrorAction SilentlyContinue }

        Write-Log "TRIMMED: $name"
        $done++
    }
    catch {
        Write-Log "TRIM FAILED: $name - $($_.Exception.Message)"
        $failed++
    }
    finally {
        Remove-Item (Join-Path $work $name) -Force -ErrorAction SilentlyContinue
    }
}
Write-Log ("Trim complete. Trimmed {0}, failed {1}. Full-length backups kept in {2}" -f $done, $failed, $full)
Write-Log "If you had captions, re-run Run-Captions.bat now so the .srt matches the trimmed length."
