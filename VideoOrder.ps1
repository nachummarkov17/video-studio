# VideoOrder.ps1
# One shared answer to "what order are the videos in?".
#
# The order you arrange in the studio's "Your videos" list is saved to
# video-order.txt and is the SAME order every step processes clips in - so the
# clip at the top gets captioned, burned, mixed and finished first.
#
# Dot-source this from the studio and from each step script:
#     . (Join-Path $Root 'VideoOrder.ps1')

function Get-VideoOrderPath([string]$Root) {
    return (Join-Path $Root 'video-order.txt')
}

# The saved order, top to bottom. Missing file => empty list (not an error), so
# a fresh install just falls back to sorting by name.
function Read-VideoOrder([string]$Root) {
    $path = Get-VideoOrderPath $Root
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t.StartsWith('#')) { continue }
        $names.Add($t)
    }
    return $names.ToArray()
}

# Rewrites video-order.txt. UTF-8 with no BOM, because ffmpeg-adjacent tooling
# and Get-Content -Encoding UTF8 both read this cleanly only without one.
function Save-VideoOrder([string]$Root, [string[]]$Names) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# VIDEO ORDER  -  the order your clips show in the studio, and the order')
    $lines.Add('# every step processes them in. Drag rows in "Your videos" to change it.')
    foreach ($n in @($Names)) {
        if ($n) { $lines.Add([string]$n) }
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Get-VideoOrderPath $Root), (($lines -join "`r`n") + "`r`n"), $enc)
}

# Files in $Dir matching $Filter, ordered by video-order.txt first (skipping any
# name whose file has since gone), then everything the order file doesn't know
# about, sorted by name so newly imported clips land predictably at the bottom.
function Get-OrderedVideos([string]$Root, [string]$Dir, [string]$Filter = '*.mp4') {
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $Dir -Filter $Filter -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($files.Count -eq 0) { return @() }

    # name -> file, case-insensitive: the order file is hand-editable and Windows
    # file names are case-insensitive, so "C.MP4" must match "c.mp4".
    $byName = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $files) { if (-not $byName.ContainsKey($f.Name)) { $byName[$f.Name] = $f } }

    $out  = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in (Read-VideoOrder $Root)) {
        if ($byName.ContainsKey($n) -and $seen.Add($byName[$n].Name)) { $out.Add($byName[$n]) }
    }
    foreach ($f in $files) {
        if ($seen.Add($f.Name)) { $out.Add($f) }
    }
    return $out.ToArray()
}
