import test from 'node:test';
import assert from 'node:assert/strict';
import { overlayPlacement, OVERLAY_SIZES, OVERLAY_FRACTION } from '../js/model.js';

// "the image takes up the entire screen. I'd like a way to paste an image on
// top of the video so while I'm talking, I can have images popping here and
// there on the screen but not replacing the video."
//
// An overlay clip is drawn at its own pixel size times `scale`. With scale
// defaulting to 1, a real photo is several times wider than the canvas - so it
// covered everything. A placement is now worked out when it's added.

const CANVAS = { width: 1080, height: 1920 };     // 9:16, the working format

test('a big photo is brought down to a fraction of the frame', () => {
  const p = overlayPlacement(CANVAS, 4032, 3024);          // a phone photo
  const w = 4032 * p.scale;
  assert.ok(Math.abs(w - 1080 * OVERLAY_FRACTION) < 1, `drawn ${w}px wide`);
  assert.ok(w < CANVAS.width, 'and is narrower than the frame');
});

test('a very tall picture is capped by HEIGHT, not width', () => {
  // 9:16 canvas + a tall portrait image: sizing on width alone would run it
  // off the top and bottom.
  const p = overlayPlacement(CANVAS, 1000, 4000);
  const h = 4000 * p.scale;
  assert.ok(h <= CANVAS.height * OVERLAY_FRACTION + 1, `drawn ${h}px tall`);
});

test('it never covers the whole frame, whatever shape it is', () => {
  for (const [w, h] of [[4032, 3024], [1000, 4000], [8000, 100], [500, 500], [1080, 1920]]) {
    const p = overlayPlacement(CANVAS, w, h);
    assert.ok(w * p.scale < CANVAS.width, `${w}x${h} is too wide`);
    assert.ok(h * p.scale < CANVAS.height, `${w}x${h} is too tall`);
  }
});

test('it lands fully on screen', () => {
  const p = overlayPlacement(CANVAS, 4032, 3024);
  assert.ok(p.x >= 0 && p.y >= 0, 'not off the top or left');
  assert.ok(p.x + 4032 * p.scale <= CANVAS.width, 'not off the right');
  assert.ok(p.y + 3024 * p.scale <= CANVAS.height, 'not off the bottom');
});

test('by default it sits in the upper part, clear of burned captions', () => {
  const p = overlayPlacement(CANVAS, 4032, 3024);
  const centreY = p.y + (3024 * p.scale) / 2;
  assert.ok(centreY < CANVAS.height * 0.55, 'above the caption band');
});

test('anchors put it in any corner', () => {
  const tl = overlayPlacement(CANVAS, 1000, 1000, { anchorX: 0, anchorY: 0 });
  assert.equal(tl.x, 0);
  assert.equal(tl.y, 0);

  const br = overlayPlacement(CANVAS, 1000, 1000, { anchorX: 1, anchorY: 1 });
  assert.equal(br.x + 1000 * br.scale, CANVAS.width);
  assert.equal(br.y + 1000 * br.scale, CANVAS.height);

  const mid = overlayPlacement(CANVAS, 1000, 1000, { anchorX: 0.5, anchorY: 0.5 });
  assert.ok(Math.abs((mid.x + 500 * mid.scale) - CANVAS.width / 2) <= 1, 'centred across');
  assert.ok(Math.abs((mid.y + 500 * mid.scale) - CANVAS.height / 2) <= 1, 'centred down');
});

test('the three sizes really are three different sizes', () => {
  const s = overlayPlacement(CANVAS, 2000, 1500, { fraction: OVERLAY_SIZES.small }).scale;
  const m = overlayPlacement(CANVAS, 2000, 1500, { fraction: OVERLAY_SIZES.medium }).scale;
  const l = overlayPlacement(CANVAS, 2000, 1500, { fraction: OVERLAY_SIZES.large }).scale;
  assert.ok(s < m && m < l);
  assert.ok(2000 * l < CANVAS.width, 'even "large" leaves the video visible around it');
});

test('landscape canvases work too', () => {
  const wide = { width: 1920, height: 1080 };
  const p = overlayPlacement(wide, 4032, 3024);
  assert.ok(4032 * p.scale < wide.width);
  assert.ok(3024 * p.scale < wide.height);
});

test('media we could not measure is left alone rather than guessed at', () => {
  const p = overlayPlacement(CANVAS, 0, 0);
  assert.deepEqual(p, { scale: 1, x: 0, y: 0 });
});
