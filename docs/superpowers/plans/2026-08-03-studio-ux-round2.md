# Video Studio UX Round 2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the eleven changes in `docs/superpowers/specs/2026-08-03-studio-ux-round2-design.md` — music ownership, video reordering, caption position/emphasis/follow-along, and editor playback/thumbnails/lanes/undo.

**Architecture:** Two independent halves. The Studio half is PowerShell + WPF in `Studio.ps1` plus the step scripts; new pure logic is extracted into dot-sourced `.ps1` helpers so Pester can test it without a window. The editor half is ES modules under `editor/js`; pure model/timeline logic is unit-tested with `node --test`, and DOM/media behaviour is verified by running the app.

**Tech Stack:** PowerShell 5.1, WPF (XAML built by string), Pester, WebView2, vanilla ES modules, `node --test` (Node 24).

## Global Constraints

- PowerShell 5.1 only: no `&&`/`||`, no ternary, no `??`, no `-AsHashtable`.
- All files written from PowerShell that other tools read use UTF-8 **no BOM** via the existing `Utf8NoBom` helper.
- Editor JS is plain ES modules, no build step, no external dependencies, no CDN.
- Brand teal is `#3D9E8E`. Do not introduce other accent colours.
- The burned-caption *look* does not change in this plan; only its vertical position (Task 4) and the ease of typing star markers (Task 5).
- `project.tracks` is always in **draw order**: `main` first, then `overlay` lanes bottom-to-top, then `audio`. `preview.js` and `EditorRender.ps1` both depend on this.
- Run JS tests from `editor/` with `npm test`. Run Pester tests with `Invoke-Pester -Path <file>`.
- Commit after every task.

---

## File Structure

**Created:**
- `VideoOrder.ps1` — pure ordering helpers (`Get-OrderedVideos`, `Save-VideoOrder`, `Read-VideoOrder`).
- `StudioSettings.ps1` — pure `key=value` settings read/write (`Get-StudioSetting`, `Set-StudioSetting`) plus `Get-CaptionPlacement`.
- `CaptionMarkup.ps1` — pure star wrap/unwrap transform (`Invoke-ToggleEmphasis`).
- `tests/VideoOrder.Tests.ps1`, `tests/StudioSettings.Tests.ps1`, `tests/CaptionMarkup.Tests.ps1` — Pester.
- `editor/js/history.js` — undo/redo stack.
- `editor/tests/history.test.js`, `editor/tests/lanes.test.js` — node tests.

**Modified:**
- `Studio.ps1` — music scan removal, music preview, list reorder, caption position dropdown, emphasis button, follow-along highlight/scroll.
- `Make-Captions.ps1`, `Burn-Captions.ps1`, `Apply-Music.ps1`, `Export-ForUpload.ps1` — ordered iteration.
- `editor/js/preview.js` — playback drift fix.
- `editor/js/thumbs.js` — crisp filmstrips.
- `editor/js/model.js` — empty `tracks`, lane helpers.
- `editor/js/timeline.js` — lane create/remove logic.
- `editor/js/timeline-ui.js` — drop strips, lane rendering, `zoomToFit`.
- `editor/js/app.js` — Fit button, history wiring, keyboard shortcuts.
- `editor/editor.html`, `editor/css/editor.css` — toolbar + drop-strip styles.
- `editor/tests/model.test.js`, `editor/tests/timeline.test.js` — updated for empty tracks.
- `README.txt` — music ownership, reordering, caption position, emphasis shortcut, editor shortcuts.

---

### Task 1: Music belongs to Step 4 only

**Files:**
- Modify: `Studio.ps1` (the `listAssets` handler, `$items += @(& $scan (Join-Path $Root 'music') 'music')`)
- Modify: `README.txt`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Remove the music scan line** from the `listAssets` bridge handler so the editor lists only `output` and `editor-imports`.
- [ ] **Step 2: Update README.txt** — in the editor section, state that background music is applied in Step 4 only and the editor's media bin shows your videos and imported media, not your music library.
- [ ] **Step 3: Commit** `fix(editor): music library belongs to step 4, not the media bin`

---

### Task 2: `VideoOrder.ps1` — ordering helpers (TDD)

**Files:**
- Create: `VideoOrder.ps1`
- Create: `tests/VideoOrder.Tests.ps1`

**Interfaces:**
- Produces:
  - `Read-VideoOrder([string]$Root) -> string[]` — names in file order; `@()` when missing.
  - `Save-VideoOrder([string]$Root, [string[]]$Names) -> void` — writes `video-order.txt`, UTF-8 no BOM, with a `#` header comment.
  - `Get-OrderedVideos([string]$Root, [string]$Dir, [string]$Filter = '*.mp4') -> FileInfo[]` — files named in `video-order.txt` first in that order, then the rest sorted by name.

- [ ] **Step 1: Write failing Pester tests**

```powershell
BeforeAll { . (Join-Path $PSScriptRoot '..\VideoOrder.ps1') }

Describe 'Get-OrderedVideos' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:dir  = Join-Path $script:root 'output'
        New-Item -ItemType Directory -Force -Path $script:dir | Out-Null
        foreach ($n in 'b.mp4','a.mp4','c.mp4') { Set-Content -Path (Join-Path $script:dir $n) -Value 'x' }
    }
    It 'sorts by name when no order file exists' {
        (Get-OrderedVideos $script:root $script:dir).Name | Should -Be @('a.mp4','b.mp4','c.mp4')
    }
    It 'honours the saved order' {
        Save-VideoOrder $script:root @('c.mp4','a.mp4','b.mp4')
        (Get-OrderedVideos $script:root $script:dir).Name | Should -Be @('c.mp4','a.mp4','b.mp4')
    }
    It 'appends unknown files after known ones, sorted by name' {
        Save-VideoOrder $script:root @('c.mp4')
        Set-Content -Path (Join-Path $script:dir 'd.mp4') -Value 'x'
        (Get-OrderedVideos $script:root $script:dir).Name | Should -Be @('c.mp4','a.mp4','b.mp4','d.mp4')
    }
    It 'ignores names in the order file that no longer exist' {
        Save-VideoOrder $script:root @('gone.mp4','b.mp4')
        (Get-OrderedVideos $script:root $script:dir).Name | Should -Be @('b.mp4','a.mp4','c.mp4')
    }
    It 'round-trips through Read-VideoOrder ignoring comments' {
        Save-VideoOrder $script:root @('a.mp4','b.mp4')
        Read-VideoOrder $script:root | Should -Be @('a.mp4','b.mp4')
    }
    It 'writes UTF-8 without a BOM' {
        Save-VideoOrder $script:root @('a.mp4')
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:root 'video-order.txt'))
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run** `Invoke-Pester -Path tests/VideoOrder.Tests.ps1` — expect failures (file not found / commands missing).
- [ ] **Step 3: Implement `VideoOrder.ps1`** with the three functions. `Get-OrderedVideos` builds a hashtable of present files keyed by name, walks the order list emitting matches, then emits leftovers sorted by name.
- [ ] **Step 4: Run the tests** — expect all pass.
- [ ] **Step 5: Commit** `feat: shared video-order helpers (video-order.txt)`

---

### Task 3: Reorderable "Your videos" wired through every step

**Files:**
- Modify: `Studio.ps1` — dot-source `VideoOrder.ps1`; `Refresh-Videos`; `$win.Add_PreviewDragOver`; new drag + Alt+Arrow handlers; `Import-VideoFiles`; `Remove-VideoFiles`; `Rename-Selected`
- Modify: `Make-Captions.ps1`, `Burn-Captions.ps1`, `Apply-Music.ps1`, `Export-ForUpload.ps1`

**Interfaces:**
- Consumes: `Get-OrderedVideos`, `Save-VideoOrder` from Task 2.
- Produces: nothing later tasks consume.

- [ ] **Step 1: Dot-source and switch `Refresh-Videos`** to `Get-OrderedVideos $Root $OutDir '*.mp4'` instead of `Get-ChildItem ... | Sort-Object Name`, and persist the resulting order with `Save-VideoOrder` so new files get pinned at the bottom.
- [ ] **Step 2: Stop the window drag handler from eating internal drags.** In `$win.Add_PreviewDragOver`, return without setting `Handled` when `$e.Data.GetDataPresent('VideoStudio.VideoRow')` is true.
- [ ] **Step 3: Add row drag-and-drop on `VidList`** — `PreviewMouseLeftButtonDown` records the hit row and point; `MouseMove` past `SystemParameters.MinimumHorizontalDragDistance` starts `DragDrop.DoDragDrop` with format `VideoStudio.VideoRow` carrying the row's `Name`; `DragOver` sets `Effects = Move`; `Drop` finds the target row, inserts before it when the pointer is in its top half and after otherwise, then calls `Save-VideoOrder` + `Refresh-Videos`.
- [ ] **Step 4: Add `Alt+Up` / `Alt+Down`** on `VidList.PreviewKeyDown` moving the selected row one place, saving and refreshing, and keeping the moved row selected.
- [ ] **Step 5: Keep the order file honest on rename/remove** — `Rename-Selected` swaps the old name for the new one in place; `Remove-VideoFiles` and `Clear-AllVideos` drop the removed names.
- [ ] **Step 6: Switch every step script to ordered iteration.** In each of `Make-Captions.ps1`, `Burn-Captions.ps1`, `Apply-Music.ps1`, `Export-ForUpload.ps1`, dot-source `VideoOrder.ps1` from `$Root` when it exists and replace the `Get-ChildItem ... | Sort-Object Name` video enumeration with `Get-OrderedVideos`; fall back to the existing call when the helper is absent.
- [ ] **Step 7: Verify** — launch the app, drag a row, confirm the order sticks after Refresh and after restarting, and confirm `video-order.txt` matches.
- [ ] **Step 8: Commit** `feat: reorder Your videos (drag or Alt+Arrow); order drives every step`

---

### Task 4: Caption position control (TDD for the mapping)

**Files:**
- Create: `StudioSettings.ps1`
- Create: `tests/StudioSettings.Tests.ps1`
- Modify: `Studio.ps1` — Step 3 XAML, `$ctrls` list, `BtnBurn` handler, startup restore

**Interfaces:**
- Produces:
  - `Get-CaptionPlacement([string]$Position) -> @{ Alignment = <int>; MarginV = <int> }` — `Bottom`→2/70, `Middle`→5/0, `Top`→8/40, anything else→Middle.
  - `Get-StudioSetting([string]$Root, [string]$Key, [string]$Default) -> string`
  - `Set-StudioSetting([string]$Root, [string]$Key, [string]$Value) -> void` (file `studio-settings.txt`, `key=value`, UTF-8 no BOM)

- [ ] **Step 1: Write failing Pester tests**

```powershell
BeforeAll { . (Join-Path $PSScriptRoot '..\StudioSettings.ps1') }

Describe 'Get-CaptionPlacement' {
    It 'maps Bottom'  { $p = Get-CaptionPlacement 'Bottom'; $p.Alignment | Should -Be 2; $p.MarginV | Should -Be 70 }
    It 'maps Middle'  { $p = Get-CaptionPlacement 'Middle'; $p.Alignment | Should -Be 5; $p.MarginV | Should -Be 0 }
    It 'maps Top'     { $p = Get-CaptionPlacement 'Top';    $p.Alignment | Should -Be 8; $p.MarginV | Should -Be 40 }
    It 'defaults unknown values to Middle' { (Get-CaptionPlacement 'sideways').Alignment | Should -Be 5 }
    It 'is case-insensitive' { (Get-CaptionPlacement 'bottom').Alignment | Should -Be 2 }
}

Describe 'Studio settings' {
    BeforeEach { $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path $script:root | Out-Null }
    It 'returns the default when unset' { Get-StudioSetting $script:root 'CaptionPosition' 'Middle' | Should -Be 'Middle' }
    It 'round-trips a value' {
        Set-StudioSetting $script:root 'CaptionPosition' 'Top'
        Get-StudioSetting $script:root 'CaptionPosition' 'Middle' | Should -Be 'Top'
    }
    It 'overwrites rather than duplicating a key' {
        Set-StudioSetting $script:root 'CaptionPosition' 'Top'
        Set-StudioSetting $script:root 'CaptionPosition' 'Bottom'
        (Get-Content (Join-Path $script:root 'studio-settings.txt') | Where-Object { $_ -like 'CaptionPosition=*' }).Count | Should -Be 1
    }
    It 'keeps other keys intact' {
        Set-StudioSetting $script:root 'A' '1'; Set-StudioSetting $script:root 'B' '2'
        Get-StudioSetting $script:root 'A' '' | Should -Be '1'
    }
}
```

- [ ] **Step 2: Run** `Invoke-Pester -Path tests/StudioSettings.Tests.ps1` — expect failures.
- [ ] **Step 3: Implement `StudioSettings.ps1`.**
- [ ] **Step 4: Run the tests** — expect all pass.
- [ ] **Step 5: Add the dropdown.** In the Step 3 card XAML add `Position:` + `<ComboBox x:Name="CmbPos" Width="120">` with items `Bottom`, `Middle`, `Top`; register `CmbPos` in the `$ctrls` loop; select the saved value at startup (default `Middle`).
- [ ] **Step 6: Pass it through.** In `BtnBurn.Add_Click`, read `CmbPos`, call `Get-CaptionPlacement`, append `-Alignment`/`-MarginV` to the argument list, and `Set-StudioSetting` the choice.
- [ ] **Step 7: Verify** — burn a clip with Middle and confirm the captions sit at chest height.
- [ ] **Step 8: Commit** `feat(captions): caption position control (Bottom/Middle/Top), default Middle`

---

### Task 5: Emphasis toggle — button + Ctrl+B (TDD for the transform)

**Files:**
- Create: `CaptionMarkup.ps1`
- Create: `tests/CaptionMarkup.Tests.ps1`
- Modify: `Studio.ps1` — `Show-CaptionEditor` XAML + handlers

**Interfaces:**
- Produces:
  - `Invoke-ToggleEmphasis([string]$Text, [int]$SelStart, [int]$SelLength) -> @{ Text = <string>; SelStart = <int>; SelLength = <int> }` — pure; expands the selection to whole words, wraps each word in `*` or strips them when all are already marked, skips cue-number and timestamp lines, and returns the new selection covering the same words.

- [ ] **Step 1: Write failing Pester tests**

```powershell
BeforeAll { . (Join-Path $PSScriptRoot '..\CaptionMarkup.ps1') }

Describe 'Invoke-ToggleEmphasis' {
    It 'wraps a single selected word' {
        $r = Invoke-ToggleEmphasis 'give it everything' 8 10   # "everything"
        $r.Text | Should -Be 'give it *everything*'
    }
    It 'wraps each word of a multi-word selection separately' {
        $r = Invoke-ToggleEmphasis 'a b c' 0 5
        $r.Text | Should -Be '*a* *b* *c*'
    }
    It 'unwraps when every selected word is already marked' {
        $r = Invoke-ToggleEmphasis '*a* *b*' 0 7
        $r.Text | Should -Be 'a b'
    }
    It 'expands a partial selection to whole words' {
        $r = Invoke-ToggleEmphasis 'hello world' 2 3   # "llo w"
        $r.Text | Should -Be '*hello* *world*'
    }
    It 'acts on the word under the caret when nothing is selected' {
        $r = Invoke-ToggleEmphasis 'hello world' 3 0
        $r.Text | Should -Be '*hello* world'
    }
    It 'keeps trailing punctuation outside the stars' {
        $r = Invoke-ToggleEmphasis 'go now!' 3 4
        $r.Text | Should -Be 'go *now*!'
    }
    It 'leaves cue numbers and timestamps untouched' {
        $t = "1`n00:00:01,000 --> 00:00:02,000`nhello"
        $r = Invoke-ToggleEmphasis $t 0 $t.Length
        $r.Text | Should -Be "1`n00:00:01,000 --> 00:00:02,000`n*hello*"
    }
    It 'returns a selection covering the transformed words' {
        $r = Invoke-ToggleEmphasis 'hello world' 0 5
        $r.Text.Substring($r.SelStart, $r.SelLength) | Should -Be '*hello*'
    }
    It 'is a no-op on whitespace-only selections' {
        $r = Invoke-ToggleEmphasis 'a  b' 1 2
        $r.Text | Should -Be 'a  b'
    }
}
```

- [ ] **Step 2: Run** `Invoke-Pester -Path tests/CaptionMarkup.Tests.ps1` — expect failures.
- [ ] **Step 3: Implement `CaptionMarkup.ps1`.** Expand selection outward while the neighbouring character is a word character; split the covered span into lines; skip lines matching `^\s*\d+\s*$` or containing `-->`; tokenise remaining lines on whitespace; a token is "marked" when a `*` sits at its outer edge (allowing attached punctuation, same rule as `Caption-Style.ps1`); if every non-empty token is marked, strip, else wrap each unmarked token.
- [ ] **Step 4: Run the tests** — expect all pass.
- [ ] **Step 5: Wire the UI.** Dot-source `CaptionMarkup.ps1`; add a `*Bold*` button to the caption editor's top bar; on click (and on `Ctrl+B` via `Txt.PreviewKeyDown`) call the transform with `$txt.SelectionStart` / `$txt.SelectionLength`, assign `$txt.Text`, then restore `SelectionStart` / `SelectionLength` from the result. Mark the key event handled so the TextBox does not also insert anything.
- [ ] **Step 6: Verify** — double-click a word, press Ctrl+B, confirm stars appear and the word stays selected; press again to remove.
- [ ] **Step 7: Commit** `feat(captions): Ctrl+B / *Bold* button applies star emphasis to the selection`

---

### Task 6: Visible follow-along highlight with smooth scrolling

**Files:**
- Modify: `Studio.ps1` — `Show-CaptionEditor` (TextBox XAML, ticker, new scroll animator, cue cache)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Make the highlight visible** — on the caption `TextBox`, add `SelectionBrush="#3D9E8E"` and `SelectionOpacity="0.45"`.
- [ ] **Step 2: Cache parsed cues** — hold `$script:capCues`; recompute in `$loadSel` and in the `TextChanged` handler instead of on every ticker tick.
- [ ] **Step 3: Grab the internal ScrollViewer** — on the TextBox's `Loaded` event, `$script:capScroll = $txt.Template.FindName('PART_ContentHost', $txt)`; guard for `$null`.
- [ ] **Step 4: Add the animated scroll.** A `DispatcherTimer` at ~16 ms eases `ScrollToVerticalOffset` from the current offset to a target over 250 ms using `1 - (1-p)^3`; setting a new target restarts the easing from wherever it currently is.
- [ ] **Step 5: Only scroll when needed.** Compute the active line's Y with `$txt.GetRectFromCharacterIndex($startCh)`; if it sits within the middle 60% of `$script:capScroll.ViewportHeight`, do not scroll. Otherwise target `currentOffset + rect.Y - ViewportHeight/2`, clamped to `[0, ScrollableHeight]`.
- [ ] **Step 6: Verify** — play a clip and confirm the spoken line is clearly highlighted and the pane glides rather than jumps.
- [ ] **Step 7: Commit** `fix(captions): clearly visible follow-along highlight + smooth scrolling`

---

### Task 7: Editor playback — stop re-seeking every frame

**Files:**
- Modify: `editor/js/preview.js` — `_updateMedia`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Reproduce** — open the editor, drop a clip, press Play, and confirm the picture is frozen and no audio plays.
- [ ] **Step 2: Fix the drift correction.** In `_updateMedia`, keep the one-time seek on activation. For already-active elements, skip correction when `el.seeking` is true, raise the threshold to `0.3`, and only correct when at least 500 ms have passed since that element's last correction (`_lastFix` Map keyed by clip id, cleared in `pause()` and `setProject()`).
- [ ] **Step 3: Verify** — press Play; the picture moves and audio plays; scrubbing then playing again still works; pausing stops both.
- [ ] **Step 4: Commit** `fix(editor): playback was re-seeking media every frame, freezing the picture`

---

### Task 8: Crisp filmstrips

**Files:**
- Modify: `editor/js/thumbs.js`
- Modify: `editor/js/timeline-ui.js` — pass display width / zoom bucket to `requestThumb`, key lookups by bucket

**Interfaces:**
- Produces:
  - `zoomBucket(pxPerSec) -> number` — `Math.floor(Math.log2(pxPerSec))`.
  - `getThumb(asset, bucket) -> string|null`
  - `requestThumb(asset, url, bucket, displayWidthPx, onReady) -> void`

- [ ] **Step 1: Rework `generateFilmstrip`** — tile height `104` (2× the 52 px clip box); tile width `round(104 * sourceAspect)`; tile count `clamp(8, 60, ceil(displayWidthPx / tileWidth))`; draw each frame **cover-cropped and centred** (compute `s = max(tileW/vw, tileH/vh)` and draw the scaled frame offset by half the overflow) instead of stretching; `toDataURL('image/jpeg', 0.8)`.
- [ ] **Step 2: Bump the waveform** to height 104 and width `clamp(900, 4000, displayWidthPx)`.
- [ ] **Step 3: Key the cache by `assetId@bucket`** and debounce regeneration by 250 ms so a zoom drag does not queue a dozen jobs.
- [ ] **Step 4: Update `timeline-ui.js` `_renderClip`** to compute `fullW` first, then call `getThumb(asset, bucket)` / `requestThumb(asset, url, bucket, fullW, cb)`.
- [ ] **Step 5: Verify** — drop a clip and confirm the strip shows recognisable, undistorted frames at the default zoom and after zooming in.
- [ ] **Step 6: Commit** `fix(editor): filmstrips rendered at display resolution, cover-cropped, no more blur`

---

### Task 9: Fit-the-whole-clip zoom

**Files:**
- Modify: `editor/js/timeline-ui.js` — `zoomToFit()`
- Modify: `editor/js/app.js` — call it after drop/import/load; wire the Fit button
- Modify: `editor/editor.html` — `<button id="btn-fit">`
- Test: `editor/tests/lanes.test.js` (shared file; add a `fitPxPerSec` case)

**Interfaces:**
- Produces: `fitPxPerSec(viewportPx, contentSec, min, max) -> number` exported from `editor/js/timeline.js` so it is testable without a DOM.

- [ ] **Step 1: Write the failing test**

```js
import { fitPxPerSec } from '../js/timeline.js';
test('fitPxPerSec fills the viewport', () => {
  assert.equal(fitPxPerSec(1000, 10, 10, 800), 100);
});
test('fitPxPerSec clamps to the max', () => {
  assert.equal(fitPxPerSec(1000, 0.5, 10, 800), 800);
});
test('fitPxPerSec clamps to the min', () => {
  assert.equal(fitPxPerSec(1000, 1000, 10, 800), 10);
});
test('fitPxPerSec falls back to the min for empty content', () => {
  assert.ok(fitPxPerSec(1000, 0, 10, 800) > 0);
});
```

- [ ] **Step 2: Run** `npm test` in `editor/` — expect failure.
- [ ] **Step 3: Implement `fitPxPerSec`** in `timeline.js` and `zoomToFit()` in `TimelineUI` using `this.root.clientWidth - LABEL_WIDTH - 24`.
- [ ] **Step 4: Run** `npm test` — expect pass.
- [ ] **Step 5: Wire it** — call `app.timeline.zoomToFit()` at the end of `addAssetAndClip` and after `projectLoaded`; add the Fit button to the toolbar and handler in `app.js`.
- [ ] **Step 6: Verify** — drag a 30 s clip in and confirm the whole clip is visible.
- [ ] **Step 7: Commit** `feat(editor): fit the whole timeline on drop, plus a Fit button`

---

### Task 10: CapCut-style dynamic lanes

**Files:**
- Modify: `editor/js/model.js` — `newProject` with no tracks; `addTrackForType`, `pruneEmptyTracks`
- Modify: `editor/js/timeline.js` — export the lane helpers used by the UI
- Modify: `editor/js/timeline-ui.js` — drop strips, reversed video-lane rendering, drop routing, prune on mouseup
- Modify: `editor/js/app.js` — remove the add-track buttons
- Modify: `editor/editor.html` — remove the add-track buttons and the three hard-coded `.track` divs
- Modify: `editor/css/editor.css` — `.drop-strip`, `.timeline-empty`
- Modify: `editor/tests/model.test.js` (the "3 tracks" assertion), `editor/tests/timeline.test.js` (build tracks explicitly)
- Create: `editor/tests/lanes.test.js`

**Interfaces:**
- Produces:
  - `addTrackForType(project, assetType) -> trackId` — `'audio'` appends an `audio` track at the end; `'video'`/`'image'` insert an `overlay` track after the last existing overlay (or right after main); when no `main` track exists and the type is not audio, the new track is the `main` track.
  - `pruneEmptyTracks(project) -> project` — removes every track with no clips.
  - `laneRows(project) -> track[]` — screen order: overlays reversed, then main, then audio lanes.

- [ ] **Step 1: Write the failing tests** (`editor/tests/lanes.test.js`)

```js
import { test } from 'node:test'; import assert from 'node:assert';
import { newProject, addAsset, addClip, addTrackForType, pruneEmptyTracks, laneRows } from '../js/model.js';

test('a new project starts with no tracks', () => {
  assert.deepEqual(newProject().tracks, []);
});
test('first video drop creates the main lane', () => {
  const p = newProject();
  const id = addTrackForType(p, 'video');
  assert.equal(p.tracks.length, 1);
  assert.equal(p.tracks[0].kind, 'main');
  assert.equal(p.tracks[0].id, id);
});
test('first audio drop creates an audio lane, not a main lane', () => {
  const p = newProject(); addTrackForType(p, 'audio');
  assert.deepEqual(p.tracks.map(t => t.kind), ['audio']);
});
test('later video drops create overlay lanes above main, in draw order', () => {
  const p = newProject();
  addTrackForType(p, 'video'); addTrackForType(p, 'video'); addTrackForType(p, 'image');
  assert.deepEqual(p.tracks.map(t => t.kind), ['main','overlay','overlay']);
});
test('audio lanes stay after overlays in draw order', () => {
  const p = newProject();
  addTrackForType(p, 'video'); addTrackForType(p, 'audio'); addTrackForType(p, 'video');
  assert.deepEqual(p.tracks.map(t => t.kind), ['main','overlay','audio']);
});
test('laneRows shows overlays reversed above main, audio below', () => {
  const p = newProject();
  addTrackForType(p, 'video');
  const o1 = addTrackForType(p, 'video');
  const o2 = addTrackForType(p, 'video');
  const a  = addTrackForType(p, 'audio');
  assert.deepEqual(laneRows(p).map(t => t.id), [o2, o1, p.tracks[0].id, a]);
});
test('pruneEmptyTracks drops lanes with no clips but keeps populated ones', () => {
  const p = newProject();
  const main = addTrackForType(p, 'video');
  addTrackForType(p, 'audio');
  const asset = addAsset(p, {path:'x.mp4', type:'video', naturalW:1080, naturalH:1920, duration:5});
  addClip(p, main, {assetId: asset, start:0, in:0, duration:5});
  pruneEmptyTracks(p);
  assert.deepEqual(p.tracks.map(t => t.kind), ['main']);
});
```

- [ ] **Step 2: Run** `npm test` — expect failures.
- [ ] **Step 3: Implement** `newProject` (empty `tracks`), `addTrackForType`, `pruneEmptyTracks`, `laneRows` in `model.js`.
- [ ] **Step 4: Update the two existing test files** — `model.test.js`'s "3 tracks" assertion becomes "no tracks", and its `addClip` case creates a lane first; `timeline.test.js`'s `mainProj()` calls `addTrackForType(p,'video')` instead of `p.tracks[0]`.
- [ ] **Step 5: Run** `npm test` — expect all pass.
- [ ] **Step 6: Render lanes and strips.** `_renderTracks` iterates `laneRows(project)`; when the project has no tracks it renders a single full-height `.timeline-empty` drop area reading "Drag material here"; otherwise it renders a `.drop-strip` before the first row and another after the last. Strips and the empty area accept `dragover`/`drop`.
- [ ] **Step 7: Route drops by asset type.** A drop on a strip or the empty area calls `addTrackForType(project, info.type)` and then `addAssetAndClip(info, newTrackId, dropTime)`. Drops on an existing lane behave as today.
- [ ] **Step 8: Prune on mouseup.** At the end of `_startClipDrag`'s `onUp`, call `pruneEmptyTracks(project)` then `commit()` — never during `onMove`.
- [ ] **Step 9: Allow dragging a clip onto a strip** to move it into a fresh lane of the matching kind.
- [ ] **Step 10: Remove the add-track buttons** from `editor.html` and their handlers from `app.js`; delete the three hard-coded `.track` divs from `#tracks`.
- [ ] **Step 11: Style** `.drop-strip` (18 px, dashed border, brightens on dragover) and `.timeline-empty` in `editor.css`.
- [ ] **Step 12: Prune on load** — after `projectLoaded`, call `pruneEmptyTracks` so old three-lane projects open clean.
- [ ] **Step 13: Verify** — empty timeline shows one drop area; dropping a video makes a main lane; dropping another on the top strip makes an overlay lane; dragging that clip away removes the lane; export still works.
- [ ] **Step 14: Commit** `feat(editor): CapCut-style lanes created by dropping, removed when empty`

---

### Task 11: Undo and redo

**Files:**
- Create: `editor/js/history.js`
- Create: `editor/tests/history.test.js`
- Modify: `editor/js/app.js` — history wiring + key handler
- Modify: `editor/js/timeline-ui.js` — `pushHistory` at gesture start
- Modify: `editor/js/inspector.js` — `pushHistory` before a property commit

**Interfaces:**
- Produces (`history.js`):
  - `class History { constructor(limit = 50); push(state); undo(current) -> state|null; redo(current) -> state|null; canUndo(); canRedo(); clear(); }`
  - States are deep-cloned on the way in and on the way out.

- [ ] **Step 1: Write the failing tests**

```js
import { test } from 'node:test'; import assert from 'node:assert';
import { History } from '../js/history.js';

test('undo returns the pushed state and redo returns the current one', () => {
  const h = new History();
  h.push({ v: 1 });
  const undone = h.undo({ v: 2 });
  assert.deepEqual(undone, { v: 1 });
  assert.deepEqual(h.redo(undone), { v: 2 });
});
test('undo returns null with nothing to undo', () => {
  assert.equal(new History().undo({ v: 1 }), null);
});
test('a new push clears the redo stack', () => {
  const h = new History();
  h.push({ v: 1 }); h.undo({ v: 2 });
  h.push({ v: 3 });
  assert.equal(h.canRedo(), false);
});
test('states are deep-cloned so later mutation cannot corrupt history', () => {
  const h = new History();
  const s = { tracks: [{ clips: [] }] };
  h.push(s);
  s.tracks[0].clips.push('mutated');
  assert.deepEqual(h.undo({}).tracks[0].clips, []);
});
test('the stack is capped at its limit', () => {
  const h = new History(3);
  for (let i = 0; i < 10; i++) h.push({ i });
  let n = 0; let cur = { i: 99 };
  while (h.canUndo()) { cur = h.undo(cur); n++; }
  assert.equal(n, 3);
});
test('multiple undos walk back in order', () => {
  const h = new History();
  h.push({ v: 1 }); h.push({ v: 2 });
  assert.deepEqual(h.undo({ v: 3 }), { v: 2 });
  assert.deepEqual(h.undo({ v: 2 }), { v: 1 });
});
```

- [ ] **Step 2: Run** `npm test` — expect failure.
- [ ] **Step 3: Implement `History`** using `structuredClone`.
- [ ] **Step 4: Run** `npm test` — expect pass.
- [ ] **Step 5: Wire it into `app.js`** — `app.history = new History(50)`; `app.pushHistory()` pushes a clone of `project`; `app.applyState(state)` swaps `project`, calls `preview.setProject`, re-renders, and restores the selection when the clip still exists (otherwise `inspector.clear()`).
- [ ] **Step 6: Push one snapshot per gesture** — at the top of `_startClipDrag` and `_startTrim` (on mousedown, before any mutation), and in the split, delete, drop/add, lane-create and lane-remove paths.
- [ ] **Step 7: Push before inspector edits** — in `inspector.js`, snapshot on the field's first change of a focus session.
- [ ] **Step 8: Add the key handler** — `document.addEventListener('keydown')`; ignore when `e.target` is `INPUT`, `TEXTAREA` or `[contenteditable]`; `Ctrl/Cmd+Z` → undo, `Ctrl+Shift+Z` or `Ctrl+Y` → redo; `preventDefault()` on both.
- [ ] **Step 9: Verify** — drag a clip, Ctrl+Z restores its position in one step; split, delete, and lane creation all undo; Ctrl+Shift+Z redoes.
- [ ] **Step 10: Commit** `feat(editor): undo/redo with Ctrl+Z and Ctrl+Shift+Z`

---

### Task 12: Documentation and full test sweep

**Files:**
- Modify: `README.txt`

- [ ] **Step 1: Update `README.txt`** — reordering the video list (drag or Alt+Arrow, and that it sets processing order), the caption Position control, Ctrl+B in Edit captions, and the editor's Fit button, drag-to-create lanes, and undo/redo shortcuts.
- [ ] **Step 2: Run the whole suite** — `npm test` in `editor/`, and `Invoke-Pester -Path tests/` plus `Invoke-Pester -Path editor/tests/`.
- [ ] **Step 3: Launch the app** and walk every changed surface once.
- [ ] **Step 4: Commit** `docs: README for reordering, caption position, Ctrl+B, editor lanes/undo/fit`

---

## Self-Review

**Spec coverage:** A1→T1, A2→T3a (music preview — see note), A3→T2+T3, A4→T4, A5→T5, A6→T6, B1→T7, B2→T8, B3→T9, B4→T10, B5→T11, testing→T12.

**Gap found and fixed:** spec item A2 (preview music from the picker) had no task. It is added as **Task 3a** below, sequenced before Task 3 so the two `Studio.ps1` edits do not overlap.

---

### Task 3a: Preview a track from the music picker

**Files:**
- Modify: `Studio.ps1` — `Show-MusicDialog`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Add one shared player** — `$player = New-Object System.Windows.Media.MediaPlayer` scoped to the dialog, plus `$script:musPlayingRow = $null`.
- [ ] **Step 2: Add a play button per row** — a 32 px-wide `▶` button between the label and the combo box, stored in a `$playMap` keyed by video name.
- [ ] **Step 3: Implement toggle** — clicking stops any current playback and resets its button to `▶`; if the clicked row was not the playing one and its combo is not `(none)`, `$player.Open((New-Object System.Uri (Join-Path $MusicDir $selected)))` then `$player.Play()`, and set that button to `■`.
- [ ] **Step 4: Reset on end** — `$player.Add_MediaEnded({ ... })` stops and restores the glyph.
- [ ] **Step 5: Stop on change and close** — the combo's `SelectionChanged` stops playback for that row; `$w.Add_Closing` stops and closes the player.
- [ ] **Step 6: Disable on `(none)`** — set `IsEnabled` from the combo's selection, initially and on every change.
- [ ] **Step 7: Verify** — preview two tracks in a row and confirm only one plays, and that closing the dialog silences it.
- [ ] **Step 8: Commit** `feat(music): preview any track from the background-music picker`

---

**Placeholder scan:** clean — no TBDs; every code step carries real code or an exact edit description.

**Type consistency:** `Get-OrderedVideos`, `Save-VideoOrder`, `Get-CaptionPlacement`, `Invoke-ToggleEmphasis`, `addTrackForType`, `pruneEmptyTracks`, `laneRows`, `fitPxPerSec`, `zoomBucket`, `History` are each defined once and referenced with the same names and shapes throughout.

**Execution order:** 1 → 2 → 3a → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12.
