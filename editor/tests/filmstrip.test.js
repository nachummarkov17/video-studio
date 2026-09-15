import test from 'node:test';
import assert from 'node:assert/strict';
import { installFakeDom } from './fake-dom.js';

installFakeDom();
const { tileLayout } = await import('../js/thumbs.js');

// The filmstrip is what you SEE while dragging the playhead - the real video
// element is deliberately never touched mid-drag. So how many frames the strip
// holds is exactly how close the picture is to where you are pointing.
//
// "the video shows the frame I was at for an instant then shows me the correct
// place" was this: the tile count came from how wide the clip happened to be
// DRAWN, so a four-minute clip fitted to the window got ~38 tiles - one frame
// every six seconds. A short drag landed on the same tile it started on, so
// nothing appeared to move until the real frame arrived and it jumped.

const PORTRAIT = 1080 / 1920;

test('a four-minute clip is sampled at least once a second and a half', () => {
  const L = tileLayout(PORTRAIT, 1100, 243);
  assert.ok(L.secondsPerTile <= 1.5, `${L.secondsPerTile}s per tile`);
});

test('density does not depend on the zoom the strip happened to be built at', () => {
  const fitted = tileLayout(PORTRAIT, 1100, 243);      // whole clip on screen
  const zoomedIn = tileLayout(PORTRAIT, 24000, 243);   // 100px/s
  assert.equal(fitted.count, zoomedIn.count);
  assert.equal(fitted.tileW, zoomedIn.tileW);
});

test('a short clip is not padded out with hundreds of tiles', () => {
  const L = tileLayout(PORTRAIT, 1100, 4);
  assert.ok(L.count <= 12, `got ${L.count}`);
  assert.ok(L.count >= 4);
});

test('a very long clip is capped rather than growing without limit', () => {
  const L = tileLayout(PORTRAIT, 1100, 3600);
  assert.ok(L.count <= 200, `got ${L.count}`);
  assert.ok(L.count * L.tileCssW <= 14000, 'the sheet stays a sane size');
});

test('tiles keep the source shape, portrait or landscape', () => {
  const portrait = tileLayout(PORTRAIT, 1100, 60);
  const landscape = tileLayout(16 / 9, 1100, 60);
  assert.ok(portrait.tileCssW < landscape.tileCssW, 'a portrait tile is narrower');
  assert.equal(portrait.tileH, landscape.tileH, 'both are the clip-row height');
});

test('an unknown duration still produces a usable strip', () => {
  const L = tileLayout(PORTRAIT, 1100, 0);
  assert.ok(L.count >= 4);
  assert.equal(L.secondsPerTile, 0);
});

// Tile i holds the frame from ((i+0.5)/count)*duration, so picking a tile for a
// given instant is a ROUND, not a FLOOR. Flooring was biasing every proxy frame
// up to a whole tile early.
const pick = (t, dur, count) =>
  Math.max(0, Math.min(count - 1, Math.round((t / dur) * count - 0.5)));

test('the tile chosen is the nearest one, not the one before', () => {
  const dur = 100, count = 100;                 // one tile per second, centred at x.5
  assert.equal(pick(0.5, dur, count), 0, 'dead on tile 0');
  assert.equal(pick(1.4, dur, count), 1, 'nearest centre is 1.5');
  assert.equal(pick(1.6, dur, count), 1, 'still nearest 1.5, not 2.5');
  assert.equal(pick(2.1, dur, count), 2, 'past the midpoint it rounds up');
  // the old floor-based pick would have said 1 here, a whole tile early
  assert.equal(pick(2.6, dur, count), 2);
  assert.equal(pick(0, dur, count), 0);
  assert.equal(pick(100, dur, count), 99, 'the end clamps inside the strip');
});

test('the nearest tile is never more than half a tile away', () => {
  const dur = 243, count = 200;
  const perTile = dur / count;
  for (let t = 0; t <= dur; t += 0.37) {
    const i = pick(t, dur, count);
    const tileTime = ((i + 0.5) / count) * dur;
    assert.ok(Math.abs(tileTime - t) <= perTile / 2 + 1e-9,
      `at ${t}s the tile was ${Math.abs(tileTime - t)}s away`);
  }
});
