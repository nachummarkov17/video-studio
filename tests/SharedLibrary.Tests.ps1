# SharedLibrary.Tests.ps1 - sharing a b-roll library between two computers.
#
# The thing worth protecting here is simple: a sync must never cost anybody a
# file. So the tests care most about the cases where something could be lost -
# a clip that exists on both sides with different content, a palette where you
# have each claimed the same marker for a different colour, a text file merged
# in both directions. In every one of those, THIS machine's copy has to survive
# untouched.
#
# Run:  powershell -ExecutionPolicy Bypass -File tests\SharedLibrary.Tests.ps1

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\SharedLibrary.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }
function Lines($text) { return @($text -split "`r?`n" | Where-Object { $_ -ne '' }) }
function HasLine($text, $line) { return ((Lines $text) -contains $line) }
function Put($path, $text) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("shlib_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    # ---- what is shared, and what is not ------------------------------------
    $shared = @(Get-SharedFolders)
    A ($shared -contains 'broll' -and $shared -contains 'music') 'b-roll and music are shared'
    A ($shared -notcontains 'output' -and $shared -notcontains 'projects') 'your videos and saved edits are not'
    A (@(Get-SharedFiles) -contains 'broll-trims.txt') 'and so are the trims you set on each clip'

    # ---- the plan (pure) ----------------------------------------------------
    $local = @{
        'both.mp4'         = [pscustomobject]@{ Size = 10; Modified = [datetime]'2026-01-01T10:00:00Z' }
        'mine.mp4'         = [pscustomobject]@{ Size = 20; Modified = [datetime]'2026-01-01T10:00:00Z' }
        'clash.mp4'        = [pscustomobject]@{ Size = 30; Modified = [datetime]'2026-01-01T10:00:00Z' }
        'Food\close.mp4'   = [pscustomobject]@{ Size = 40; Modified = [datetime]'2026-01-01T10:00:00Z' }
    }
    $remote = @{
        'both.mp4'         = [pscustomobject]@{ Size = 10; Modified = [datetime]'2026-01-01T10:00:01Z' }
        'theirs.mp4'       = [pscustomobject]@{ Size = 50; Modified = [datetime]'2026-01-01T10:00:00Z' }
        'clash.mp4'        = [pscustomobject]@{ Size = 31; Modified = [datetime]'2026-01-01T10:00:00Z' }
    }
    $plan = Get-SyncPlan $local $remote
    A ((@($plan.Push) -join ',') -eq 'Food\close.mp4,mine.mp4') 'what only this machine has is sent'
    A ((@($plan.Pull) -join ',') -eq 'theirs.mp4') 'what only the other has is fetched'
    A ((@($plan.Same) -join ',') -eq 'both.mp4') 'a second of clock drift still counts as the same file'
    A ((@($plan.Conflict) -join ',') -eq 'clash.mp4') 'and a real difference is a conflict, not a copy'
    A (@($plan.Conflict) -notcontains 'both.mp4') 'which timestamp slack alone never causes'

    $far = @{ 'both.mp4' = [pscustomobject]@{ Size = 10; Modified = [datetime]'2026-01-01T11:00:00Z' } }
    A ((@((Get-SyncPlan $local $far).Conflict) -contains 'both.mp4')) 'an hour apart at the same size is still a conflict'

    $empty = Get-SyncPlan @{} @{}
    A ($empty.Push.Count -eq 0 -and $empty.Pull.Count -eq 0) 'two empty libraries produce no work'
    $fromNull = Get-SyncPlan $null $remote
    A ($fromNull.Pull.Count -eq 3) 'and a library that does not exist yet simply fetches everything'

    # ---- inventories and copying, on real files -----------------------------
    $a = Join-Path $tmp 'here\broll'
    $b = Join-Path $tmp 'there\broll'
    Put (Join-Path $a 'one.mp4') 'AAA'
    Put (Join-Path $a 'Food\two.mp4') 'BB'
    Put (Join-Path $b 'three.mp4') 'CCCC'

    $inv = Get-FileInventory $a
    A ($inv.Count -eq 2) 'an inventory walks subfolders'
    A ($inv.ContainsKey('Food\two.mp4')) 'and keys files by their path inside the library'
    A ($inv['one.mp4'].Size -eq 3) 'with the size it will be compared by'
    A ((Get-FileInventory (Join-Path $tmp 'nothing-here')).Count -eq 0) 'a missing library is empty, not an error'

    $p2 = Get-SyncPlan (Get-FileInventory $a) (Get-FileInventory $b)
    A ((Copy-PlannedFiles $a $b $p2.Push) -eq 2) 'both files are sent'
    A (Test-Path (Join-Path $b 'Food\two.mp4')) 'and the group folder is created on the way'
    A ((Copy-PlannedFiles $b $a $p2.Pull) -eq 1) 'and the missing one comes back'
    A (([System.IO.File]::ReadAllText((Join-Path $a 'three.mp4'))) -eq 'CCCC') 'with its content intact'

    $after = Get-SyncPlan (Get-FileInventory $a) (Get-FileInventory $b)
    A ($after.Push.Count -eq 0 -and $after.Pull.Count -eq 0) 'syncing twice copies nothing the second time'
    A ($after.Same.Count -eq 3) 'because every file now matches'

    # ---- merging keyed lines (pure) -----------------------------------------
    $mine = "# my notes`r`nbroll/a.mov|1|2`r`nbroll/shared.mov|5|6`r`n"
    $theirs = "# their notes`r`nbroll/shared.mov|99|100`r`nbroll/b.mov|3|4`r`n"
    $m = Merge-KeyedLines $mine $theirs 0
    A (HasLine $m 'broll/a.mov|1|2') 'my line survives the merge'
    A (HasLine $m 'broll/b.mov|3|4') 'and theirs arrives'
    A (HasLine $m 'broll/shared.mov|5|6') 'and where we both set a trim, mine stands'
    A (-not (HasLine $m 'broll/shared.mov|99|100')) 'theirs does not quietly replace it'
    A (HasLine $m '# my notes') 'my comments are kept'
    A (-not (HasLine $m '# their notes')) "and theirs are not dragged in as duplicates"

    A ((Lines (Merge-KeyedLines '' $theirs 0)).Count -eq 2) 'an empty file here takes everything from there'
    A ((Merge-KeyedLines '' '' 0).Trim() -eq '') 'two empty files merge to nothing'
    $junk = Merge-KeyedLines "`r`n   `r`nnopipe`r`n|1|2`r`ngood/x.mov|7|8`r`n" '' 0
    A (HasLine $junk 'good/x.mov|7|8') 'a hand-edited file keeps its good lines'
    A ((Lines $junk).Count -eq 1) 'and blank, key-less and pipe-less lines are dropped'

    $twice = Merge-KeyedLines (Merge-KeyedLines $mine $theirs 0) $theirs 0
    A ((Lines $twice).Count -eq (Lines $m).Count) 'merging again changes nothing'

    # ---- merging the colour palette -----------------------------------------
    # Markers are what .srt files actually contain, so a colour that arrives
    # from the other computer has to keep the character it arrived with.
    $mineCol   = "Teal|*|#3D9E8E`r`nRed|~|#CC3322`r`n"
    $theirsCol = "Teal|*|#111111`r`nPurple|^|#7744AA`r`n"
    $mc = Merge-CaptionColorFiles $mineCol $theirsCol
    A (HasLine $mc 'Purple|^|#7744AA') 'their colour arrives on its own marker'
    A (HasLine $mc 'Red|~|#CC3322') 'mine is untouched'
    A (HasLine $mc 'Teal|*|#3D9E8E') 'and my star colour is not repainted by theirs'

    # same character, different colour: mine wins, because captions I have
    # already written say what that character means
    $clashCol = "Blue|~|#2255DD`r`n"
    $mc2 = Merge-CaptionColorFiles $mineCol $clashCol
    A (HasLine $mc2 'Red|~|#CC3322') 'a marker we both claimed keeps my meaning'
    A (-not ($mc2 -match 'Blue')) 'and theirs is dropped rather than re-lettered'

    $dup = Merge-CaptionColorFiles $mineCol "Red|^|#CC3322`r`n"
    A ((@((Lines $dup) | Where-Object { $_ -like 'Red*' })).Count -eq 1) 'the same colour twice does not fill the palette'

    $fresh = Merge-CaptionColorFiles '' $theirsCol
    A (HasLine $fresh 'Purple|^|#7744AA') 'an empty palette takes theirs'
    A (HasLine $fresh 'Teal|*|#3D9E8E') 'while the star colour stays the one every caption depends on'

    # ---- the text files, written to both sides ------------------------------
    $lt = Join-Path $tmp 'here\broll-trims.txt'
    $rt = Join-Path $tmp 'there\broll-trims.txt'
    Put $lt $mine; Put $rt $theirs
    A (Sync-SharedTextFile $lt $rt) 'syncing a text file reports that it did something'
    A (([System.IO.File]::ReadAllText($lt)) -eq ([System.IO.File]::ReadAllText($rt))) 'and both computers end up with the same file'
    A (HasLine ([System.IO.File]::ReadAllText($rt)) 'broll/a.mov|1|2') 'containing both sets of trims'
    A (-not (Sync-SharedTextFile (Join-Path $tmp 'here\none.txt') (Join-Path $tmp 'there\none.txt'))) 'a file neither has is left unwritten'

    # ---- where the shared folder is -----------------------------------------
    $root = Join-Path $tmp 'here'
    A ($null -eq (Get-LibraryLocation $root)) 'a fresh install shares with nobody'
    Set-LibraryLocation $root 'D:\Shared\Video Studio'
    A ((Get-LibraryLocation $root) -eq 'D:\Shared\Video Studio') 'the folder is remembered, spaces and all'
    Set-LibraryLocation $root '\\nas\media\studio'
    A ((Get-LibraryLocation $root) -eq '\\nas\media\studio') 'and can be changed to a network folder'

    # ---- end to end, through the script the button runs ---------------------
    $eRoot = Join-Path $tmp 'e2e\root'
    $eShare = Join-Path $tmp 'e2e\share'
    Put (Join-Path $eRoot 'broll\Food\mine.mov') 'MINE'
    Put (Join-Path $eRoot 'broll\clash.mov') 'LOCAL VERSION'
    Put (Join-Path $eRoot 'output\private.mp4') 'NOT YOURS'
    Put (Join-Path $eRoot 'projects\edit.json') '{}'
    Put (Join-Path $eShare 'broll\clash.mov') 'REMOTE VERSION'
    Put (Join-Path $eShare 'music\bed.mp3') 'MUSIC'
    Set-LibraryLocation $eRoot $eShare

    $script = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'Sync-Library.ps1'
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Root $eRoot 2>&1 | Out-String

    A (Test-Path (Join-Path $eRoot 'music\bed.mp3')) 'their music arrives here'
    A (Test-Path (Join-Path $eShare 'broll\Food\mine.mov')) 'my b-roll goes there, group and all'
    A (([System.IO.File]::ReadAllText((Join-Path $eRoot 'broll\clash.mov'))) -eq 'LOCAL VERSION') 'a clashing clip is NOT overwritten here'
    A (([System.IO.File]::ReadAllText((Join-Path $eShare 'broll\clash.mov'))) -eq 'REMOTE VERSION') 'nor theirs over there'
    A ($out -match 'LEFT ALONE') 'and the clash is reported rather than hidden'
    A (-not (Test-Path (Join-Path $eShare 'output'))) 'my videos are not uploaded to the shared folder'
    A (-not (Test-Path (Join-Path $eShare 'projects'))) 'and neither are my saved edits'

    # running it again is a no-op apart from the standing conflict
    $out2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Root $eRoot 2>&1 | Out-String
    A ($out2 -match 'Added 0 file\(s\)') 'a second sync has nothing left to fetch'
    A ($out2 -match 'sent 0') 'and nothing left to send'

    # Run with no -Root at all, the way the button runs it. This is the one that
    # matters: under [CmdletBinding()] a `$Root = $PSScriptRoot` parameter
    # default binds EMPTY, and the sync then looked at a bare 'broll' folder,
    # found nothing, and reported success. -WhatIf so the real library is only
    # read, never written.
    $dry = Join-Path $tmp 'e2e\dry'
    New-Item -ItemType Directory -Force -Path $dry | Out-Null
    $o5 = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Location $dry -WhatIf 2>&1 | Out-String
    A ($o5 -notmatch 'Cannot bind argument') 'with no -Root it still knows where it lives'
    # -like, not -match: the line is "broll\  -  ..." and a trailing backslash in
    # a regex is an escape with nothing after it.
    A ($o5 -like '*broll\  -*') 'and reports on the real b-roll folder'
    A ($o5 -match 'Nothing was copied') 'while a dry run copies nothing'
    A ((Get-ChildItem $dry -Recurse -File).Count -eq 0) 'and leaves the other side untouched'

    # nothing set up at all, and a folder that is not plugged in
    $bare = Join-Path $tmp 'e2e\bare'
    New-Item -ItemType Directory -Force -Path $bare | Out-Null
    $o3 = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Root $bare 2>&1 | Out-String
    A ($o3 -match 'No shared folder') 'with no folder chosen it explains itself'
    Set-LibraryLocation $bare 'Z:\not-plugged-in'
    $o4 = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Root $bare 2>&1 | Out-String
    A ($o4 -match "isn't reachable") 'and an unplugged stick says so instead of failing oddly'
    A ($o4 -match 'Nothing was changed') 'while promising it changed nothing'
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails -eq 0) { Write-Host "All SharedLibrary tests passed." } else { Write-Host "$fails test(s) FAILED."; exit 1 }
