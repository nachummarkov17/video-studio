# Find-Music.ps1
# Writes an editable "music-map.txt" listing every video in the source folder
# (default: output\) next to a suggested background track from the music\ folder.
# You edit which track each video gets, then run Apply-Music.bat to mix them.
#
# Nothing is changed to your videos here - this only writes the text map.

[CmdletBinding()]
param(
    [string]$Root      = $PSScriptRoot,
    [string]$SourceDir = "output"     # folder holding the videos to score (relative to Root)
)

if (-not $Root -or -not (Test-Path (Join-Path $Root "Srt-Chunk.ps1"))) {
    if ($PSCommandPath) { $Root = Split-Path -Parent $PSCommandPath }
}
$src   = Join-Path $Root $SourceDir
$music = Join-Path $Root "music"
$map   = Join-Path $Root "music-map.txt"
$log   = Join-Path $Root "cleaner.log"
New-Item -ItemType Directory -Force -Path $music | Out-Null

function Write-Log($m) {
    $line = ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m)
    Write-Host $line
    Add-Content -Path $log -Value $line -Encoding UTF8
}

if (-not (Test-Path $src)) { Write-Log "No '$SourceDir' folder yet - clean some videos first."; exit 0 }

# Audio tracks available in music\
$exts   = @('.mp3','.wav','.m4a','.aac','.flac','.ogg','.wma')
$tracks = Get-ChildItem -Path $music -File -ErrorAction SilentlyContinue |
          Where-Object { $exts -contains $_.Extension.ToLower() } | Sort-Object Name
# Videos to score (skip the with-music output subfolder)
$vids = Get-ChildItem -Path $src -Filter *.mp4 -File -ErrorAction SilentlyContinue | Sort-Object Name
if (-not $vids) { Write-Log "No videos found in $src to add music to."; exit 0 }

# Keep any assignments you already made
$prev = @{}
if (Test-Path $map) {
    foreach ($line in Get-Content -LiteralPath $map -Encoding UTF8) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $parts = $t -split '\|', 2
        $vn = $parts[0].Trim()
        $tn = ''
        if ($parts.Count -ge 2) { $tn = $parts[1].Trim() }
        if ($vn) { $prev[$vn] = $tn }
    }
}

$maxLen = ($vids | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
if (-not $maxLen) { $maxLen = 20 }

$out = New-Object System.Collections.Generic.List[string]
$out.Add("# MUSIC MAP  -  which background track plays under which video.")
$out.Add("# Format:   <video file>  |  <track file from the music\ folder>")
$out.Add("#   - Put a track's filename (e.g. calm.mp3) after the |")
$out.Add("#   - Leave it blank, or write  none , to add NO music to that video")
$out.Add("#   - Save this file, then click  Add music  in the app  (result -> output\with-music\)")
$out.Add("#")
if ($tracks.Count -eq 0) {
    $out.Add("# !! No music files in the  music\  folder yet.")
    $out.Add("# !! Drop a few .mp3 tracks into  music\  (see music\README.txt for free,")
    $out.Add("# !! royalty-free sources), then run Find-Music.bat again.")
} else {
    $out.Add("# Available tracks in music\ :")
    foreach ($tr in $tracks) { $out.Add("#     $($tr.Name)") }
}
$out.Add("")

$i = 0
foreach ($v in $vids) {
    if ($prev.ContainsKey($v.Name)) {
        $assigned = $prev[$v.Name]                       # keep what you set before
    } elseif ($tracks.Count -gt 0) {
        $assigned = $tracks[$i % $tracks.Count].Name     # rotate suggestions for variety
    } else {
        $assigned = ""
    }
    $out.Add(("{0} | {1}" -f $v.Name.PadRight($maxLen), $assigned))
    $i++
}

[System.IO.File]::WriteAllText($map, (($out -join "`r`n").TrimEnd() + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Log ("Wrote music map for {0} video(s) with {1} track(s) available -> music-map.txt" -f $vids.Count, $tracks.Count)
if ($tracks.Count -eq 0) { Write-Log "Add music to the music\ folder, then run Find-Music.bat again." }
