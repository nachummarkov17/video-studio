# CaptionUndo.ps1 - undo/redo for the caption editor.
#
# What gets remembered is just the LIST OF CAPTION TEXTS: timings are never
# edited here, so a snapshot is a handful of short strings and taking one costs
# nothing.
#
# The interesting part is WHEN to take one. A snapshot per keystroke would make
# Ctrl+Z walk back letter by letter, which nobody wants. Instead there is a
# BASELINE - the text as of the last remembered state - and a snapshot is only
# taken at an edit boundary: you stop typing for a moment, you move to another
# caption, you press a colour, or you save. A burst of typing in one box is
# therefore one undo step.
#
# Pure: no UI, no timers. The editor decides when the boundaries are.

function New-TextHistory {
    param([int]$Limit = 80)
    return [pscustomobject]@{
        Past     = New-Object System.Collections.Generic.List[object]
        Future   = New-Object System.Collections.Generic.List[object]
        Baseline = @()
        Limit    = [Math]::Max(1, $Limit)
    }
}

function Test-TextsEqual {
    param([string[]]$A, [string[]]$B)
    if ($null -eq $A) { $A = @() }
    if ($null -eq $B) { $B = @() }
    if ($A.Count -ne $B.Count) { return $false }
    # -cne, not -ne: PowerShell's default comparison is case-INSENSITIVE, so
    # capitalising a word would not have counted as an edit at all.
    for ($i = 0; $i -lt $A.Count; $i++) { if ($A[$i] -cne $B[$i]) { return $false } }
    return $true
}

# Start again from this state: no undo, no redo. Called when a different clip is
# loaded - one clip's edits are not the next clip's history.
function Reset-TextHistory {
    param([Parameter(Mandatory = $true)][object]$History, [string[]]$Texts)
    $History.Past.Clear()
    $History.Future.Clear()
    $History.Baseline = @($Texts)
}

# Remember the baseline and adopt $Texts as the new one - but only if something
# actually changed. Returns $true when a step was recorded.
#
# Recording a step throws away the redo branch, which is what every editor does:
# once you type after undoing, the thing you undid is gone.
function Push-TextHistory {
    param([Parameter(Mandatory = $true)][object]$History, [string[]]$Texts)
    $now = @($Texts)
    if (Test-TextsEqual $History.Baseline $now) { return $false }
    $History.Past.Add(@($History.Baseline))
    while ($History.Past.Count -gt $History.Limit) { $History.Past.RemoveAt(0) }
    $History.Future.Clear()
    $History.Baseline = $now
    return $true
}

function Test-CanUndo { param([object]$History) return ($History -and $History.Past.Count -gt 0) }
function Test-CanRedo { param([object]$History) return ($History -and $History.Future.Count -gt 0) }

# Step back. $Current is the text as it stands right now, which may be ahead of
# the baseline if the user was mid-burst - it goes onto the redo pile so the
# step forward returns exactly what they had.
function Undo-TextHistory {
    param([Parameter(Mandatory = $true)][object]$History, [string[]]$Current)
    if (-not (Test-CanUndo $History)) { return $null }
    $now = @($Current)
    # An uncommitted burst is its own step: step back to the baseline and leave
    # the past alone, so the NEXT undo goes one further rather than skipping one.
    if (-not (Test-TextsEqual $History.Baseline $now)) {
        $History.Future.Insert(0, $now)
        return ,@($History.Baseline)
    }
    $History.Future.Insert(0, $now)
    $prev = @($History.Past[$History.Past.Count - 1])
    $History.Past.RemoveAt($History.Past.Count - 1)
    $History.Baseline = $prev
    return ,$prev
}

function Redo-TextHistory {
    param([Parameter(Mandatory = $true)][object]$History, [string[]]$Current)
    if (-not (Test-CanRedo $History)) { return $null }
    $History.Past.Add(@($Current))
    $next = @($History.Future[0])
    $History.Future.RemoveAt(0)
    $History.Baseline = $next
    return ,$next
}
