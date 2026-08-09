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
