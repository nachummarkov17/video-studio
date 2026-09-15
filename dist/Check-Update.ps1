# Check-Update.ps1 - fetches the update manifest, or the package itself.
#
# Lives in its own process because it touches the network: a shared folder that
# has gone offline or a slow link would otherwise freeze the window, and this
# app has spent enough of its life being frozen by things that should have been
# waiting in the background.
#
# The SOURCE is either a folder (a synced OneDrive/Dropbox folder, a network
# share, a USB stick) or an https URL pointing at update.json. Both work the
# same way from here on.
#
#   Check-Update.ps1 -Source <folder|url>                      -> prints update.json
#   Check-Update.ps1 -Source <folder|url> -Package x.zip -Out <file> [-Url <url>]
#                                                              -> downloads the package

param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$Package,
    [string]$Url,
    [string]$Out
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Where things live is shared with the installer and the app - see Release.ps1.
$here = Split-Path -Parent $PSCommandPath
$release = Join-Path $here 'Release.ps1'
if (-not (Test-Path -LiteralPath $release)) { $release = Join-Path (Split-Path -Parent $here) 'Release.ps1' }
. $release

function Get-Text([string]$location) {
    if (Test-IsWebSource $location) {
        return (ConvertTo-TextContent (Invoke-WebRequest -Uri $location -UseBasicParsing -TimeoutSec 20).Content)
    }
    if (-not (Test-Path -LiteralPath $location)) { throw "Not found: $location" }
    return [System.IO.File]::ReadAllText($location)
}

function Save-File([string]$from, [string]$to) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
    if (Test-IsWebSource $from) {
        Invoke-WebRequest -Uri $from -UseBasicParsing -TimeoutSec 600 -OutFile $to
    } else {
        if (-not (Test-Path -LiteralPath $from)) { throw "Not found: $from" }
        Copy-Item -LiteralPath $from -Destination $to -Force
    }
}

if ($Package -and $Out) {
    Save-File (Get-PackageLocation $Source $Package $Url) $Out
    Write-Output "OK $Out"
    exit 0
}

Write-Output (Get-Text (Get-ManifestLocation $Source))
exit 0
