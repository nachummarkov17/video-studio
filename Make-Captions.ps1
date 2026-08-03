# Make-Captions.ps1
# Makes a caption (.srt) file for each video in the "output" folder using local,
# offline speech-to-text (whisper.cpp, medium.en). No internet, nothing uploaded.
#
# (Audio cleaning is no longer done here - that's handled by your microphone now.)
#
# Reads:  output\<name>.mp4
# Writes: output\<name>.srt   (captions, in sync with your voice)

[CmdletBinding()]
param(
    [string]$Root     = $PSScriptRoot,
    [int]   $Threads  = 0,       # 0 = auto (use all CPU cores)
    [int]   $MaxWords = 5,       # keep each caption to at most this many words on screen
    [switch]$Force              # re-transcribe even if output\<name>.srt already exists
)

# Resolve tool root robustly (profile can pollute $PSScriptRoot without -NoProfile).
if (-not $Root -or -not (Test-Path (Join-Path $Root "Srt-Chunk.ps1"))) {
    if ($PSCommandPath) { $Root = Split-Path -Parent $PSCommandPath }
}

$out   = Join-Path $Root "output"
$work  = Join-Path $Root "work"
$log   = Join-Path $Root "cleaner.log"
$cli   = Join-Path $Root "tools\whisper\Release\whisper-cli.exe"
$model = Join-Path $Root "tools\whisper\ggml-medium.en.bin"
$alignPy     = Join-Path $Root "tools\align-venv\Scripts\python.exe"   # isolated aligner env
$alignScript = Join-Path $Root "tools\align.py"
if ($Threads -le 0) { $Threads = [int]$env:NUMBER_OF_PROCESSORS; if ($Threads -le 0) { $Threads = 4 } }

function Write-Log($m) {
    $line = ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m)
    Write-Host $line
    Add-Content -Path $log -Value $line -Encoding UTF8
}

# --- Preflight ------------------------------------------------------------
if (-not (Test-Path $cli))   { Write-Log "ERROR: whisper-cli not found at $cli"; exit 1 }
if (-not (Test-Path $model)) { Write-Log "ERROR: caption model not found at $model"; exit 1 }
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { Write-Log "ERROR: ffmpeg not on PATH"; exit 1 }

# Shared caption re-chunker (short, readable captions).
. (Join-Path $Root "Srt-Chunk.ps1")
# Shared clip ordering - "Your videos" order, top to bottom.
. (Join-Path $Root "VideoOrder.ps1")

New-Item -ItemType Directory -Force -Path $work | Out-Null
$vids = @(Get-OrderedVideos $Root $out '*.mp4')
if (-not $vids) { Write-Log "No videos in 'output' to caption. Use 'Add videos' first."; exit 0 }

Write-Log ("=== Making captions with medium.en on {0} threads ===" -f $Threads)
$made = 0; $skipped = 0; $failed = 0
foreach ($v in $vids) {
    $name = $v.BaseName
    $srt  = Join-Path $out "$name.srt"
    if ((Test-Path $srt) -and -not $Force) { Write-Log "CAPTION exists, skipping: $name.srt (tick 'Re-make captions' to redo)"; $skipped++; continue }
    if ((Test-Path $srt) -and $Force) { Write-Log "Re-making captions (replacing existing, any manual edits will be lost): $name.srt" }

    $wav      = Join-Path $work "$name.16k.wav"
    $wordsOf  = Join-Path $work "$name.words"
    $wordsJson = "$wordsOf.json"
    $wordsSrt  = "$wordsOf.srt"
    try {
        Write-Log "Captioning: $($v.Name)  (this can take a few minutes per video)"
        # whisper wants 16 kHz mono wav
        & ffmpeg -y -loglevel error -i $v.FullName -vn -ar 16000 -ac 1 -c:a pcm_s16le $wav
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg audio extract failed" }

        # Transcribe to FULL json (-ojf): its per-token offsets carry each word's
        # TRUE end time (when the sound stops), unlike -ml 1 -sow whose word ends
        # are just the next word's onset (that made captions linger through pauses).
        # -dtw improves token alignment for the model.
        & $cli -m $model -f $wav -l en -t $Threads -dtw medium.en -ojf -of $wordsOf 2>$null
        if (-not (Test-Path $wordsJson)) { throw "whisper produced no json" }

        # json token offsets -> word-level .srt (whisper's own word times)
        Convert-WhisperJsonToWordSrt -InPath $wordsJson -OutPath $wordsSrt
        if (-not (Test-Path $wordsSrt)) { throw "json->word conversion produced no .srt" }

        # BEST timing: forced alignment measures each word's real position in the
        # audio (wav2vec2, phoneme-level) - far tighter than whisper's estimates.
        # Runs in the isolated tools\align-venv; if that's not set up, we fall back
        # to whisper's times refined by silence-snapping.
        $alignedSrt = "$wordsOf.aligned.srt"
        $useAligned = $false
        if ((Test-Path $alignPy) -and (Test-Path $alignScript)) {
            Write-Log "  aligning word timings (forced alignment)..."
            & $alignPy $alignScript --audio $wav --words $wordsSrt --out $alignedSrt 2>&1 | ForEach-Object { Write-Log ("    " + $_) }
            if ((Test-Path $alignedSrt) -and ((Get-Item $alignedSrt).Length -gt 0)) { $useAligned = $true }
            else { Write-Log "  (alignment produced nothing - using whisper timings)" }
        }

        if ($useAligned) {
            # aligned times are measured, so group them straight through (no snapping)
            Group-WordSrtFile -InPath $alignedSrt -OutPath $srt -MaxWords $MaxWords
        } else {
            # fallback: whisper times + real speech/silence edge-snapping
            $silences = Get-SilenceIntervals -WavPath $wav
            Write-Log ("  found {0} silence gap(s) for edge-snapping" -f $silences.Count)
            Group-WordSrtFile -InPath $wordsSrt -OutPath $srt -MaxWords $MaxWords -Silences $silences
        }
        if (-not (Test-Path $srt)) { throw "grouping produced no .srt" }

        Write-Log "CAPTION done: $name.srt"
        $made++
    }
    catch {
        Write-Log "CAPTION FAILED: $($v.Name) - $($_.Exception.Message)"
        $failed++
    }
    finally {
        Remove-Item $wav -Force -ErrorAction SilentlyContinue
        Remove-Item $wordsSrt -Force -ErrorAction SilentlyContinue
        Remove-Item $wordsJson -Force -ErrorAction SilentlyContinue
        if ($alignedSrt) { Remove-Item $alignedSrt -Force -ErrorAction SilentlyContinue }
    }
}
Write-Log ("Captions complete. Made {0}, skipped {1}, failed {2}. Caption files (.srt) are in {3}" -f $made, $skipped, $failed, $out)
