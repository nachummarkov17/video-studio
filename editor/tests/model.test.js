import { test } from 'node:test'; import assert from 'node:assert';
import { newProject, addAsset, addClip, findClip, addTrackForType, PRESETS } from '../js/model.js';

test('newProject makes a 9:16 canvas and no lanes yet', () => {
  const p = newProject();
  assert.equal(p.canvas.width, 1080); assert.equal(p.canvas.height, 1920);
  assert.deepEqual(p.tracks, []);   // lanes appear when you drop something in
});
test('addAsset then addClip links them and clip is findable', () => {
  const p = newProject();
  const a = addAsset(p, {path:'output/x.mp4', type:'video', naturalW:1080, naturalH:1920, duration:10});
  const main = addTrackForType(p, 'video');
  const c = addClip(p, main, {assetId:a, start:0, in:0, duration:4});
  const { clip, track } = findClip(p, c);
  assert.equal(track.kind, 'main'); assert.equal(clip.duration, 4); assert.equal(clip.assetId, a);
});
test('preset switches dimensions', () => {
  assert.equal(PRESETS['16:9'].width, 1920);
});
