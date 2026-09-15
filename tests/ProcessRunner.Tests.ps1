# ProcessRunner.Tests.ps1 - proves the two failure modes that broke the editor's
# export are actually gone:
#   1. a child that floods stderr must NOT deadlock (it used to: the pipe was
#      only read after exit, so ffmpeg wedged once the OS buffer filled);
#   2. a completion timer must actually stop itself and report (it used to
#      throw on $watch.Stop() because event scriptblocks can't see function
#      locals, so "Rendering... 0%" never went away).
#
# Run:  powershell -STA -ExecutionPolicy Bypass -File tests\ProcessRunner.Tests.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
. "$PSScriptRoot\..\ProcessRunner.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

# ---- command-line quoting --------------------------------------------------
A ((ConvertTo-CommandLineArg 'plain') -eq 'plain') 'a plain arg is not quoted'
A ((ConvertTo-CommandLineArg 'has space') -eq '"has space"') 'a spaced arg is quoted'
A ((ConvertTo-CommandLineArg '') -eq '""') 'an empty arg becomes ""'
A ((ConvertTo-CommandLineArg 'C:\dir with space\') -eq '"C:\dir with space\\"') 'a trailing backslash is doubled so it cannot escape the closing quote'
A ((ConvertTo-CommandLine @('a', 'b c')) -eq 'a "b c"') 'the vector joins with spaces'
A ((ConvertTo-CommandLine @()) -eq '') 'an empty vector is an empty line'
# filtergraph-shaped argument: commas, colons, brackets and quotes must survive
$graph = "[0:v]overlay=x=0:y=0:enable='between(t,1,2)'[v]"
A ((ConvertTo-CommandLineArg $graph) -eq $graph) 'a filtergraph with no spaces passes through untouched'

# ---- no deadlock on a chatty child ----------------------------------------
# ~500 KB of stderr, far past any pipe buffer. Before the async drain this hung
# forever instead of finishing.
$noisy = '1..5000 | ForEach-Object { [Console]::Error.WriteLine("x" * 100) }; [Console]::Out.WriteLine("done"); exit 3'
$t = Start-TrackedProcess -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', $noisy)
$exited = $t.Process.WaitForExit(60000)
A $exited 'a child that floods stderr still exits (no pipe deadlock)'
$r = Get-ProcessResult $t
A ($r.ExitCode -eq 3) "the real exit code comes back (got $($r.ExitCode))"
A (-not $r.Ok) 'a non-zero exit is not Ok'
A ($r.StdOut.Trim() -eq 'done') 'stdout is captured'
A ($r.StdErr.Length -gt 400000) "all of stderr is captured (got $($r.StdErr.Length) chars)"

# ---- Watch-Process reports, and stops itself -------------------------------
$script:seen = $null
$script:ticks = 0
$t2 = Start-TrackedProcess -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Milliseconds 400; exit 0')
$timer = Watch-Process -Tracked $t2 -IntervalMs 100 `
    -Context ([pscustomobject]@{ Label = 'my-context' }) `
    -OnPoll { param($tracked, $ctx) $script:ticks++ } `
    -OnExit { param($result, $ctx) $script:seen = [pscustomobject]@{ Ok = $result.Ok; Label = $ctx.Label } }

$stop = New-Object System.Windows.Threading.DispatcherTimer
$stop.Interval = [TimeSpan]::FromMilliseconds(2500)
$stop.Add_Tick({ param($s, $e) $s.Stop(); [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })
$stop.Start()
[System.Windows.Threading.Dispatcher]::Run()

A ($null -ne $script:seen) 'OnExit fired'
A ($script:seen -and $script:seen.Ok) 'OnExit saw a successful result'
A ($script:seen -and $script:seen.Label -eq 'my-context') 'OnExit received its context (event blocks cannot see caller locals)'
A ($script:ticks -ge 1) "OnPoll ran while the process was alive (got $($script:ticks))"
A (-not $timer.IsEnabled) 'the watcher stopped itself once the process exited'
A ($script:ProcessWatchers.Count -eq 0) 'the watcher unregistered itself'

Write-Host ''
if ($fails -eq 0) { Write-Host "All ProcessRunner tests passed." } else { Write-Host "$fails test(s) FAILED."; exit 1 }
