# EditorRender.ps1 - PURE function: project JSON (hashtable) -> ffmpeg argument vector.
# Build-EditorFilterGraph does NOT run ffmpeg; it only builds and returns the arg array.
# Dot-source this file to get Build-EditorFilterGraph in scope.

function Build-EditorFilterGraph {
  param(
    [Parameter(Mandatory=$true)] [object]$project,
    [Parameter(Mandatory=$true)] [string]$outPath
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

  # Total timeline duration = furthest clip end across every track.
  $totalDur = 0
  foreach ($c in ($mainClips + $overlayClips + $audioClips)) {
    $end = $c.start + $c.duration
    if ($end -gt $totalDur) { $totalDur = $end }
  }
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

  $currentStage = "${baseIdx}:v"

  if ($mainLabels.Count -gt 0) {
    $concatIn = ($mainLabels | ForEach-Object { "[$_]" }) -join ''
    $filters += "${concatIn}concat=n=$($mainLabels.Count):v=1:a=0[mainv]"
    $filters += "[$currentStage][mainv]overlay=x=0:y=0:shortest=0[stage0]"
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
    $filters += "[${idx}:v]trim=start=$($c.in):duration=$($c.duration),setpts=PTS-STARTPTS,scale=iw*${scale}:ih*${scale},format=yuva420p,colorchannelmixer=aa=$opacity,tpad=start_duration=${start}:start_mode=add:color=black@0.0,setpts=PTS-STARTPTS[$ovLbl]"

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
    if ($c.muted) { return }
    $vol   = $c.volume; if ($null -eq $vol) { $vol = 1 }
    $endT  = $c.in + $c.duration
    $delayMs = [int]($c.start * 1000)
    $lbl = "a$aCounter"; $aCounter++
    $filters += "[${idx}:a]atrim=start=$($c.in):end=$endT,asetpts=PTS-STARTPTS,adelay=$delayMs|$delayMs,volume=$vol[$lbl]"
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

  $ffArgs += '-filter_complex', ($filters -join ';')
  $ffArgs += '-map', "[$currentStage]"
  $ffArgs += '-map', '[aout]'
  $ffArgs += '-c:v','libx264','-profile:v','high','-pix_fmt','yuv420p','-crf','18','-r',"$fps",'-movflags','+faststart','-c:a','aac','-b:a','256k'
  $ffArgs += $outPath

  return $ffArgs
}
