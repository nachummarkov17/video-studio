# LibraryLocation.Tests.ps1 - finding the shared folder, including when the
# stick isn't the drive letter it was last time.
#
# The case that matters: the folder is remembered as D:\Video Studio\shared-
# library on one computer, and the same stick comes up as E: on the other. If
# that isn't handled, the editor clicks the button and is told the folder isn't
# reachable while it is sitting in their hand.
#
# The drive-walking is tested through injected callbacks rather than real
# drives, so it proves the logic on any machine, plugged in or not.
#
# Run:  powershell -ExecutionPolicy Bypass -File tests\LibraryLocation.Tests.ps1

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\LibraryLocation.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("libloc_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    # ---- splitting a path off its drive (pure) ------------------------------
    A ((Get-DriveRelativePath 'D:\Video Studio\shared-library') -eq 'Video Studio\shared-library') 'a path is split from its drive letter'
    A ((Get-DriveRelativePath 'D:/Video Studio/shared-library') -eq 'Video Studio/shared-library') 'forward slashes too'
    A ((Get-DriveRelativePath 'D:\lib\') -eq 'lib') 'and a trailing slash is not kept'
    A ($null -eq (Get-DriveRelativePath '\\nas\media\studio')) 'a network share has no drive letter to drift'
    A ($null -eq (Get-DriveRelativePath '')) 'and nothing in means nothing out'

    # ---- the same folder on another drive (pure) ---------------------------
    # Pretend only E: has it - exactly the editor's stick.
    $onlyE = { param($p) return ($p -like 'E:\*') }
    $drives = @('C:\', 'D:\', 'E:\')

    $found = Find-PathOnDrives 'D:\Video Studio\shared-library' $drives $onlyE
    A ($found -eq 'E:\Video Studio\shared-library') 'a stick that changed letter is found on the drive it really is'

    $onlyD = { param($p) return ($p -like 'D:\*') }
    A ((Find-PathOnDrives 'D:\Video Studio\shared-library' $drives $onlyD) -eq 'D:\Video Studio\shared-library') 'and when it is where it says, that is used unchanged'

    $none = { param($p) return $false }
    A ($null -eq (Find-PathOnDrives 'D:\Video Studio\shared-library' $drives $none)) 'an unplugged stick is reported missing, not guessed at'
    A ($null -eq (Find-PathOnDrives '\\nas\media\studio' $drives $none)) 'and a missing network share is not hunted for on drives'
    A ((Find-PathOnDrives '\\nas\media\studio' $drives { param($p) $true }) -eq '\\nas\media\studio') 'while a share that IS there is used as written'

    # the first drive that has it wins, and C: is looked at before E:
    $cAndE = { param($p) return ($p -like 'C:\*' -or $p -like 'E:\*') }
    A ((Find-PathOnDrives 'D:\lib' $drives $cAndE) -eq 'C:\lib') 'the first drive that has it is the one used'

    # ---- what to suggest (pure) --------------------------------------------
    # Only D: has a "Video Studio" folder on it - that is the install stick.
    $studioOnD = { param($p) return ($p -eq 'D:\Video Studio') }
    $sug = @(Get-LibrarySuggestions $drives $studioOnD @())
    A ($sug.Count -eq 1) 'exactly one folder is suggested when one stick is in'
    A ($sug[0] -eq 'D:\Video Studio\shared-library') 'and it is inside the Video Studio folder on the stick'

    $withCloud = @(Get-LibrarySuggestions $drives $studioOnD @('C:\Users\me\OneDrive'))
    A ($withCloud.Count -eq 2) 'a OneDrive folder is offered as well'
    A ($withCloud[0] -eq 'D:\Video Studio\shared-library') 'with the stick first, because both people have held it'
    A ($withCloud[1] -like '*OneDrive\Video Studio shared library') 'and the cloud folder named for what it is'

    $noneFound = @(Get-LibrarySuggestions $drives { param($p) $false } @())
    A ($noneFound.Count -eq 0) 'with no stick and no cloud folder, nothing is suggested'

    # ---- remembering it, on real files -------------------------------------
    A ($null -eq (Get-LibraryLocation $tmp)) 'a fresh install shares with nobody'
    Set-LibraryLocation $tmp 'D:\Video Studio\shared-library'
    A ((Get-LibraryLocation $tmp) -eq 'D:\Video Studio\shared-library') 'the folder is remembered, spaces and all'
    $text = [System.IO.File]::ReadAllText((Get-LibraryLocationPath $tmp))
    A ($text -like '#*') 'the file explains itself to anyone who opens it'
    A (($text -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('#') }).Count -eq 1) 'and holds exactly one path'

    Set-LibraryLocation $tmp '\\nas\media\studio'
    A ((Get-LibraryLocation $tmp) -eq '\\nas\media\studio') 'and can be changed to a network folder'

    # ---- resolving against this machine ------------------------------------
    $real = Join-Path $tmp 'a real folder'
    New-Item -ItemType Directory -Force -Path $real | Out-Null
    Set-LibraryLocation $tmp $real
    A ((Resolve-LibraryLocation $tmp) -eq $real) 'a folder that is really there resolves to itself'
    Set-LibraryLocation $tmp (Join-Path $tmp 'not there')
    A ($null -eq (Resolve-LibraryLocation $tmp)) 'and one that is not, resolves to nothing'
    A ((Resolve-LibraryLocation $tmp $real) -eq $real) 'an explicit folder wins over the remembered one'

    # every drive it reports is one Windows agrees is there
    $roots = @(Get-DriveRoots)
    A ($roots.Count -ge 1) 'the drives on this machine are listed'
    A (@($roots | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -eq 0) 'and every one of them is actually reachable'

    # and the suggestion machinery runs here without throwing
    $live = @(Get-SuggestedLibraryFolders)
    A ($true) ("this machine suggests: " + $(if ($live.Count) { $live -join ' | ' } else { '(nothing plugged in)' }))
    A (@($live | Where-Object { -not $_ }).Count -eq 0) 'and never suggests an empty path'
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails -eq 0) { Write-Host "All LibraryLocation tests passed." } else { Write-Host "$fails test(s) FAILED."; exit 1 }
