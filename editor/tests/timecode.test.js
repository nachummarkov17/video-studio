// timecode.test.js - the transport readout. It used to be a hard-coded
// "00:00:00:00" on both sides; this is the formatting behind the real numbers.
import { test } from 'node:test'; import assert from 'node:assert';
import { timecode } from '../js/timecode.js';

test('formats hours, minutes, seconds and frames', () => {
  assert.equal(timecode(0, 30), '00:00:00:00');
  assert.equal(timecode(1.5, 30), '00:00:01:15');
  assert.equal(timecode(61.25, 30), '00:01:01:07');
  assert.equal(timecode(3661, 30), '01:01:01:00');
});
test('frames follow the project frame rate', () => {
  assert.equal(timecode(0.5, 24), '00:00:00:12');
  assert.equal(timecode(0.5, 60), '00:00:00:30');
});
test('never shows a frame number at or past the frame rate', () => {
  assert.equal(timecode(0.9999, 30), '00:00:00:29');
});
test('negative and missing values read as zero', () => {
  assert.equal(timecode(-5, 30), '00:00:00:00');
  assert.equal(timecode(undefined, 30), '00:00:00:00');
  assert.equal(timecode(NaN, 30), '00:00:00:00');
});
test('falls back to 30fps when none is given', () => {
  assert.equal(timecode(1.5), '00:00:01:15');
});
