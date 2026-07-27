# EditorProjects.Tests.ps1 - round-trip unit tests for the save/load helpers
# (Save-EditorProject, Get-EditorProjectNames, Read-EditorProject) added to
# EditorRender.ps1 for Task 11 (project persistence).

. "$PSScriptRoot\..\..\EditorRender.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("EditorProjectsTest_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
  $sampleProject = @{
    version = 1
    name    = 'My Cut'
    canvas  = @{ width = 1080; height = 1920; fps = 30 }
    assets  = @(
      @{ id = 'a1'; path = 'output/main.mp4'; type = 'video'; naturalW = 1080; naturalH = 1920; duration = 20 },
      @{ id = 'a2'; path = 'music/bed.mp3';   type = 'audio'; duration = 60 }
    )
    tracks  = @(
      @{ id = 't1'; kind = 'main';    clips = @(@{ id = 'c1'; assetId = 'a1'; start = 0; in = 2; duration = 5 }) },
      @{ id = 't2'; kind = 'overlay'; clips = @() },
      @{ id = 't3'; kind = 'audio';   clips = @(@{ id = 'c2'; assetId = 'a2'; start = 0; in = 10; duration = 5 }) }
    )
  }

  # ---- Save-EditorProject --------------------------------------------------
  $path = Save-EditorProject 'My Cut' $sampleProject $tmp
  A (Test-Path $path) 'Save-EditorProject writes a file'
  A ($path -eq (Join-Path (Join-Path $tmp 'projects') 'My Cut.json')) 'saved path is projects\<safeName>.json'

  # ---- Get-EditorProjectNames ----------------------------------------------
  $names = Get-EditorProjectNames $tmp
  A ($names -contains 'My Cut') 'Get-EditorProjectNames includes the saved name'

  # ---- Read-EditorProject ---------------------------------------------------
  $loaded = Read-EditorProject 'My Cut' $tmp
  A ($null -ne $loaded) 'Read-EditorProject returns an object'
  A ($loaded.canvas.width -eq 1080) 'loaded canvas.width matches saved sample'
  A ($loaded.canvas.height -eq 1920) 'loaded canvas.height matches saved sample'
  A ($loaded.tracks.Count -eq 3) 'loaded track count matches saved sample'
  A ($loaded.tracks[0].clips.Count -eq 1) 'loaded main track clip count matches saved sample'
  A ($loaded.tracks[2].clips.Count -eq 1) 'loaded audio track clip count matches saved sample'
  A ($loaded.tracks[0].clips[0].assetId -eq 'a1') 'loaded main clip assetId matches saved sample'

  # ---- missing project -> $null --------------------------------------------
  $missing = Read-EditorProject 'Does Not Exist' $tmp
  A ($null -eq $missing) 'Read-EditorProject returns $null for a missing project'

  # ---- name sanitization ----------------------------------------------------
  $badName = 'a/b:c*d'
  $badPath = Save-EditorProject $badName $sampleProject $tmp
  A ($badPath -eq (Join-Path (Join-Path $tmp 'projects') 'a_b_c_d.json')) 'bad-char name is sanitized in the filename'
  A ((Get-EditorProjectNames $tmp) -contains 'a_b_c_d') 'sanitized name shows up in Get-EditorProjectNames'

  # ---- no BOM ----------------------------------------------------------------
  $bytes = [System.IO.File]::ReadAllBytes($path)
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  A (-not $hasBom) 'written file has no UTF-8 BOM'

  # ---- non-ASCII round-trip --------------------------------------------------
  # Reproduces the Fix 1 bug: the file is written UTF-8 (no BOM), so reading
  # it back WITHOUT -Encoding UTF8 falls back to the ANSI codepage on Windows
  # PowerShell 5.1 and mangles accents/smart quotes/em-dashes/emoji into
  # mojibake. This case fails before the Read-EditorProject fix and passes
  # after it.
  #
  # Built from explicit Unicode code points (not literal characters in this
  # source file) so the test itself is immune to *this script's own* on-disk
  # encoding being misread by whatever runs it - the only thing under test is
  # Read-EditorProject's -Encoding UTF8 argument.
  $eAcute  = [char]0x00E9   # é
  $nTildeU = [char]0x00D1   # Ñ
  $nTildeL = [char]0x00F1   # ñ
  $emDash  = [char]0x2014   # —
  $lDQuote = [char]0x201C   # "
  $rDQuote = [char]0x201D   # "
  $clapper = [char]::ConvertFromUtf32(0x1F3AC)   # 🎬
  $nonAsciiName = "Caf${eAcute} ${emDash} ${nTildeU}o${nTildeL}o ${clapper}"
  $nonAsciiAssetName = "Caf${eAcute} clip ${emDash} ${lDQuote}final${rDQuote} ${clapper}.mp4"
  $nonAsciiProject = @{
    version = 1
    name    = $nonAsciiName
    canvas  = @{ width = 1080; height = 1920; fps = 30 }
    assets  = @(
      @{ id = 'a1'; path = 'output/main.mp4'; type = 'video'; name = $nonAsciiAssetName; naturalW = 1080; naturalH = 1920; duration = 20 }
    )
    tracks  = @()
  }
  Save-EditorProject $nonAsciiName $nonAsciiProject $tmp | Out-Null
  $loadedNonAscii = Read-EditorProject $nonAsciiName $tmp
  A ($null -ne $loadedNonAscii) 'Read-EditorProject returns an object for a non-ASCII name'
  A ($loadedNonAscii.name -ceq $nonAsciiName) 'non-ASCII project name round-trips exactly'
  A ($loadedNonAscii.assets[0].name -ceq $nonAsciiAssetName) 'non-ASCII asset name round-trips exactly'
}
finally {
  Remove-Item -Recurse -Force -Path $tmp -ErrorAction SilentlyContinue
}

if ($fails) { Write-Host "FAILS=$fails"; exit 1 } else { Write-Host 'ALL PASS' }
