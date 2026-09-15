# CaptionUndo.Tests.ps1 - undo/redo over caption text.
#
# Run:  powershell -ExecutionPolicy Bypass -File tests\CaptionUndo.Tests.ps1

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\CaptionUndo.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }
function Same($a, $b) { return (Test-TextsEqual @($a) @($b)) }

$start = @('one', 'two', 'three')

# ---- nothing to undo on a fresh clip ---------------------------------------
$h = New-TextHistory
Reset-TextHistory $h $start
A (-not (Test-CanUndo $h)) 'a freshly opened clip has nothing to undo'
A (-not (Test-CanRedo $h)) 'and nothing to redo'
A ($null -eq (Undo-TextHistory $h $start)) 'undoing nothing returns nothing'

# ---- one edit, one step ----------------------------------------------------
$edited = @('ONE', 'two', 'three')
A (Push-TextHistory $h $edited) 'an edit is recorded'
A (Test-CanUndo $h) 'and can be undone'
A (Same (Undo-TextHistory $h $edited) $start) 'undo gives back exactly what was there'
A (Test-CanRedo $h) 'and the edit is now redoable'
A (Same (Redo-TextHistory $h $start) $edited) 'redo puts it back'

# ---- a burst of typing is ONE step, not one per keystroke ------------------
$h2 = New-TextHistory
Reset-TextHistory $h2 $start
A (-not (Push-TextHistory $h2 $start)) 'nothing changed, nothing recorded'
# the editor only calls Push at an edit boundary, so the intermediate states of
# a burst never reach here at all
$typed = @('one two three', 'two', 'three')
Push-TextHistory $h2 $typed | Out-Null
A ($h2.Past.Count -eq 1) 'a whole burst is a single undo step'

# ---- undo mid-burst: what is on screen is not lost -------------------------
$h3 = New-TextHistory
Reset-TextHistory $h3 $start
Push-TextHistory $h3 @('A', 'two', 'three') | Out-Null      # committed step
$midBurst = @('A', 'BB', 'three')                            # typed, not yet committed
$back = Undo-TextHistory $h3 $midBurst
A (Same $back @('A', 'two', 'three')) 'undo mid-burst steps back to the last committed state'
A (Same (Redo-TextHistory $h3 $back) $midBurst) 'and redo returns the uncommitted typing, not a stale copy'

# ---- a new edit after undoing drops the redo branch ------------------------
$h4 = New-TextHistory
Reset-TextHistory $h4 $start
Push-TextHistory $h4 @('A', 'two', 'three') | Out-Null
$u = Undo-TextHistory $h4 @('A', 'two', 'three')
A (Test-CanRedo $h4) 'redo is available right after an undo'
Push-TextHistory $h4 @('B', 'two', 'three') | Out-Null
A (-not (Test-CanRedo $h4)) 'typing after an undo throws the redo branch away'

# ---- several steps, walked all the way back and forward --------------------
$h5 = New-TextHistory
Reset-TextHistory $h5 $start
# @(,$start), not @($start): the latter FLATTENS the three strings into the
# outer list instead of keeping them as one snapshot.
$states = @(); $states += ,$start
foreach ($w in @('a', 'b', 'c', 'd')) {
    $next = @($w, 'two', 'three')
    Push-TextHistory $h5 $next | Out-Null
    $states += ,$next
}
$cur = $states[-1]
for ($i = $states.Count - 2; $i -ge 0; $i--) {
    $cur = Undo-TextHistory $h5 $cur
    if (-not (Same $cur $states[$i])) { A $false "undo step $i"; break }
}
A (Same $cur $start) 'undoing every step lands back at the original'
A (-not (Test-CanUndo $h5)) 'and then stops'
for ($i = 1; $i -lt $states.Count; $i++) { $cur = Redo-TextHistory $h5 $cur }
A (Same $cur $states[-1]) 'redoing every step lands back at the latest'
A (-not (Test-CanRedo $h5)) 'and then stops'

# ---- the stack is bounded --------------------------------------------------
$h6 = New-TextHistory 5
Reset-TextHistory $h6 $start
for ($i = 1; $i -le 20; $i++) { Push-TextHistory $h6 @("v$i", 'two', 'three') | Out-Null }
A ($h6.Past.Count -eq 5) "history is capped at its limit (got $($h6.Past.Count))"

# ---- switching clip clears everything --------------------------------------
Reset-TextHistory $h6 @('other')
A (-not (Test-CanUndo $h6)) 'loading another clip clears the undo history'
A (-not (Test-CanRedo $h6)) 'and the redo history'

# ---- comparison edge cases -------------------------------------------------
A (Test-TextsEqual @() @()) 'two empty lists are equal'
A (-not (Test-TextsEqual @('a') @('a', 'b'))) 'different lengths are not equal'
A (-not (Test-TextsEqual @('a') @('A'))) 'comparison is case-sensitive - captions are text'
A (Test-TextsEqual $null $null) 'nulls do not blow up'

Write-Host ''
if ($fails -eq 0) { Write-Host "All CaptionUndo tests passed." } else { Write-Host "$fails test(s) FAILED."; exit 1 }
