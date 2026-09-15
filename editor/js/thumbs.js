// thumbs.js — client-side clip visuals: filmstrips for video clips, waveforms for
// audio clips. Generated in the browser (no ffmpeg round-trip, no host UI freeze),
// cached per asset.
//
// Generating a strip means loading the source into a second <video> and seeking
// it dozens of times. That is EXPENSIVE and it competes with playback for the
// same decoder, so three rules keep it out of the way:
//
//   1. ONE strip per asset, ever. It used to be regenerated per zoom level,
//      and since zoom-to-fit changes the zoom on every drop, simply adding a
//      clip kicked off a full re-decode of the source - the picture stuttered
//      and the audio dropped out "until it finished loading".
//   2. One job at a time, globally. Jobs queue instead of fighting each other.
//   3. Never while the preview is playing. Playback owns the decoder; queued
//      jobs resume the moment it stops.
//   4. PERSISTED TO DISK by the host. Strips used to live only in memory, so
//      every time the editor opened, every asset was decoded again from
//      scratch - a decode storm on startup that got worse with every clip you
//      added. Now a strip is generated ONCE, ever, written to
//      work\thumb-cache\ and referenced by URL from then on. Referencing a
//      file instead of a ~150KB base64 data URL also keeps them out of the JS
//      heap and lets the browser cache the decoded image.
//
// The strip is rendered wide enough to stay sharp at normal working zooms and
// is scaled by the timeline from there.

import { request, hasHost } from './bridge.js';

const CLIP_H      = 52;    // .clip box height: .track 64px minus 6px top/bottom
const DPR         = 2;     // render at 2x so downscaling stays crisp
const MIN_TILES   = 8;
const MAX_TILES   = 200;   // how many tiles the strip is made of
const MAX_STRIP_W = 14000; // ceiling on the strip's width, in CSS px
const JPEG_Q      = 0.8;
// How much of the clip one tile is allowed to stand for. This is what decides
// how CLOSE the scrub picture is to the frame you're actually on, because the
// strip is what gets drawn while you drag.
const TARGET_TILE_SEC = 1.2;

// Every tile keeps the SOURCE's shape. The tile WIDTH is derived from the source
// aspect and never from the available width; stretching a strip to the clip's
// width is what once squashed portrait frames into wide boxes and cropped away
// everything but a band of midriff.
//
// The tile COUNT is derived from the clip's DURATION, and deliberately not from
// the zoom level. It used to come from how wide the clip happened to be drawn,
// which meant a four-minute clip fitted to the window got about 38 tiles - one
// frame every six seconds. Dragging the playhead a second or two therefore
// showed the SAME tile, so the picture appeared not to move until the real
// frame landed and it jumped. One tile per ~1.2s keeps the proxy close enough
// that the exact frame arriving is a sharpening, not a jump.
export function tileLayout(aspect, displayWidthPx, durationSec) {
  const a = aspect > 0 ? aspect : 1.6;
  const tileCssW = Math.max(8, CLIP_H * a);
  const dur = durationSec > 0 ? durationSec : 0;
  const wanted = dur > 0 ? Math.round(dur / TARGET_TILE_SEC) : MIN_TILES;
  let count = Math.max(MIN_TILES, Math.min(MAX_TILES, wanted));
  // never let the sheet grow past what a canvas/JPEG handles comfortably
  count = Math.max(MIN_TILES, Math.min(count, Math.floor(MAX_STRIP_W / tileCssW)));
  return {
    count,
    tileW: Math.max(8, Math.round(tileCssW * DPR)),
    tileH: CLIP_H * DPR,
    tileCssW,
    secondsPerTile: dur > 0 ? dur / count : 0,
  };
}

const cache   = new Map();  // assetId -> dataURL (the timeline's clip background)
const strips  = new Map();  // assetId -> {img, count, tileW, tileH, duration}
const posters = new Map();  // media-bin key -> small dataURL
const posterMeta = new Map(); // media-bin key -> { duration }
const started = new Set();  // assetIds we've already generated (or are generating)
const queue   = [];         // pending jobs, run one at a time
let running = false;
let deferred = false;       // true while playback owns the decoder

export function getThumb(asset) {
  return (asset && cache.get(asset.id)) || null;
}

// The decoded filmstrip plus the geometry needed to pick one tile out of it.
// The preview uses this to show a frame WHILE SCRUBBING without seeking the
// real <video>, which is what made dragging the playhead so expensive.
export function getStrip(assetId) {
  return strips.get(assetId) || null;
}

export function getPoster(key) {
  return posters.get(key) || null;
}

// What we learned about a file while making its poster - currently just how
// long it is, which the bin shows so you can tell a full shot from a cut piece.
export function getPosterMeta(key) {
  return posterMeta.get(key) || null;
}

// A single small frame for the media bin. Shares the one job queue, so it can
// never pile on top of playback or a filmstrip.
export function requestPoster(key, url, type, onReady) {
  if (!key || posters.has(key) || started.has('poster:' + key)) return;
  if (type !== 'video' && type !== 'image') return;
  started.add('poster:' + key);
  queue.push({ poster: true, key, url, type, onReady });
  pump();
}

// The app calls this when playback starts/stops. While playing we neither start
// nor continue generating; when it stops, whatever queued up resumes.
export function setThumbsDeferred(v) {
  deferred = !!v;
  if (!deferred) pump();
}

// Ask for this asset's strip. Safe to call on every render: it does nothing
// once the asset has been queued or generated.
export function requestThumb(asset, url, displayWidthPx, onReady) {
  if (!asset) return;
  if (asset.type !== 'video' && asset.type !== 'audio') return;
  if (started.has(asset.id)) return;
  started.add(asset.id);
  queue.push({ asset, url, width: displayWidthPx, onReady, key: asset.path });
  pump();
}

// Ask the host whether this asset already has a strip on disk from a previous
// session. Returns a URL, or null when there's no host or no cached file.
async function diskGet(path, kind) {
  if (!hasHost()) return null;
  const r = await request('thumbGet', { path, kind });
  return (r && r.url) || null;
}

async function diskPut(path, kind, dataUrl) {
  if (!hasHost()) return null;
  const r = await request('thumbPut', { path, kind, dataUrl });
  return (r && r.url) || null;
}

function pump() {
  if (running || deferred || queue.length === 0) return;
  running = true;
  const job = queue.shift();

  if (job.poster) {
    diskGet(job.key, 'poster').then((cached) => {
      // even with the picture cached we still want the length for the bin
      if (cached) { probeDuration(job.url, job.type, job.key); return cached; }
      return generatePoster(job.url, job.type, job.key)
        .then((dataUrl) => dataUrl ? diskPut(job.key, 'poster', dataUrl).then((u) => u || dataUrl) : null);
    }).then((url) => {
      if (url) { posters.set(job.key, url); if (job.onReady) job.onReady(job.key); }
    }).catch(() => {
      started.delete('poster:' + job.key);
    }).finally(() => { running = false; pump(); });
    return;
  }

  const onPartial = (partial) => {
    cache.set(job.asset.id, partial);
    if (job.onReady) job.onReady(job.asset.id);
  };
  const kind = job.asset.type === 'audio' ? 'wave' : 'strip';

  const finish = (url, meta) => {
    cache.set(job.asset.id, url);
    if (meta && meta.count) {
      const img = new Image();          // decoded once, up front
      img.src = url;
      strips.set(job.asset.id, {
        img, count: meta.count, tileW: meta.tileW, tileH: meta.tileH,
        tileCssW: meta.tileCssW, duration: meta.duration,
      });
    }
    if (job.onReady) job.onReady(job.asset.id);
  };

  diskGet(job.asset.path || job.key || job.url, kind).then((cachedUrl) => {
    if (cachedUrl) {
      // A cached strip means no decode at all. Its tile geometry is derived
      // the same way it was when it was generated, so the scrub proxy still
      // knows how to index into it.
      finish(cachedUrl, stripGeometry(job.asset, job.width));
      return null;
    }
    const work = kind === 'wave'
      ? generateWaveform(job.url, job.width).then((dataUrl) => ({ dataUrl }))
      : generateFilmstrip(job.url, job.asset.duration, job.width, onPartial);
    return work.then((res) => {
      if (!res || !res.dataUrl) return;
      return diskPut(job.asset.path || job.key || job.url, kind, res.dataUrl)
        .then((url) => finish(url || res.dataUrl, res));
    });
  }).catch(() => {
    started.delete(job.asset.id);   // let a later render retry a failed asset
  }).finally(() => {
    running = false;
    pump();
  });
}

// The tile layout generateFilmstrip would have chosen for this asset. Kept as
// its own function so a strip restored from disk can be indexed identically
// without re-deriving it by hand in two places.
export function stripGeometry(asset, displayWidthPx) {
  if (!asset || asset.type === 'audio') return null;
  const aspect = (asset.naturalW && asset.naturalH) ? (asset.naturalW / asset.naturalH) : 1.6;
  const L = tileLayout(aspect, displayWidthPx, asset.duration);
  return { count: L.count, tileW: L.tileW, tileH: L.tileH, tileCssW: L.tileCssW, duration: asset.duration || 1 };
}

// One frame, small, for the media-bin row.
// Cheap metadata-only read; no frames decoded.
function probeDuration(url, type, key) {
  if (type !== 'video' || posterMeta.has(key)) return;
  const v = document.createElement('video');
  v.preload = 'metadata'; v.muted = true; v.src = url;
  once(v, 'loadedmetadata').then(() => {
    posterMeta.set(key, { duration: v.duration || 0 });
    v.removeAttribute('src'); v.load();
  }).catch(() => { v.removeAttribute('src'); v.load(); });
}

async function generatePoster(url, type, key) {
  const H = 72, W = 128;
  const canvas = document.createElement('canvas');
  canvas.width = W; canvas.height = H;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#101614';
  ctx.fillRect(0, 0, W, H);

  if (type === 'image') {
    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.src = url;
    await once(img, 'load');
    drawCover(ctx, img, 0, 0, W, H);
    return canvas.toDataURL('image/jpeg', 0.7);
  }

  const v = document.createElement('video');
  v.preload = 'metadata'; v.muted = true; v.crossOrigin = 'anonymous'; v.src = url;
  try {
    await once(v, 'loadedmetadata');
    if (key) posterMeta.set(key, { duration: v.duration || 0 });
    await waitWhileDeferred();
    // a second in tends to be past any black/fade-in at the head
    v.currentTime = Math.min(1, Math.max(0, (v.duration || 1) / 2));
    await once(v, 'seeked');
    drawCover(ctx, v, 0, 0, W, H);
    return canvas.toDataURL('image/jpeg', 0.7);
  } finally {
    v.removeAttribute('src'); v.load();
  }
}

function once(el, ev) {
  return new Promise((resolve, reject) => {
    const ok = () => { cleanup(); resolve(); };
    const bad = () => { cleanup(); reject(new Error(ev + ' failed')); };
    const cleanup = () => { el.removeEventListener(ev, ok); el.removeEventListener('error', bad); };
    el.addEventListener(ev, ok, { once: true });
    el.addEventListener('error', bad, { once: true });
  });
}

// Wait here if playback started midway through a job, so we stop stealing
// decoder time the moment the user hits play.
function waitWhileDeferred() {
  if (!deferred) return Promise.resolve();
  return new Promise((resolve) => {
    const check = () => { if (!deferred) resolve(); else setTimeout(check, 120); };
    check();
  });
}

// Fill the tile completely, cropping the overflow, centred - the frame keeps its
// shape instead of being squashed into the box.
function drawCover(ctx, src, dx, dy, dw, dh) {
  const sw = src.videoWidth || src.naturalWidth || dw;
  const sh = src.videoHeight || src.naturalHeight || dh;
  const s = Math.max(dw / sw, dh / sh);
  const w = sw * s, h = sh * s;
  ctx.save();
  ctx.beginPath();
  ctx.rect(dx, dy, dw, dh);
  ctx.clip();
  ctx.drawImage(src, dx + (dw - w) / 2, dy + (dh - h) / 2, w, h);
  ctx.restore();
}

async function generateFilmstrip(url, duration, displayWidthPx, onPartial) {
  const v = document.createElement('video');
  v.preload = 'metadata'; v.muted = true; v.crossOrigin = 'anonymous'; v.src = url;
  try {
    await once(v, 'loadedmetadata');

    const dur = duration || v.duration || 1;
    const aspect = (v.videoWidth && v.videoHeight) ? (v.videoWidth / v.videoHeight) : 1.6;
    // ONE layout function, shared with stripGeometry, so a strip restored from
    // disk is indexed exactly the way it was written.
    const L = tileLayout(aspect, displayWidthPx, dur);
    const count = L.count;
    const TW = L.tileW;
    const TH = L.tileH;

    const canvas = document.createElement('canvas');
    canvas.width = TW * count; canvas.height = TH;
    const ctx = canvas.getContext('2d');
    ctx.imageSmoothingQuality = 'high';
    ctx.fillStyle = '#101614';
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    for (let i = 0; i < count; i++) {
      await waitWhileDeferred();
      const t = ((i + 0.5) / count) * dur;
      try {
        v.currentTime = Math.min(t, Math.max(0, (v.duration || dur) - 0.05));
        await once(v, 'seeked');
        drawCover(ctx, v, i * TW, 0, TW, TH);
      } catch { break; }
      // show the strip filling in rather than nothing until the last frame
      if (onPartial && i > 0 && i % 5 === 0) onPartial(canvas.toDataURL('image/jpeg', JPEG_Q));
    }
    return { dataUrl: canvas.toDataURL('image/jpeg', JPEG_Q), count, tileW: TW, tileH: TH, duration: dur };
  } finally {
    v.removeAttribute('src'); v.load();   // release the decoder, even on failure
  }
}

async function generateWaveform(url, displayWidthPx) {
  const resp = await fetch(url);
  const arr = await resp.arrayBuffer();
  await waitWhileDeferred();
  const AC = window.AudioContext || window.webkitAudioContext;
  const ac = new AC();
  const audioBuf = await ac.decodeAudioData(arr);
  const data = audioBuf.getChannelData(0);
  const W = Math.max(900, Math.min(MAX_STRIP_W, Math.round((displayWidthPx || 900) * DPR)));
  const H = CLIP_H * DPR, mid = H / 2;
  const canvas = document.createElement('canvas');
  canvas.width = W; canvas.height = H;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = 'rgba(210,196,240,0.92)';  // light violet over the audio-clip base
  const step = Math.max(1, Math.floor(data.length / W));
  for (let x = 0; x < W; x++) {
    let min = 1, max = -1;
    const base = x * step;
    for (let j = 0; j < step; j++) { const s = data[base + j]; if (s < min) min = s; if (s > max) max = s; }
    const y1 = (1 + min) * mid, y2 = (1 + max) * mid;
    ctx.fillRect(x, y1, 1, Math.max(1, y2 - y1));
  }
  try { ac.close(); } catch {}
  return canvas.toDataURL('image/png');
}
