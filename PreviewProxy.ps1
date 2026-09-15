# PreviewProxy.ps1 - small, fast-seeking stand-ins for the full-size masters.
#
# WHY THIS EXISTS. Both preview surfaces in this app - the caption editor's WPF
# MediaElement and the editor's WebView2 <video> elements - were being pointed
# straight at the masters: 1080x1920 at ~16 Mbit/s, minutes long. A single seek
# in a file like that costs hundreds of milliseconds and leaves the decoder busy
# for a second or two afterwards, which is exactly what "the video lags when I
# move the playhead" and "it stalls when it crosses a cut" felt like. It is also
# why the caption editor's audio ran ahead of its picture: the decoder simply
# could not keep up with the presentation clock.
#
# Every real editor solves this the same way, and so do we: EDIT AGAINST A
# PROXY, RENDER FROM THE MASTER. The proxy is capped at 1280 on its long side
# and carries a keyframe every second, so seeking it is instant. Nothing that
# produces a deliverable ever touches it - Burn-Captions, Apply-Music,
# Export-ForUpload and the editor's own render all still read the master.
#
# Proxies are content-addressed in work\proxy-cache\, so an edited clip gets a
# new one and an untouched clip is only ever built once. A missing or failed
# proxy is never fatal: every consumer falls back to the master.

. (Join-Path $PSScriptRoot 'ContentKey.ps1')
. (Join-Path $PSScriptRoot 'VideoColor.ps1')

# Bump this when the proxy RECIPE changes, so everyone's cached proxies are
# rebuilt instead of quietly staying on the old settings. (v2: carry the
# source's colour tags, so the preview looks like the export.)
$script:ProxyRecipe = 'v2'
$script:ProxyLongEdge = 1280
$script:ProxyGpuEncoder = $null      # $null = not probed yet, '' = none available
# Only moving pictures get a proxy. A still is already cheap to show, and
# running one through the video encoder would produce a one-frame film.
$script:ProxyVideoExts = @('.mp4', '.mov', '.m4v', '.avi', '.mkv', '.webm', '.mpg', '.mpeg', '.wmv')

function Test-ProxyApplies {
    param([string]$SourcePath)
    if ([string]::IsNullOrWhiteSpace($SourcePath)) { return $false }
    return ($script:ProxyVideoExts -contains ([System.IO.Path]::GetExtension($SourcePath).ToLower()))
}

function Get-ProxyCacheDir {
    param([Parameter(Mandatory = $true)][string]$Root)
    return (Join-Path $Root 'work\proxy-cache')
}

# The cache file this source maps to. Deterministic: same file in the same state
# always gives the same path, whether or not it has been built yet.
function Get-ProxyPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$SourcePath
    )
    if ([string]::IsNullOrWhiteSpace($SourcePath)) { return $null }
    $full = $SourcePath
    if (-not [System.IO.Path]::IsPathRooted($full)) { $full = Join-Path $Root ($SourcePath -replace '/', '\') }
    $key = Get-StringHashHex ("proxy|{0}|{1}|{2}" -f $script:ProxyRecipe, $full.ToLowerInvariant(), (Get-FileContentStamp $full))
    return (Join-Path (Get-ProxyCacheDir $Root) "$key.mp4")
}

# A proxy counts as ready only when it exists AND is big enough to be a real
# file - an interrupted build leaves a stub behind, and playing that would look
# exactly like the bug we're fixing.
function Test-ProxyReady {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$SourcePath
    )
    $p = Get-ProxyPath $Root $SourcePath
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { return $false }
    return ((Get-Item -LiteralPath $p).Length -gt 20000)
}

# The URL the editor page should load for a ready proxy (studio.media maps to
# the app root). Returns $null when there isn't one yet.
function Get-ProxyUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$SourcePath
    )
    if (-not (Test-ProxyReady $Root $SourcePath)) { return $null }
    $name = [System.IO.Path]::GetFileName((Get-ProxyPath $Root $SourcePath))
    return "https://studio.media/work/proxy-cache/$name"
}

# Which H.264 encoder to build proxies with. The GPU is probed once per session;
# a proxy is a throwaway preview file, so NVENC's speed is worth far more here
# than the last few percent of efficiency. Deliverables are never encoded this
# way - they keep the CPU libx264 settings the rest of the pipeline uses.
function Get-ProxyEncoderArgs {
    if ($null -eq $script:ProxyGpuEncoder) {
        $script:ProxyGpuEncoder = ''
        try {
            $enc = & ffmpeg -hide_banner -loglevel error -encoders 2>$null | Out-String
            if ($enc -match 'h264_nvenc') { $script:ProxyGpuEncoder = 'h264_nvenc' }
        } catch { $script:ProxyGpuEncoder = '' }
    }
    if ($script:ProxyGpuEncoder -eq 'h264_nvenc') {
        # -rc vbr with -b:v 0 is what makes -cq actually govern the size. Without
        # it nvenc falls back to its own bitrate target and a preview proxy comes
        # out nearly as big as the master, which defeats the point.
        return @('-c:v', 'h264_nvenc', '-preset', 'p4', '-rc', 'vbr', '-cq', '30', '-b:v', '0',
                 '-maxrate', '6M', '-bufsize', '12M', '-pix_fmt', 'yuv420p', '-g', '30')
    }
    return @('-c:v', 'libx264', '-preset', 'veryfast', '-crf', '26', '-pix_fmt', 'yuv420p',
             '-g', '30', '-keyint_min', '30', '-sc_threshold', '0')
}

# PURE: the ffmpeg argument vector that turns $SourcePath into $DestPath.
#
# The two-stage scale is deliberate. force_original_aspect_ratio=decrease fits
# the frame inside a square box, which caps the LONG edge whichever way round
# the clip is - no orientation probing, and portrait phone footage is handled
# identically to landscape. The trunc pass then guarantees even dimensions,
# which yuv420p requires and a fractional scale factor can easily break.
function Get-ProxyBuildArgs {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestPath,
        [string[]]$EncoderArgs,
        [object]$ColorTags = $null
    )
    if (-not $EncoderArgs) { $EncoderArgs = Get-ProxyEncoderArgs }
    $edge = $script:ProxyLongEdge
    $vf = "scale=${edge}:${edge}:force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"
    # a -vf chain drops primaries/transfer, so stamp them back on (see VideoColor.ps1)
    $setparams = Get-SetParamsFilter $ColorTags
    if ($setparams) { $vf = $vf + ',' + $setparams }
    return @(
        '-y', '-hide_banner', '-nostats', '-loglevel', 'error',
        '-i', $SourcePath,
        '-vf', $vf
    ) + $EncoderArgs + (Get-ColorOutputArgs $ColorTags) + @(
        '-c:a', 'aac', '-b:a', '128k',
        '-movflags', '+faststart',
        $DestPath
    )
}

# Starts a build and returns @{ Tracked; Dest; Temp }, or $null when there is
# nothing to do (already built, or the source is gone). Writes to a .part file
# and moves it into place on success, so Test-ProxyReady can never see a
# half-written proxy. Runs OUT OF PROCESS - callers are on the UI thread.
function Start-ProxyBuild {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$SourcePath
    )
    if (-not (Test-ProxyApplies $SourcePath)) { return $null }
    $full = $SourcePath
    if (-not [System.IO.Path]::IsPathRooted($full)) { $full = Join-Path $Root ($SourcePath -replace '/', '\') }
    if (-not (Test-Path -LiteralPath $full)) { return $null }
    if (Test-ProxyReady $Root $SourcePath) { return $null }

    $dest = Get-ProxyPath $Root $SourcePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    # ".part.mp4", not ".mp4.part": ffmpeg picks its muxer from the EXTENSION, and
    # a name ending in .part makes it give up with "unable to choose an output
    # format" before it encodes a single frame.
    $temp = [System.IO.Path]::ChangeExtension($dest, '.part.mp4')
    try { if (Test-Path -LiteralPath $temp) { [System.IO.File]::Delete($temp) } } catch {}

    # The proxy keeps the source's colour tags too, so what you edit against
    # looks like what you export - an HDR clip previewed as BT.709 would be
    # washed out in exactly the way the final file used to be.
    $ffArgs = Get-ProxyBuildArgs $full $temp $null (Get-VideoColorTags $full)
    try {
        $tracked = Start-TrackedProcess -FilePath 'ffmpeg' -ArgumentList $ffArgs
    } catch { return $null }
    return [pscustomobject]@{ Tracked = $tracked; Dest = $dest; Temp = $temp; Source = $full }
}

# Call from the build's completion handler: promotes the .part file to the real
# cache entry when ffmpeg succeeded. Returns $true if a usable proxy now exists.
function Complete-ProxyBuild {
    param(
        [Parameter(Mandatory = $true)][object]$Build,
        [Parameter(Mandatory = $true)][object]$Result
    )
    $ok = $false
    try {
        if ($Result.Ok -and (Test-Path -LiteralPath $Build.Temp) -and
            ((Get-Item -LiteralPath $Build.Temp).Length -gt 20000)) {
            Move-Item -LiteralPath $Build.Temp -Destination $Build.Dest -Force
            $ok = $true
        }
    } catch { $ok = $false }
    if (-not $ok) { try { if (Test-Path -LiteralPath $Build.Temp) { [System.IO.File]::Delete($Build.Temp) } } catch {} }
    return $ok
}
