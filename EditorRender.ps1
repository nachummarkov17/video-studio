# EditorRender.ps1 - PURE function: project JSON (hashtable) -> ffmpeg argument vector.
# Build-EditorFilterGraph does NOT run ffmpeg; it only builds and returns the arg array.
# Dot-source this file to get Build-EditorFilterGraph in scope.

. (Join-Path $PSScriptRoot 'VideoColor.ps1')   # Get-ColorOutputArgs / Get-SetParamsFilter

# Get-SafeProjectName - sanitizes a project name into a safe filename stem.
# Replaces filesystem-hostile characters with '_'; falls back to 'Untitled'
# for null/empty/whitespace-only names.
function Get-SafeProjectName {
  param([string]$name)
  if ([string]::IsNullOrWhiteSpace($name)) { return 'Untitled' }
  return ($name -replace '[\\/:*?"<>|]', '_')
}

# Resolve-EditorAssetPaths - rewrites every asset's root-relative path (as sent
# by the editor UI, forward-slashed, e.g. "output/clip.mp4") to an absolute
# filesystem path under $root so ffmpeg can open it. Already-absolute paths
# pass through unchanged. Mutates the assets in place (reference types) and
# returns $project for convenient chaining.
function Resolve-EditorAssetPaths {
  param(
    [Parameter(Mandatory=$true)] [object]$project,
    [Parameter(Mandatory=$true)] [string]$root
  )
  foreach ($a in $project.assets) {
    if ($a.path -and -not [System.IO.Path]::IsPathRooted($a.path)) {
      $a.path = Join-Path $root ($a.path -replace '/', '\')
    }
  }
  return $project
}

# Save-EditorProject - sanitizes $name via Get-SafeProjectName, ensures
# projects\ exists under $root, and writes the project as UTF-8 (no BOM)
# JSON to projects\<safeName>.json. Returns the full path written.
function Save-EditorProject {
  param(
    [Parameter(Mandatory=$true)] [string]$name,
    [Parameter(Mandatory=$true)] [object]$project,
    [Parameter(Mandatory=$true)] [string]$root
  )
  $safeName = Get-SafeProjectName $name
  $projectsDir = Join-Path $root 'projects'
  New-Item -ItemType Directory -Force -Path $projectsDir | Out-Null
  $path = Join-Path $projectsDir ($safeName + '.json')
  $json = $project | ConvertTo-Json -Depth 25
  [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
  return $path
}

# Get-EditorProjectNames - basenames (no extension) of projects\*.json under
# $root, sorted. Returns an empty array if projects\ doesn't exist.
function Get-EditorProjectNames {
  param([Parameter(Mandatory=$true)] [string]$root)
  $projectsDir = Join-Path $root 'projects'
  if (-not (Test-Path $projectsDir)) { return @() }
  $names = @(Get-ChildItem -Path $projectsDir -Filter '*.json' -File | ForEach-Object { $_.BaseName })
  return @($names | Sort-Object)
}

# Read-EditorProject - reads projects\<safeName>.json under $root and returns
# the parsed object, or $null if the file doesn't exist.
function Read-EditorProject {
  param(
    [Parameter(Mandatory=$true)] [string]$name,
    [Parameter(Mandatory=$true)] [string]$root
  )
  $safeName = Get-SafeProjectName $name
  $path = Join-Path (Join-Path $root 'projects') ($safeName + '.json')
  if (-not (Test-Path $path)) { return $null }
  return (Get-Content -Path $path -Raw -Encoding UTF8) | ConvertFrom-Json
}

# How long the finished video will be: the furthest clip end across every track.
# Shared with the export watcher, which needs it to turn ffmpeg's "seconds
# rendered so far" into a percentage.
function Get-EditorTimelineDuration {
  param([Parameter(Mandatory=$true)] [object]$project)
  $total = 0
  foreach ($t in $project.tracks) {
    foreach ($c in $t.clips) {
      $end = $c.start + $c.duration
      if ($end -gt $total) { $total = $end }
    }
  }
  return $total
}

# $colorTags is what the source says it is (see VideoColor.ps1: Range, Space,
# Primaries, Transfer). Passed in rather than probed here so this stays pure.
#
# It has to be applied TWICE, which is not belt-and-braces but a real ffmpeg
# behaviour: a filtergraph only carries `range` and `colorspace` through to its
# output, and DROPS primaries and transfer. ffmpeg then takes the encoder's
# values from the filter output, so the -color_* flags alone are silently
# ignored on any graph. Verified: a plain transcode keeps all four; the same
# encode behind a filtergraph keeps two. So the tags are also stamped back onto
# the frames with `setparams` at the end of the chain.
function Build-EditorFilterGraph {
  param(
    [Parameter(Mandatory=$true)] [object]$project,
    [Parameter(Mandatory=$true)] [string]$outPath,
    [object]$colorTags = $null
  )

  $W   = $project.canvas.width
  $H   = $project.canvas.height
  $fps = $project.canvas.fps

  # asset lookup by id
  $assetsById = @{}
  foreach ($a in $project.assets) { $assetsById[$a.id] = $a }

  # Gather clips in deterministic, fixed order: main track clips, then overlay
  # track clips (tracks array order = bottom-to-top layer order), then audio
  # track clips. Each clip is its own "asset-instance" -> its own -i input.
  $mainClips    = @()
  $overlayClips = @()
  $audioClips   = @()

  foreach ($t in $project.tracks) {
    if ($t.kind -eq 'main') {
      foreach ($c in $t.clips) { $mainClips += $c }
    } elseif ($t.kind -eq 'overlay') {
      foreach ($c in $t.clips) { $overlayClips += $c }
    } elseif ($t.kind -eq 'audio') {
      foreach ($c in $t.clips) { $audioClips += $c }
    }
  }

  $totalDur = Get-EditorTimelineDuration $project
  if ($totalDur -le 0) { $totalDur = 1 }

  $ffArgs = @()
  $inputIndex = 0

  # Input 0: base canvas (color source), sized + timed to the whole timeline.
  $ffArgs += '-f','lavfi','-i',"color=c=black:s=${W}x${H}:d=${totalDur}:r=${fps}"
  $baseIdx = $inputIndex; $inputIndex++

  $mainInputIdx = @()
  foreach ($c in $mainClips) {
    $asset = $assetsById[$c.assetId]
    $ffArgs += '-i', $asset.path
    $mainInputIdx += $inputIndex
    $inputIndex++
  }

  $overlayInputIdx = @()
  foreach ($c in $overlayClips) {
    $asset = $assetsById[$c.assetId]
    $ffArgs += '-i', $asset.path
    $overlayInputIdx += $inputIndex
    $inputIndex++
  }

  $audioInputIdx = @()
  foreach ($c in $audioClips) {
    $asset = $assetsById[$c.assetId]
    $ffArgs += '-i', $asset.path
    $audioInputIdx += $inputIndex
    $inputIndex++
  }

  $filters = @()

  # ---- Main track: trim + cover-scale each clip, concat to fill the timeline ----
  $mainLabels = @()
  for ($i = 0; $i -lt $mainClips.Count; $i++) {
    $c   = $mainClips[$i]
    $idx = $mainInputIdx[$i]
    $lbl = "m$i"
    $filters += "[${idx}:v]trim=start=$($c.in):duration=$($c.duration),setpts=PTS-STARTPTS,scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H}[$lbl]"
    $mainLabels += $lbl
  }

  # Pass the base canvas through a named filter so $currentStage is always a
  # DECLARED filtergraph output label (never a bare "N:v" input ref) - this is
  # what lets the final video map stay valid even when there are no main or
  # overlay clips at all (audio-only projects).
  $filters += "[${baseIdx}:v]null[vbase]"
  $currentStage = 'vbase'

  if ($mainLabels.Count -gt 0) {
    $concatIn = ($mainLabels | ForEach-Object { "[$_]" }) -join ''
    $filters += "${concatIn}concat=n=$($mainLabels.Count):v=1:a=0[mainv]"
    # eof_action=pass (not the default repeat): once the main track ends,
    # let the base canvas show through instead of freezing main's last frame.
    $filters += "[$currentStage][mainv]overlay=x=0:y=0:shortest=0:eof_action=pass[stage0]"
    $currentStage = 'stage0'
  }

  # ---- Overlay tracks: scale, apply opacity, delay to start, gate with enable ----
  $stageCounter = 1
  for ($i = 0; $i -lt $overlayClips.Count; $i++) {
    $c   = $overlayClips[$i]
    $idx = $overlayInputIdx[$i]

    $scale   = $c.scale;   if ($null -eq $scale)   { $scale = 1 }
    $opacity = $c.opacity; if ($null -eq $opacity) { $opacity = 1 }
    $start   = $c.start
    $endT    = $c.start + $c.duration

    $ovLbl = "ov$i"
    # trunc(.../2)*2 forces even width/height - format=yuva420p (4:2:0) rejects
    # odd dimensions, which a fractional $scale (e.g. 0.33) can easily produce.
    $filters += "[${idx}:v]trim=start=$($c.in):duration=$($c.duration),setpts=PTS-STARTPTS,scale=trunc(iw*${scale}/2)*2:trunc(ih*${scale}/2)*2,format=yuva420p,colorchannelmixer=aa=$opacity,tpad=start_duration=${start}:start_mode=add:color=black@0.0,setpts=PTS-STARTPTS[$ovLbl]"

    $nextStage = "stage$stageCounter"
    $filters += "[$currentStage][$ovLbl]overlay=x=$($c.x):y=$($c.y):enable='between(t,$start,$endT)'[$nextStage]"
    $currentStage = $nextStage
    $stageCounter++
  }

  # ---- Audio: every non-muted audio-bearing clip -> atrim, adelay, volume; then amix + limiter ----
  $audioLabels = @()
  $aCounter = 0

  # Dot-sourced scriptblock (not a nested function) so it mutates $filters,
  # $audioLabels and $aCounter in *this* function's scope, not script scope.
  $AddAudioChain = {
    param([object]$c, [int]$idx)
    $asset = $assetsById[$c.assetId]
    if ($asset -and $asset.type -eq 'image') { return }   # images have no audio stream
    if ($c.muted) { return }
    $vol   = $c.volume; if ($null -eq $vol) { $vol = 1 }
    $endT  = $c.in + $c.duration
    $delayMs = [int]($c.start * 1000)
    $lbl = "a$aCounter"; $aCounter++
    # all=1 (not the "L|R" pair form) applies the delay to every channel
    # regardless of layout, so mono sources (e.g. a mic recording) don't hit
    # ffmpeg's documented-undefined behavior for a stereo-shaped delay list.
    $filters += "[${idx}:a]atrim=start=$($c.in):end=$endT,asetpts=PTS-STARTPTS,adelay=${delayMs}:all=1,volume=$vol[$lbl]"
    $audioLabels += $lbl
  }

  for ($i = 0; $i -lt $mainClips.Count; $i++)    { . $AddAudioChain $mainClips[$i]    $mainInputIdx[$i] }
  for ($i = 0; $i -lt $overlayClips.Count; $i++) { . $AddAudioChain $overlayClips[$i] $overlayInputIdx[$i] }
  for ($i = 0; $i -lt $audioClips.Count; $i++)   { . $AddAudioChain $audioClips[$i]   $audioInputIdx[$i] }

  if ($audioLabels.Count -gt 0) {
    $mixIn = ($audioLabels | ForEach-Object { "[$_]" }) -join ''
    $filters += "${mixIn}amix=inputs=$($audioLabels.Count):normalize=0[amixed]"
    $filters += "[amixed]alimiter[aout]"
  } else {
    # Guard: no audio anywhere -> synth a silent track instead of a broken
    # amix with 0 inputs, so the output always has a valid audio stream.
    $ffArgs += '-f','lavfi','-i','anullsrc=channel_layout=stereo:sample_rate=44100'
    $silentIdx = $inputIndex; $inputIndex++
    $filters += "[${silentIdx}:a]atrim=duration=$totalDur,asetpts=PTS-STARTPTS[aout]"
  }

  # Final video output is always an explicit declared label - never a bare
  # input ref - so -map "[vout]" resolves in every project shape (audio-only,
  # video-only, both, or neither). When the source told us what its colour is,
  # that goes back onto the frames here (see the note on $colorTags above).
  $setparams = Get-SetParamsFilter $colorTags
  if ($setparams) { $filters += "[$currentStage]$setparams[vout]" }
  else            { $filters += "[$currentStage]null[vout]" }

  $ffArgs += '-filter_complex', ($filters -join ';')
  $ffArgs += '-map', '[vout]'
  $ffArgs += '-map', '[aout]'
  $ffArgs += '-c:v','libx264','-profile:v','high','-pix_fmt','yuv420p','-crf','18','-r',"$fps",'-movflags','+faststart','-c:a','aac','-b:a','256k'
  # Say what the picture is. Without these the mp4 carries no colr box, and a
  # player falls back to BT.709 - which is why HDR (HLG) phone footage came out
  # looking washed out and bright even though not one pixel had changed.
  $ffArgs += Get-ColorOutputArgs $colorTags
  $ffArgs += $outPath

  return $ffArgs
}
