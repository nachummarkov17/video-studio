# B-roll library

Date: 2026-08-09
Status: approved

A place to keep b-roll clips and photos, get them into the editor quickly, and
trim them to the piece you actually want *before* they land on the timeline.

## Storage

A new `broll\` folder beside `music\`, created at startup like the others.

It is scanned recursively. The first path segment under `broll\` becomes a
group; files sitting directly in `broll\` fall into a group called "B-roll".
So this:

```
broll\
  skyline.mp4
  city\  traffic.mp4  crossing.mp4
  food\  coffee.jpg
```

shows as three groups: **B-roll** (skyline), **City** (traffic, crossing),
**Food** (coffee). Organising is just making folders in Explorer — there is no
tag file to keep in sync, and it works fine if you never make a subfolder.

Recognised types are the editor's existing video and image extensions. Audio in
`broll\` is ignored; music belongs to step 4.

## Getting b-roll in

A **+ B-roll** button in the media bin header opens a file picker (videos and
photos) and copies what you choose into `broll\`. Copies, so your originals are
untouched, consistent with how clips are added to the studio.

Explorer drag-and-drop onto the bin is deliberately out of scope: the editor is
a WebView2 surface, so a file dropped there arrives without a usable path and
would have to be streamed through the bridge. The button is the one way in.

## The media bin

The bin becomes two sections:

- **Your videos** — `output\` and `editor-imports\`, exactly as today.
- **B-roll** — the `broll\` library, split into its groups. Group headers
  collapse, and collapsed state is remembered for the session.

Every row keeps the preview frame it has today, generated through the existing
one-job-at-a-time queue so it can never compete with playback.

## Trimming before adding

Clicking a b-roll row opens it in the preview area — the biggest picture
available, and it reuses the player and scrubbing already there.

```
┌─ Preview ────────────────────┐
│        [ b-roll clip ]       │
├──────────────────────────────┤
│ ▶  [▐████████████████▐] 0:03 │
│    in ↑            ↑ out     │
│      [ Add to timeline ]     │
└──────────────────────────────┘
```

- A **trim bar** spans the clip's full duration with draggable **in** and **out**
  handles and a position marker. Dragging either handle scrubs the picture to
  that frame, so you can see where you're cutting.
- Play/pause plays only the selected range, looping it.
- Readouts show in, out and the selected length.
- **Photos** show the still with a **duration** box instead of a trim bar,
  defaulting to 5 seconds.
- **Add to timeline** and **Cancel**. Escape cancels.

The timeline is untouched while the panel is open; the project preview returns
when it closes.

Constraints: out is always at least 0.1s after in; both clamp to the clip's real
duration. The chosen in/out is remembered per item for the session, so an item
you trimmed once keeps that selection if you come back to it.

## Getting it onto the timeline

Two routes, both landing the *trimmed* piece:

1. **Add to timeline** — inserts at the playhead on an overlay lane above your
   main clip. It reuses the topmost existing overlay lane, and only creates a
   new one if there isn't one. B-roll is overlay footage by definition, so it
   never displaces the main track.
2. **Drag the row onto any lane** — arrives already trimmed, dropped where you
   let go. This is the existing drag path, with the trim carried in the drag
   payload.

`addAssetAndClip` gains an optional `{ in, duration }`. Without it, behaviour is
exactly as today, so every existing drop path is unaffected.

## What this does NOT change

- Music stays in step 4 only.
- The main track, the export pipeline and the render graph are untouched: a
  trimmed b-roll clip is an ordinary clip with an in-point, which the exporter
  already handles.

## Testing

- **PowerShell** (`tests/BrollLibrary.Tests.ps1`): the scan — grouping by
  subfolder, the default group for loose files, extension filtering, ignoring
  audio, a missing `broll\` folder yielding nothing.
- **JS unit** (`editor/tests/broll.test.js`): the pure trim maths — clamping in
  and out to the source, enforcing the minimum length, keeping in < out however
  the handles are dragged, and the photo duration default.
- **Browser probe**: opening the panel from a bin row, dragging the handles,
  Add landing a clip with the right `in`/`duration` on an overlay lane, and
  Cancel restoring the project preview.
