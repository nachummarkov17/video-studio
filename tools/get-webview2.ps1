# Downloads the Microsoft.Web.WebView2 NuGet package once and extracts the DLLs
# the WPF host needs into tools\webview2\. Requires internet ONCE (build time only).
param([string]$Version = '1.0.2792.45')
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = Split-Path -Parent $PSScriptRoot          # ...\AudioCleaner
$dest = Join-Path $root 'tools\webview2'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$tmp = Join-Path $env:TEMP ("wv2_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$nupkg = Join-Path $tmp 'wv2.nupkg.zip'
Invoke-WebRequest -UseBasicParsing -Uri "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$Version" -OutFile $nupkg
Expand-Archive -Path $nupkg -DestinationPath $tmp -Force
# Note: for this package version the managed DLLs live under lib\net462 (not lib\net45 as
# older docs suggest). Resolve whichever net4xx folder actually shipped in the nupkg.
$libDir = Get-ChildItem (Join-Path $tmp 'lib') -Directory | Where-Object { $_.Name -like 'net4*' } | Select-Object -First 1
Copy-Item (Join-Path $libDir.FullName 'Microsoft.Web.WebView2.Core.dll') $dest -Force
Copy-Item (Join-Path $libDir.FullName 'Microsoft.Web.WebView2.Wpf.dll')  $dest -Force
Copy-Item (Join-Path $tmp 'runtimes\win-x64\native\WebView2Loader.dll') $dest -Force
Write-Host "WebView2 SDK DLLs -> $dest"
