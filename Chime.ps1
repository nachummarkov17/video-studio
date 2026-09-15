# Chime.ps1 - the sound a step makes when it finishes.
#
# The old one was a sine wave per note, played one after another with a hard
# little envelope: a beep. Three things separate a beep from a chime, and this
# does all three:
#
#   1. HARMONICS. A struck bell or marimba bar is a fundamental plus a handful
#      of partials, each quieter and each dying away FASTER than the one below
#      it. That decay-per-partial is what makes it sound struck rather than
#      switched on.
#   2. EXPONENTIAL DECAY. Real resonators ring down; they don't hold a level and
#      then stop. A few milliseconds of attack, then a long tail.
#   3. NOTES THAT OVERLAP AND A ROOM TO RING IN. Notes are mixed onto one
#      timeline so each is still sounding when the next arrives, and the whole
#      thing goes through a small reverb so it ends somewhere rather than
#      simply ceasing.
#
# Still synthesised in memory - the app ships no audio files.

$script:ChimeRate = 44100

# Partial number (x fundamental), its share of the level, and how much faster
# than the fundamental it dies. Slightly inharmonic on purpose: exact integer
# multiples sound like an organ, a little stretch sounds like metal and wood.
$script:ChimePartials = @(
    @(1.00, 1.00, 1.0),
    @(2.01, 0.42, 1.7),
    @(3.02, 0.22, 2.6),
    @(4.16, 0.11, 3.6),
    @(5.43, 0.05, 5.0)
)

# PURE-ish: renders notes into a float buffer.
#   $Notes: @{ Freq; At (seconds); Dur (seconds, the ring-down time); Gain }
function New-ChimeSamples {
    param(
        [Parameter(Mandatory = $true)][object[]]$Notes,
        [double]$TailSec = 0.9
    )
    $rate = $script:ChimeRate
    $end = 0.0
    foreach ($n in $Notes) { $e = [double]$n.At + [double]$n.Dur; if ($e -gt $end) { $end = $e } }
    $total = [int](($end + $TailSec) * $rate)
    if ($total -lt 1) { $total = 1 }
    $buf = New-Object 'double[]' $total

    foreach ($n in $Notes) {
        $freq = [double]$n.Freq
        $gain = [double]$n.Gain
        $start = [int]([double]$n.At * $rate)
        $len = [int]([double]$n.Dur * $rate)
        # 6ms attack: enough to avoid a click, short enough to still read as a strike
        $attack = [int](0.006 * $rate)
        # ring down to about -60dB over the note's length
        $decay = 6.9 / [Math]::Max(1.0, [double]$n.Dur)

        for ($i = 0; $i -lt $len; $i++) {
            $idx = $start + $i
            if ($idx -ge $total) { break }
            $t = $i / [double]$rate
            $env = [Math]::Exp(-$decay * $t)
            if ($i -lt $attack) { $env *= ($i / [double]$attack) }
            $s = 0.0
            foreach ($p in $script:ChimePartials) {
                $s += [Math]::Sin(2 * [Math]::PI * $freq * $p[0] * $t) * $p[1] * [Math]::Exp(-$decay * $p[2] * $t)
            }
            $buf[$idx] += $s * $env * $gain
        }
    }
    return $buf
}

# A small Schroeder reverb: a few delayed, decaying copies of the signal. This
# is the difference between "a sound" and "a sound in a room", and it is what
# stops the chime ending abruptly.
function Add-ChimeReverb {
    param(
        [Parameter(Mandatory = $true)][double[]]$Samples,
        [double]$Mix = 0.24
    )
    $rate = $script:ChimeRate
    $out = New-Object 'double[]' $Samples.Length
    [Array]::Copy($Samples, $out, $Samples.Length)
    # prime-ish delays so the repeats don't line up into a ringing pitch
    foreach ($tap in @(@(0.0237, 0.62), @(0.0311, 0.50), @(0.0413, 0.40), @(0.0577, 0.30))) {
        $delay = [int]($tap[0] * $rate)
        $feedback = [double]$tap[1]
        for ($i = $delay; $i -lt $out.Length; $i++) {
            $out[$i] += $out[$i - $delay] * $feedback * $Mix
        }
    }
    return $out
}

# Bring the peak to a comfortable level. A chime that makes you jump is not
# classier than a beep.
function Set-ChimeLevel {
    param([Parameter(Mandatory = $true)][double[]]$Samples, [double]$Peak = 0.72)
    $max = 0.0
    foreach ($s in $Samples) { $a = [Math]::Abs($s); if ($a -gt $max) { $max = $a } }
    if ($max -le 0) { return $Samples }
    $g = $Peak / $max
    for ($i = 0; $i -lt $Samples.Length; $i++) { $Samples[$i] = $Samples[$i] * $g }
    return $Samples
}

function ConvertTo-WavStream {
    param([Parameter(Mandatory = $true)][double[]]$Samples)
    $rate = $script:ChimeRate
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $dataSize = $Samples.Length * 2
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF')); $bw.Write([uint32](36 + $dataSize))
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes('WAVE'))
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes('fmt ')); $bw.Write([uint32]16)
    $bw.Write([uint16]1); $bw.Write([uint16]1); $bw.Write([uint32]$rate)
    $bw.Write([uint32]($rate * 2)); $bw.Write([uint16]2); $bw.Write([uint16]16)
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes('data')); $bw.Write([uint32]$dataSize)
    foreach ($s in $Samples) {
        $v = [int][Math]::Round($s * 32767)
        if ($v -gt 32767) { $v = 32767 } elseif ($v -lt -32768) { $v = -32768 }
        $bw.Write([int16]$v)
    }
    $bw.Flush(); $ms.Position = 0
    return $ms
}

function New-ChimeWav {
    param([Parameter(Mandatory = $true)][object[]]$Notes, [double]$Reverb = 0.24)
    $buf = New-ChimeSamples $Notes
    if ($Reverb -gt 0) { $buf = Add-ChimeReverb $buf $Reverb }
    $buf = Set-ChimeLevel $buf
    return (ConvertTo-WavStream $buf)
}

# Equal temperament from A4=440, so the motifs below can be written as notes.
function Get-NoteHz {
    param([Parameter(Mandatory = $true)][string]$Name)
    $steps = @{ 'C' = -9; 'C#' = -8; 'D' = -7; 'D#' = -6; 'E' = -5; 'F' = -4;
                'F#' = -3; 'G' = -2; 'G#' = -1; 'A' = 0; 'A#' = 1; 'B' = 2 }
    $m = [regex]::Match($Name, '^([A-G]#?)(-?\d)$')
    if (-not $m.Success) { return 440.0 }
    $semi = $steps[$m.Groups[1].Value] + (([int]$m.Groups[2].Value - 4) * 12)
    return 440.0 * [Math]::Pow(2.0, $semi / 12.0)
}

# Helper so a motif reads as music: note name, when it starts, how long it rings.
function New-ChimeNote {
    param([string]$Note, [double]$At, [double]$Dur = 1.4, [double]$Gain = 1.0)
    return @{ Freq = (Get-NoteHz $Note); At = $At; Dur = $Dur; Gain = $Gain }
}
