# VideoColor.Tests.ps1 - the tags that decide whether a re-encode still looks
# like the clip it came from.
#
# The bug: phone footage is often HDR (bt2020 primaries, HLG transfer). Every
# re-encode in this app dropped those tags, and HLG shown as plain BT.709 looks
# "so much brighter, really washed out" - with the pixels completely unchanged.
#
# Run:  powershell -STA -ExecutionPolicy Bypass -File tests\VideoColor.Tests.ps1

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\VideoColor.ps1"
. "$PSScriptRoot\..\EditorRender.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

$hdr = [ordered]@{ Range = 'tv'; Space = 'bt2020nc'; Primaries = 'bt2020'; Transfer = 'arib-std-b67' }
$sdr = [ordered]@{ Range = 'tv'; Space = 'bt709'; Primaries = 'bt709'; Transfer = 'bt709' }
$none = [ordered]@{ Range = $null; Space = $null; Primaries = $null; Transfer = $null }

# ---- output flags ----------------------------------------------------------
$flags = (Get-ColorOutputArgs $hdr) -join ' '
A ($flags -like '*-colorspace bt2020nc*') 'the matrix is carried through'
A ($flags -like '*-color_primaries bt2020*') 'the primaries are carried through'
A ($flags -like '*-color_trc arib-std-b67*') 'the transfer (HLG) is carried through'
A ($flags -like '*-color_range tv*') 'the range is carried through'
A ((Get-ColorOutputArgs $none).Count -eq 0) 'an untagged clip gets no flags - we never invent a tag'
A ((Get-ColorOutputArgs $null).Count -eq 0) 'no tags at all is not an error'

# ---- the setparams filter --------------------------------------------------
# A filtergraph carries range and colorspace through but DROPS primaries and
# transfer, and ffmpeg then takes the encoder's colour from the filter output -
# so behind any -vf the flags alone are silently ignored. Verified against real
# ffmpeg: plain transcode keeps all four, the same encode behind a graph keeps
# two. This filter is what puts the other two back.
$sp = Get-SetParamsFilter $hdr
A ($sp -like 'setparams=*') 'a setparams filter is produced'
A ($sp -like '*color_primaries=bt2020*') 'it sets the primaries the graph would drop'
A ($sp -like '*color_trc=arib-std-b67*') 'it sets the transfer the graph would drop'
A ($sp -like '*range=tv*' -and $sp -like '*colorspace=bt2020nc*') 'and restates range and matrix'
A ((Get-SetParamsFilter $none) -eq '') 'an untagged clip changes the graph not at all'
A ((Get-SetParamsFilter $null) -eq '') 'no tags means no filter'
A ((Get-SetParamsFilter ([ordered]@{ Range = 'tv'; Space = $null; Primaries = $null; Transfer = $null })) -eq 'setparams=range=tv') 'partial tags produce a partial filter'

# ---- HDR detection ---------------------------------------------------------
A (Test-HdrTags $hdr) 'HLG counts as HDR'
A (Test-HdrTags ([ordered]@{ Transfer = 'smpte2084' })) 'PQ counts as HDR'
A (-not (Test-HdrTags $sdr)) 'BT.709 does not'
A (-not (Test-HdrTags $none)) 'and neither does an untagged clip'

# ---- the render graph uses both mechanisms ---------------------------------
$proj = @{
    canvas = @{ width = 1080; height = 1920; fps = 30 }
    assets = @(@{ id = 'a1'; path = 'C:\x.mp4'; type = 'video'; duration = 10 })
    tracks = @(@{ id = 't1'; kind = 'main'; clips = @(
        @{ id = 'c1'; assetId = 'a1'; start = 0; in = 0; duration = 5; volume = 1; muted = $false }) })
}
$tagged = (Build-EditorFilterGraph $proj 'C:\out.mp4' $hdr) -join ' '
A ($tagged -like '*setparams=*') 'the render stamps the tags onto the frames'
A ($tagged -like '*-color_trc arib-std-b67*') 'AND onto the encoder'
A ($tagged -like '*setparams=*`[vout`]*') 'the setparams sits at the end of the chain, on the final label'

$untagged = (Build-EditorFilterGraph $proj 'C:\out.mp4' $null) -join ' '
A ($untagged -notlike '*setparams*') 'an untagged source leaves the graph exactly as it was'
A ($untagged -notlike '*-color_*') 'and adds no colour flags'
A ($untagged -like '*`[vout`]*') 'the final label is still declared'

Write-Host ''
if ($fails -eq 0) { Write-Host "All VideoColor tests passed." } else { Write-Host "$fails test(s) FAILED."; exit 1 }
