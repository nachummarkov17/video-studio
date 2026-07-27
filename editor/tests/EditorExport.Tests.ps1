# EditorExport.Tests.ps1 - unit tests for the pure export-handler helpers
# (Get-SafeProjectName, Resolve-EditorAssetPaths) extracted from Editor.ps1's
# 'export' case into EditorRender.ps1 so they're testable without a WebView2
# host or a real ffmpeg render.

. "$PSScriptRoot\..\..\EditorRender.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

# ---- Get-SafeProjectName -------------------------------------------------
A ((Get-SafeProjectName 'a/b:c*d') -eq 'a_b_c_d') 'sanitizes reserved filename characters'
A ((Get-SafeProjectName '') -eq 'Untitled') 'empty string falls back to Untitled'
A ((Get-SafeProjectName $null) -eq 'Untitled') 'null falls back to Untitled'
A ((Get-SafeProjectName '   ') -eq 'Untitled') 'whitespace-only falls back to Untitled'

# ---- Resolve-EditorAssetPaths --------------------------------------------
$root = 'C:\Users\nachu\AudioCleaner'

$relProject = @{ assets = @(@{ id = 'a1'; path = 'output/x.mp4' }) }
$resolved = Resolve-EditorAssetPaths $relProject $root
$relPath = $resolved.assets[0].path
A ([System.IO.Path]::IsPathRooted($relPath)) 'relative asset path becomes rooted'
A ($relPath.EndsWith('output\x.mp4')) 'relative asset path resolves under root as output\x.mp4'

$absIn = 'C:\Users\nachu\AudioCleaner\editor-imports\already-abs.mp4'
$absProject = @{ assets = @(@{ id = 'a2'; path = $absIn }) }
$resolvedAbs = Resolve-EditorAssetPaths $absProject $root
A ($resolvedAbs.assets[0].path -eq $absIn) 'already-absolute asset path is left unchanged'

if ($fails) { Write-Host "FAILS=$fails"; exit 1 } else { Write-Host 'ALL PASS' }
