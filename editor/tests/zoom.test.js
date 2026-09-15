import test from 'node:test';
import assert from 'node:assert/strict';
import {
  ZOOM_MIN, ZOOM_MAX, ZOOM_FACTOR, clampZoom, zoomBy, fitPxPerSec,
  tailPaddingSec, tickStep, playheadAfterRipple,
} from '../js/timeline.js';

// The complaint this exists for: "Can't zoom out enough to see videos longer
// than 3 minutes so the Fit button doesn't work either."
test('a four-minute clip fits in a normal-sized timeline', () => {
  const viewport = 1100;                 // roughly what the window gives it
  const fitted = fitPxPerSec(viewport, 243 + tailPaddingSec(243));
  assert.ok(fitted > ZOOM_MIN, 'not pinned to the floor');
  assert.ok(fitted * (243 + tailPaddingSec(243)) <= viewport + 1, 'the whole clip fits');
});

test('even an hour fits', () => {
  const fitted = fitPxPerSec(900, 3600);
  assert.ok(fitted >= ZOOM_MIN);
  assert.ok(fitted * 3600 <= 901);
});

test('fit never exceeds the zoom ceiling on a very short clip', () => {
  assert.equal(fitPxPerSec(1100, 0.5), ZOOM_MAX);
});

test('fit falls back to the floor with nothing on the timeline', () => {
  assert.equal(fitPxPerSec(1100, 0), ZOOM_MIN);
  assert.equal(fitPxPerSec(0, 100), ZOOM_MIN);
});

test('zoom is geometric, so it works at both ends of the range', () => {
  assert.ok(Math.abs(zoomBy(100, ZOOM_FACTOR) - 135) < 0.001);
  assert.ok(Math.abs(zoomBy(1, ZOOM_FACTOR) - 1.35) < 0.001);
  // and zooming out from a low level still moves, which +/-20 px/s could not
  assert.ok(zoomBy(1, 1 / ZOOM_FACTOR) < 1);
});

test('zoom clamps to its range', () => {
  assert.equal(zoomBy(ZOOM_MAX, 4), ZOOM_MAX);
  assert.equal(zoomBy(ZOOM_MIN, 1 / 100), ZOOM_MIN);
  assert.equal(clampZoom(0), ZOOM_MIN);
  assert.equal(clampZoom(NaN), ZOOM_MIN);
});

test('zoom in then out returns you to where you were', () => {
  const start = 60;
  assert.ok(Math.abs(zoomBy(zoomBy(start, ZOOM_FACTOR), 1 / ZOOM_FACTOR) - start) < 1e-9);
});

test('tail padding scales with the project instead of being a flat 10s', () => {
  assert.equal(tailPaddingSec(4), 1);          // a 4s project is not given 10s of blank
  assert.ok(Math.abs(tailPaddingSec(240) - 4.8) < 1e-9);
  assert.equal(tailPaddingSec(3600), 10);      // and never more than 10s
});

test('ruler labels stay readable at every zoom', () => {
  for (const pps of [ZOOM_MIN, 0.5, 1, 5, 10, 40, 100, 400, ZOOM_MAX]) {
    const step = tickStep(pps);
    const gap = step * pps;
    assert.ok(gap >= 20, `labels at ${pps}px/s would be ${gap}px apart`);
  }
});

test('an hour-long timeline does not emit thousands of ticks when zoomed out', () => {
  const ticks = 3600 / tickStep(ZOOM_MIN);
  assert.ok(ticks <= 12, `got ${ticks} ticks`);
});

test('zoomed right in, ticks are one second apart', () => {
  assert.equal(tickStep(200), 1);
});

// The complaint: "After doing a cut, the playhead should move with the video
// instead of just staying where it is."
test('deleting ahead of the playhead leaves it alone', () => {
  assert.equal(playheadAfterRipple(5, 10, -3), 5);
});

test('deleting behind the playhead pulls it back with the picture', () => {
  // 3s removed at t=10; the frame that was at 20 is now at 17
  assert.equal(playheadAfterRipple(20, 10, -3), 17);
});

test('a playhead inside the removed span lands on the join', () => {
  assert.equal(playheadAfterRipple(11, 10, -3), 10);
  assert.equal(playheadAfterRipple(12.9, 10, -3), 10);
});

test('lengthening a clip pushes the playhead along with the content', () => {
  assert.equal(playheadAfterRipple(20, 10, 4), 24);
});

test('no ripple, no move', () => {
  assert.equal(playheadAfterRipple(20, 10, 0), 20);
  assert.equal(playheadAfterRipple(20, 10, undefined), 20);
});

test('the playhead never goes behind the edit point', () => {
  assert.equal(playheadAfterRipple(10.5, 10, -100), 10);
});
