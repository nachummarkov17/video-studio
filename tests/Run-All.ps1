# Run-All.ps1 - every test in the project, in one go.
#
#   powershell -STA -ExecutionPolicy Bypass -File tests\Run-All.ps1
#
# Add -Quick to skip the two that shell out to ffmpeg (~40s).

param([switch]$Quick)

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$slow = @('RenderE2E.Tests.ps1', 'CaptionEditor.Tests.ps1')
$failed = @()

Write-Host "--- JavaScript (node --test) ---"
Push-Location (Join-Path $root 'editor')
try {
    & node --test 2>&1 | Select-Object -Last 8 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $failed += 'editor (node --test)' }
} finally { Pop-Location }

Write-Host ""
Write-Host "--- PowerShell ---"
$suites = @(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.Tests.ps1' -File) +
          @(Get-ChildItem -LiteralPath (Join-Path $root 'editor\tests') -Filter '*.Tests.ps1' -File)
foreach ($suite in $suites) {
    if ($Quick -and $slow -contains $suite.Name) { Write-Host ("SKIP  " + $suite.Name); continue }
    $out = & powershell -NoProfile -STA -ExecutionPolicy Bypass -File $suite.FullName 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("ok    " + $suite.Name)
    } else {
        Write-Host ("FAIL  " + $suite.Name)
        $out | Select-String -Pattern 'FAIL' | ForEach-Object { Write-Host ("        " + $_) }
        $failed += $suite.Name
    }
}

Write-Host ""
if ($failed.Count -eq 0) { Write-Host "EVERYTHING PASSED"; exit 0 }
Write-Host ("FAILED: " + ($failed -join ', ')); exit 1
