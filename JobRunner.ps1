# JobRunner.ps1 - running one pipeline step at a time, and the chime that says
# it finished.
#
# Each step (captions, burn, music, finish) is a separate PowerShell script run
# as a hidden child process. Its stdout/stderr go to temp FILES which a 350 ms
# DispatcherTimer tails into the log panel - that timer lives at script scope,
# which is the only reason it can stop itself when the job ends.


# ---------------------------------------------------------------- finish sounds
# Each step plays its own short chime when it finishes, so you can tell by ear
# which one completed without watching the screen. They are synthesised as
# struck-bell tones (see Chime.ps1) and played asynchronously, so they never
# hold up the window.
#
# The motifs are written as real intervals rather than arbitrary pitches, and
# the notes OVERLAP - each is still ringing when the next lands, which is what
# makes a chord rather than a sequence of blips.
$script:Melodies = @{
    # captions: a rising major triad, open and unhurried
    captions = @((New-ChimeNote 'F4'  0.00 1.6), (New-ChimeNote 'A4'  0.11 1.6), (New-ChimeNote 'C5'  0.22 2.0))
    # burn: a fifth resolving up an octave - "that's set"
    burn     = @((New-ChimeNote 'C4'  0.00 1.7), (New-ChimeNote 'G4'  0.10 1.7), (New-ChimeNote 'C5'  0.20 2.1))
    # music: a gentle falling third, softer than the rest
    music    = @((New-ChimeNote 'A4'  0.00 1.5 0.85), (New-ChimeNote 'F4' 0.13 2.0 0.85))
    # export/finish: a full major chord with the root doubled low - the "done" one
    export   = @((New-ChimeNote 'F3'  0.00 2.2 0.7), (New-ChimeNote 'F4' 0.02 1.8),
                 (New-ChimeNote 'A4'  0.10 1.8), (New-ChimeNote 'C5' 0.19 2.2))
    # anything else: one clean bell
    generic  = @((New-ChimeNote 'A4'  0.00 1.6))
}
$script:SoundPlayers = @{}
function Play-DoneSound([string]$key) {
    if (-not $key -or -not $script:Melodies.ContainsKey($key)) { $key = 'generic' }
    try {
        if (-not $script:SoundPlayers.ContainsKey($key)) {
            $p = New-Object System.Media.SoundPlayer
            $p.Stream = (New-ChimeWav $script:Melodies[$key])
            $p.Load()
            $script:SoundPlayers[$key] = $p
        }
        $script:SoundPlayers[$key].Play()   # asynchronous
    } catch {}
}

# ---------------------------------------------------------------- job runner
$script:proc = $null; $script:outFile = $null; $script:errFile = $null
$script:outPos = 0; $script:errPos = 0; $script:onDone = $null; $script:jobTitle = ''; $script:jobSound = ''

$script:jobTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:jobTimer.Interval = [TimeSpan]::FromMilliseconds(350)

function Write-LogText([string]$t) { if (-not [string]::IsNullOrEmpty($t)) { $log.AppendText($t); $log.ScrollToEnd() } }
function Write-LogLine([string]$t) { Write-LogText ($t + "`r`n") }

function Read-New([string]$path, [ref]$pos) {
    if (-not (Test-Path $path)) { return '' }
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        [void]$fs.Seek($pos.Value, [System.IO.SeekOrigin]::Begin)
        $sr = New-Object System.IO.StreamReader($fs)
        $txt = $sr.ReadToEnd(); $pos.Value = $fs.Position
        $sr.Dispose(); $fs.Dispose(); return $txt
    } catch { return '' }
}
function Set-Busy([bool]$busy) {
    foreach ($b in $script:jobButtons) { $b.IsEnabled = -not $busy }
    $status.Text = if ($busy) { "Working... please wait (details on the right)" } else { "Ready" }
    $win.Cursor  = if ($busy) { [System.Windows.Input.Cursors]::Wait } else { [System.Windows.Input.Cursors]::Arrow }
}
# $s is the timer. Taking it from the sender rather than a captured variable is
# not fussiness: an event scriptblock cannot see the locals of whatever created
# it, and a Stop() that throws leaves a timer running for the life of the app.
$script:jobTimer.Add_Tick({
    param($s, $e)
    Write-LogText (Read-New $script:outFile ([ref]$script:outPos))
    Write-LogText (Read-New $script:errFile ([ref]$script:errPos))
    if ($script:proc -and $script:proc.HasExited) {
        $s.Stop()
        Write-LogText (Read-New $script:outFile ([ref]$script:outPos))
        Write-LogText (Read-New $script:errFile ([ref]$script:errPos))
        Write-LogLine ""; Write-LogLine "--- $($script:jobTitle): finished ---"; Write-LogLine ""
        $od = $script:onDone
        try { [System.IO.File]::Delete($script:outFile) } catch {}
        try { [System.IO.File]::Delete($script:errFile) } catch {}
        $script:proc = $null
        Set-Busy $false
        Play-DoneSound $script:jobSound
        Refresh-Videos
        if ($od) { & $od }
    }
})
function Start-Task([string]$title, [string]$scriptName, [string[]]$argList, [scriptblock]$onDone) {
    if ($script:proc) { return }
    $file = Join-Path $Root $scriptName
    if (-not (Test-Path $file)) { Write-LogLine "ERROR: missing $scriptName"; return }
    $script:jobTitle = $title; $script:onDone = $onDone
    $script:jobSound = switch -Wildcard ($scriptName) {
        'Make-Captions*' { 'captions'; break }
        'Burn-Captions*' { 'burn';     break }
        'Apply-Music*'   { 'music';    break }
        'Export-*'       { 'export';   break }
        default          { 'generic' }
    }
    Write-LogLine "=== $title ==="
    Set-Busy $true
    $script:outFile = [System.IO.Path]::GetTempFileName()
    $script:errFile = [System.IO.Path]::GetTempFileName()
    $script:outPos = 0; $script:errPos = 0
    $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $file) + $argList
    try {
        $script:proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -WindowStyle Hidden -PassThru `
                        -RedirectStandardOutput $script:outFile -RedirectStandardError $script:errFile
    } catch { Write-LogLine ("ERROR launching: " + $_.Exception.Message); Set-Busy $false; $script:proc = $null; return }
    $script:jobTimer.Start()
}
