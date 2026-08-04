# ThumbCache.ps1
# Where the editor's clip filmstrips live between sessions.
#
# Building a filmstrip means decoding the whole source clip and grabbing frames
# across it. Doing that every time the editor opens made startup slower with
# every clip you added. Strips are built once now and kept in work\thumb-cache\,
# keyed by the clip's path AND its last-write time - so re-editing a clip
# rebuilds its strip, while an untouched clip is never decoded again.

function Get-ThumbCacheDir([string]$Root) {
    return (Join-Path $Root 'work\thumb-cache')
}

function Get-ThumbKey([string]$Root, [string]$RelPath, [string]$Kind) {
    if ([string]::IsNullOrWhiteSpace($RelPath)) { return $null }
    $full = Join-Path $Root ($RelPath -replace '/', '\')
    $stamp = ''
    if (Test-Path -LiteralPath $full) { $stamp = (Get-Item -LiteralPath $full).LastWriteTimeUtc.Ticks }
    $raw = "$Kind|$RelPath|$stamp"
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $md5.Dispose() }
}

# The cached file for a key, or $null when it hasn't been built yet.
function Get-CachedThumbPath([string]$Root, [string]$RelPath, [string]$Kind) {
    $key = Get-ThumbKey $Root $RelPath $Kind
    if (-not $key) { return $null }
    $file = Join-Path (Get-ThumbCacheDir $Root) "$key.jpg"
    if (Test-Path -LiteralPath $file) { return $file }
    return $null
}

# Writes a data: URL's payload out as a real file and returns the URL the editor
# should use for it. Serving a file beats handing a ~150KB base64 string to CSS:
# it stays out of the JS heap and the browser caches the decoded image.
function Save-CachedThumb([string]$Root, [string]$RelPath, [string]$Kind, [string]$DataUrl) {
    $key = Get-ThumbKey $Root $RelPath $Kind
    if (-not $key -or -not $DataUrl) { return $null }
    $comma = $DataUrl.IndexOf(',')
    if ($comma -lt 1) { return $null }
    $dir = Get-ThumbCacheDir $Root
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $bytes = [Convert]::FromBase64String($DataUrl.Substring($comma + 1))
    [System.IO.File]::WriteAllBytes((Join-Path $dir "$key.jpg"), $bytes)
    return "https://studio.media/work/thumb-cache/$key.jpg"
}

function Get-CachedThumbUrl([string]$Root, [string]$RelPath, [string]$Kind) {
    $key = Get-ThumbKey $Root $RelPath $Kind
    if (-not $key) { return $null }
    if (-not (Test-Path -LiteralPath (Join-Path (Get-ThumbCacheDir $Root) "$key.jpg"))) { return $null }
    return "https://studio.media/work/thumb-cache/$key.jpg"
}
