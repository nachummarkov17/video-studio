============================================================
  VIDEO STUDIO
============================================================

One window that takes your raw clips and turns them into
upload-ready videos with captions (and optional music).

Audio cleaning is no longer part of this - your microphone
handles that now.


------------------------------------------------------------
  HOW TO OPEN IT
------------------------------------------------------------

Double-click the "Video Studio" icon on your Desktop.

(That icon just runs "Video Studio.vbs" in this folder - you
can also double-click that file directly. No black terminal
window appears; only the app window opens.)

If the Desktop icon ever goes missing (or the icon looks wrong),
run this once in PowerShell from the AudioCleaner folder - it
recreates the Desktop and Start Menu shortcuts with the right
icon and identity:
    powershell -ExecutionPolicy Bypass -File tools\install-shortcuts.ps1

PINNING TO THE TASKBAR:
  Search "Video Studio" in the Start menu, right-click it, and
  "Pin to taskbar" (or open the app, right-click its taskbar
  button, Pin to taskbar). It launches straight to the app with
  the proper icon - no empty terminal.
  If you had an OLD pin that opened an empty black window, unpin
  it first (right-click the pin > Unpin), then pin it again as
  above. The old pin was pointing at PowerShell itself; the new
  one points at the app.


------------------------------------------------------------
  HOW TO USE IT
------------------------------------------------------------

Everything is in the window. Progress for each step shows in
the dark panel on the right.

The video list has a column for each step (Captions, Burned,
Music, Finished). Each shows:
    yes   - done and up to date (green)
    redo  - done before, but something earlier changed, so this
            step needs re-running (orange)
    -     - not done yet
"redo" cascades: if you re-caption a clip, its Burn/Music/Finished
turn to "redo"; change the music and only Finished does; re-edit a clip
and everything downstream does. So you always know exactly what to
re-run, and never post a stale file by accident.

  CLEAR ALL
     The "Clear all" button (top toolbar) empties the whole studio
     in one go - every video and everything made from it - after a
     Yes/No confirmation, so you don't have to remove clips one by
     one. Your exported files (in your own folder) are NOT touched.

  +  ADD VIDEOS
     Pick the clips off your computer - OR just drag video files
     (or a whole folder) straight onto the window. They're copied
     in, so your originals are never touched.
     Tip: right-click a video in the list to Play, Rename, or
     Remove it. Renaming and removing also handle its captions and
     finished copies, so nothing gets left behind or out of sync.
     Double-click to play.

  RE-ORDERING YOUR VIDEOS
     Drag a row up or down in "Your videos" to put your clips in the
     order you want (or select a row and press Alt+Up / Alt+Down).
     That order sticks between sessions, and it's the order EVERY
     step works through: the clip at the top gets captioned, burned,
     given music and finished first. New clips land at the bottom.
     (The order lives in video-order.txt - you never need to open it.)

  1. EDIT / ASSEMBLE
     - "Open editor" opens the video editor RIGHT HERE in the same
       window (it fills the screen; no separate window or terminal):
       cut, trim, split and layer your video (B-roll, photos,
       audio) on a timeline.
     - Click "Back to Studio" (top-left) to return to the steps.
     - The media bin shows your videos and anything you Import. It does
       NOT show your background music - music is added in step 4, and
       only there, so there's one place to think about it. (You can
       still Import a specific sound onto the timeline if you want one.)
     - The timeline starts empty. Drag material into it and the lane
       appears under it; drag onto the thin strip above or below the
       lanes to start a NEW lane (video and photos stack above, audio
       below). A lane vanishes when its last clip leaves, so you never
       stare at rows you aren't using.
     - Drop a clip in and the timeline zooms so you see the WHOLE clip.
       "Fit" (next to the zoom buttons) re-fits whenever you want.
     - Ctrl+Z undoes, Ctrl+Shift+Z (or Ctrl+Y) redoes. A whole drag
       undoes in one press, not pixel by pixel.
     - When you export your assembled clip from the editor, it
       appears in the video list here, ready for captions, burning,
       music, finishing and export - just like any other video.

  2. MAKE CAPTIONS
     - "Make captions" transcribes each video on your computer
       (offline) into captions that stay in sync.
     - Captions are kept short and readable: one sentence at most per
       caption (the next sentence never bleeds in) and about 5 words
       max. Timing is tight: the app runs "forced alignment" - it
       measures where each word actually lands in the audio (the same
       technique YouTube uses) - so a caption appears exactly as you
       say its first word and clears right after the last, without
       lagging your voice, lingering, or overlapping the next line.
       A long breathing/demo pause shows no caption.
       (If the aligner isn't installed it automatically falls back to
       a good-enough method; see "Caption timing engine" below.)
     - Already-captioned clips are skipped so re-running is safe. To
       regenerate them (e.g. after a caption update), tick "Re-make
       captions (redo already-captioned clips)" and click Make
       captions again. NOTE: this replaces the caption file, so any
       wording you fixed in "Edit captions" is redone from scratch.
     - "Edit captions" opens a watch-and-edit view INSIDE the app:
       the video is on the left (one Play/Pause button that toggles;
       click the slider to jump to a spot) and the words are on the
       right, so you can fix them as you watch. Pick the clip from the
       drop-down; click Save. "Open in player" plays it in your normal
       video player if you prefer. (Portrait phone clips are shown the
       right way up automatically.)
     - While it plays, the caption being spoken is highlighted in teal
       on the right and the list glides to keep it in view.
     - To colour a word teal: select it (a double-click is enough) and
       press Ctrl+B, or click the "*Bold*" button. Press again to take
       it off. It works on a phrase too - each word gets its own stars.
       Behind the scenes that just wraps the word in *stars*, e.g.
           give it *everything*
       so you can still type them by hand if you prefer. Punctuation
       right after the word is fine - *everything*! works and no stray
       star shows up.

  3. BURN CAPTIONS ONTO THE VIDEO
     - Pick a style:
         Regular  - white words; any *starred* word is teal
         Karaoke  - each word pops teal as it's spoken
     - Pick a position:
         Middle   - the middle of the frame (chest height on a phone
                    clip). This is the default and the safe choice -
                    captions near the bottom land on your legs and get
                    covered by Instagram's own buttons.
         Bottom   - the old low placement
         Top      - above your head
       It remembers whichever you used last.
     - Click "Burn captions".
     - Already-burned clips are skipped so re-running is safe. If you
       edited the captions or want a different style, tick
       "Re-burn (redo already-burned clips)" and burn again - it
       overwrites the old burned copy.

  4. BACKGROUND MUSIC   (optional)
     - "Background music" opens a window INSIDE the app.
     - Click "Import music files..." to bring in a few .mp3s
       (see music\README.txt for free, royalty-free sources).
     - Pick a track for each video from its drop-down (leave it
       on "(none)" for no music), then "Add music to videos"
       mixes a quiet bed under your voice.
     - Click the small play button next to a drop-down to LISTEN to
       the track you picked before committing to it. Click it again
       (or pick a different track) to stop; only one plays at a time.
     - This is the only place music is applied - the editor's media
       bin deliberately doesn't list your music folder.

  5. FINISH FOR SOCIAL MEDIA
     - "Finish clips" makes an upload-ready master with the best
       settings for YouTube / Instagram. It automatically uses your
       most finished version of each clip (with music > captioned >
       plain).
     - The "Finished" column in the video list turns to "yes" when
       a clip is done. Finished files are kept in output\upload.
     - "Upscale to 4K" is optional - only helps if you want the
       extra resolution; it makes bigger files.
     - Nothing leaves your computer here - this just prepares the
       files. Use step 6 to send them where you actually want them.

  6. EXPORT TO YOUR FOLDER
     - "Export finished videos" copies ALL your finished clips
       (everything from step 5) into a folder you choose - so you
       don't have to dig them out of output\upload by hand.
     - Set the folder once: the first time, you'll be asked to pick
       it; after that it's one click. The card shows where it sends
       to, and "Change folder..." re-points it whenever you like.
     - It COPIES (your originals stay in the studio), and re-sending
       overwrites the same file so your folder always has the newest
       version. If a clip isn't finished yet, run step 5 first.

See UPLOAD-GUIDE.txt for the platform-side settings that make
the biggest difference to upload quality (especially
Instagram's "Upload at highest quality" toggle).


------------------------------------------------------------
  WHERE THINGS LIVE
------------------------------------------------------------

  music\                  - drop your background tracks here
  output\                 - your working videos + caption files
  output\captioned\       - videos with captions burned on
  output\with-music\      - videos with background music
  output\upload\          - FINISHED, upload-ready videos
  video-order.txt         - the order you arranged your clips in
  studio-settings.txt     - choices the app remembers (caption position)

You don't need to open these yourself - the app shows your
videos and their progress in the middle panel. These folders
are just where the files are kept. When you're ready to post,
use step 6 "Export to your folder" to drop the finished videos
wherever you want them (or grab them from output\upload).


------------------------------------------------------------
  NOTES
------------------------------------------------------------

- Each step plays its own little chime when it finishes, so you
  can tell by ear which one is done without watching the screen
  (captions, burn, music and export each sound different).

- Phone videos are "variable frame rate", which can make players
  drift the picture behind the sound (so burned captions look late
  even when they're on the right frame). Burn and Export now output
  a constant frame rate to fix this - if an older clip's captions
  seem to lag in playback, re-burn (and re-export) it.

- Steps skip files that are already done (so you can re-run
  safely). To redo a step for a clip, delete that clip's file
  from the matching folder and run the step again.
- Everything runs on your computer. Nothing is uploaded.


------------------------------------------------------------
  CAPTION TIMING ENGINE (forced alignment)
------------------------------------------------------------

For the tightest caption timing, the app uses "forced alignment"
(wav2vec2) to measure exactly where each word is spoken. This lives
in a self-contained Python environment inside the tool at
   tools\align-venv\
and the aligner script is  tools\align.py .

- It's already set up. The first time captions run it downloads a
  ~360 MB alignment model once (cached afterwards); everything stays
  on your computer.
- If that folder is ever missing or Python is unavailable, captions
  still work - they automatically fall back to whisper's timings
  refined by silence detection (slightly looser, no setup needed).
- To rebuild the environment (e.g. after moving the tool), run in
  PowerShell from the AudioCleaner folder:
     python -m venv tools\align-venv
     tools\align-venv\Scripts\python.exe -m pip install torch==2.5.1 torchaudio==2.5.1 numpy --index-url https://download.pytorch.org/whl/cpu
