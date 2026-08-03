// lanes.test.js - CapCut-style lanes: nothing is pre-drawn, lanes come into
// existence when you drop something and disappear when their last clip leaves.
import { test } from 'node:test'; import assert from 'node:assert';
import { newProject, addAsset, addClip, addTrackForType, pruneEmptyTracks, laneRows } from '../js/model.js';

test('a new project starts with no lanes at all', () => {
  assert.deepEqual(newProject().tracks, []);
});

test('the first video drop creates the main lane', () => {
  const p = newProject();
  const id = addTrackForType(p, 'video');
  assert.equal(p.tracks.length, 1);
  assert.equal(p.tracks[0].kind, 'main');
  assert.equal(p.tracks[0].id, id);
});

test('an image counts as video for lane purposes', () => {
  const p = newProject();
  addTrackForType(p, 'image');
  assert.equal(p.tracks[0].kind, 'main');
});

test('the first audio drop creates an audio lane, not a main lane', () => {
  const p = newProject();
  addTrackForType(p, 'audio');
  assert.deepEqual(p.tracks.map(t => t.kind), ['audio']);
});

test('later video drops create overlay lanes, in draw order after main', () => {
  const p = newProject();
  addTrackForType(p, 'video'); addTrackForType(p, 'video'); addTrackForType(p, 'image');
  assert.deepEqual(p.tracks.map(t => t.kind), ['main', 'overlay', 'overlay']);
});

test('audio lanes stay last in draw order however they were added', () => {
  const p = newProject();
  addTrackForType(p, 'video'); addTrackForType(p, 'audio'); addTrackForType(p, 'video');
  assert.deepEqual(p.tracks.map(t => t.kind), ['main', 'overlay', 'audio']);
});

test('laneRows shows overlays reversed above main, audio below', () => {
  const p = newProject();
  const main = addTrackForType(p, 'video');
  const o1 = addTrackForType(p, 'video');
  const o2 = addTrackForType(p, 'video');
  const a  = addTrackForType(p, 'audio');
  assert.deepEqual(laneRows(p).map(t => t.id), [o2, o1, main, a]);
});

test('laneRows on an empty project is empty', () => {
  assert.deepEqual(laneRows(newProject()), []);
});

test('pruneEmptyTracks drops empty lanes and keeps populated ones', () => {
  const p = newProject();
  const main = addTrackForType(p, 'video');
  addTrackForType(p, 'audio');
  const asset = addAsset(p, { path: 'x.mp4', type: 'video', naturalW: 1080, naturalH: 1920, duration: 5 });
  addClip(p, main, { assetId: asset, start: 0, in: 0, duration: 5 });
  pruneEmptyTracks(p);
  assert.deepEqual(p.tracks.map(t => t.kind), ['main']);
});

test('pruneEmptyTracks cleans up an old fixed-three-lane project on load', () => {
  const p = { version: 1, name: 'old', canvas: { width: 1080, height: 1920, fps: 30 }, assets: [],
              tracks: [{ id: 't1', kind: 'main', clips: [] },
                       { id: 't2', kind: 'overlay', clips: [] },
                       { id: 't3', kind: 'audio', clips: [] }] };
  pruneEmptyTracks(p);
  assert.deepEqual(p.tracks, []);
});
