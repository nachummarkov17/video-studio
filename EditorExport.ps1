# EditorExport.ps1 - rendering the editor timeline into "Your videos".
#
# What went wrong before, and what each piece here is for:
#
#  * The progress bar sat at 0 % forever even on a render that had FINISHED and
#    written a perfectly good file. The completion timer lived in a function
#    local, so its Tick couldn't see it, `$watch.Stop()` threw, and the line
#    that posts exportDone never ran. Watching is now Watch-Process's job.
#
#  * There was no progress to report anyway - one pct=0 was posted and that was
#    that. ffmpeg is now asked for `-progress`, and the watcher tails it.
#
#  * ffmpeg rendered STRAIGHT INTO output\, so the half-written file showed up
#    in "Your videos" while it was still being muxed. Opening it then is what
#    "the new one won't open, format unsupported or corrupted" was. We render to
#    work\export\ and move the finished file into place.
#
#  * "Did it work?" was answered by Test-Path, which is true the instant ffmpeg
#    creates the file. Success now means exit code 0 AND a file of real size.

. (Join-Path $PSScriptRoot 'EditorRender.ps1')
. (Join-Path $PSScriptRoot 'ProcessRunner.ps1')
. (Join-Path $PSScriptRoot 'VideoColor.ps1')

# PURE: the asset whose colour the render should be tagged with - the first clip
# on the main track, i.e. what the finished video mostly IS. A project can only
# carry one set of colour tags, so it inherits the one the picture starts with.
function Get-ColorReferencePath {
    param([Parameter(Mandatory = $true)][object]$Project)
    $byId = @{}
    foreach ($a in $Project.assets) { $byId[$a.id] = $a }
    foreach ($t in $Project.tracks) {
        if ($t.kind -ne 'main') { continue }
        foreach ($c in $t.clips) {
            $a = $byId[$c.assetId]
            if ($a -and $a.type -eq 'video' -and $a.path) { return [string]$a.path }
        }
    }
    return $null
}

# Where a render's files live. Pure - just path arithmetic.
function Get-ExportPaths {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $safe = Get-SafeProjectName $Name
    $workDir = Join-Path $Root 'work\export'
    return [pscustomobject]@{
        Name     = $safe
        Final    = Join-Path $Root ('output\' + $safe + '.mp4')
        Temp     = Join-Path $workDir ($safe + '.mp4')
        Progress = Join-Path $workDir ($safe + '.progress')
        Log      = Join-Path $Root 'work\export.log'
        WorkDir  = $workDir
    }
}

# ffmpeg's -progress stream is blocks of key=value lines. `out_time` is the one
# unambiguous field: out_time_ms has meant microseconds in several releases, so
# we read the formatted timestamp and only fall back to out_time_us.
#
# Returns seconds rendered so far, or $null when nothing is readable yet.
function Read-FfmpegProgressSeconds {
    param([Parameter(Mandatory = $true)][string]$ProgressPath)
    if (-not (Test-Path -LiteralPath $ProgressPath)) { return $null }
    $text = ''
    try {
        # share ReadWrite: ffmpeg still has it open for writing
        $fs = [System.IO.File]::Open($ProgressPath, [System.IO.FileMode]::Open,
                                     [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { $sr = New-Object System.IO.StreamReader($fs); $text = $sr.ReadToEnd(); $sr.Dispose() }
        finally { $fs.Dispose() }
    } catch { return $null }
    if (-not $text) { return $null }

    $last = $null
    foreach ($m in [regex]::Matches($text, '(?m)^out_time=(\d+):(\d\d):(\d\d(?:\.\d+)?)\s*$')) {
        $last = ([double]$m.Groups[1].Value * 3600) + ([double]$m.Groups[2].Value * 60) + [double]$m.Groups[3].Value
    }
    if ($null -ne $last) { return $last }

    foreach ($m in [regex]::Matches($text, '(?m)^out_time_us=(\d+)\s*$')) {
        $last = [double]$m.Groups[1].Value / 1000000.0
    }
    return $last
}

# 0-100. Held below 100 until the process actually exits, so the bar can't claim
# it's done while the file is still being muxed.
function Get-RenderPercent {
    param([double]$RenderedSeconds, [double]$TotalSeconds)
    if ($TotalSeconds -le 0) { return 0 }
    if ($RenderedSeconds -le 0) { return 0 }
    $pct = [int][Math]::Floor(($RenderedSeconds / $TotalSeconds) * 100)
    if ($pct -lt 0) { return 0 }
    if ($pct -gt 99) { return 99 }
    return $pct
}

# A render only counts if ffmpeg said so AND left a real file behind. Test-Path
# alone was true for a file ffmpeg had merely created and then abandoned.
function Test-RenderSucceeded {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MinBytes = 20000
    )
    if (-not $Result.Ok) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return ((Get-Item -LiteralPath $Path).Length -ge $MinBytes)
}

# The last few lines of ffmpeg's complaint, for a status message that says
# something useful instead of just "Export failed".
function Get-RenderErrorSummary {
    param([object]$Result, [int]$Lines = 3)
    $text = ''
    if ($Result) { $text = [string]$Result.StdErr }
    $useful = @($text -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -Last $Lines)
    if (-not $useful -or $useful.Count -eq 0) { return "ffmpeg exited with code $($Result.ExitCode)" }
    return ($useful -join ' / ')
}

# Starts the render. Returns @{ Timer; Paths; Duration }, or throws if ffmpeg
# can't be started at all.
#
# OnProgress is called as: & $OnProgress <percent> $Context
# OnDone     is called as: & $OnDone <pscustomobject Ok/Path/Name/Error> $Context
# Neither can see the caller's locals - pass what they need through $Context.
function Start-EditorRender {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Project,
        [Parameter(Mandatory = $true)][string]$Name,
        [object]$Context,
        [scriptblock]$OnProgress,
        [scriptblock]$OnDone
    )
    $paths = Get-ExportPaths $Root $Name
    New-Item -ItemType Directory -Force -Path $paths.WorkDir | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'output') | Out-Null
    foreach ($stale in @($paths.Temp, $paths.Progress)) {
        try { if (Test-Path -LiteralPath $stale) { [System.IO.File]::Delete($stale) } } catch {}
    }

    $resolved = Resolve-EditorAssetPaths $Project $Root
    $duration = Get-EditorTimelineDuration $resolved
    # Carry the source's colour tags through, or an HDR clip comes out looking
    # washed out despite the pixels being identical.
    $colorRef = Get-ColorReferencePath $resolved
    $colorTags = $null
    if ($colorRef) { $colorTags = Get-VideoColorTags $colorRef }
    $graph = Build-EditorFilterGraph $resolved $paths.Temp $colorTags

    # -nostats keeps stderr down to real problems; -progress gives us numbers we
    # can actually show. Both are global options, so they lead the vector.
    $ffArgs = @('-y', '-hide_banner', '-nostats', '-loglevel', 'warning',
                '-progress', $paths.Progress) + $graph

    $tracked = Start-TrackedProcess -FilePath 'ffmpeg' -ArgumentList $ffArgs

    $watchCtx = [pscustomobject]@{
        Paths = $paths; Duration = $duration; Caller = $Context
        OnProgress = $OnProgress; OnDone = $OnDone; LastPct = -1
    }

    $timer = Watch-Process -Tracked $tracked -IntervalMs 400 -Context $watchCtx -OnPoll {
        param($tracked, $ctx)
        $secs = Read-FfmpegProgressSeconds $ctx.Paths.Progress
        if ($null -eq $secs) { return }
        $pct = Get-RenderPercent $secs $ctx.Duration
        if ($pct -eq $ctx.LastPct) { return }
        $ctx.LastPct = $pct
        if ($ctx.OnProgress) { & $ctx.OnProgress $pct $ctx.Caller }
    } -OnExit {
        param($result, $ctx)
        $done = Complete-EditorRender $result $ctx.Paths
        if ($ctx.OnDone) { & $ctx.OnDone $done $ctx.Caller }
    }

    return [pscustomobject]@{ Timer = $timer; Paths = $paths; Duration = $duration }
}

# Validate, publish, tidy up. Split out so it can be tested without ffmpeg.
function Complete-EditorRender {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][object]$Paths
    )
    $log = "=== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $($Paths.Name) ===`r`n"
    if ($Result.StdErr) { $log += $Result.StdErr }
    $log += "`r`nffmpeg exit code: $($Result.ExitCode)`r`n"
    try { Add-Content -LiteralPath $Paths.Log -Value $log -Encoding UTF8 } catch {}

    $ok = Test-RenderSucceeded $Result $Paths.Temp
    if ($ok) {
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Paths.Final) | Out-Null
            Move-Item -LiteralPath $Paths.Temp -Destination $Paths.Final -Force
        } catch {
            $ok = $false
            return [pscustomobject]@{ Ok = $false; Path = $Paths.Final; Name = $Paths.Name
                                      Error = "Couldn't put the finished file in output: $($_.Exception.Message)" }
        }
    } else {
        try { if (Test-Path -LiteralPath $Paths.Temp) { [System.IO.File]::Delete($Paths.Temp) } } catch {}
    }
    try { if (Test-Path -LiteralPath $Paths.Progress) { [System.IO.File]::Delete($Paths.Progress) } } catch {}

    if ($ok) {
        return [pscustomobject]@{ Ok = $true; Path = $Paths.Final; Name = $Paths.Name; Error = $null }
    }
    return [pscustomobject]@{ Ok = $false; Path = $Paths.Final; Name = $Paths.Name
                              Error = (Get-RenderErrorSummary $Result) }
}

# The name to offer in the export prompt: the project's own name once it has
# been saved, otherwise the first main-track clip's name WITH " edit" on the
# end.
#
# The suffix is not cosmetic. Offering the source clip's own name invited
# exporting straight over the footage the edit was cut from - which is exactly
# what happened, and it destroyed the original.
function Get-SuggestedExportName {
    param([Parameter(Mandatory = $true)][object]$Project)
    $name = ''
    try { $name = [string]$Project.name } catch {}
    if ($name -and $name -ne 'Untitled') { return $name }

    try {
        $assetsById = @{}
        foreach ($a in $Project.assets) { $assetsById[$a.id] = $a }
        foreach ($t in $Project.tracks) {
            if ($t.kind -ne 'main') { continue }
            foreach ($c in $t.clips) {
                $a = $assetsById[$c.assetId]
                if ($a -and $a.path) {
                    return ([System.IO.Path]::GetFileNameWithoutExtension(($a.path -replace '/', '\')) + ' edit')
                }
            }
        }
    } catch {}
    return 'Untitled'
}

# Would this export write over one of the clips it is made FROM?
#
# There is no version of that which is what anyone wanted: the render reads the
# source and would then replace it, so the footage is gone and the edit can
# never be opened again. Overwriting anything ELSE is a fair question to ask the
# user; this one is just refused.
function Test-ExportOverwritesSource {
    param(
        [Parameter(Mandatory = $true)][object]$Project,
        [Parameter(Mandatory = $true)][string]$FinalPath,
        [string]$Root
    )
    $target = $FinalPath
    try { $target = [System.IO.Path]::GetFullPath($FinalPath) } catch {}
    foreach ($a in $Project.assets) {
        if (-not $a.path) { continue }
        $p = [string]$a.path -replace '/', '\'
        if ($Root -and -not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $Root $p }
        try { $p = [System.IO.Path]::GetFullPath($p) } catch {}
        if ($p -and $p.Equals($target, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
