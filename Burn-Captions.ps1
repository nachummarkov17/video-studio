# Burn-Captions.ps1
# Burns the .srt captions directly ONTO the video (TikTok/Reels style on-screen
# text) - the words become part of the picture. Uses the .srt already made by
# Run-Captions.bat, so you can EDIT the .srt first and the fixes show up here.
#
# Reads:  output\<name>.mp4  +  output\<name>.srt
# Writes: output\captioned\<name>.mp4   (originals in output\ are left alone)

[CmdletBinding()]
param(
    [string]$Root      = $PSScriptRoot,
    [int]   $FontSize  = 12,          # bigger = larger on-screen text
    [string]$FontName  = "Arial",
    [int]   $Outline   = 2,           # black border thickness around letters
    [int]   $Shadow    = 1,
    [int]   $MarginV   = 70,          # distance from the bottom (higher = further up)
    [int]   $Alignment = 2,           # 2 = bottom-center, 5 = middle-center, 8 = top-center
    [int]   $MaxWords  = 5,           # most words shown on screen at once (breaks at commas/periods too)
    [string]$Style     = "highlight", # caption look: highlight | karaoke | plain
    [string]$HighlightColor = "teal", # accent: teal(brand) yellow gold green lime cyan orange pink red
    [int]   $Crf       = 18,          # video quality (lower = better/bigger; 18-23 sensible)
    [switch]$Force                    # re-burn even if captioned\<name>.mp4 already exists
)

if (-not $Root -or -not (Test-Path (Join-Path $Root "Srt-Chunk.ps1"))) {
    if ($PSCommandPath) { $Root = Split-Path -Parent $PSCommandPath }
}
$out  = Join-Path $Root "output"
$dest = Join-Path $out  "captioned"
$work = Join-Path $Root "work"
$log  = Join-Path $Root "cleaner.log"
New-Item -ItemType Directory -Force -Path $dest,$work | Out-Null

function Write-Log($m) {
    $line = ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m)
    Write-Host $line
    Add-Content -Path $log -Value $line -Encoding UTF8
}

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { Write-Log "ERROR: ffmpeg not on PATH"; exit 1 }

# Shared caption re-chunker (short, readable captions) + styled-caption builder.
. (Join-Path $Root "Srt-Chunk.ps1")
. (Join-Path $Root "VideoColor.ps1")   # keep the source's colour tags on the encode
. (Join-Path $Root "CaptionColors.ps1") # the emphasis palette you painted words with
. (Join-Path $Root "Caption-Style.ps1")
# Shared clip ordering - "Your videos" order, top to bottom.
. (Join-Path $Root "VideoOrder.ps1")

$vids = @(Get-OrderedVideos $Root $out '*.mp4')
if (-not $vids) { Write-Log "No videos in output to burn captions onto."; exit 0 }

$captionColors = Get-CaptionColors $Root
Write-Log ("=== Burning captions onto videos ($Style, $FontName ${FontSize}pt, align $Alignment) ===")
Write-Log ("Emphasis colours: " + (($captionColors | ForEach-Object { $_.Name + ' ' + $_.Marker + $_.Hex }) -join ', '))
$made = 0; $skipped = 0; $failed = 0
foreach ($v in $vids) {
    $name = $v.BaseName
    $srt  = Join-Path $out "$name.srt"
    $outFileBurn = Join-Path $dest ($v.Name)
    if (-not (Test-Path $srt)) { Write-Log "NO .srt for $($v.Name) - run Run-Captions.bat first. Skipping."; $skipped++; continue }
    if ((Test-Path $outFileBurn) -and -not $Force) { Write-Log "Already burned, skipping: captioned\$($v.Name) (tick 'Re-burn' to redo)"; $skipped++; continue }
    if ((Test-Path $outFileBurn) -and $Force) { Write-Log "Re-burning (overwriting): captioned\$($v.Name)" }

    # Re-chunk into short captions, then build a STYLED .ass (colours/emphasis) -
    # both dropped to simple ASCII names in work\, so we avoid Windows path-escaping
    # problems (drive colons, spaces) in the filter. Any word edits you made in the
    # .srt are preserved; this only changes line breaks + styling.
    $tmpSrt = Join-Path $work "_sub.srt"
    $tmpAss = Join-Path $work "_sub.ass"
    Split-SrtFile -InPath $srt -OutPath $tmpSrt -MaxWords $MaxWords
    # video dimensions so the caption PlayRes matches the frame's aspect ratio
    $vw = 0; $vh = 0
    $wh = (& ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 $v.FullName) | Select-Object -First 1
    if ($wh) { $p = $wh -split ','; if ($p.Count -ge 2) { [void][int]::TryParse($p[0], [ref]$vw); [void][int]::TryParse($p[1], [ref]$vh) } }
    # Phone clips are variable-frame-rate (VFR); burning captions onto VFR video
    # lets many players (and Instagram/YouTube) drift the video behind the audio,
    # so a caption looks late even though it's on the right frame. Force a constant
    # frame rate on the output = the fix. Target the source's average rate rounded
    # to a standard so motion cadence is preserved.
    $tfps = Get-TargetFps $v.FullName
    Convert-SrtToAss -InPath $tmpSrt -OutPath $tmpAss -FontSize $FontSize -FontName $FontName `
        -Outline $Outline -Shadow $Shadow -MarginV $MarginV -Alignment $Alignment `
        -Style $Style -HighlightColor $HighlightColor -Colors $captionColors -VideoW $vw -VideoH $vh
    Push-Location $work
    try {
        Write-Log "Burning: $($v.Name)  (constant ${tfps}fps)"
        # -color_* keeps HDR (HLG) phone footage looking like itself; without
        # them the burned copy plays back washed out and bright.
        $burnArgs = @('-y','-loglevel','error','-i',$v.FullName,'-vf','subtitles=_sub.ass',
                      '-vsync','cfr','-r',"$tfps",'-c:v','libx264','-profile:v','high',
                      '-preset','veryfast','-crf',"$Crf",'-pix_fmt','yuv420p',
                      '-movflags','+faststart','-c:a','copy')
        $burnArgs += (Get-ColorArgsForSource $v.FullName)
        $burnArgs += $outFileBurn
        & ffmpeg @burnArgs
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg burn failed" }
        Write-Log "BURNED: captioned\$($v.Name)"
        $made++
    }
    catch {
        Write-Log "BURN FAILED: $($v.Name) - $($_.Exception.Message)"
        if (Test-Path $outFileBurn) { Remove-Item $outFileBurn -Force -ErrorAction SilentlyContinue }
        $failed++
    }
    finally {
        Pop-Location
        Remove-Item $tmpSrt -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpAss -Force -ErrorAction SilentlyContinue
    }
}
Write-Log ("Burn-in complete. Made {0}, skipped {1}, failed {2}. On-screen-caption videos are in {3}" -f $made, $skipped, $failed, $dest)
