# Chime.Tests.ps1 - the finish sounds.
#
# You can't unit-test "classier", but you can test the things that make the
# difference between a chime and a beep: harmonics, a struck envelope that rings
# down, notes that overlap, a tail, and a level that doesn't make you jump.
#
# Run:  powershell -ExecutionPolicy Bypass -File tests\Chime.Tests.ps1

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\Chime.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }
function Rms([double[]]$s, [int]$from, [int]$count) {
    $sum = 0.0; $n = 0
    for ($i = $from; $i -lt [Math]::Min($from + $count, $s.Length); $i++) { $sum += $s[$i] * $s[$i]; $n++ }
    if ($n -eq 0) { return 0.0 }
    return [Math]::Sqrt($sum / $n)
}

# ---- pitch -----------------------------------------------------------------
A ([Math]::Abs((Get-NoteHz 'A4') - 440.0) -lt 0.01) 'A4 is 440Hz'
A ([Math]::Abs((Get-NoteHz 'A5') - 880.0) -lt 0.01) 'an octave up doubles'
A ([Math]::Abs((Get-NoteHz 'A3') - 220.0) -lt 0.01) 'an octave down halves'
A ([Math]::Abs((Get-NoteHz 'C5') - 523.25) -lt 0.1) 'C5 is 523.25Hz'
A ([Math]::Abs((Get-NoteHz 'nonsense') - 440.0) -lt 0.01) 'an unreadable note falls back rather than crashing'

# ---- one struck note --------------------------------------------------------
$one = New-ChimeSamples @((New-ChimeNote 'A4' 0.0 1.2)) 0.5
$rate = 44100
A ($one.Length -gt ($rate * 1.5)) 'the note is followed by a tail, not cut off'
A ((Rms $one 0 200) -lt (Rms $one 500 2000)) 'it fades IN over a few milliseconds - no click at the start'

$early = Rms $one ([int]($rate * 0.05)) 2000
$mid   = Rms $one ([int]($rate * 0.50)) 2000
$late  = Rms $one ([int]($rate * 1.10)) 2000
A ($early -gt $mid -and $mid -gt $late) 'it rings DOWN the whole time, like something struck'
A ($late -lt ($early * 0.35)) 'and is much quieter by the end'
A ($early -gt 0.01) 'it is not silence'

# A beep is one frequency. Compare energy at the fundamental with energy at the
# 2nd partial: a bell has plenty of both.
function Goertzel([double[]]$s, [double]$freq, [int]$from, [int]$count) {
    $w = 2 * [Math]::PI * $freq / 44100
    $c = 2 * [Math]::Cos($w); $s1 = 0.0; $s2 = 0.0
    for ($i = $from; $i -lt [Math]::Min($from + $count, $s.Length); $i++) {
        $s0 = $s[$i] + $c * $s1 - $s2; $s2 = $s1; $s1 = $s0
    }
    return [Math]::Sqrt([Math]::Abs($s1 * $s1 + $s2 * $s2 - $c * $s1 * $s2))
}
$f0 = Goertzel $one 440.0 1000 8192
$f2 = Goertzel $one (440.0 * 2.01) 1000 8192
$off = Goertzel $one 999.0 1000 8192
A ($f0 -gt 0) 'the fundamental is there'
A ($f2 -gt ($f0 * 0.05)) 'and so is a real second partial - this is not a bare sine'
A ($f0 -gt ($off * 2)) 'energy sits at the note, not smeared everywhere'

# ---- notes overlap into a chord --------------------------------------------
$chord = New-ChimeSamples @((New-ChimeNote 'F4' 0.0 1.6), (New-ChimeNote 'A4' 0.11 1.6), (New-ChimeNote 'C5' 0.22 2.0)) 0.9
$at = [int](44100 * 0.30)     # after all three have started
$hasF = Goertzel $chord (Get-NoteHz 'F4') $at 8192
$hasA = Goertzel $chord (Get-NoteHz 'A4') $at 8192
$hasC = Goertzel $chord (Get-NoteHz 'C5') $at 8192
A ($hasF -gt 0 -and $hasA -gt 0 -and $hasC -gt 0) 'all three notes are still sounding together - a chord, not a sequence'

# ---- the room ---------------------------------------------------------------
$dry = New-ChimeSamples @((New-ChimeNote 'A4' 0.0 0.4)) 0.6
$wet = Add-ChimeReverb $dry 0.24
$tailAt = [int](44100 * 0.55)
A ((Rms $wet $tailAt 4000) -gt (Rms $dry $tailAt 4000)) 'reverb leaves something ringing after the note has gone'
A ($wet.Length -eq $dry.Length) 'and does not change the length'

# ---- level ------------------------------------------------------------------
$loud = New-ChimeSamples @((New-ChimeNote 'A4' 0.0 1.0 8.0)) 0.4     # deliberately way too hot
$tamed = Set-ChimeLevel $loud
$peak = 0.0
foreach ($s in $tamed) { $a = [Math]::Abs($s); if ($a -gt $peak) { $peak = $a } }
A ($peak -le 0.9) "the level is brought under control (peak $([Math]::Round($peak,3)))"
A ($peak -gt 0.5) 'but is still audible'
A ((Set-ChimeLevel (New-Object 'double[]' 100)).Length -eq 100) 'silence does not divide by zero'

# ---- a real WAV that Windows will actually play -----------------------------
$stream = New-ChimeWav @((New-ChimeNote 'F4' 0.0 1.5), (New-ChimeNote 'A4' 0.1 1.5))
A ($stream.Length -gt 44) 'the WAV has a header and data'
$stream.Position = 0
$head = New-Object byte[] 12
[void]$stream.Read($head, 0, 12)
A ([System.Text.Encoding]::ASCII.GetString($head, 0, 4) -eq 'RIFF') 'it is RIFF'
A ([System.Text.Encoding]::ASCII.GetString($head, 8, 4) -eq 'WAVE') 'it is WAVE'
$stream.Position = 0
$player = New-Object System.Media.SoundPlayer
$player.Stream = $stream
$player.Load()                       # throws if Windows can't read it
A $true 'Windows loads it without complaint'

# ---- every motif the app uses builds --------------------------------------
$motifs = @{
    captions = @((New-ChimeNote 'F4' 0.00 1.6), (New-ChimeNote 'A4' 0.11 1.6), (New-ChimeNote 'C5' 0.22 2.0))
    burn     = @((New-ChimeNote 'C4' 0.00 1.7), (New-ChimeNote 'G4' 0.10 1.7), (New-ChimeNote 'C5' 0.20 2.1))
    music    = @((New-ChimeNote 'A4' 0.00 1.5 0.85), (New-ChimeNote 'F4' 0.13 2.0 0.85))
    export   = @((New-ChimeNote 'F3' 0.00 2.2 0.7), (New-ChimeNote 'F4' 0.02 1.8),
                 (New-ChimeNote 'A4' 0.10 1.8), (New-ChimeNote 'C5' 0.19 2.2))
    generic  = @((New-ChimeNote 'A4' 0.00 1.6))
}
foreach ($k in $motifs.Keys) {
    $ok = $false
    try {
        $p = New-Object System.Media.SoundPlayer
        $p.Stream = (New-ChimeWav $motifs[$k])
        $p.Load()
        $ok = $true
    } catch {}
    A $ok "the '$k' chime builds and loads"
}

Write-Host ''
if ($fails -eq 0) { Write-Host "All Chime tests passed." } else { Write-Host "$fails test(s) FAILED."; exit 1 }
