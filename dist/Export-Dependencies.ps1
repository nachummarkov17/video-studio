# Export-Dependencies.ps1 - hand the heavy parts over, once.
#
#   .\dist\Export-Dependencies.ps1 -To "E:\VideoStudio-deps"
#
# The captions engine is 2.8 GB: a 1.5 GB speech model, and a 1.3 GB timing
# aligner. Those are not things to put in an update - they never change, and
# nobody wants a 2.8 GB download every time a button moves. So they are copied
# ACROSS ONCE, by hand, onto a USB stick or a shared folder, and the installer
# picks them up from there with -DependenciesFrom.
#
# After that, updates are 0.5 MB and this never has to happen again.

param(
    [Parameter(Mandatory = $true)][string]$To,
    [switch]$NoAligner          # captions still work without it, just timed slightly less precisely
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

function Copy-Part([string]$name, [string]$why) {
    $src = Join-Path $Root "tools\$name"
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Host "  $name is not on this machine - skipping" -ForegroundColor Yellow
        return
    }
    $size = (Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    Write-Host ("  {0} ({1:N0} MB) - {2}" -f $name, ($size / 1MB), $why)
    Copy-Item -LiteralPath $src -Destination $To -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $To | Out-Null
Write-Host "Copying the captions engine to $To"
Write-Host 'This takes a few minutes and only ever needs doing once.'
Write-Host ''

Copy-Part 'whisper' 'speech recognition + its model'
if (-not $NoAligner) { Copy-Part 'align-venv' 'word-accurate caption timing' }

$total = (Get-ChildItem $To -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
Write-Host ''
Write-Host ('Done - {0:N0} MB in {1}' -f ($total / 1MB), $To) -ForegroundColor Green
Write-Host 'On the other machine, run the installer with:'
Write-Host "  -DependenciesFrom `"$To`""
