# ContentKey.ps1 - stable cache keys for derived files.
#
# Anything the app generates FROM a source clip (filmstrips, preview proxies)
# is stored under a key derived from that clip's identity and its content
# stamp, so an edited clip regenerates and an untouched one never does.

function Get-StringHashHex {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $md5.Dispose() }
}

# "This exact file, in this exact state." Missing files still produce a key so
# callers get a deterministic answer instead of $null; the stamp is simply
# empty, and the key changes as soon as the file appears.
function Get-FileContentStamp {
    param([Parameter(Mandatory = $true)][string]$FullPath)
    if (-not (Test-Path -LiteralPath $FullPath)) { return '' }
    $item = Get-Item -LiteralPath $FullPath
    return ('{0}:{1}' -f $item.LastWriteTimeUtc.Ticks, $item.Length)
}
