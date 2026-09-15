# ProcessRunner.ps1 - the one safe way to run a child process from the Studio UI.
#
# Two traps this app has already fallen into. Both are fixed here, once, so no
# caller has to remember them again.
#
#  1. DEADLOCK. A redirected stdout/stderr pipe that is only read AFTER the
#     child exits wedges the child the moment the OS pipe buffer (a few KB)
#     fills up. ffmpeg writes to stderr continuously, so a long render simply
#     stops and never exits. Fixed by draining both pipes with ReadToEndAsync
#     the instant the process starts: the .NET thread pool empties them for us,
#     with no PowerShell callback involved and therefore no runspace-affinity
#     problem.
#
#  2. SCOPE. A DispatcherTimer kept in a FUNCTION-LOCAL variable is $null by the
#     time its Tick fires - a PowerShell event scriptblock does not close over
#     the locals of the function that created it. `$watch.Stop()` then throws
#     before the completion branch can report anything, which is exactly why the
#     editor's export sat at "Rendering... 0%" forever even though ffmpeg had
#     finished and written a perfectly good file. Watch-Process builds the timer
#     and hands its own scriptblock everything it needs through a state object
#     captured with GetNewClosure().

# Windows command-line quoting. Only args that need it get quoted; a trailing
# run of backslashes is doubled first, because "C:\dir\" would otherwise escape
# the closing quote and swallow the next argument.
function ConvertTo-CommandLineArg {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function ConvertTo-CommandLine {
    param([string[]]$ArgumentList)
    if (-not $ArgumentList) { return '' }
    return (($ArgumentList | ForEach-Object { ConvertTo-CommandLineArg ([string]$_) }) -join ' ')
}

# Starts $FilePath with $ArgumentList, hidden, with both output streams being
# drained continuously. Returns a tracker: pass it to Watch-Process and to
# Get-ProcessResult. Throws if the executable can't be started, so callers can
# report "ffmpeg isn't installed" instead of hanging on a process that never was.
function Start-TrackedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ConvertTo-CommandLine $ArgumentList
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $proc = [System.Diagnostics.Process]::Start($psi)
    return [pscustomobject]@{
        Process     = $proc
        OutTask     = $proc.StandardOutput.ReadToEndAsync()
        ErrTask     = $proc.StandardError.ReadToEndAsync()
        CommandLine = $psi.FileName + ' ' + $psi.Arguments
    }
}

# Everything the caller needs to judge the run. Safe to call only once the
# process has exited; the two awaits complete as soon as the pipes close.
function Get-ProcessResult {
    param([Parameter(Mandatory = $true)][object]$Tracked)
    $out = ''; $err = ''
    try { $out = $Tracked.OutTask.GetAwaiter().GetResult() } catch {}
    try { $err = $Tracked.ErrTask.GetAwaiter().GetResult() } catch {}
    $code = -1
    try { $code = $Tracked.Process.ExitCode } catch {}
    return [pscustomobject]@{
        ExitCode = $code
        StdOut   = [string]$out
        StdErr   = [string]$err
        Ok       = ($code -eq 0)
    }
}

# Every live watcher, keyed by its own timer object. This is how a tick finds
# its state without capturing anything: the Tick handler is handed the timer as
# its sender, and looks itself up in here.
#
# (.GetNewClosure() is NOT the answer, tempting as it looks: it re-binds
# $script: to a fresh dynamic module too, so a closure quietly writes to a
# DIFFERENT $script:foo than the rest of the file and can't see the script's own
# functions. Verified, not assumed.)
# Guarded: this file is dot-sourced by more than one caller, and re-running the
# assignment would throw away watchers that are mid-flight.
if (-not $script:ProcessWatchers) { $script:ProcessWatchers = @{} }

# Poll a running process from the UI thread without blocking it.
#   OnPoll  - called each tick while the process is alive, as: & $OnPoll $Tracked $Context
#   OnExit  - called once after it exits, as:                  & $OnExit $Result   $Context
#
# Pass anything the callbacks need through -Context. They CANNOT see the locals
# of the function that defined them - that is the whole reason this file exists.
function Watch-Process {
    param(
        [Parameter(Mandatory = $true)][object]$Tracked,
        [int]$IntervalMs = 300,
        [object]$Context,
        [scriptblock]$OnPoll,
        [scriptblock]$OnExit
    )
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds([Math]::Max(50, $IntervalMs))
    $script:ProcessWatchers[$timer] = [pscustomobject]@{
        Tracked = $Tracked; OnPoll = $OnPoll; OnExit = $OnExit; Context = $Context
    }

    $timer.Add_Tick({
        param($s, $e)
        $w = $script:ProcessWatchers[$s]
        if (-not $w) { $s.Stop(); return }          # already finished, or orphaned
        if (-not $w.Tracked.Process.HasExited) {
            if ($w.OnPoll) { try { & $w.OnPoll $w.Tracked $w.Context } catch {} }
            return
        }
        $s.Stop()
        $script:ProcessWatchers.Remove($s)
        $result = Get-ProcessResult $w.Tracked
        if ($w.OnExit) { & $w.OnExit $result $w.Context }
    })

    $timer.Start()
    return $timer
}

# Give up on a watched process: stops the timer and kills the child if it is
# still running. Used when a window closes while work is in flight.
function Stop-WatchedProcess {
    param([object]$Timer, [switch]$Kill)
    if (-not $Timer) { return }
    $w = $script:ProcessWatchers[$Timer]
    try { $Timer.Stop() } catch {}
    $script:ProcessWatchers.Remove($Timer)
    if ($Kill -and $w) {
        try { if (-not $w.Tracked.Process.HasExited) { $w.Tracked.Process.Kill() } } catch {}
    }
}
