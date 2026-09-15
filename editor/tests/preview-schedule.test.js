import test from 'node:test';
import assert from 'node:assert/strict';
import { installFakeDom, makeCanvas } from './fake-dom.js';

installFakeDom();
const { Preview } = await import('../js/preview.js');

// The user's actual saved project: one source, cut into two pieces that are
// nowhere near each other in the original. Crossing the join used to freeze for
// a second or two because the single shared <video> had to seek from ~78s to
// ~230s at the moment the cut arrived.
function twoCutProject() {
  return {
    canvas: { width: 1080, height: 1920, fps: 30 },
    assets: [{ id: 'a1', path: 'output/IMG_4923.mp4', type: 'video', duration: 243.4 }],
    tracks: [{
      id: 't1', kind: 'main', clips: [
        { id: 'c1', assetId: 'a1', start: 0, in: 4.9, duration: 73.1 },
        { id: 'c2', assetId: 'a1', start: 73.1, in: 230.4, duration: 12.1 },
      ],
    }],
  };
}

const build = () => {
  const project = twoCutProject();
  const preview = new Preview(makeCanvas(), project, () => 'https://studio.media/output/IMG_4923.mp4');
  return { project, preview };
};

test('the next clip is pre-rolled onto its in-point before the cut arrives', () => {
  const { preview } = build();
  preview.setTime(71.5);                       // 1.6s before the join
  const next = preview.pool.get('c2');
  assert.ok(next, 'the upcoming clip has its own element');
  assert.equal(next.el.currentTime, 230.4, 'parked exactly on its first frame');
  assert.equal(next.el.paused, true, 'and not playing yet');
  assert.equal(next.el.preload, 'auto', 'and buffering');
});

test('crossing the cut costs a play(), not a seek', () => {
  const { preview } = build();
  preview.setTime(71.5);                       // pre-roll happens here
  const next = preview.pool.get('c2');
  next.el.readyState = 4;
  const seeksBeforeTheCut = next.el.seekCount;

  preview.playing = true;
  preview._schedule(73.11, true);              // one frame past the join

  assert.equal(next.el.seekCount, seeksBeforeTheCut,
    'the incoming clip was already in the right place - no seek at the cut');
  assert.equal(next.el.paused, false, 'it just started playing');
});

test('a clip too far ahead is not pre-rolled - we do not buffer the whole project', () => {
  const { preview } = build();
  preview.setTime(10);
  assert.equal(preview.pool.get('c2'), null);
});

test('elements are released once their clip is well behind the playhead', () => {
  const { preview } = build();
  preview.setTime(10);
  assert.ok(preview.pool.get('c1'));
  preview.setTime(80);                          // c1 is over
  assert.equal(preview.pool.get('c1'), null);
  assert.ok(preview.pool.get('c2'));
});

test('scrubbing never touches the elements', () => {
  const { preview } = build();
  preview.setTime(10);
  const el = preview.pool.get('c1').el;
  const seeks = el.seekCount;
  preview.setScrubbing(true);
  for (let t = 10; t < 40; t += 0.4) preview.setTime(t);   // a long drag
  assert.equal(el.seekCount, seeks, 'not one seek while dragging');
});

test('letting go of a scrub fetches the exact frame, once', () => {
  const { preview } = build();
  preview.setTime(10);
  preview.setScrubbing(true);
  preview.setTime(40);
  preview.setScrubbing(false);
  const el = preview.pool.get('c1').el;
  assert.ok(Math.abs(el.currentTime - (4.9 + 40)) < 0.001, 'landed on the right frame');
  assert.equal(el.seekCount, 1, 'a whole drag cost exactly one seek');
});

test('until the real frame lands, the canvas is told to stand in for it', () => {
  const { preview } = build();
  preview.setTime(10);
  const entry = preview.pool.get('c1');
  entry.el.readyState = 0;                     // nothing decoded here yet
  assert.equal(preview._layers(10)[0].exact, false, 'draw a proxy frame');
  entry.el.readyState = 2;
  entry.el.currentTime = 4.9 + 10;
  assert.equal(preview._layers(10)[0].exact, true, 'now draw the real one');
});

test('an empty timeline draws nothing and blows up on nothing', () => {
  const empty = { canvas: { width: 100, height: 100, fps: 30 }, assets: [], tracks: [] };
  const preview = new Preview(makeCanvas(), empty, () => '');
  preview.setTime(5);
  assert.deepEqual(preview._layers(5), []);
});

test('audio lanes contribute sound but no picture', () => {
  const project = twoCutProject();
  project.assets.push({ id: 'a2', path: 'music.mp3', type: 'audio', duration: 60 });
  project.tracks.push({ id: 't2', kind: 'audio', clips: [{ id: 'm1', assetId: 'a2', start: 0, in: 0, duration: 60 }] });
  const preview = new Preview(makeCanvas(), project, (id) => 'https://studio.media/' + id);
  preview.setTime(5);
  assert.equal(preview._layers(5).length, 1, 'only the main video is drawn');
  assert.ok(preview.pool.get('m1'), 'but the music still has an element');
});
