# StudioLoad.Tests.ps1 - loads the WHOLE app the way it really starts, right up
# to (but not including) ShowDialog.
#
# Studio.ps1 is now a dozen dot-sourced files. A typo in any of them, a control
# that no longer exists in the markup, or a handler wired to a function that
# moved would otherwise only show up when the user clicks something. This runs
# the real startup path and then checks that everything the UI reaches for is
# actually there.
#
# Run:  powershell -STA -ExecutionPolicy Bypass -File tests\StudioLoad.Tests.ps1

$ErrorActionPreference = 'Stop'
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$src = Get-Content -LiteralPath (Join-Path $root 'Studio.ps1') -Raw

# Run everything except the final blocking ShowDialog.
A ($src -match '(?m)^\[void\]\$win\.ShowDialog\(\)') 'Studio.ps1 still ends by showing its window'
$headless = $src -replace '(?m)^\[void\]\$win\.ShowDialog\(\)', '# (ShowDialog suppressed for this test)'

# $PSScriptRoot is empty under Invoke-Expression, so hand it the root the same
# way the real launcher does.
$headless = "`$PSScriptRoot = '$root'`n" + $headless

try {
    Invoke-Expression $headless
    A $true 'the whole app loads (all dot-sourced files, window built, handlers wired)'
} catch {
    A $false "the whole app loads - $($_.Exception.Message)"
    Write-Host "`n$fails test(s) FAILED"; exit 1
}

# ---- the window and its controls -------------------------------------------
A ($null -ne $win) 'the main window was built'
foreach ($n in 'BtnAdd', 'BtnRefresh', 'BtnClearAll', 'BtnEditor', 'BtnCaptions', 'BtnEditCaps',
                'CmbStyle', 'CmbPos', 'BtnBurn', 'BtnMusic', 'BtnExport', 'BtnSendOut',
                'BtnExportDest', 'LblExportDest', 'ChkRecap', 'ChkReburn', 'ChkFourK',
                'VidList', 'Log', 'Status', 'EditorOverlay', 'EditorWebHost', 'BtnEditorBack',
                'BtnSharedLib') {
    A ($null -ne $ctrls[$n]) "control $n resolved"
}

# ---- every function the handlers call must exist after the split ------------
foreach ($fn in 'Show-CaptionEditor', 'Show-MusicDialog', 'Initialize-Editor', 'Send-EditorMessage',
                 'Invoke-EditorMessage', 'Start-EditorRender', 'Complete-EditorRender',
                 'Start-TrackedProcess', 'Watch-Process', 'Stop-WatchedProcess',
                 'Read-SrtCues', 'ConvertTo-SrtText', 'Find-ActiveCueIndex',
                 'Get-ProxyPath', 'Test-ProxyReady', 'Start-ProxyBuild', 'Complete-ProxyBuild',
                 'Refresh-Videos', 'Start-Task', 'Play-Selected', 'Import-VideoFiles',
                 'New-Win', 'Format-Clock', 'Utf8NoBom', 'Get-SuggestedExportName',
                 'Sync-Library', 'Get-LibraryLocation', 'Get-SyncPlan', 'Select-Folder') {
    A ($null -ne (Get-Command $fn -ErrorAction SilentlyContinue)) "function $fn is in scope"
}

# ---- the caption cue type compiled -----------------------------------------
A ($null -ne ([System.Management.Automation.PSTypeName]'VideoStudio.CaptionCue').Type) 'the CaptionCue type compiled'

# ---- no file drifts past the size we said we would keep them under ----------
$overSized = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File |
    Where-Object { (Get-Content -LiteralPath $_.FullName | Measure-Object -Line).Lines -gt 500 } |
    ForEach-Object { $_.Name })
A ($overSized.Count -eq 0) ("no PowerShell file is over 500 lines" +
    $(if ($overSized.Count) { " (over: " + ($overSized -join ', ') + ")" } else { "" }))

# ---- $PSScriptRoot is never trusted as a parameter default ------------------
# Measured, and the cause of a sync that silently did nothing: in a script with
# [CmdletBinding()], a parameter default that reads $PSScriptRoot binds to an
# EMPTY string - the automatic variable is not populated yet at binding time.
# Drop [CmdletBinding()] and the identical line works, which is why this is so
# easy to write and so hard to spot. Every script that wants $PSScriptRoot as a
# default must therefore fall back to it in the BODY.
$noFallback = @()
foreach ($f in @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File)) {
    $text = Get-Content -LiteralPath $f.FullName -Raw
    if ($text -notmatch '\[CmdletBinding\(') { continue }
    if ($text -notmatch '(?m)^\s*\[string\]\$Root\s*=\s*\$PSScriptRoot') { continue }
    # a body line that puts it right again, whichever form the script uses
    if ($text -match '(?m)^\s*if \(-not \$Root') { continue }
    $noFallback += $f.Name
}
A ($noFallback.Count -eq 0) ("no script leaves `$Root to a `$PSScriptRoot parameter default" +
    $(if ($noFallback.Count) { " (unguarded: " + ($noFallback -join ', ') + ")" } else { "" }))

# ---- no stray control characters in any source file -------------------------
# This has bitten three times now. A tool that writes a path like work\broll.log
# or tools\ffmpeg\bin through something that interprets backslash escapes leaves
# a real BACKSPACE or FORMFEED byte in the file. The path silently becomes
# nonsense, and the failure surfaces somewhere else entirely - so look for the
# bytes directly rather than for the symptom.
$ctrl = [char]0x00 + '-' + [char]0x08 + [char]0x0B + [char]0x0C + [char]0x0E + '-' + [char]0x1F
$pattern = '[' + $ctrl + ']'
# Only where source actually lives. Walking the whole folder would drag the
# scan through tools\align-venv and tools\whisper - 2.8 GB of dependencies with
# nothing to check in them.
$sourceDirs = @(
    @{ Dir = '.';          Recurse = $false }
    @{ Dir = 'editor';     Recurse = $true  }
    @{ Dir = 'ui';         Recurse = $true  }
    @{ Dir = 'dist';       Recurse = $false }
    @{ Dir = 'tests';      Recurse = $false }
    @{ Dir = 'tools';      Recurse = $false }
)
$dirty = @()
foreach ($sd in $sourceDirs) {
    $dir = if ($sd.Dir -eq '.') { $root } else { Join-Path $root $sd.Dir }
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    # -Include is silently ignored without -Recurse, which let a binary .ico
    # through and "failed" every run - filter on the extension instead.
    $found = Get-ChildItem -LiteralPath $dir -File -Recurse:$sd.Recurse -ErrorAction SilentlyContinue |
             Where-Object { $_.Extension -in '.ps1', '.js', '.html', '.css', '.xaml' }
    foreach ($f in $found) {
        $hits = [regex]::Matches([System.IO.File]::ReadAllText($f.FullName), $pattern)
        if ($hits.Count) { $dirty += ('{0} ({1})' -f $f.Name, $hits.Count) }
    }
}
A ($dirty.Count -eq 0) ('no source file contains a stray control character' +
    $(if ($dirty.Count) { ' (found in: ' + ($dirty -join ', ') + ')' } else { '' }))

if ($fails -gt 0) { Write-Host "`n$fails test(s) FAILED"; exit 1 }
Write-Host "`nAll Studio load tests passed."
exit 0
