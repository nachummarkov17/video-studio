# SharedLibrary.ps1 - keeping a b-roll library (and your music) in step across
# two computers.
#
# WHAT IS SHARED, AND WHAT DELIBERATELY IS NOT
#
#   broll\              shared - the whole tree, so your groups come across.
#                       That includes the pictures you pop up over the video:
#                       they live in the same library as the clips.
#   music\              shared
#   broll-trims.txt     shared - the piece of each clip you reach for
#   caption-colors.txt  shared - so both of you burn the same colours
#
#   output\             NOT shared. That is each person's working footage:
#                       gigabytes, and personal to whoever is cutting.
#   projects\           NOT shared. A saved edit points at clips in output\,
#                       so it would open to a row of missing files.
#   work\, settings     NOT shared. Caches and per-machine choices.
#
# HOW IT MERGES. Additive, both directions: a file that exists on one side and
# not the other is copied across. A file that exists on BOTH with different
# content is left completely alone and reported - overwriting somebody's media
# because a clock said it was newer is not a trade this should ever make. In a
# library you add to, that case is rare and worth a human look when it happens.
#
# The "shared folder" is any path both machines can see: a OneDrive or Dropbox
# folder, a network share, or a USB stick. This file does not care which - the
# syncing service (or the stick) moves the bytes, and this decides what belongs
# where.

. (Join-Path $PSScriptRoot 'CaptionColors.ps1')

$script:LibraryLocationFile = 'shared-library.txt'

# Folder trees copied wholesale, and small text files merged line by line.
function Get-SharedFolders { return @('broll', 'music') }
function Get-SharedFiles   { return @('broll-trims.txt', 'caption-colors.txt') }

function Get-LibraryLocation {
    param([Parameter(Mandatory = $true)][string]$Root)
    $path = Join-Path $Root $script:LibraryLocationFile
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
        '# Any path both machines can see: a shared OneDrive/Dropbox folder, a',
        '# network share, or a USB stick. One line.',
        $Location.Trim()
    ) -join "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $Root $script:LibraryLocationFile), $text + "`r`n",
                                   (New-Object System.Text.UTF8Encoding($false)))
}

# ---- comparing two folder trees ---------------------------------------------

# relative path -> size + last write. Relative paths are the identity: the same
# clip in the same group is the same file, wherever the library lives.
function Get-FileInventory {
    param([Parameter(Mandatory = $true)][string]$Dir)
    $inv = @{}
    if (-not (Test-Path -LiteralPath $Dir)) { return $inv }
    $base = (Resolve-Path -LiteralPath $Dir).Path.TrimEnd('\')
    foreach ($f in @(Get-ChildItem -LiteralPath $base -File -Recurse -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($base.Length).TrimStart('\')
        $inv[$rel] = [pscustomobject]@{ Size = $f.Length; Modified = $f.LastWriteTimeUtc }
    }
    return $inv
}

# PURE: given both inventories, what should happen.
#   Push     - here but not there
#   Pull     - there but not here
#   Same     - identical on both sides, nothing to do
#   Conflict - same name, different content: left alone, reported
function Get-SyncPlan {
    param([hashtable]$Local, [hashtable]$Remote)
    if (-not $Local) { $Local = @{} }
    if (-not $Remote) { $Remote = @{} }
    $push = @(); $pull = @(); $same = @(); $conflict = @()

    foreach ($rel in $Local.Keys) {
        if (-not $Remote.ContainsKey($rel)) { $push += $rel; continue }
        $a = $Local[$rel]; $b = $Remote[$rel]
        # A copied file keeps its size but not always its timestamp to the tick,
        # so size plus a couple of seconds of slack is the honest test for "this
        # is the same file", and avoids copying the whole library every sync.
        if ($a.Size -eq $b.Size -and [Math]::Abs(($a.Modified - $b.Modified).TotalSeconds) -le 2) { $same += $rel }
        else { $conflict += $rel }
    }
    foreach ($rel in $Remote.Keys) {
        if (-not $Local.ContainsKey($rel)) { $pull += $rel }
    }
    return [pscustomobject]@{
        Push = @($push | Sort-Object); Pull = @($pull | Sort-Object)
        Same = @($same | Sort-Object); Conflict = @($conflict | Sort-Object)
    }
}

function Copy-PlannedFiles {
    param([string]$FromDir, [string]$ToDir, [string[]]$Relative)
    $copied = 0
    foreach ($rel in $Relative) {
        $src = Join-Path $FromDir $rel
        $dst = Join-Path $ToDir $rel
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst -Force
            $copied++
        } catch {}
    }
    return $copied
}

# ---- merging the small text files -------------------------------------------

# PURE. Lines look like "key|value|value". Union by key; when both sides have a
# key, THIS machine's line wins - a merge should never quietly change settings
# under the person who is running it. Comments from the local file are kept.
function Merge-KeyedLines {
    param(
        [AllowEmptyString()][string]$LocalText,
        [AllowEmptyString()][string]$RemoteText,
        [int]$KeyIndex = 0
    )
    $comments = @()
    $order = New-Object System.Collections.Generic.List[string]
    $byKey = @{}

    # Local first, so its lines claim their keys before the remote's are seen.
    # Written as two plain passes rather than a shared scriptblock: a
    # scriptblock would need $script: state to accumulate, and this codebase has
    # been bitten enough times by PowerShell scope to not go looking for it.
    foreach ($pass in @(@{ Text = $LocalText; Local = $true }, @{ Text = $RemoteText; Local = $false })) {
        foreach ($line in ($pass.Text -split "`r?`n")) {
            $t = $line.Trim()
            if ($t -eq '') { continue }
            if ($t.StartsWith('#')) { if ($pass.Local) { $comments += $t }; continue }
            $parts = $t -split '\|'
            # A key on its own is not a record in any of these files - they all
            # read "key|value|...". Dropping a half-line here keeps a
            # hand-edited file from propagating its typo to the other computer.
            if ($parts.Count -lt ($KeyIndex + 2)) { continue }
            $key = $parts[$KeyIndex].Trim()
            if ($key -eq '') { continue }
            if ($byKey.ContainsKey($key)) { continue }     # first claim wins, and local goes first
            $byKey[$key] = $t
            [void]$order.Add($key)
        }
    }

    $out = @($comments) + @($order | ForEach-Object { $byKey[$_] })
    return (($out -join "`r`n") + "`r`n")
}

# The palette has its own rules, so it merges through its own parser rather than
# as raw lines.
#
# A colour arriving from the other computer KEEPS ITS OWN MARKER. That is the
# whole point: a caption written over there says ~seed oils~, and if this
# machine filed that colour under a different character the words would come out
# painted the wrong colour. So a remote colour is taken only when its marker is
# still free here; when the two of you have claimed the same character for
# different colours, this machine's meaning stands and the remote one is
# dropped, because changing it would silently repaint captions already written.
#
# The '*' colour is never taken from the remote side either - every .srt ever
# written leans on it.
function Merge-CaptionColorFiles {
    param([AllowEmptyString()][string]$LocalText, [AllowEmptyString()][string]$RemoteText)
    # Assigned, never wrapped in @(): ConvertFrom-CaptionColorText returns with
    # `,$out` so it always arrives as an array, and @() around that nests it one
    # deeper - which is exactly how this first "merged" nothing at all.
    $merged = ConvertFrom-CaptionColorText $LocalText
    $incoming = ConvertFrom-CaptionColorText $RemoteText
    $pool = Get-CaptionMarkerPool
    foreach ($c in $incoming) {
        if ($c.Marker -eq '*') { continue }
        if ($pool -notcontains $c.Marker) { continue }
        if (@($merged | Where-Object { $_.Marker -eq $c.Marker })) { continue }
        if (@($merged | Where-Object { $_.Name -eq $c.Name })) { continue }   # same colour, other marker
        $merged += [pscustomobject]@{ Name = $c.Name; Marker = $c.Marker; Hex = $c.Hex }
    }
    return (ConvertTo-CaptionColorText $merged)
}

function Sync-SharedTextFile {
    param([string]$LocalPath, [string]$RemotePath)
    $localText = if (Test-Path -LiteralPath $LocalPath) { [System.IO.File]::ReadAllText($LocalPath) } else { '' }
    $remoteText = if (Test-Path -LiteralPath $RemotePath) { [System.IO.File]::ReadAllText($RemotePath) } else { '' }
    if (-not $localText -and -not $remoteText) { return $false }

    $merged = if ((Split-Path -Leaf $LocalPath) -eq 'caption-colors.txt') {
        Merge-CaptionColorFiles $localText $remoteText
    } else {
        Merge-KeyedLines $localText $remoteText 0
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    foreach ($p in @($LocalPath, $RemotePath)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
        [System.IO.File]::WriteAllText($p, $merged, $enc)
    }
    return $true
}
