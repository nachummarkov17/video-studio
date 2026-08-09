// broll.test.js - the trim selection you set before a b-roll clip is added.
import { test } from 'node:test'; import assert from 'node:assert';
import { clampSelection, PHOTO_DEFAULT_SEC, MIN_SELECTION_SEC } from '../js/broll.js';

test('a fresh selection is the whole clip', () => {
  assert.deepEqual(clampSelection({ in: 0, out: 10 }, 10), { in: 0, out: 10 });
});
test('the out point cannot pass the end of the source', () => {
  assert.deepEqual(clampSelection({ in: 2, out: 99 }, 10), { in: 2, out: 10 });
});
test('the in point cannot go below zero', () => {
  assert.deepEqual(clampSelection({ in: -5, out: 6 }, 10), { in: 0, out: 6 });
});
test('dragging the in handle past the out handle keeps a minimum length', () => {
  const s = clampSelection({ in: 9.9, out: 5 }, 10);
  assert.ok(s.in < s.out, 'in stays before out');
  assert.ok(Math.abs((s.out - s.in) - MIN_SELECTION_SEC) < 1e-9, 'and they are the minimum apart');
});
test('dragging the out handle past the in handle keeps a minimum length', () => {
  const s = clampSelection({ in: 4, out: 4 }, 10);
  assert.ok(s.out > s.in);
  assert.ok(Math.abs((s.out - s.in) - MIN_SELECTION_SEC) < 1e-9);
});
test('a selection at the very end still fits inside the source', () => {
  const s = clampSelection({ in: 10, out: 10 }, 10);
  assert.ok(s.out <= 10 && s.in >= 0 && s.in < s.out);
});
test('a zero-length source degrades gracefully rather than throwing', () => {
  const s = clampSelection({ in: 0, out: 0 }, 0);
  assert.ok(s.out >= s.in);
});
test('photos default to five seconds', () => {
  assert.equal(PHOTO_DEFAULT_SEC, 5);
});
