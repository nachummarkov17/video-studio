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

    # --- trims survive closing the app --------------------------------------
    A ((Get-BrollTrims $tmp).Count -eq 0) "no trims recorded to begin with"

    Set-BrollTrim $tmp 'broll/skyline.mp4' 1.5 4.25
    $tr = Get-BrollTrims $tmp
    A ($tr.Count -eq 1) "a trim is recorded"
    A ([math]::Abs($tr['broll/skyline.mp4'].in - 1.5) -lt 1e-9) "the in point round-trips"
    A ([math]::Abs($tr['broll/skyline.mp4'].out - 4.25) -lt 1e-9) "the out point round-trips"

    Set-BrollTrim $tmp 'broll/city/traffic.mp4' 0 2
    A ((Get-BrollTrims $tmp).Count -eq 2) "a second clip's trim is kept alongside"
    Set-BrollTrim $tmp 'broll/skyline.mp4' 3 9
    $tr = Get-BrollTrims $tmp
    A ((@($tr.Keys)).Count -eq 2 -and $tr['broll/skyline.mp4'].in -eq 3) "re-trimming replaces rather than duplicating"

    Set-BrollTrim $tmp 'broll/skyline.mp4' $null $null
    A ((Get-BrollTrims $tmp).ContainsKey('broll/skyline.mp4') -eq $false) "clearing a trim forgets it"
    A ((Get-BrollTrims $tmp).Count -eq 1) "and leaves the others alone"

    Set-BrollTrim $tmp 'broll/bad.mp4' 5 5
    A ((Get-BrollTrims $tmp).ContainsKey('broll/bad.mp4') -eq $false) "a zero-length selection is not stored"

    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $tmp 'broll-trims.txt'))
    A (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) "the trims file is UTF-8 with no BOM"

    # --- adding files to the library ----------------------------------------
    $src = Join-Path $tmp 'incoming'
    New-Item -ItemType Directory -Force -Path $src | Out-Null
    Set-Content -LiteralPath (Join-Path $src 'shot.mp4') -Value 'a'
    Set-Content -LiteralPath (Join-Path $src 'notes.txt') -Value 'a'

    $n = Add-BrollFiles $tmp @((Join-Path $src 'shot.mp4'), (Join-Path $src 'notes.txt'))
    A ($n -eq 1) "only media is taken in (added $n)"
    A (Test-Path (Join-Path $tmp 'broll\shot.mp4')) "the file landed in the library"

    Add-BrollFiles $tmp @((Join-Path $src 'shot.mp4')) | Out-Null
    A (Test-Path (Join-Path $tmp 'broll\shot (2).mp4')) "adding the same name again keeps both, rather than overwriting"

    Add-BrollFiles $tmp @((Join-Path $src 'shot.mp4')) 'City' | Out-Null
    A (Test-Path (Join-Path $tmp 'broll\City\shot.mp4')) "a group name files it into that folder"

    A ((Add-BrollFiles $tmp @('X:
ope\missing.mp4')) -eq 0) "a missing file is skipped, not fatal"

    # --- saved clips get their own shelf ------------------------------------
    Touch 'broll/saved/traffic wide.mp4'
    $saved = @(Get-BrollAssets $tmp) | Where-Object { $_.name -eq 'traffic wide.mp4' }
    A ($saved.group -eq 'Saved clips') "a cut-down piece is grouped under Saved clips"

    A ((Get-SafeBrollName 'traffic wide') -eq 'traffic wide') "a sensible name is left alone"
    A ((Get-SafeBrollName '  spaced  ') -eq 'spaced') "surrounding space is trimmed"
    A ((Get-SafeBrollName 'a/b:c*d?') -eq 'abcd') "characters Windows won't allow are stripped"
    A ((Get-SafeBrollName '') -eq 'clip') "an empty name falls back to something usable"
    A ((Get-SafeBrollName ('x' * 200)).Length -le 80) "an absurd name is cut to a sane length"

    $t1 = Get-BrollClipTarget $tmp 'punch in'
    A ($t1 -like '*saved*punch in.mp4') "a saved clip targets broll\saved (got '$t1')"
    A ((Get-BrollClipTarget $tmp 'brand new') -like '*brand new.mp4') "an unused name is used as-is"
    $t2 = Get-BrollClipTarget $tmp 'traffic wide'
    A ($t2 -like '*traffic wide (2).mp4') "saving over an existing name keeps both (got '$(Split-Path -Leaf $t2)')"

    $cut = Get-BrollCutArgs 'C:\src.mp4' 1.5 3.25 'C:\out.mp4'
    A ($cut -contains '-ss' -and $cut[[array]::IndexOf($cut,'-ss')+1] -eq '1.5') "the cut starts at the in point"
    A ($cut -contains '-t' -and $cut[[array]::IndexOf($cut,'-t')+1] -eq '3.25') "and runs for the selected length"
    A ([array]::IndexOf($cut,'-ss') -lt [array]::IndexOf($cut,'-i')) "seek comes before the input, so it's fast"
    A ($cut -contains 'libx264') "it re-encodes, so the cut lands on the exact frame"
    A ($cut[$cut.Count-1] -eq 'C:\out.mp4') "the output path is last"

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
