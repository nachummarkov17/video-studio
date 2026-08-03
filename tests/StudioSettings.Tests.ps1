# StudioSettings.Tests.ps1 - unit tests for the remembered-UI-choice helpers
# (Get-StudioSetting / Set-StudioSetting) and the caption position mapping that
# turns Bottom/Middle/Top into the ASS alignment + vertical margin we burn with.
#
# Run:  powershell -ExecutionPolicy Bypass -File tests\StudioSettings.Tests.ps1

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\StudioSettings.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("StudioSettingsTest_" + [Guid]::NewGuid().ToString('N'))
function NewRoot {
    $r = Join-Path $tmp ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $r | Out-Null
    return $r
}

try {
    # --- caption placement mapping -----------------------------------------
    $p = Get-CaptionPlacement 'Bottom'
    A ($p.Alignment -eq 2 -and $p.MarginV -eq 70) "Bottom -> alignment 2, margin 70"
    $p = Get-CaptionPlacement 'Middle'
    A ($p.Alignment -eq 5 -and $p.MarginV -eq 0)  "Middle -> alignment 5 (vertical centre), margin 0"
    $p = Get-CaptionPlacement 'Top'
    A ($p.Alignment -eq 8 -and $p.MarginV -eq 40) "Top -> alignment 8, margin 40"
    A ((Get-CaptionPlacement 'sideways').Alignment -eq 5) "unknown position falls back to Middle"
    A ((Get-CaptionPlacement '').Alignment -eq 5)         "empty position falls back to Middle"
    A ((Get-CaptionPlacement $null).Alignment -eq 5)      "null position falls back to Middle"
    A ((Get-CaptionPlacement 'bottom').Alignment -eq 2)   "position match is case-insensitive"

    # --- settings round trip ------------------------------------------------
    $root = NewRoot
    A ((Get-StudioSetting $root 'CaptionPosition' 'Middle') -eq 'Middle') "returns the default when the file is missing"

    Set-StudioSetting $root 'CaptionPosition' 'Top'
    A ((Get-StudioSetting $root 'CaptionPosition' 'Middle') -eq 'Top') "round-trips a saved value"

    Set-StudioSetting $root 'CaptionPosition' 'Bottom'
    $hits = @(Get-Content -LiteralPath (Join-Path $root 'studio-settings.txt') | Where-Object { $_ -like 'CaptionPosition=*' })
    A ($hits.Count -eq 1) "re-saving a key overwrites it instead of duplicating it (got $($hits.Count))"
    A ((Get-StudioSetting $root 'CaptionPosition' 'Middle') -eq 'Bottom') "the overwritten value is the one read back"

    Set-StudioSetting $root 'Other' 'kept'
    A ((Get-StudioSetting $root 'CaptionPosition' '') -eq 'Bottom') "writing one key leaves the others intact"
    A ((Get-StudioSetting $root 'Other' '') -eq 'kept') "the second key reads back too"

    A ((Get-StudioSetting $root 'Missing' 'fallback') -eq 'fallback') "an absent key returns the default"

    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $root 'studio-settings.txt'))
    A (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) "writes UTF-8 with no BOM"

    # a value containing '=' survives (only the first separator splits)
    Set-StudioSetting $root 'Weird' 'a=b=c'
    A ((Get-StudioSetting $root 'Weird' '') -eq 'a=b=c') "only the first = splits key from value"
}
catch {
    Write-Host "FAIL: unexpected error - $($_.Exception.Message)"
    $fails++
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fails -gt 0) { Write-Host "`n$fails test(s) FAILED"; exit 1 }
Write-Host "`nAll StudioSettings tests passed."
exit 0
