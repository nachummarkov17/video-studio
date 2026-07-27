. "$PSScriptRoot\..\..\EditorRender.ps1"
$fails=0; function A($cond,$m){ if($cond){Write-Host "PASS: $m"}else{Write-Host "FAIL: $m";$script:fails++} }
$proj = @{ canvas=@{width=1080;height=1920;fps=30}
  assets=@(@{id='a1';path='output/main.mp4';type='video';naturalW=1080;naturalH=1920;duration=20},
           @{id='a2';path='output/broll.mp4';type='video';naturalW=1080;naturalH=1920;duration=20},
           @{id='a3';path='music/bed.mp3';type='audio';duration=60})
  tracks=@(@{kind='main';clips=@(@{id='c1';assetId='a1';start=0;in=2;duration=5;opacity=1;volume=1;muted=$false})},
           @{kind='overlay';clips=@(@{id='c2';assetId='a2';start=1;in=0;duration=3;x=40;y=60;scale=0.5;opacity=0.8;muted=$true})},
           @{kind='audio';clips=@(@{id='c3';assetId='a3';start=0;in=10;duration=5;volume=0.6;muted=$false})})}
$args = Build-EditorFilterGraph $proj 'output\proj.mp4'
$s = ($args -join ' ')
A ($s -match 'color=.*1080x1920') 'has 1080x1920 base canvas'
A ($s -match 'overlay=') 'has an overlay filter'
A ($s -match "between\(t,1,4\)") 'overlay enabled 1..4s'
A ($s -match 'amix') 'mixes audio'
A ($s -match 'main\.mp4') 'includes main input'
A ($args[-1] -eq 'output\proj.mp4') 'output path is last arg'

# Regression: an UNMUTED overlay IMAGE must not get an audio chain (images have
# no audio stream -> ffmpeg would fail with "Stream specifier ':a' matches no
# streams"). Main video (unmuted) is input 1 -> its audio ref is [1:a]; the
# overlay image is input 2 -> its would-be audio ref [2:a] must be absent.
$proj2 = @{ canvas=@{width=1080;height=1920;fps=30}
  assets=@(@{id='a1';path='output/main.mp4';type='video';naturalW=1080;naturalH=1920;duration=20},
           @{id='a2';path='output/photo.png';type='image';naturalW=800;naturalH=600;duration=5})
  tracks=@(@{kind='main';clips=@(@{id='c1';assetId='a1';start=0;in=0;duration=5;opacity=1;volume=1;muted=$false})},
           @{kind='overlay';clips=@(@{id='c2';assetId='a2';start=0;in=0;duration=5;x=0;y=0;scale=1;opacity=1;muted=$false})})}
$args2 = Build-EditorFilterGraph $proj2 'output\proj2.mp4'
$s2 = ($args2 -join ' ')
A ($s2 -match '\[1:a\]') 'unmuted main video audio input [1:a] is present'
A (-not ($s2 -match '\[2:a\]')) 'unmuted overlay image does NOT get an audio chain [2:a]'

if($fails){ Write-Host "FAILS=$fails"; exit 1 } else { Write-Host 'ALL PASS' }
