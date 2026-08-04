# Editor lag audit

Date: 2026-08-04

A full pass over every path that can stall the editor, with measurements, the
fixes, and the guardrails that keep it from regressing.

## Method

`editor/tests/manual/audit-probe.html` builds a deliberately heavy project — 48
clips, 6 sources, 4 lanes — and times every hot path against a budget. It also
asserts the I/O invariants that the timings can't see. It fails loudly, so it
serves as a regression gate rather than a report.

## Findings

### The JavaScript was never the problem (any more)

Every per-frame and per-edit path measures far inside budget:

| path | measured | budget |
|---|---|---|
| `timeline.render()` (full rebuild) | 1.0 ms | 8 ms |
| `timeline.renderGeometry()` (drag) | 0.06 ms | 1 ms |
| `timeline.setPlayhead()` | 0.001 ms | 0.2 ms |
| `preview.setTime()` (scrub frame) | 0.02 ms | 2 ms |
| `preview._updateMedia()` (per frame) | 0.05 ms | 1 ms |
| `preview._drawVisual()` (per frame) | 0.006 ms | 3 ms |
| `app.pushHistory()` (per gesture) | 0.14 ms | 5 ms |
| `app.commit()` (per edit) | 0.9 ms | 10 ms |

A 60 Hz frame is 16.7 ms. Nothing here is close.

**All remaining lag was I/O and video decoding.** That is where the audit went.

### 1. Every source buffered its whole file, always (biggest remaining stall)

Every `<video>` was created with `preload="auto"`. Adding a clip therefore
started a full download-and-buffer of that source through the WebView2 virtual
host — and every source stayed buffering for the life of the session,
concurrently. With phone clips of a few hundred MB each, that alone accounts for
the stalls and audio dropouts that survived the earlier rounds.

**Fix.** Elements are created `preload="metadata"`. A prefetch window promotes
only assets with a clip inside `[t-1s, t+4s]` to `preload="auto"` and demotes
everything else as the playhead moves.

Verified: at `t=0`, 2 of 6 sources buffer; mid-project, 4 of 6; parked past the
end of the project, **0**.

### 2. Filmstrips were rebuilt from scratch on every launch

The strip cache was in memory only. Every time the editor opened, every asset
was decoded again — a full pass with ~28 seeks per source, serialised, so
startup got worse with every clip added.

**Fix.** Strips and media-bin posters are persisted by the host to
`work\thumb-cache\`, keyed by the clip's path **and its last-write time**, and
referenced by URL. A clip is decoded once, ever; re-editing a clip invalidates
just that clip. Referencing a file instead of a ~150 KB base64 data URL also
keeps them out of the JS heap and lets the browser cache the decoded image.

Covered by `tests/ThumbCache.Tests.ps1`.

### 3. Export froze the whole studio window

`ffmpeg` was invoked inline inside the WebView2 message handler, which runs on
the WPF UI thread. The entire Studio window was blocked for the duration of a
render, and no progress could be posted back.

**Fix.** ffmpeg runs out of process and a `DispatcherTimer` watches for it to
exit, then reports the result. The window stays live throughout.

### 4. Releasing a scrub waited an extra debounce

`setScrubbing(false)` went through the debounced refine, so the exact frame
arrived 130 ms after you let go. Release now refines immediately; the debounce
remains for bursts of edits, which is what it was for.

## Invariants now enforced by the probe

- A 60-step scrub issues **zero** decoder seeks (frames come from the filmstrip).
- Letting go fetches the exact frame immediately.
- 10 rapid edits issue **zero** immediate seeks — they collapse into one.
- Sources buffer in full only near the playhead; none when the playhead is past
  the end of the project.

## Architecture, stated plainly

The editor now has two clearly separated frame sources, which is what makes it
feel immediate:

- **Proxy path** — the filmstrip, decoded once and cached to disk. Drives the
  timeline thumbnails and every frame shown while scrubbing or dragging. Costs
  nothing at interaction time.
- **Decoder path** — the real `<video>` elements. Used for playback, and for a
  single exact frame when you settle. Never touched during a gesture.

The rule to keep: **no gesture may touch the decoder path.** Anything that has
to feel instant reads from the proxy; the decoder is only asked once the user
has stopped moving.
