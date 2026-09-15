# Release.ps1 - what a "version of the program" actually consists of.
#
# The app folder holds three very different kinds of thing, and an update must
# treat them differently:
#
#   PROGRAM       ~0.6 MB of .ps1/.js/.css/.xaml. Changes every release.
#                 Replaced wholesale by an update.
#   YOUR CONTENT  output\, broll\, music\, projects\ and the little settings
#                 files. NEVER touched by an update - these are the reason the
#                 program exists.
#   DEPENDENCIES  tools\whisper (1.5 GB incl. the speech model), tools\align-venv
#                 (1.3 GB of torch), tools\webview2. Installed ONCE and never
#                 shipped again - putting 2.8 GB in every update would make
#                 updating something you avoid doing.
#
# The rule is a WHITELIST: a file is part of the program only if it matches one
# of the specs below. Everything else is yours by default, which is the safe way
# round - a new kind of user file can never be mistaken for a program file and
# deleted.
#
# Pure: no downloads, no zipping, no UI. Just "what is the program".

# Each spec: a folder relative to the root, which patterns count, and whether to
# recurse. Anything not listed here is content and is left alone, forever.
function Get-ProgramFileSpec {
    return @(
        # the app itself, plus the two docs that describe it
        [pscustomobject]@{ Dir = '.';            Patterns = @('*.ps1', '*.vbs', '*.ico'); Recurse = $false }
        [pscustomobject]@{ Dir = '.';            Patterns = @('README.txt', 'UPLOAD-GUIDE.txt', 'VERSION.txt'); Recurse = $false }
        # the in-window editor (its tests are for development, not for running)
        [pscustomobject]@{ Dir = 'editor';       Patterns = @('*.html');                  Recurse = $false }
        [pscustomobject]@{ Dir = 'editor\js';    Patterns = @('*.js');                    Recurse = $false }
        [pscustomobject]@{ Dir = 'editor\css';   Patterns = @('*.css');                   Recurse = $false }
        # window markup
        [pscustomobject]@{ Dir = 'ui';           Patterns = @('*.xaml');                  Recurse = $false }
        # helper scripts ONLY - tools\whisper, tools\align-venv and tools\webview2
        # are dependencies and are deliberately not recursed into
        [pscustomobject]@{ Dir = 'tools';        Patterns = @('*.ps1', '*.py');           Recurse = $false }
        # the updater has to travel with the app so it can replace it
        [pscustomobject]@{ Dir = 'dist';         Patterns = @('*.ps1');                   Recurse = $false }
    )
}

# Every program file present under $Root, as paths relative to it.
function Get-ProgramFiles {
    param([Parameter(Mandatory = $true)][string]$Root)
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $out = @()
    foreach ($spec in Get-ProgramFileSpec) {
        $dir = if ($spec.Dir -eq '.') { $Root } else { Join-Path $Root $spec.Dir }
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($pattern in $spec.Patterns) {
            $files = Get-ChildItem -LiteralPath $dir -Filter $pattern -File -Recurse:$spec.Recurse -ErrorAction SilentlyContinue
            foreach ($f in $files) {
                $rel = $f.FullName.Substring($Root.TrimEnd('\').Length + 1)
                if ($seen.Add($rel.ToLowerInvariant())) { $out += $rel }
            }
        }
    }
    return ,@($out | Sort-Object)
}

# Would this relative path be part of the program? Used when applying an update
# to decide whether a local file that ISN'T in the new package should be deleted
# (a script that was removed in the new version) or left alone (your videos).
function Test-ProgramPath {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$RelPath)
    if ([string]::IsNullOrWhiteSpace($RelPath)) { return $false }
    $rel = $RelPath -replace '/', '\'
    $rel = $rel.TrimStart('\')
    if ($rel -match '\.\.') { return $false }                  # never outside the root
    $dir = [System.IO.Path]::GetDirectoryName($rel)
    if ([string]::IsNullOrEmpty($dir)) { $dir = '.' }
    $name = [System.IO.Path]::GetFileName($rel)
    foreach ($spec in Get-ProgramFileSpec) {
        if ($spec.Recurse) {
            if ($dir -ne $spec.Dir -and -not $dir.StartsWith($spec.Dir + '\', 'OrdinalIgnoreCase')) { continue }
        } else {
            if ($dir -ne $spec.Dir) { continue }
        }
        foreach ($pattern in $spec.Patterns) {
            if ($name -like $pattern) { return $true }
        }
    }
    return $false
}

# ---- versions ---------------------------------------------------------------

# The installed version, from VERSION.txt. A build with no VERSION.txt is
# treated as 0.0.0, so the very first update always looks newer than it.
function Get-AppVersion {
    param([Parameter(Mandatory = $true)][string]$Root)
    $path = Join-Path $Root 'VERSION.txt'
    if (-not (Test-Path -LiteralPath $path)) { return '0.0.0' }
    try {
        $v = ([System.IO.File]::ReadAllText($path)).Trim()
        if (Test-VersionString $v) { return $v }
    } catch {}
    return '0.0.0'
}

function Set-AppVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Version
    )
    if (-not (Test-VersionString $Version)) { throw "Not a version number: '$Version'" }
    [System.IO.File]::WriteAllText((Join-Path $Root 'VERSION.txt'),
                                   $Version.Trim() + "`r`n",
                                   (New-Object System.Text.UTF8Encoding($false)))
    return $Version.Trim()
}

function Test-VersionString {
    param([AllowEmptyString()][string]$Version)
    return ($Version -match '^\s*\d+(\.\d+){0,3}\s*$')
}

# -1 / 0 / 1. Padded to three parts first, because [version]'1.4' and
# [version]'1.4.0' do NOT compare equal - the unspecified part counts as -1,
# which would make 1.4 look OLDER than 1.4.0 and offer a pointless update.
function Compare-AppVersion {
    param([string]$A, [string]$B)
    $pad = {
        param($v)
        if (-not (Test-VersionString $v)) { $v = '0.0.0' }
        $parts = @($v.Trim() -split '\.')
        while ($parts.Count -lt 3) { $parts += '0' }
        return [version](($parts[0..2]) -join '.')
    }
    $va = & $pad $A; $vb = & $pad $B
    if ($va -lt $vb) { return -1 }
    if ($va -gt $vb) { return 1 }
    return 0
}

# ---- the manifest a release publishes ---------------------------------------
#
# One small JSON file sitting next to the package. The app reads it to answer
# "is there anything newer than me?" without downloading 600 KB to find out.

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try { return (($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '') }
        finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}

function New-UpdateManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$PackageName,
        [string]$Notes = '',
        [string]$Sha256 = '',
        [string]$Url = ''
    )
    return [ordered]@{
        version  = $Version.Trim()
        package  = $PackageName
        url      = $Url                      # empty = the package sits beside this file
        sha256   = $Sha256
        notes    = $Notes
        released = (Get-Date -Format 'yyyy-MM-dd')
    }
}

# Forgiving on purpose: a manifest that can't be read must never stop the app
# starting, it just means "no update today".
function ConvertFrom-UpdateManifestJson {
    param([AllowEmptyString()][string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    $m = $null
    try { $m = $Json | ConvertFrom-Json } catch { return $null }
    if (-not $m -or -not $m.version -or -not (Test-VersionString $m.version)) { return $null }
    if (-not $m.package) { return $null }
    return [pscustomobject]@{
        Version  = ([string]$m.version).Trim()
        Package  = [string]$m.package
        Url      = [string]$m.url
        Sha256   = ([string]$m.sha256).Trim().ToLowerInvariant()
        Notes    = [string]$m.notes
        Released = [string]$m.released
    }
}

# ---- where the files actually are -------------------------------------------
#
# An update source is either a FOLDER (a synced OneDrive/Dropbox folder, a
# network share, a USB stick) or an https URL. These two functions are the only
# place that difference is reasoned about.
#
# The URL case is shaped by GitHub: a repo has a permanent "latest release"
# address, https://github.com/<owner>/<repo>/releases/latest/download/update.json,
# and the package sits beside it under the same path. So "the package lives next
# to the manifest" is the rule for the web too, not just for folders.

function Test-IsWebSource {
    param([AllowEmptyString()][string]$Source)
    return ($Source -match '^https?://')
}

function Get-ManifestLocation {
    param([Parameter(Mandatory = $true)][string]$Source)
    if (Test-IsWebSource $Source) {
        if ($Source -match '\.json($|\?)') { return $Source }    # already points at it
        return ($Source.TrimEnd('/') + '/update.json')
    }
    # [IO.Path]::Combine, not Join-Path: Join-Path asks the PROVIDER whether the
    # drive exists and THROWS if it doesn't. An update source on a USB stick
    # that isn't plugged in is an ordinary Tuesday, not an error - work out the
    # path as a string and let the caller find nothing there.
    return [System.IO.Path]::Combine($Source, 'update.json')
}

# $Url is the manifest's own "url" field: an absolute address wins (that is how
# a package hosted somewhere else entirely would work). Otherwise the package is
# a sibling of the manifest.
function Get-PackageLocation {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Package,
        [string]$Url
    )
    if ($Url) { return $Url }
    if (Test-IsWebSource $Source) {
        return (((Get-ManifestLocation $Source) -replace '[^/]+$', '') + $Package)
    }
    return [System.IO.Path]::Combine($Source, $Package)
}

# Invoke-WebRequest hands back a BYTE ARRAY whenever the server doesn't declare
# the body as text - and GitHub serves every release asset as octet-stream. So
# the manifest arrives as bytes, ConvertFrom-Json chokes on it, and the update
# check fails silently. Decode it.
function ConvertTo-TextContent {
    param($Content)
    if ($null -eq $Content) { return '' }
    if ($Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($Content) }
    return [string]$Content
}
