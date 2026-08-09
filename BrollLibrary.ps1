# BrollLibrary.ps1
# The b-roll library: cutaway clips and photos you keep around and drop into
# edits. Lives in broll\ next to music\.
#
# Organising is just making folders in Explorer. The first folder under broll\
# becomes the group shown in the editor's media bin; files sitting loose in
# broll\ fall into a group called "B-roll". No tag file to keep in sync.

$script:BrollVideoExts = @('.mp4', '.mov', '.m4v', '.avi', '.mkv', '.webm')
$script:BrollImageExts = @('.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp')

function Get-BrollDir([string]$Root) {
    return (Join-Path $Root 'broll')
}

# The group a file belongs to: its first folder under broll\, Title Cased for
# display, or "B-roll" when it sits directly in broll\.
function Get-BrollGroup([string]$Root, [string]$FullPath) {
    $base = Get-BrollDir $Root
    $rel = $FullPath.Substring($base.Length).TrimStart('\', '/')
    $parts = $rel -split '[\\/]'
    if ($parts.Count -le 1) { return 'B-roll' }
    $name = $parts[0]
    if (-not $name) { return 'B-roll' }
    return ($name.Substring(0, 1).ToUpper() + $name.Substring(1))
}

# Every usable b-roll file, as objects shaped like the editor's other assets:
#   path  - forward-slashed and relative to Root, so it resolves through the
#           editor's studio.media virtual host
#   type  - 'video' or 'image'
#   name  - file name
#   group - which bin group it shows under
# Audio is deliberately skipped: background music belongs to step 4.
function Get-BrollAssets([string]$Root) {
    $dir = Get-BrollDir $Root
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    $files = @(Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)
    foreach ($f in $files) {
        $ext = $f.Extension.ToLower()
        $type = $null
        if ($script:BrollVideoExts -contains $ext) { $type = 'video' }
        elseif ($script:BrollImageExts -contains $ext) { $type = 'image' }
        if (-not $type) { continue }
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
        $out.Add([pscustomobject]@{
            path  = $rel
            type  = $type
            name  = $f.Name
            group = (Get-BrollGroup $Root $f.FullName)
            broll = $true
        })
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------- trims
# The in/out you set on a b-roll clip is worth keeping: you usually want the
# same three seconds of a shot every time you reach for it. Stored next to the
# library so it survives closing the app.

function Get-BrollTrimFile([string]$Root) {
    return (Join-Path $Root 'broll-trims.txt')
}

# path|in|out  ->  @{ path = @{ in = <double>; out = <double> } }
function Get-BrollTrims([string]$Root) {
    $map = @{}
    $file = Get-BrollTrimFile $Root
    if (-not (Test-Path -LiteralPath $file)) { return $map }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($line in (Get-Content -LiteralPath $file -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $p = $t -split '\|'
        if ($p.Count -lt 3) { continue }
        $a = 0.0; $b = 0.0
        if (-not [double]::TryParse($p[1], [System.Globalization.NumberStyles]::Float, $inv, [ref]$a)) { continue }
        if (-not [double]::TryParse($p[2], [System.Globalization.NumberStyles]::Float, $inv, [ref]$b)) { continue }
        if ($b -le $a) { continue }
        $map[$p[0].Trim()] = @{ in = $a; out = $b }
    }
    return $map
}

# Records (or with a null selection, forgets) one clip's trim.
function Set-BrollTrim([string]$Root, [string]$Path, $In, $Out) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $map = Get-BrollTrims $Root
    if ($null -eq $In -or $null -eq $Out -or [double]$Out -le [double]$In) { $map.Remove($Path) }
    else { $map[$Path] = @{ in = [double]$In; out = [double]$Out } }

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# B-ROLL TRIMS  -  the piece of each clip you reach for. Set these in the editor.')
    foreach ($k in ($map.Keys | Sort-Object)) {
        $lines.Add(("{0}|{1}|{2}" -f $k, $map[$k].in.ToString($inv), $map[$k].out.ToString($inv)))
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Get-BrollTrimFile $Root), (($lines -join "`r`n") + "`r`n"), $enc)
}

# ---------------------------------------------------------------- adding
# Copies files into the library, never overwriting: a name that is already taken
# gets " (2)", " (3)" and so on, so pasting the same shot twice can't silently
# replace the one you already trimmed. Returns how many landed.
function Add-BrollFiles([string]$Root, [string[]]$Paths, [string]$Group) {
    $dest = Get-BrollDir $Root
    if ($Group -and $Group -ne 'B-roll') {
        $safe = [string]$Group
        foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) { $safe = $safe.Replace([string]$ch, '') }
        if ($safe) { $dest = Join-Path $dest $safe }
    }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null

    $added = 0
    foreach ($src in @($Paths)) {
        if (-not $src -or -not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
        $ext = [System.IO.Path]::GetExtension($src).ToLower()
        if (-not (($script:BrollVideoExts -contains $ext) -or ($script:BrollImageExts -contains $ext))) { continue }
        $base = [System.IO.Path]::GetFileNameWithoutExtension($src)
        $name = "$base$ext"
        $n = 2
        while (Test-Path -LiteralPath (Join-Path $dest $name)) { $name = "$base ($n)$ext"; $n++ }
        try { Copy-Item -LiteralPath $src -Destination (Join-Path $dest $name) -Force; $added++ } catch {}
    }
    return $added
}
