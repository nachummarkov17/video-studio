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
if($fails){ Write-Host "FAILS=$fails"; exit 1 } else { Write-Host 'ALL PASS' }
