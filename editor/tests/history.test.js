// history.test.js - the undo/redo stack behind Ctrl+Z / Ctrl+Shift+Z.
import { test } from 'node:test'; import assert from 'node:assert';
import { History } from '../js/history.js';

test('undo returns the pushed state and redo returns the current one', () => {
  const h = new History();
  h.push({ v: 1 });
  const undone = h.undo({ v: 2 });
  assert.deepEqual(undone, { v: 1 });
  assert.deepEqual(h.redo(undone), { v: 2 });
});

test('undo returns null when there is nothing to undo', () => {
  assert.equal(new History().undo({ v: 1 }), null);
});

test('redo returns null when there is nothing to redo', () => {
  const h = new History();
  h.push({ v: 1 });
  assert.equal(h.redo({ v: 2 }), null);
});

test('a new push clears the redo stack', () => {
  const h = new History();
  h.push({ v: 1 });
  h.undo({ v: 2 });
  assert.equal(h.canRedo(), true);
  h.push({ v: 3 });
  assert.equal(h.canRedo(), false);
});

test('states are deep-cloned, so later mutation cannot corrupt history', () => {
  const h = new History();
  const s = { tracks: [{ clips: [] }] };
  h.push(s);
  s.tracks[0].clips.push('mutated');
  assert.deepEqual(h.undo({}).tracks[0].clips, []);
});

test('the undo stack is capped at its limit', () => {
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

test('undo then redo then undo lands back on the same state', () => {
  const h = new History();
  h.push({ v: 1 });
  const a = h.undo({ v: 2 });
  h.redo(a);
  assert.deepEqual(h.undo({ v: 2 }), { v: 1 });
});

test('clear empties both stacks', () => {
  const h = new History();
  h.push({ v: 1 }); h.undo({ v: 2 });
  h.clear();
  assert.equal(h.canUndo(), false);
  assert.equal(h.canRedo(), false);
});
