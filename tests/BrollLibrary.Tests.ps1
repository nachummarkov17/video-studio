# BrollLibrary.Tests.ps1 - scanning the b-roll library.
#
# Run:  powershell -ExecutionPolicy Bypass -File tests\BrollLibrary.Tests.ps1

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\BrollLibrary.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("BrollTest_" + [Guid]::NewGuid().ToString('N'))
function Touch($rel) {
    $p = Join-Path $tmp $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
    Set-Content -LiteralPath $p -Value 'x'
}

try {
    # --- nothing there yet --------------------------------------------------
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    A ((@(Get-BrollAssets $tmp)).Count -eq 0) "a missing broll folder yields nothing"

    # --- a library with loose files and subfolders ---------------------------
    Touch 'broll\skyline.mp4'
    Touch 'broll\city\traffic.mp4'
    Touch 'broll\city\crossing.MOV'
    Touch 'broll\food\coffee.jpg'
    Touch 'broll\notes.txt'          # not media
    Touch 'broll\hum.mp3'            # audio belongs to step 4

    $items = @(Get-BrollAssets $tmp)
    A ($items.Count -eq 4) "finds only the usable media (got $($items.Count) of 6 files)"

    $names = @($items | ForEach-Object { $_.name })
    A ($names -contains 'skyline.mp4' -and $names -contains 'traffic.mp4') "picks up loose files and files in subfolders"
    A (-not ($names -contains 'notes.txt')) "skips non-media"
    A (-not ($names -contains 'hum.mp3')) "skips audio - music is step 4's job"

    # --- grouping -----------------------------------------------------------
    $g = @{}; foreach ($i in $items) { $g[$i.name] = $i.group }
    A ($g['skyline.mp4'] -eq 'B-roll') "a loose file falls into the default group"
    A ($g['traffic.mp4'] -eq 'City')   "a file in city\ is grouped as City"
    A ($g['crossing.MOV'] -eq 'City')  "and so is its neighbour"
    A ($g['coffee.jpg'] -eq 'Food')    "a file in food\ is grouped as Food"

    # --- types --------------------------------------------------------------
    $t = @{}; foreach ($i in $items) { $t[$i.name] = $i.type }
    A ($t['skyline.mp4'] -eq 'video') "an mp4 is a video"
    A ($t['crossing.MOV'] -eq 'video') "extension matching is case-insensitive"
    A ($t['coffee.jpg'] -eq 'image')  "a jpg is an image"

    # --- paths are editor-shaped -------------------------------------------
    $sky = $items | Where-Object { $_.name -eq 'skyline.mp4' }
    A ($sky.path -eq 'broll/skyline.mp4') "paths are relative and forward-slashed (got '$($sky.path)')"
    $tr = $items | Where-Object { $_.name -eq 'traffic.mp4' }
    A ($tr.path -eq 'broll/city/traffic.mp4') "including inside subfolders (got '$($tr.path)')"
    A ($sky.broll -eq $true) "items are marked as b-roll so the bin can group them"

    # --- deeper nesting still lands in its top-level group -------------------
    Touch 'broll\city\night\neon.mp4'
    $deep = @(Get-BrollAssets $tmp) | Where-Object { $_.name -eq 'neon.mp4' }
    A ($deep.group -eq 'City') "a deeper folder still belongs to its top-level group"
}
catch {
    Write-Host "FAIL: unexpected error - $($_.Exception.Message)"
    $fails++
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fails -gt 0) { Write-Host "`n$fails test(s) FAILED"; exit 1 }
Write-Host "`nAll BrollLibrary tests passed."
exit 0
