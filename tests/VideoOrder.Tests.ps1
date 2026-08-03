# VideoOrder.Tests.ps1 - unit tests for the shared video-ordering helpers
# (Read-VideoOrder, Save-VideoOrder, Get-OrderedVideos) that make the "Your
# videos" list order stick AND drive the order every step processes clips in.
#
# Run:  powershell -ExecutionPolicy Bypass -File tests\VideoOrder.Tests.ps1

$ErrorActionPreference = 'Stop'   # a missing function must FAIL the run, not skip a case
. "$PSScriptRoot\..\VideoOrder.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }
function Names($files) { return ,@(@($files) | ForEach-Object { $_.Name }) }
function SameList($got, $want) {
    $g = @($got); $w = @($want)
    if ($g.Count -ne $w.Count) { return $false }
    for ($i = 0; $i -lt $w.Count; $i++) { if ($g[$i] -ne $w[$i]) { return $false } }
    return $true
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("VideoOrderTest_" + [Guid]::NewGuid().ToString('N'))
function NewRoot {
    $r = Join-Path $tmp ([Guid]::NewGuid().ToString('N'))
    $d = Join-Path $r 'output'
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    foreach ($n in 'b.mp4', 'a.mp4', 'c.mp4') { Set-Content -LiteralPath (Join-Path $d $n) -Value 'x' }
    return $r
}

try {
    # --- no order file: plain name sort -------------------------------------
    $root = NewRoot
    $got = Names (Get-OrderedVideos $root (Join-Path $root 'output'))
    A (SameList $got @('a.mp4', 'b.mp4', 'c.mp4')) "sorts by name when no order file exists (got: $($got -join ','))"

    # --- saved order wins ---------------------------------------------------
    $root = NewRoot
    Save-VideoOrder $root @('c.mp4', 'a.mp4', 'b.mp4')
    $got = Names (Get-OrderedVideos $root (Join-Path $root 'output'))
    A (SameList $got @('c.mp4', 'a.mp4', 'b.mp4')) "honours the saved order (got: $($got -join ','))"

    # --- unknown files land after known ones, sorted by name ----------------
    $root = NewRoot
    Save-VideoOrder $root @('c.mp4')
    Set-Content -LiteralPath (Join-Path $root 'output\d.mp4') -Value 'x'
    $got = Names (Get-OrderedVideos $root (Join-Path $root 'output'))
    A (SameList $got @('c.mp4', 'a.mp4', 'b.mp4', 'd.mp4')) "new files append after known ones (got: $($got -join ','))"

    # --- names that no longer exist are skipped ----------------------------
    $root = NewRoot
    Save-VideoOrder $root @('gone.mp4', 'b.mp4')
    $got = Names (Get-OrderedVideos $root (Join-Path $root 'output'))
    A (SameList $got @('b.mp4', 'a.mp4', 'c.mp4')) "skips names whose file is gone (got: $($got -join ','))"

    # --- round trip, comments ignored --------------------------------------
    $root = NewRoot
    Save-VideoOrder $root @('a.mp4', 'b.mp4')
    $got = @(Read-VideoOrder $root)
    A (SameList $got @('a.mp4', 'b.mp4')) "Read-VideoOrder round-trips and ignores the # header (got: $($got -join ','))"

    # --- UTF-8 with no BOM --------------------------------------------------
    $root = NewRoot
    Save-VideoOrder $root @('a.mp4')
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $root 'video-order.txt'))
    A (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) "writes UTF-8 with no BOM"

    # --- missing order file reads as empty, not an error -------------------
    $root = NewRoot
    A ((@(Read-VideoOrder $root)).Count -eq 0) "Read-VideoOrder returns empty when the file is missing"

    # --- a missing directory yields nothing rather than throwing -----------
    $root = NewRoot
    A ((@(Get-OrderedVideos $root (Join-Path $root 'nope'))).Count -eq 0) "missing directory yields no files"

    # --- filter is honoured -------------------------------------------------
    $root = NewRoot
    Set-Content -LiteralPath (Join-Path $root 'output\a.srt') -Value 'x'
    $got = Names (Get-OrderedVideos $root (Join-Path $root 'output') '*.mp4')
    A (SameList $got @('a.mp4', 'b.mp4', 'c.mp4')) "filter excludes non-matching files (got: $($got -join ','))"

    # --- ordering is case-insensitive on names -----------------------------
    $root = NewRoot
    Save-VideoOrder $root @('C.MP4', 'A.mp4')
    $got = Names (Get-OrderedVideos $root (Join-Path $root 'output'))
    A (SameList $got @('c.mp4', 'a.mp4', 'b.mp4')) "matches names case-insensitively (got: $($got -join ','))"
}
catch {
    Write-Host "FAIL: unexpected error - $($_.Exception.Message)"
    $fails++
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fails -gt 0) { Write-Host "`n$fails test(s) FAILED"; exit 1 }
Write-Host "`nAll VideoOrder tests passed."
exit 0
