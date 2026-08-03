# StudioSettings.ps1
# Small key=value store for choices the studio should remember between launches
# (currently: where burned captions sit on the frame), plus the mapping from a
# friendly caption position to the subtitle alignment/margin we burn with.
#
# File: studio-settings.txt in the app folder. Plain text on purpose - you can
# open it and see exactly what the app remembered.

function Get-StudioSettingsPath([string]$Root) {
    return (Join-Path $Root 'studio-settings.txt')
}

function Read-StudioSettings([string]$Root) {
    $map = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $path = Get-StudioSettingsPath $Root
    if (-not (Test-Path -LiteralPath $path)) { return $map }
    foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        # only the FIRST '=' separates key from value, so a value may contain one
        $map[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
    }
    return $map
}

function Get-StudioSetting([string]$Root, [string]$Key, [string]$Default = '') {
    $map = Read-StudioSettings $Root
    if ($map.ContainsKey($Key)) { return $map[$Key] }
    return $Default
}

function Set-StudioSetting([string]$Root, [string]$Key, [string]$Value) {
    $map = Read-StudioSettings $Root
    $map[$Key] = $Value
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# VIDEO STUDIO SETTINGS  -  choices the app remembers for you.')
    foreach ($k in ($map.Keys | Sort-Object)) { $lines.Add("$k=$($map[$k])") }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Get-StudioSettingsPath $Root), (($lines -join "`r`n") + "`r`n"), $enc)
}

# Where the burned captions sit. Alignment is the ASS numpad convention:
#   2 = bottom-centre, 5 = middle-centre, 8 = top-centre.
# MarginV is the distance from that edge; libass ignores it for middle-centre,
# which is exactly what we want - Middle means the true centre of the frame
# (chest height on a portrait clip), not "a bit above the bottom".
function Get-CaptionPlacement([string]$Position) {
    $p = ''
    if ($Position) { $p = $Position.Trim().ToLower() }
    switch ($p) {
        'bottom' { return @{ Alignment = 2; MarginV = 70 } }
        'top'    { return @{ Alignment = 8; MarginV = 40 } }
        default  { return @{ Alignment = 5; MarginV = 0 } }   # Middle
    }
}
