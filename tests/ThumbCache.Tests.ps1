# ThumbCache.Tests.ps1 - the on-disk cache for clip filmstrips.
#
# The point of this cache is that a clip is decoded ONCE, ever. These tests pin
# the two properties that guarantee it: the same untouched clip always maps to
# the same cached file, and an edited clip maps to a different one.
#
# Run:  powershell -ExecutionPolicy Bypass -File tests\ThumbCache.Tests.ps1

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ThumbCache.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ThumbCacheTest_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'output') | Out-Null
$clip = Join-Path $tmp 'output\clip.mp4'
Set-Content -LiteralPath $clip -Value 'pretend video'

# a 1x1 jpeg as a data URL
$dataUrl = 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q=='

try {
    # --- key identity -------------------------------------------------------
    $k1 = Get-ThumbKey $tmp 'output/clip.mp4' 'strip'
    $k2 = Get-ThumbKey $tmp 'output/clip.mp4' 'strip'
    A ($k1 -and $k1 -eq $k2) "the same untouched clip always gets the same key"
    A ($k1 -match '^[0-9a-f]{32}$') "the key is a safe file name (got '$k1')"

    A ((Get-ThumbKey $tmp 'output/clip.mp4' 'poster') -ne $k1) "a poster and a filmstrip don't collide"
    A ((Get-ThumbKey $tmp 'output/other.mp4' 'strip') -ne $k1) "different clips get different keys"
    A ($null -eq (Get-ThumbKey $tmp '' 'strip')) "an empty path has no key"
    A ($null -eq (Get-ThumbKey $tmp $null 'strip')) "a null path has no key"

    # --- editing the clip must invalidate it --------------------------------
    Start-Sleep -Milliseconds 20
    (Get-Item -LiteralPath $clip).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(5)
    $k3 = Get-ThumbKey $tmp 'output/clip.mp4' 'strip'
    A ($k3 -ne $k1) "re-editing the clip changes its key, so its strip is rebuilt"

    # --- store and retrieve -------------------------------------------------
    A ($null -eq (Get-CachedThumbUrl $tmp 'output/clip.mp4' 'strip')) "nothing cached before the first save"

    $url = Save-CachedThumb $tmp 'output/clip.mp4' 'strip' $dataUrl
    A ($url -like 'https://studio.media/work/thumb-cache/*.jpg') "saving returns a URL the editor can load (got '$url')"

    $again = Get-CachedThumbUrl $tmp 'output/clip.mp4' 'strip'
    A ($again -eq $url) "the same clip now resolves straight to the cached file - no decode"

    $file = Get-CachedThumbPath $tmp 'output/clip.mp4' 'strip'
    A ($file -and (Test-Path -LiteralPath $file)) "the file really is on disk"
    A ((Get-Item -LiteralPath $file).Length -gt 0) "and it isn't empty"

    # bytes round-trip, i.e. we wrote the decoded payload not the base64 text
    $bytes = [System.IO.File]::ReadAllBytes($file)
    A ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8) "the payload was base64-decoded into a real JPEG"

    # --- bad input doesn't throw -------------------------------------------
    A ($null -eq (Save-CachedThumb $tmp 'output/clip.mp4' 'strip' 'not-a-data-url')) "a malformed data URL is refused, not written"
    A ($null -eq (Save-CachedThumb $tmp '' 'strip' $dataUrl)) "an empty path is refused"
}
catch {
    Write-Host "FAIL: unexpected error - $($_.Exception.Message)"
    $fails++
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fails -gt 0) { Write-Host "`n$fails test(s) FAILED"; exit 1 }
Write-Host "`nAll ThumbCache tests passed."
exit 0
