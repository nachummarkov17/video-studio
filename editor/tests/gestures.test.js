import test from 'node:test';
import assert from 'node:assert/strict';
import { installFakeDom } from './fake-dom.js';

installFakeDom();
const { TimelineGestures } = await import('../js/timeline-gestures.js');

// "if I cut off 1 second, it should move back 1 second so the playhead is
// before the same section as it was before the cut."
//
// The playhead is a pointer into the CONTENT, not into the ruler. Any edit that
// slides the content has to slide the playhead with it, or the frame you were
// watching moves out from under the line.

// Two 10s pieces of one source, laid out gapless on the magnetic main track.
function project() {
  return {
    canvas: { width: 100, height: 100, fps: 30 },
    assets: [{ id: 'a1', path: 'clip.mp4', type: 'video', duration: 60 }],
    tracks: [{
      id: 't1', kind: 'main', clips: [
        { id: 'c1', assetId: 'a1', start: 0,  in: 0,  duration: 10 },
        { id: 'c2', assetId: 'a1', start: 10, in: 30, duration: 10 },
      ],
    }],
  };
}

// A timeline stand-in: 100px per second, no DOM.
function harness(playhead) {
  const app = {
    project: project(),
    playhead,
    snapping: false,           // isolate the playhead maths from the magnets
    selectedId: null,
    pushHistory() {},
    commit() { this.commits = (this.commits || 0) + 1; },
  };
  const tl = {
    pxPerSec: 100,
    clientXToTime: (x) => x / 100,
    renderGeometry() {},
    setSnapIndicator() {},
    select(id) { app.selectedId = id; },
    setPlayhead(t) { app.playhead = t; },
    snapped: (t) => t,
  };
  const g = new TimelineGestures(tl, app);
  tl.snapped = (t, id) => g.snapped(t, id);
  return { app, tl, g };
}

const clipOf = (app, id) => app.project.tracks[0].clips.find(c => c.id === id);

// Press on the edge at `fromSec`, drag to `toSec`, let go.
function trim(h, clipId, edge, fromSec, toSec) {
  h.g.startTrim({ preventDefault() {}, clientX: fromSec * 100, clientY: 0 }, clipId, edge);
  document.fire('mousemove', { clientX: toSec * 100, clientY: 0 });
  document.fire('mouseup', {});
}

test('trimming 1s off the END: the playhead beyond it comes back 1s', () => {
  const h = harness(15);                      // 5s into the second piece
  trim(h, 'c1', 'R', 10, 9);                  // c1 now 0..9, c2 slides to 9..19
  assert.equal(clipOf(h.app, 'c1').duration, 9);
  assert.equal(clipOf(h.app, 'c2').start, 9);
  assert.equal(h.app.playhead, 14, 'the same frame is still under the playhead');
});

test('trimming 1s off the FRONT: the playhead inside that clip comes back 1s too', () => {
  // The bug this test exists for. A left trim ripples the clip's start back to
  // where it was, so EVERYTHING in the clip shifts - including whatever the
  // playhead was sitting on. Using the clip's END as the edit point (as the
  // first version did) left the playhead parked on a different shot.
  const h = harness(5);                       // 5s into the first piece
  trim(h, 'c1', 'L', 0, 1);                   // drop the first second
  const c1 = clipOf(h.app, 'c1');
  assert.equal(c1.start, 0, 'ripple pulls it back against the start');
  assert.equal(c1.in, 1, 'and it now starts one second later in the source');
  assert.equal(c1.duration, 9);
  assert.equal(h.app.playhead, 4, 'the frame that was at 5s is at 4s now, and so is the playhead');
});

test('trimming the front also carries the playhead in LATER clips', () => {
  const h = harness(15);
  trim(h, 'c1', 'L', 0, 1);
  assert.equal(h.app.playhead, 14);
});

test('a playhead BEFORE the edit is left exactly where it is', () => {
  const h = harness(2);
  trim(h, 'c2', 'R', 20, 19);                 // edit is at 19s, playhead at 2s
  assert.equal(h.app.playhead, 2);
});

test('a playhead inside the part you trimmed away lands on the new edge', () => {
  const h = harness(9.5);
  trim(h, 'c1', 'R', 10, 9);
  assert.equal(h.app.playhead, 9);
});

test('lengthening a clip again pushes the playhead back out with the content', () => {
  const h = harness(15);
  trim(h, 'c1', 'R', 10, 9);
  assert.equal(h.app.playhead, 14);
  trim(h, 'c1', 'R', 9, 10);                  // put the second back
  assert.equal(h.app.playhead, 15, 'and we are back where we started');
});

test('a free (non-magnetic) lane does not move the playhead - nothing rippled', () => {
  const h = harness(15);
  h.app.project.tracks[0].kind = 'overlay';
  trim(h, 'c1', 'R', 10, 9);
  assert.equal(h.app.playhead, 15);
});

test('grabbing a handle does not teleport the edge to the cursor', () => {
  // You grab a 10px handle somewhere in its width; the edge must move by how far
  // you DRAG, not jump to wherever you happened to press.
  const h = harness(0);
  // press 4px to the LEFT of the 10s edge (inside the handle), then don't move
  h.g.startTrim({ preventDefault() {}, clientX: 996, clientY: 0 }, 'c1', 'R');
  document.fire('mousemove', { clientX: 996, clientY: 0 });
  document.fire('mouseup', {});
  assert.equal(clipOf(h.app, 'c1').duration, 10, 'the edge stayed put');
});
