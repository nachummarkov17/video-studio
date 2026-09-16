# get-ffmpeg.ps1 - put ffmpeg where Video Studio can use it.
#
#   powershell -ExecutionPolicy Bypass -File tools\get-ffmpeg.ps1 -To "<app>\tools\ffmpeg\bin"
#
# WHY THIS EXISTS. The installer used to ask winget for ffmpeg and then, if that
# didn't work, download a zip with Invoke-WebRequest - both with their output
# thrown away. On the first real handover that step sat for an hour with nothing
# on screen: winget wants administrator rights for a per-machine install, and a
# prompt nobody can see is a prompt nobody can answer. A stalled Invoke-WebRequest
# -OutFile behaves the same way, because -TimeoutSec covers getting the response,
# not the hours the body can then take to not arrive.
#
# So this does three things that the old code did not:
#   - copies from a folder you already have (the handover stick) before it even
#     thinks about the internet
#   - never calls winget, so nothing can wait on a hidden prompt
#   - reads with a stall timeout and prints progress, so it either moves or says
#     why it stopped
#
# A local copy under tools\ffmpeg\bin is what the app looks for anyway, so this
# needs no administrator rights and changes nothing outside the app folder.

param(
    [Parameter(Mandatory = $true)][string]$To,      # the bin folder to end up with ffmpeg.exe in
    [string]$From,                                  # a folder that may already hold a copy
    [int]$StallSeconds = 60,                        # no data for this long = give up on the attempt
    [int]$MaxMinutes = 20,                          # ...and a whole attempt can't outlast this
    [int]$Attempts = 6                              # each one resumes, so these are cheap
)

$ErrorActionPreference = 'Stop'
# Smallest first. gyan.dev's "essentials" build is about 80 MB and has
# everything this app asks of ffmpeg; BtbN's is the full GPL build at 186 MB and
# is here only as a second host to try. On a slow line that difference is the
# difference between a coffee and an afternoon.
$urls = @(
    'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip',
    'https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip'
)
$wanted = @('ffmpeg.exe', 'ffprobe.exe')

function Say($m) { Write-Host "   $m" }

function Test-FfmpegAt([string]$dir) {
    if (-not $dir) { return $false }
    return (Test-Path -LiteralPath (Join-Path $dir 'ffmpeg.exe'))
}

# A folder someone points us at might be the bin folder itself, or the folder
# above it. Both are reasonable things to hand over, so accept either.
function Find-FfmpegBin([string]$dir) {
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return $null }
    foreach ($try in @($dir, (Join-Path $dir 'bin'), (Join-Path $dir 'ffmpeg\bin'))) {
        if (Test-FfmpegAt $try) { return $try }
    }
    # -Depth on purpose: the folder handed over also holds 2.8 GB of captions
    # engine, and a full walk of it to find a file that is not there is minutes
    # of disk for nothing.
    $found = Get-ChildItem -LiteralPath $dir -Recurse -Depth 3 -Filter 'ffmpeg.exe' -File -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($found) { return $found.Directory.FullName }
    return $null
}

function Copy-FfmpegFrom([string]$binDir, [string]$dest) {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    foreach ($exe in $wanted) {
        $src = Join-Path $binDir $exe
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dest -Force }
    }
    return (Test-FfmpegAt $dest)
}

# Downloads with a stall timeout and visible progress. The stall timeout is the
# whole point: a read that never returns is what an hour of silence looks like.
# RESUMES. Measured on the connection this first went wrong on: 12 KB/s with
# regular stalls. Starting an 80 MB file from zero every time it stalls never
# finishes, however many times you try - so each attempt asks for the bytes it
# hasn't got yet and appends. Slow then merely means slow.
function Get-FileWithProgress([string]$uri, [string]$path, [int]$stallSeconds, [int]$maxMinutes) {
    $have = 0
    if (Test-Path -LiteralPath $path) { $have = (Get-Item -LiteralPath $path).Length }

    $req = [System.Net.HttpWebRequest]::Create($uri)
    $req.UserAgent = 'VideoStudio-Installer'
    $req.Timeout = 60000
    $req.ReadWriteTimeout = $stallSeconds * 1000
    if ($have -gt 0) { $req.AddRange($have); Say ("  resuming at {0:N0} MB" -f ($have / 1MB)) }

    try { $resp = $req.GetResponse() }
    catch [System.Net.WebException] {
        # 416 means we already have the whole thing; a server with no range
        # support gets a fresh start; anything else is a real failure.
        $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        if ($code -eq 416) { return $true }
        if ($have -gt 0) {
            Say '  this source will not resume - starting over'
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            return (Get-FileWithProgress $uri $path $stallSeconds $maxMinutes)
        }
        throw
    }
    try {
        $partial = ($resp.StatusCode -eq [System.Net.HttpStatusCode]::PartialContent)
        if ($have -gt 0 -and -not $partial) { $have = 0 }   # served the whole file anyway
        $total = $resp.ContentLength + $have
        $in = $resp.GetResponseStream()
        $in.ReadTimeout = $stallSeconds * 1000
        $out = if ($have -gt 0) { [System.IO.File]::Open($path, 'Append', 'Write') } else { [System.IO.File]::Create($path) }
        try {
            $buf = New-Object byte[] 262144
            $read = $have
            $startedAt = $have
            $started = Get-Date
            $lastSaid = $started
            # Every 15 seconds, not every 10 percent. A download trickling in at
            # 20 KB/s never trips the stall timeout and would otherwise print
            # nothing for half an hour - which is exactly what an hour of
            # silence looked like the first time this was handed to someone.
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n)
                $read += $n
                $now = Get-Date
                if (($now - $lastSaid).TotalSeconds -ge 15) {
                    $secs = [Math]::Max(1, ($now - $started).TotalSeconds)
                    $rate = ($read - $startedAt) / $secs / 1KB
                    if ($total -gt 0) {
                        Say ("  {0,3}%  ({1:N0} of {2:N0} MB, {3:N0} KB/s)" -f [int](($read * 100) / $total), ($read / 1MB), ($total / 1MB), $rate)
                    } else {
                        Say ("  {0:N0} MB ({1:N0} KB/s)" -f ($read / 1MB), $rate)
                    }
                    $lastSaid = $now
                }
                if (($now - $started).TotalMinutes -ge $maxMinutes) {
                    throw "Still going after $maxMinutes minutes - this connection is too slow for it."
                }
            }
        } finally { $out.Dispose(); $in.Dispose() }
    } finally { $resp.Dispose() }
    return (Test-Path -LiteralPath $path)
}

# ---- already there? ---------------------------------------------------------
if (Test-FfmpegAt $To) { Say 'Already installed (local copy)'; exit 0 }

# ---- from the stick ---------------------------------------------------------
$fromBin = Find-FfmpegBin $From
if ($fromBin) {
    Say "Copying from $fromBin"
    if (Copy-FfmpegFrom $fromBin $To) { Say 'Installed'; exit 0 }
    Say "That copy didn't work - falling back to downloading it."
}

# ---- or from the internet ---------------------------------------------------
# A FIXED folder, not a new one each run: run this again tomorrow on a bad line
# and it carries on from the megabytes it already has rather than starting the
# 80 MB again.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'VideoStudio-ffmpeg'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$zip = Join-Path $tmp 'ffmpeg.zip'
$ok = $false
foreach ($url in $urls) {
    for ($i = 1; $i -le $Attempts -and -not $ok; $i++) {
        try {
            Say $(if ($i -eq 1) { "Downloading from $(([Uri]$url).Host)..." } else { "Stalled - trying again ($i of $Attempts)..." })
            $ok = Get-FileWithProgress $url $zip $StallSeconds $MaxMinutes
        } catch {
            # The part-file is deliberately KEPT: the next attempt resumes from it.
            Say "  $($_.Exception.Message)"
        }
    }
    if ($ok) { break }
    Say 'Trying another source...'
}

if ($ok) {
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $x = Join-Path $tmp 'x'
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $x)
        $binDir = Find-FfmpegBin $x
        if ($binDir) { $ok = Copy-FfmpegFrom $binDir $To } else { $ok = $false }
    } catch {
        # A zip that will not open is a truncated download, and keeping it would
        # poison every later resume.
        Say "Could not unpack it: $($_.Exception.Message)"
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        $ok = $false
    }
}
if ($ok) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

if ($ok) { Say 'Installed'; exit 0 }

Say 'ffmpeg could not be installed.'
Say 'Video Studio needs it. Check the internet connection and run this again:'
Say "   powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -To `"$To`""
exit 1
