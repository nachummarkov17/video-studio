# Video Studio — UX feedback round 2

Date: 2026-08-03
Status: approved

Eleven changes across the Studio window (PowerShell/WPF) and the in-window
video editor (WebView2 + JS). Section A items are independent of each other and
of section B. Section B items share `timeline-ui.js` / `app.js`; the dynamic-lane
change reshapes the project model, so it lands before undo/redo.

---

## A. Studio window (Studio.ps1 and the burn pipeline)

### A1. Background music belongs to Step 4 only

**Problem.** `music\` is scanned into the editor's media bin *and* driven by
Step 4, so it is unclear where music is applied.

**Change.** Drop the `music\` scan from the `listAssets` bridge handler in
`Studio.ps1` (the `$items += @(& $scan (Join-Path $Root 'music') 'music')` line).
The editor keeps `output\` and `editor-imports\`, so audio you deliberately
import (stings, voiceover) still reaches the timeline; your music library no
longer appears there.

Step 4 is unchanged: it keeps the batch mix with the bed ducked under the voice,
and it is the only place background music is applied.

`README.txt` is updated to say so.

### A2. Preview a track from the music picker

**Change.** Each row of `Show-MusicDialog` gains a play button between the label
and the dropdown.

- Playback uses one shared `System.Windows.Media.MediaPlayer`. A `MediaElement`
  would need to sit in the visual tree; `MediaPlayer` does not.
- Only one track plays at a time. Starting a second row stops the first.
- The button reads `▶` when idle and `■` while that row is playing.
- Playback stops when the row's dropdown changes, when the media ends, and when
  the dialog closes.
- The button is disabled while the row is on `(none)`.

### A3. Reorderable "Your videos", affecting processing order

**Change.** The order shown in the video list is user-controlled, persisted, and
drives the order every step processes clips in.

Storage: `video-order.txt` at the project root, one file name per line, UTF-8 no
BOM, `#` comments ignored.

Ordering rule (one shared implementation, `VideoOrder.ps1`, dot-sourced by the
Studio and by each step script):

```
Get-OrderedVideos -Dir <dir> -Filter *.mp4
  -> files whose names appear in video-order.txt, in that order
  -> then any remaining files, sorted by name
```

`Save-VideoOrder -Names <string[]>` rewrites the file.

Reordering gestures in `Studio.ps1`:

- Drag a row and drop it on another row. Insertion goes *before* the target when
  the pointer is in the target's top half, *after* it otherwise.
- `Alt+Up` / `Alt+Down` move the selected row one place, as a keyboard fallback.

Both paths write `video-order.txt` and re-run `Refresh-Videos`.

**Known conflict.** `$win.Add_PreviewDragOver` currently sets
`Effects = None; Handled = $true` for any payload that is not `FileDrop`, which
would swallow the internal row drag before the ListView sees it. It must let the
internal format (`VideoStudio.VideoRow`) bubble through untouched.

**Processing order.** `Refresh-Videos`, `Make-Captions.ps1`,
`Burn-Captions.ps1`, `Apply-Music.ps1` and `Export-ForUpload.ps1` replace their
`Get-ChildItem ... | Sort-Object Name` with `Get-OrderedVideos`. Each step
script resolves `VideoOrder.ps1` from its own `$Root`, and falls back to
name-sort if the file is missing.

### A4. Caption position control

**Problem.** Burned captions sit near the bottom of the frame (leg height on a
portrait clip).

**Change.** Step 3 gains a `Position:` dropdown next to `Style:` with
`Bottom` / `Middle` / `Top`, defaulting to **Middle**.

| Position | `-Alignment` | `-MarginV` |
|----------|--------------|------------|
| Bottom   | 2            | 70         |
| Middle   | 5            | 0          |
| Top      | 8            | 40         |

`Burn-Captions.ps1` already accepts both parameters and forwards them to
`Convert-SrtToAss`; only the Studio's `BtnBurn` handler needs to pass them.
With alignment 5, libass centres vertically and ignores `MarginV`, which is the
intended behaviour.

The selection persists between launches in `studio-settings.txt` (`key=value`
lines, root of the project). Unknown or missing values fall back to `Middle`.

### A5. Emphasis button and Ctrl+B in Edit captions

**Problem.** Typing `*stars*` by hand is tedious.

**Change.** The Edit captions window gains a `*Bold*` button and a `Ctrl+B` key
binding. Both act on the current selection in the caption text box. Nothing
about the burned output changes — this is a typing shortcut for the existing
star syntax.

Behaviour:

- The selection is expanded to whole words at both ends, so a double-clicked
  word or a sloppy drag both work.
- Each selected **word** is wrapped individually: `a b c` becomes `*a* *b* *c*`.
  A single `*a b c*` would only mark the first and last word, because
  `Caption-Style.ps1` splits on whitespace and strips one outer star per token.
- Toggle: if every selected word is already starred, the stars are removed
  instead.
- Punctuation attached to a word stays outside the stars on the trailing side
  (`*word*!`), matching what `Caption-Style.ps1` already parses.
- Lines that are cue numbers (`^\d+$`) or timestamps (contain `-->`) are left
  untouched even if the selection spans them.
- After the edit the selection is restored over the same words.
- With an empty selection (a caret, no text) the button acts on the word under
  the caret.

### A6. Visible follow-along highlight with smooth scrolling

**Problem.** The spoken line's highlight is nearly invisible and the scroll
jumps.

**Change.** Three fixes in `Show-CaptionEditor`:

1. **Visibility.** Set `SelectionBrush` to the brand teal `#3D9E8E` with
   `SelectionOpacity="0.45"` on the caption `TextBox`. The default inactive
   selection brush is what makes the current highlight imperceptible.
2. **Smooth scroll.** Replace `ScrollToLine` with an animated scroll. On
   `Loaded`, grab the TextBox's internal ScrollViewer via
   `$txt.Template.FindName('PART_ContentHost', $txt)`; compute the target
   vertical offset from `GetRectFromCharacterIndex`; ease
   `ScrollToVerticalOffset` to it over ~250 ms with a `DispatcherTimer`
   (ease-out). A new scroll target supersedes an in-flight one.
3. **Scroll less often.** Only scroll when the active line falls outside the
   middle 60% of the viewport. Lines already comfortably in view do not move the
   window at all.

Also: cues are parsed on text change and cached, instead of re-parsing the whole
document on every 200 ms tick.

The existing guards stay: follow-along runs only while playing, only when not
seeking, and only when the text box does not have keyboard focus.

---

## B. Video editor (`editor/js`)

### B1. Playback does nothing (bug)

**Root cause.** `preview.js` `_updateMedia` drift-corrects on every animation
frame:

```js
} else if(Math.abs(el.currentTime - expected) > 0.05){
  el.currentTime = expected;
}
```

`expected` advances on a wall clock (`performance.now()`). A media element takes
longer than 50 ms to spin up and to recover from each seek, so the drift test
passes on essentially every frame and the element is re-seeked ~60 times a
second. The decoder never plays; the picture is frozen and no audio is emitted.

**Fix.**

- Never correct while `el.seeking` is true.
- Raise the correction threshold to 0.3 s.
- Rate-limit corrections to at most one every 500 ms per element.

Activation (first frame a clip becomes active) still seeks exactly once, as
today.

The hypothesis is confirmed by observing playback before and after the change,
not assumed.

### B2. Crisp filmstrips

**Root cause.** `thumbs.js` renders one strip for the whole asset — at most 24
tiles, each `48 × (48 × aspect)`, so ~650 px wide for portrait footage. The
timeline then stretches it across `duration × pxPerSec` px (`timeline-ui.js`,
`backgroundSize = ${fullW}px 100%`), which is thousands of pixels: up to a 10×
upscale. Separately each tile is drawn with
`ctx.drawImage(v, i*W, 0, W, H)`, which stretches the frame to fill the tile
rather than cropping it, distorting the image.

**Fix in `thumbs.js`.**

- Tile height `52 * 2 = 104` px (clip box height at 2× for crispness on
  high-DPI); tile width `104 * (16/9 inverse of source aspect)` — i.e. tile
  aspect follows the source.
- Draw each frame **cover-cropped and centred** into its tile instead of
  stretched.
- Tile count from the width the strip will actually occupy:
  `clamp(8, 60, ceil(displayWidthPx / tileWidthPx))`.
- JPEG quality 0.6 → 0.8.
- Cache key becomes `assetId@zoomBucket` where the bucket is
  `floor(log2(pxPerSec))`. Crossing a bucket triggers one debounced (250 ms)
  regeneration; within a bucket the cached strip is reused and scaled at most
  2×, which is not visibly soft.

Audio waveforms keep their current generation path, with the same 2× height
bump.

### B3. Fit the whole clip on drop

**Change.** `TimelineUI` gains `zoomToFit()`:

```
pxPerSec = (viewportWidth - LABEL_WIDTH - 24) / contentSec, clamped to [MIN, MAX]
```

Called after every drop, after import, and after project load. A **Fit** button
joins the zoom controls in the toolbar. Manual `+` / `−` still win until the next
drop.

### B4. CapCut-style lanes

**Problem.** The timeline shows three fixed lanes whether or not they hold
anything.

**Change.**

- `newProject()` creates **no** tracks. `p.tracks` starts empty.
- An empty timeline renders one tall "Drag material here" area. Dropping a
  video or image there creates the main lane; dropping audio creates an audio
  lane.
- Once lanes exist, a thin drop strip sits above the stack and another below it.
  Dropping on either strip creates a new lane. The **asset type** decides the
  lane kind, not which strip was used:
  - `video` / `image` → a new `overlay` lane above main
  - `audio` → a new `audio` lane below main
  This makes an invalid lane impossible to create.
- Dragging an existing clip onto a strip moves it into a brand-new lane.
- A lane whose last clip leaves is removed — on `mouseup`, never mid-drag, so
  the timeline does not jump under the cursor.
- The main lane keeps its gapless ripple behaviour.
- `+ Video Track` and `+ Audio Track` are removed from the toolbar.

**Ordering.** `project.tracks` stays in *draw* order (main first, then overlays
bottom-to-top, then audio), because `preview.js` `_clipsAt` and
`EditorRender.ps1` both depend on it. The timeline *renders* video lanes
reversed above main and audio lanes below, so array order and screen order stay
decoupled.

`EditorRender.ps1` already groups clips by `kind` and tolerates zero main clips,
so the ffmpeg export needs no change for dynamic lane counts.

**Loading old projects.** A saved project with the old fixed three tracks loads
unchanged; empty lanes in it are dropped on load by the same rule that removes
emptied lanes.

### B5. Undo and redo

**Change.** `Ctrl+Z` undoes, `Ctrl+Shift+Z` and `Ctrl+Y` redo.

- Snapshot-based history in `app.js`: a deep clone of `project` per entry,
  capped at 50 entries; the redo stack is cleared by any new action.
- **One snapshot per gesture.** A drag or trim pushes its snapshot on
  `mousedown`, not per `mousemove`, so one undo reverses a whole drag.
- Covered: add clip (drop/import), move, trim, split, delete, lane create,
  lane remove, and inspector property edits.
- On undo/redo: swap `project`, call `preview.setProject`, re-render the
  timeline, and restore the selection if that clip still exists (otherwise clear
  the inspector).
- The keyboard handler ignores events whose target is an `input`, `textarea` or
  `[contenteditable]`, so typing in inspector fields is unaffected.

---

## Testing

- `editor/tests/*.test.js` (`node --test`) covers the pure model/timeline logic:
  empty-project construction, lane creation by asset type, lane removal when
  emptied, draw-order invariants, `zoomToFit` math, and the undo/redo stack.
- Pester covers the new PowerShell logic that is pure enough to test:
  `Get-OrderedVideos` / `Save-VideoOrder` ordering and round-trip, the caption
  position → alignment/margin mapping, and the star-wrap/unwrap text transform
  (extracted as a pure function so it is testable without a window).
- Interaction-level behaviour (drag-reorder, music preview, follow-along scroll,
  playback) is verified by running the app.
