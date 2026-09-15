# Sync-Library.ps1
# Brings this computer's b-roll and music into step with the shared folder, both
# directions. Run by the "Shared library" button; also runnable on its own.
#
# It ADDS, it does not replace. A clip either side is missing gets copied
# across; a clip that exists on both with different content is left exactly
# where it is and reported, because quietly overwriting somebody's media is not
# a trade worth making to save them a look.
#
# Nothing here touches output\ or projects\ - see SharedLibrary.ps1 for why.

[CmdletBinding()]
param(
    [string]$Root,                # whose b-roll and music; defaults to this folder
    [string]$Location,            # defaults to the folder in shared-library.txt
    [switch]$WhatIf               # report what would happen, copy nothing
)

# NOT `param([string]$Root = $PSScriptRoot)`. Measured: under [CmdletBinding()]
# a parameter default that reads $PSScriptRoot comes back EMPTY - the automatic
# variable isn't populated yet when an advanced script binds its parameters. The
# same line without [CmdletBinding()] works, which is what makes it so easy to
# miss. Left in the param block, every path below became a bare 'broll' and the
# sync cheerfully reported nothing to do.
#
# The other engine scripts here carry a fallback for the same reason (their
# comments blame a polluted $PSScriptRoot; this is the real cause).
if (-not $Root) { $Root = $PSScriptRoot }

# The code always comes from beside this script; $Root only says whose b-roll
# and music to sync. They are the same folder in the app, and deliberately not
# in the tests.
. (Join-Path $PSScriptRoot 'SharedLibrary.ps1')

function Say($m) { Write-Output $m }

if (-not $Location) { $Location = Get-LibraryLocation $Root }
if (-not $Location) {
    Say "No shared folder is set up yet."
    Say "Click 'Shared library' and choose a folder both computers can see -"
    Say "a shared OneDrive/Dropbox folder, a network folder, or a USB stick."
    exit 0
}
if (-not (Test-Path -LiteralPath $Location)) {
    Say "The shared folder isn't reachable right now:"
    Say "  $Location"
    Say "If it's a USB stick, plug it in. If it's OneDrive or Dropbox, make sure"
    Say "it has finished starting up, then try again. Nothing was changed."
    exit 1
}

Say "Shared library: $Location"
Say ""

$totalIn = 0; $totalOut = 0; $totalConflict = 0
foreach ($part in Get-SharedFolders) {
    $local = Join-Path $Root $part
    $remote = Join-Path $Location $part
    New-Item -ItemType Directory -Force -Path $local | Out-Null
    if (-not $WhatIf) { New-Item -ItemType Directory -Force -Path $remote | Out-Null }

    $plan = Get-SyncPlan (Get-FileInventory $local) (Get-FileInventory $remote)
    Say ("{0}\  -  {1} here, {2} to send, {3} to fetch" -f $part, $plan.Same.Count, $plan.Push.Count, $plan.Pull.Count)

    if ($WhatIf) {
        foreach ($f in $plan.Push) { Say "    would send:  $f" }
        foreach ($f in $plan.Pull) { Say "    would fetch: $f" }
    } else {
        if ($plan.Push.Count) { $totalOut += (Copy-PlannedFiles $local $remote $plan.Push) }
        if ($plan.Pull.Count) { $totalIn  += (Copy-PlannedFiles $remote $local $plan.Pull) }
        foreach ($f in $plan.Push) { Say "    sent:  $f" }
        foreach ($f in $plan.Pull) { Say "    added: $f" }
    }
    foreach ($f in $plan.Conflict) {
        Say "    LEFT ALONE (different on each computer): $part\$f"
        $totalConflict++
    }
}

Say ""
foreach ($file in Get-SharedFiles) {
    $local = Join-Path $Root $file
    $remote = Join-Path $Location $file
    if ($WhatIf) { Say "would merge: $file"; continue }
    if (Sync-SharedTextFile $local $remote) { Say "merged: $file" }
}

Say ""
if ($WhatIf) {
    Say "Nothing was copied (-WhatIf)."
} else {
    Say ("Shared library up to date. Added {0} file(s) from the shared folder, sent {1}." -f $totalIn, $totalOut)
    if ($totalConflict -gt 0) {
        Say ""
        Say "$totalConflict file(s) differ on the two computers and were left alone."
        Say "Rename one of them if you want both, then sync again."
    }
}
exit 0
