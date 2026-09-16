# LibraryLocation.ps1 - WHERE the shared library is.
#
# Kept apart from SharedLibrary.ps1 on purpose: that file decides what gets
# copied and how it merges, this one only answers "which folder, and is it
# plugged in". They change for completely different reasons.
#
# THE DRIVE-LETTER PROBLEM. The obvious shared folder is one on the USB stick
# the program was handed over on - it needs no accounts and no internet. But a
# stick is D: on one computer and E: on another, so a remembered path like
#
#     D:\Video Studio\shared-library
#
# is right on one machine and dead on the other. A removable drive is known by
# what is ON it, not by the letter Windows happened to give it. So when the
# remembered path isn't there, the same tail is looked for on every drive, and
# the one that turns up is used. The remembered path is NOT rewritten - the
# letters swap back just as easily, and a path that works on both machines
# should not need editing on either.

$script:LibraryLocationFile = 'shared-library.txt'

# The folder name suggested inside "Video Studio" on a stick. One word, no
# spaces, so it is obvious in Explorer what it is and that it belongs to us.
$script:LibraryFolderName = 'shared-library'

function Get-LibraryLocationPath {
    param([Parameter(Mandatory = $true)][string]$Root)
    return [System.IO.Path]::Combine($Root, $script:LibraryLocationFile)
}

# What is written in shared-library.txt, exactly as written - no checking that
# it exists. Use Resolve-LibraryLocation for the folder to actually work in.
function Get-LibraryLocation {
    param([Parameter(Mandatory = $true)][string]$Root)
    $path = Get-LibraryLocationPath $Root
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($path)) {
            $t = $line.Trim()
            if ($t -and -not $t.StartsWith('#')) { return $t }
        }
    } catch {}
    return $null
}

function Set-LibraryLocation {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Location
    )
    $text = @(
        '# The folder this computer shares its b-roll and music through.',
        '# Any path both machines can see: a folder on the USB stick, a shared',
        '# OneDrive/Dropbox folder, or a network share. One line.',
        '#',
        '# If this is on a stick and the stick comes up as a different drive',
        '# letter, it is found anyway - the rest of the path is what matters.',
        $Location.Trim()
    ) -join "`r`n"
    [System.IO.File]::WriteAllText((Get-LibraryLocationPath $Root), $text + "`r`n",
                                   (New-Object System.Text.UTF8Encoding($false)))
}

# ---- the same folder on a different drive -----------------------------------

# PURE: 'D:\Video Studio\shared-library' -> 'Video Studio\shared-library'.
# $null for a path with no drive letter (a network share stays as it is - it
# has no letter to drift).
function Get-DriveRelativePath {
    param([string]$Path)
    if (-not $Path) { return $null }
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { return $null }
    return $Path.Substring(3).Trim('\', '/')
}

# PURE: the first drive in $DriveRoots that has this path on it, given a
# callback that says whether a path exists. Taking the test as an argument is
# what lets this be tested without plugging anything in.
function Find-PathOnDrives {
    param(
        [string]$Path,
        [string[]]$DriveRoots,
        [scriptblock]$Exists
    )
    if (-not $Path) { return $null }
    if (& $Exists $Path) { return $Path }
    $tail = Get-DriveRelativePath $Path
    if (-not $tail) { return $null }
    foreach ($d in @($DriveRoots)) {
        if (-not $d) { continue }
        $try = [System.IO.Path]::Combine($d.TrimEnd('\') + '\', $tail)
        if ((& $Exists $try)) { return $try }
    }
    return $null
}

# Every drive that is actually there right now, sticks included.
function Get-DriveRoots {
    $out = @()
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            try { if ($d.IsReady) { $out += $d.RootDirectory.FullName } } catch {}
        }
    } catch {}
    return $out
}

# The folder to actually work in: what was remembered if it is there, otherwise
# the same folder on whichever drive the stick came up as. $null if neither.
function Resolve-LibraryLocation {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$Location
    )
    if (-not $Location) { $Location = Get-LibraryLocation $Root }
    if (-not $Location) { return $null }
    return (Find-PathOnDrives $Location (Get-DriveRoots) { param($p) Test-Path -LiteralPath $p })
}

# ---- suggesting a folder, so nobody has to think about it -------------------

# PURE: given the drives that are present and a test for "has a Video Studio
# folder on it", where the shared library most likely belongs. The stick the
# program was handed over on comes first: it is the one folder both people are
# guaranteed to have seen.
function Get-LibrarySuggestions {
    param(
        [string[]]$DriveRoots,
        [scriptblock]$HasStudioFolder,
        [string[]]$CloudFolders
    )
    $out = @()
    foreach ($d in @($DriveRoots)) {
        if (-not $d) { continue }
        $studio = [System.IO.Path]::Combine($d.TrimEnd('\') + '\', 'Video Studio')
        # Combine, not Join-Path: Join-Path CHECKS the drive and throws when it is
        # not there, and "the stick is not plugged in" is the ordinary case here,
        # not an error. Path arithmetic should never need a drive to exist.
        if (& $HasStudioFolder $studio) { $out += [System.IO.Path]::Combine($studio, $script:LibraryFolderName) }
    }
    foreach ($c in @($CloudFolders)) {
        if ($c) { $out += [System.IO.Path]::Combine($c, 'Video Studio shared library') }
    }
    return ($out | Select-Object -Unique)
}

# The same thing against this machine. Returned PLAIN - callers wrap in @().
function Get-SuggestedLibraryFolders {
    $cloud = @()
    foreach ($v in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) {
        if ($v -and (Test-Path -LiteralPath $v)) { $cloud += $v }
    }
    $dropbox = [System.IO.Path]::Combine($env:USERPROFILE, 'Dropbox')
    if (Test-Path -LiteralPath $dropbox) { $cloud += $dropbox }

    return (Get-LibrarySuggestions (Get-DriveRoots) { param($p) Test-Path -LiteralPath $p } $cloud)
}
