# Find-Trims.ps1
# Looks at each cleaned video and works out where the LAST take is (using the
# denoised audio, so silence is real silence). Writes proposed cut points to
# trim-points.txt for you to review/edit. THIS CUTS NOTHING - it only proposes.
#
# A silent gap of >= TakeGapSec seconds counts as a break between takes.
# Keeps the last take, plus PadSec seconds of padding before/after your talking.

[CmdletBinding()]
param(
    [string]$Root       = $PSScriptRoot,
    [double]$TakeGapSec = 3.0,    # silence this long (or longer) = a break between takes
    [double]$PadSec     = 1.0,    # seconds of breathing room kept before first / after last word
    [int]   $SilenceDb  = 40      # below -this- many dB counts as silence (tuned for a clean mic's natural room floor)
)

if (-not $Root -or -not (Test-Path (Join-Path $Root "Srt-Chunk.ps1"))) {
    if ($PSCommandPath) { $Root = Split-Path -Parent $PSCommandPath }
}
$out      = Join-Path $Root "output"
$full     = Join-Path $out  "_full-length"
$ptsFile  = Join-Path $Root "trim-points.txt"

function Fmt($sec) {
    if ($sec -lt 0) { $sec = 0 }
    $ts = [TimeSpan]::FromSeconds([double]$sec)
    "{0:00}:{1:00}:{2:00}.{3:000}" -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds, $ts.Milliseconds
}

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { Write-Host "ERROR: ffmpeg not on PATH"; exit 1 }
$vids = Get-ChildItem -Path $out -Filter *.mp4 -File -ErrorAction SilentlyContinue
if (-not $vids) { Write-Host "No videos to analyze. Use 'Add videos' first."; exit 0 }

$lines = @(
    "# TRIM POINTS  -  edit the START and END times below, then run Apply-Trims.bat",
    "# format:   filename.mp4 | START | END | (info - ignored)",
    "# times are HH:MM:SS.mmm  |  default = keep the LAST take + ${PadSec}s padding",
    "# (delete a whole line to leave that video untrimmed)",
    ""
)

Write-Host ("Analyzing {0} video(s) (take gap {1}s, padding {2}s)..." -f $vids.Count, $TakeGapSec, $PadSec)
foreach ($v in $vids) {
    # Prefer the full-length backup if a previous trim already made one.
    $src = if (Test-Path (Join-Path $full $v.Name)) { Join-Path $full $v.Name } else { $v.FullName }
    $D = [double](ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $src)

    $raw = (& ffmpeg -hide_banner -nostats -i $src -af "silencedetect=noise=-${SilenceDb}dB:d=0.3" -f null - 2>&1 | Out-String)
    $starts = [regex]::Matches($raw, 'silence_start:\s*([\d.]+)') | ForEach-Object { [double]$_.Groups[1].Value }
    $ends   = [regex]::Matches($raw, 'silence_end:\s*([\d.]+)')   | ForEach-Object { [double]$_.Groups[1].Value }

    # Build silence intervals, then the speech intervals between them.
    $sil = @()
    for ($i = 0; $i -lt $starts.Count; $i++) {
        $e = if ($i -lt $ends.Count) { $ends[$i] } else { $D }
        $sil += [pscustomobject]@{ Start = $starts[$i]; End = $e }
    }
    $speech = @(); $prev = 0.0
    foreach ($s in ($sil | Sort-Object Start)) {
        if ($s.Start - $prev -gt 0.05) { $speech += [pscustomobject]@{ Start = $prev; End = $s.Start } }
        $prev = $s.End
    }
    if ($D - $prev -gt 0.05) { $speech += [pscustomobject]@{ Start = $prev; End = $D } }

    if (-not $speech) {
        $takeStart = 0.0; $takeEnd = $D; $takes = 1
    } else {
        $takeStart = $speech[0].Start; $takes = 1
        for ($i = 1; $i -lt $speech.Count; $i++) {
            if (($speech[$i].Start - $speech[$i-1].End) -ge $TakeGapSec) { $takeStart = $speech[$i].Start; $takes++ }
        }
        $takeEnd = $speech[-1].End
    }

    $startCut = [math]::Max(0.0, $takeStart - $PadSec)
    $endCut   = [math]::Min($D,   $takeEnd   + $PadSec)
    $lines += ("{0} | {1} | {2} | (full {3}; last take {4}-{5}; {6} take(s))" -f `
        $v.Name, (Fmt $startCut), (Fmt $endCut), (Fmt $D), (Fmt $takeStart), (Fmt $takeEnd), $takes)
    Write-Host ("  {0}  ->  keep {1} to {2}  ({3} take(s) found)" -f $v.Name, (Fmt $startCut), (Fmt $endCut), $takes)
}

Set-Content -Path $ptsFile -Value $lines -Encoding UTF8
Write-Host ""
Write-Host "Proposed cuts written to: $ptsFile"
Write-Host "Review/edit that file, then run Apply-Trims.bat to actually cut."
