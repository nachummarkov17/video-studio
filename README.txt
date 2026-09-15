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
     - B-ROLL LIBRARY: your permanent shelf of cutaway clips and photos.
       There is NO "save" step - anything you add is copied into the
       broll\ folder and is simply there, in every future session and
       every project, until you delete it.
       THREE WAYS TO PUT THINGS IN:
         1. Click "+ B-roll" at the top of the media bin and pick files.
         2. Copy files in Explorer (Ctrl+C) and press Ctrl+V in the editor.
            You can also paste an image copied from anywhere - it's saved
            as a picture in your library.
         3. Click "Open the b-roll folder" at the bottom of the media bin
            and drop files straight in with Explorer.
       To organise them, just make folders inside broll\ (city\, nature\,
       food\...) - each folder shows as its own group in the media bin,
       and you can collapse the ones you're not using.
       CLICK a b-roll item to preview it big and TRIM IT FIRST: drag the
       start and end handles to pick just the piece you want, press play
       to check it (it loops your selection), then "Add to timeline" drops
       it at the playhead, on a lane above your main clip. Photos ask how
       many seconds to show instead (5 by default).
       You can also drag a b-roll item straight onto any lane - if you
       trimmed it, it arrives already trimmed.
       SAVE THE GOOD BIT AS ITS OWN CLIP: once you've set the start and
       end, type a name and click "Save to library". That cuts those
       seconds out into a small file of their own, kept in
       broll\saved\ and listed at the top of the media bin under
       "Saved clips". From then on it's just select and drag - no
       trimming to redo, ever. The cut is frame-exact.
       The full-length shot stays in your library, so you can go back and
       save a different piece out of it whenever you like. Saving twice
       under one name keeps both ("punch in", "punch in (2)").
       Each row shows its length, so a 3s saved piece is easy to tell
       apart from the 2-minute shot it came from.
       (Your last trim on a shot is also remembered between sessions, so
       re-opening it starts where you left off.)
     - The timeline starts empty. Drag material into it and the lane
       appears under it; drag onto the thin strip above or below the
       lanes to start a NEW lane (video and photos stack above, audio
       below). A lane vanishes when its last clip leaves, so you never
       stare at rows you aren't using.
     - Drop a clip in and the timeline zooms so you see the WHOLE clip.
       "Fit" (next to the zoom buttons) re-fits whenever you want, and
       it works at any length - a four-minute clip or an hour-long one
       both fit on screen.
     - PICTURES ON TOP OF THE VIDEO (pop-ups): drop a photo onto the
       strip ABOVE your main clip and it lands as a picture ON the
       video, not instead of it - sized to a fraction of the frame and
       placed in the upper third, clear of your captions. Select it and
       the inspector on the right gives you "Pop it up": small / medium
       / large, and nine spots to put it in (corners, edges, centre).
       Drag its ends on the timeline to control how long it's up for.
       Pictures live in the same b-roll library as your cutaway clips -
       add them with "+ B-roll", by pasting with Ctrl+V, or by dropping
       files into the broll\ folder (subfolders become groups). So you
       can keep a shelf of the images you use and drop them in as you
       talk.
       (A photo dropped on the MAIN lane still fills the frame, which is
       what you want when the picture IS the shot.)
     - SNAP (the magnet button, on by default): while you drag a clip or
       drag a trim handle, edges pull onto the playhead and onto other
       clips' edges so cuts land exactly where you meant. Park the
       playhead where you want the cut, drag the edge up to it, and it
       grabs on - the playhead lights up teal when it has. Turn Snap off
       to place things freely.
     - Grab the playhead by its HEAD (the triangle in the time ruler at
       the top) to drag it. Below the ruler it's out of the way, so it
       can never steal a click from a clip's trim handle.
     - Cut something out and the playhead comes with the picture: delete
       a piece and the line lands on the join, so you carry on watching
       the same frame instead of jumping somewhere else.
     - Ctrl+Z undoes, Ctrl+Shift+Z (or Ctrl+Y) redoes. A whole drag
       undoes in one press, not pixel by pixel.
     - EXPORT NEVER WRITES OVER ONE OF YOUR SOURCE CLIPS. If you name the
       export after a clip the edit is made from, it refuses - that would
       destroy the footage and leave the edit unopenable. The suggested
       name is "<your clip> edit" for the same reason.
     - SAVE vs EXPORT - two different things:
         "Save project" writes your EDIT to projects\ so you can reopen
         it later with "Open project". It does not make a video.
         "Export video" RENDERS the timeline into a finished clip and
         puts it in "Your videos", where captions, music and finishing
         pick it up. You're asked what to call it (it suggests a name),
         and warned before it replaces one you already have. Your source
         clips stay exactly where they are - the export is a NEW clip
         alongside them, not a replacement.
       While it renders you see a real percentage. The finished file
       only appears in "Your videos" once it's complete, so you can
       never open a half-written one.
     - The editor plays a small stand-in copy of each clip (kept in
       work\proxy-cache\, built once per clip) so scrubbing and playback
       stay instant on big files. Everything that produces a real video -
       export, burning captions, music, finishing - always uses your
       full-quality original.

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
       click the slider to jump to a spot) and the captions are on the
       right - one box per caption, so you fix the words as you watch
       and the timings look after themselves. Pick the clip from the
       drop-down; click Save. "Open in player" plays it in your normal
       video player if you prefer. (Portrait phone clips are shown the
       right way up automatically.)
     - CLICK THE TIME on any caption to jump the video straight there.
     - While it plays, the caption being spoken lights up teal, and the
       list only scrolls when that caption would otherwise be off
       screen - it doesn't shuffle under you while you read.
     - The first time you open a clip here the app makes a small preview
       copy of it in the background ("Preparing a smooth preview..."),
       then switches to it without losing your place. That's what keeps
       the picture in step with the sound on big files. Your original is
       untouched - it's what gets burned and exported.
     - UNDO / REDO: Ctrl+Z and Ctrl+Y (or Ctrl+Shift+Z), or the buttons
       top-right. A burst of typing undoes in one press, not letter by
       letter - a step ends when you pause, move to another caption,
       press a colour, or save.
     - COLOURING WORDS: select a word (a double-click is enough) and
       press Ctrl+B, or click the colour's button. Press the same colour
       again to take it off; press a DIFFERENT colour and the word simply
       changes colour. It works on a phrase too - each word is painted.
     - MORE THAN ONE COLOUR: click "+ Colour", give it a name (e.g.
       "Unhealthy") and pick the colour. It gets its own button and its
       own shortcut - Ctrl+1 is the first colour, Ctrl+2 the second, and
       so on (Ctrl+B stays the first one). So you can have teal for the
       words you want to land and red for the ingredients you're warning
       about, in the same caption.
       Behind the scenes each colour has a MARKER character wrapped
       around the word:
           I eat *protein* and no ~seed oils~
       so you can still type them by hand if you prefer. The markers are
       * ~ ^ = + | - characters that never come up in speech - and the
       list of colours lives in caption-colors.txt, which you can edit
       directly (Name|Marker|#RRGGBB). Punctuation right after the word
       is fine: *everything*! works and no stray marker shows up.

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

  broll\                  - your b-roll clips and photos (subfolders = groups)
  broll-trims.txt         - the piece of each b-roll clip you use
  music\                  - drop your background tracks here
  output\                 - your working videos + caption files
  output\captioned\       - videos with captions burned on
  output\with-music\      - videos with background music
  output\upload\          - FINISHED, upload-ready videos
  projects\               - saved EDITS from the editor (not videos)
  video-order.txt         - the order you arranged your clips in
  studio-settings.txt     - choices the app remembers (caption position)
  shared-library.txt      - the folder you swap b-roll and music through
  work\proxy-cache\       - small preview copies, so editing stays smooth
  work\thumb-cache\       - the filmstrips shown on timeline clips
  work\export.log         - what ffmpeg said during the last editor export

work\ is all rebuildable. If it ever gets big you can delete
anything inside it; the app makes what it needs again.

You don't need to open these yourself - the app shows your
videos and their progress in the middle panel. These folders
are just where the files are kept. When you're ready to post,
use step 6 "Export to your folder" to drop the finished videos
wherever you want them (or grab them from output\upload).


------------------------------------------------------------
  GIVING IT TO SOMEONE ELSE (and updating them)
------------------------------------------------------------

Video Studio can run on more than one computer - yours and your
editor's, say - and updates reach them by themselves.

HOW IT IS SPLIT
  The program is tiny (about half a megabyte) and changes often.
  The captions engine is huge (2.8 GB: a 1.5 GB speech model and
  a 1.3 GB timing aligner) and never changes. And your videos are
  neither - they are yours.
  So: the program is what gets updated, the captions engine is
  copied across once by hand, and your videos are never touched
  by any of it.

--- HOW IT IS SET UP (already done) ------------------------------

Releases live at:
    https://github.com/nachummarkov17/video-studio/releases

GitHub keeps one permanent address pointing at the newest release,
and that address is built into the app itself - so an installed
copy already knows where to look and there is nothing to configure
on any machine.

--- SHIPPING AN IMPROVEMENT -------------------------------------

    .\dist\Publish-Update.ps1 -Version 1.1.0 -Notes "what changed" ^
        -GitHub nachummarkov17/video-studio

It runs the whole test suite first and refuses to publish if
anything fails. Leave off -Version and it just bumps the last
number.

Your editor does nothing. Next time they open Video Studio an
orange "Update to 1.1.0" button appears in the toolbar; they click
it and the app closes and reopens on the new version.

ONE RULE: publish a NEW version number each time. Deleting a
release and re-using its tag leaves GitHub's cache serving "not
found" for several minutes.

--- SETTING UP A NEW MACHINE ------------------------------------

The program comes off the internet; only the captions engine
(2.8 GB - too big to download sensibly) is handed over by hand.

1. Make the captions-engine bundle once:
       .\dist\Export-Dependencies.ps1 -To "E:\VideoStudio-deps"
   Copy it to a USB stick.

2. On the new machine:
       powershell -ExecutionPolicy Bypass -File Install-VideoStudio.ps1 ^
           -Source "https://github.com/nachummarkov17/video-studio/releases/latest/download/update.json" ^
           -DependenciesFrom "E:\VideoStudio-deps"
   (Install-VideoStudio.ps1 is in dist\, and is also copied onto
   any USB stick you publish to.)

   Leave off -DependenciesFrom and everything works except
   "Make captions" - you can add it later.

   The installer sets the caption timer up by itself. That timer is
   a Python environment, and a Python environment only holds a
   POINTER to the Python it was built from - so copied to another
   computer it would not start, and captions would quietly fall
   back to less precise timing with nothing looking broken. The
   installer finds a Python 3.12 (installing one, without needing
   administrator rights, if there is not one), re-points the timer
   at it, and checks it actually runs before saying so. Video
   Studio also re-points it by itself if Python ever moves.

--- IF YOU EVER WANT A DIFFERENT SOURCE -------------------------

Put a folder path or an https address in update-source.txt in the
app folder and it overrides the built-in one. That is how a shared
OneDrive/Dropbox folder, a network share or a USB stick is used
instead. Publishing to one of those is -To <folder> rather than
-GitHub.

--- WHAT AN UPDATE CAN AND CANNOT TOUCH -------------------------

An update replaces PROGRAM files only - the .ps1, .js, .css and
.xaml files that make up the app. It cannot see, move or delete:
       your videos          output\ (and captioned\, upload\...)
       your b-roll          broll\
       your music           music\
       your saved edits     projects\
       your settings        caption colours, caption position,
                            export folder, clip order
Before replacing anything it copies the old program into
work\update-backup\, and if any part of the install fails it puts
the old one straight back - a half-updated app is not a state you
can end up in. Downloads are checksummed, so a damaged file is
thrown away rather than installed. Everything it did is written
to work\update.log.

If an update ever goes wrong, the previous version is sitting in
work\update-backup\ and can be copied back over the top.

--- IF YOU WOULD RATHER USE A WEBSITE ---------------------------

The shared folder can be an https address instead - anywhere that
serves files. Publish as above, upload those same files, and put
the address of update.json in update-source.txt on their machine.
Nothing else changes.


------------------------------------------------------------
  SHARING YOUR B-ROLL AND MUSIC WITH THE OTHER COMPUTER
------------------------------------------------------------

The "Shared library" button at the top swaps your b-roll clips,
your pop-up pictures and your music tracks with the other
computer, both directions at once. Whatever either of you has
added since last time, you both end up with.

FIRST TIME
  Click "Shared library" and pick a folder BOTH computers can
  see. Any of these works:
    - a shared OneDrive or Dropbox folder (easiest - it syncs
      itself in the background, so you can each click the button
      whenever, without being at the same desk)
    - a folder on the office network
    - a USB stick (click the button on one machine, carry the
      stick across, click it on the other)
  Do the same on the other computer, pointing at the same folder.
  It is remembered, so from then on the button just syncs.

WHAT MOVES
    broll\               all of it, subfolders and all, so your
                         groups arrive as groups - and your
                         pop-up pictures come with them
    music\               your background tracks
    broll-trims.txt      the piece of each b-roll clip you use
    caption-colors.txt   your emphasis colours

WHAT DOES NOT MOVE, ON PURPOSE
    output\              your videos. Gigabytes, and yours.
    projects\            saved edits - they point at clips in
                         output\, so on the other machine they
                         would open to a row of missing files.
    work\, settings      caches and per-machine choices.

IF YOU BOTH CHANGED THE SAME THING
  Nothing is ever overwritten. If a clip with the same name is
  different on the two computers, both are left exactly as they
  are and the log says so - rename one of them if you want to
  keep both, then sync again. Same for the trims and colours:
  where you disagree, the machine you clicked on keeps its own.

  So it is always safe to click, and safe to click twice: the
  second time copies nothing.

------------------------------------------------------------
  NOTES
------------------------------------------------------------

- Each step plays its own chime when it finishes, so you can tell
  by ear which one is done without watching the screen. They're
  struck-bell tones - a small chord that rings down rather than a
  beep - and each step has its own: captions rises, burn resolves
  to an octave, music falls gently, finishing is a full chord.

- Phone videos are "variable frame rate", which can make players
  drift the picture behind the sound (so burned captions look late
  even when they're on the right frame). Burn and Export now output
  a constant frame rate to fix this - if an older clip's captions
  seem to lag in playback, re-burn (and re-export) it.

- Steps skip files that are already done (so you can re-run
  safely). To redo a step for a clip, delete that clip's file
  from the matching folder and run the step again.
- Everything runs on your computer. Nothing is uploaded.

- IF AN EDITOR EXPORT FAILS, the app says why in the log panel and
  nothing is added to "Your videos". The full ffmpeg output is in
  work\export.log if you want the detail.

- HDR PHONE FOOTAGE keeps its colour. iPhone clips are usually HDR
  (BT.2020 primaries, HLG transfer). Those four little tags are what
  tell a player how bright the picture should be - and every step that
  re-encodes (import, editor export, burn captions, finish) now copies
  them onto the result. Without them the exact same pixels play back
  washed out and far too bright, which is what a "brighter, milky"
  export used to be. Nothing filters or grades your picture; the file
  just says what it is again.
  If you have an OLD file from before this that looks washed out, it
  can be repaired in seconds without re-encoding - it only needs its
  labels back:
     ffmpeg -i washed-out.mp4 -c copy ^
       -colorspace bt2020nc -color_primaries bt2020 ^
       -color_trc arib-std-b67 -color_range tv fixed.mp4
  (Use whatever the ORIGINAL clip reports for those four - check with
   ffprobe -v error -select_streams v:0 ^
     -show_entries stream=color_range,color_space,color_primaries,color_transfer ^
     -of default=nw=1 original.mp4)


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
