import test from 'node:test';
import assert from 'node:assert/strict';
import { installFakeDom } from './fake-dom.js';

installFakeDom();
const { MediaPool } = await import('../js/media-pool.js');

const asset = (id, path, type = 'video') => ({ id, path, type, duration: 300 });
const clip = (id, assetId) => ({ id, assetId });
const urlFor = (a) => 'https://studio.media/' + a.path;

test('two clips of the same source get their OWN element', () => {
  // This is the whole point. One element per ASSET meant a cut had to seek that
  // element from where the outgoing clip ended to where the incoming one
  // starts - minutes away in a real edit - and playback froze for the duration.
  const pool = new MediaPool(urlFor);
  const a = asset('a1', 'clip.mp4');
  const e1 = pool.bind(clip('c1', 'a1'), a);
  const e2 = pool.bind(clip('c2', 'a1'), a);
  assert.notEqual(e1, e2);
  assert.notEqual(e1.el, e2.el);
});

test('binding the same clip again is the same element, not a reload', () => {
  const pool = new MediaPool(urlFor);
  const a = asset('a1', 'clip.mp4');
  const e1 = pool.bind(clip('c1', 'a1'), a);
  const loads = e1.el.loadCount;
  const e2 = pool.bind(clip('c1', 'a1'), a);
  assert.equal(e1, e2);
  assert.equal(e2.el.loadCount, loads);
});

test('a released element is reused for the same source without reloading it', () => {
  const pool = new MediaPool(urlFor);
  const a = asset('a1', 'clip.mp4');
  const first = pool.bind(clip('c1', 'a1'), a);
  const el = first.el;
  const loads = el.loadCount;
  pool.release('c1');
  const second = pool.bind(clip('c2', 'a1'), a);
  assert.equal(second.el, el, 'the pooled element came back');
  assert.equal(second.el.loadCount, loads, 'and was not re-sourced');
});

test('releasing pauses and stops the element buffering', () => {
  const pool = new MediaPool(urlFor);
  const e = pool.bind(clip('c1', 'a1'), asset('a1', 'clip.mp4'));
  e.el.preload = 'auto';
  e.el.paused = false;
  pool.release('c1');
  assert.equal(e.el.paused, true);
  assert.equal(e.el.preload, 'metadata');
  assert.equal(pool.get('c1'), null);
});

test('retain keeps what is needed and releases the rest', () => {
  const pool = new MediaPool(urlFor);
  const a = asset('a1', 'clip.mp4');
  pool.bind(clip('c1', 'a1'), a);
  pool.bind(clip('c2', 'a1'), a);
  pool.bind(clip('c3', 'a1'), a);
  pool.retain(new Set(['c2']));
  assert.equal(pool.get('c1'), null);
  assert.ok(pool.get('c2'));
  assert.equal(pool.get('c3'), null);
});

test('the pool is capped so a long project cannot hold a decoder per clip', () => {
  const pool = new MediaPool(urlFor);
  const a = asset('a1', 'clip.mp4');
  const els = new Set();
  for (let i = 0; i < 30; i++) {
    const e = pool.bind(clip('c' + i, 'a1'), a);
    if (e) els.add(e.el);
  }
  assert.ok(els.size <= 6, `held ${els.size} elements`);
});

test('a seek within a frame of where we already are is not a seek at all', () => {
  const pool = new MediaPool(urlFor);
  const e = pool.bind(clip('c1', 'a1'), asset('a1', 'clip.mp4'));
  pool.seek(e, 10);
  assert.equal(e.el.seekCount, 1);
  pool.seek(e, 10.01);                       // 10ms away: not worth a round trip
  assert.equal(e.el.seekCount, 1);
});

test('seeks are coalesced - one in flight, and a newer target replaces a pending one', () => {
  const pool = new MediaPool(urlFor);
  const e = pool.bind(clip('c1', 'a1'), asset('a1', 'clip.mp4'));
  pool.seek(e, 10);
  e.el.seeking = true;
  pool.seek(e, 20);
  pool.seek(e, 30);
  assert.equal(e.el.seekCount, 1, 'nothing queued behind the one in flight');
  assert.equal(e.pending, 30, 'only the newest target survives');

  e.el.seeking = false;
  e.el.emit('seeked');
  assert.equal(e.el.currentTime, 30, 'and it goes straight there, skipping 20');
  assert.equal(e.el.seekCount, 2);
});

test('frameIsAt only trusts an element that is loaded, still, and in the right place', () => {
  const pool = new MediaPool(urlFor);
  const e = pool.bind(clip('c1', 'a1'), asset('a1', 'clip.mp4'));
  e.el.currentTime = 10;
  assert.equal(pool.frameIsAt(e, 10), false, 'nothing decoded yet');
  e.el.readyState = 2;
  assert.equal(pool.frameIsAt(e, 10), true);
  assert.equal(pool.frameIsAt(e, 12), false, 'wrong place');
  e.el.seeking = true;
  assert.equal(pool.frameIsAt(e, 10), false, 'mid-seek shows the old frame');
  assert.equal(pool.frameIsAt(null, 10), false);
});

test('preroll buffers and parks the element on the frame it will need', () => {
  const pool = new MediaPool(urlFor);
  const e = pool.bind(clip('c1', 'a1'), asset('a1', 'clip.mp4'));
  pool.preroll(e, 200);
  assert.equal(e.el.preload, 'auto');
  assert.equal(e.el.currentTime, 200);
  assert.equal(e.el.paused, true, 'parked, not playing');
});

test('a changed source (a proxy arriving) rebinds rather than playing the old file', () => {
  let url = 'https://studio.media/master.mp4';
  const pool = new MediaPool(() => url);
  const a = asset('a1', 'master.mp4');
  const before = pool.bind(clip('c1', 'a1'), a);
  url = 'https://studio.media/work/proxy-cache/abc.mp4';
  const after = pool.bind(clip('c1', 'a1'), a);
  assert.equal(after.url, url);
  assert.notEqual(after.url, before.url);
});

test('audio and video are pooled separately', () => {
  const pool = new MediaPool(urlFor);
  const v = pool.bind(clip('c1', 'a1'), asset('a1', 'clip.mp4', 'video'));
  const s = pool.bind(clip('c2', 'a2'), asset('a2', 'music.mp3', 'audio'));
  assert.equal(v.kind, 'video');
  assert.equal(s.kind, 'audio');
  assert.equal(v.el.tag, 'video');
  assert.equal(s.el.tag, 'audio');
});
