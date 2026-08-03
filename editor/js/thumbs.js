// thumbs.js — client-side clip visuals: filmstrips for video clips, waveforms for
// audio clips. Generated in the browser (no ffmpeg round-trip, no host UI freeze).
//
// Strips are rendered at the size they will actually OCCUPY on the timeline, at
// 2x for sharpness, and each frame is cover-cropped into its tile. The old
// version built one ~650px strip per asset and let the browser stretch it across
// thousands of pixels while squashing every frame into a fixed box - which is
// what made clips look like fuzzy outlines instead of recognisable frames.
//
// Because "how wide will this be" depends on the zoom level, strips are cached
// per (asset, zoom bucket). Zooming past a bucket regenerates once; until the
// new strip is ready the nearest existing one keeps showing, so nothing blanks.

const CLIP_H     = 52;    // .clip box height: .track 64px minus 6px top/bottom
const DPR        = 2;     // render at 2x so downscaling stays crisp
const MIN_TILES  = 6;
const MAX_TILES  = 30;    // each tile costs a seek+decode; 30 keeps it responsive
const DEBOUNCE_MS = 250;  // don't start a job for every step of a zoom drag
const JPEG_Q     = 0.8;

const cache   = new Map();  // "assetId@bucket" -> dataURL
const pending = new Set();
const timers  = new Map();

// Zoom levels are bucketed by powers of two: within a bucket the cached strip is
// never scaled more than 2x, which is not visibly soft.
export function zoomBucket(pxPerSec) {
  return Math.max(0, Math.round(Math.log2(Math.max(1, pxPerSec))));
}

export function getThumb(asset, bucket) {
  if (!asset) return null;
  const exact = cache.get(`${asset.id}@${bucket}`);
  if (exact) return exact;
  // fall back to the closest resolution we already have rather than showing
  // nothing while a sharper strip renders
  let best = null, bestDist = Infinity;
  for (const [k, v] of cache) {
    const at = k.lastIndexOf('@');
    if (k.slice(0, at) !== asset.id) continue;
    const d = Math.abs(Number(k.slice(at + 1)) - bucket);
    if (d < bestDist) { bestDist = d; best = v; }
  }
  return best;
}

// Kick off generation for this asset at this zoom bucket unless it is cached,
// already running, or already queued. onReady(assetId) fires as tiles land.
export function requestThumb(asset, url, bucket, displayWidthPx, onReady) {
  if (!asset) return;
  if (asset.type !== 'video' && asset.type !== 'audio') return;
  const key = `${asset.id}@${bucket}`;
  if (cache.has(key) || pending.has(key) || timers.has(key)) return;

  timers.set(key, setTimeout(() => {
    timers.delete(key);
    if (cache.has(key) || pending.has(key)) return;
    pending.add(key);
    const onPartial = (partial) => { cache.set(key, partial); if (onReady) onReady(asset.id); };
    const job = asset.type === 'audio'
      ? generateWaveform(url, displayWidthPx)
      : generateFilmstrip(url, asset.duration, displayWidthPx, onPartial);
    job.then((dataUrl) => {
      pending.delete(key);
      if (dataUrl) { cache.set(key, dataUrl); if (onReady) onReady(asset.id); }
    }).catch(() => { pending.delete(key); });
  }, DEBOUNCE_MS));
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
  v.preload = 'auto'; v.muted = true; v.crossOrigin = 'anonymous'; v.src = url;
  await once(v, 'loadedmetadata');

  const dur = duration || v.duration || 1;
  const aspect = (v.videoWidth && v.videoHeight) ? (v.videoWidth / v.videoHeight) : 1.6;
  // a tile at its natural shape would be this wide on screen; pick a tile count
  // that lands near it, then size the tiles to exactly fill the strip
  const naturalTileW = Math.max(12, CLIP_H * aspect);
  const width = Math.max(1, displayWidthPx || naturalTileW * MIN_TILES);
  const count = Math.max(MIN_TILES, Math.min(MAX_TILES, Math.round(width / naturalTileW)));
  const TW = Math.max(8, Math.round((width / count) * DPR));
  const TH = CLIP_H * DPR;

  const canvas = document.createElement('canvas');
  canvas.width = TW * count; canvas.height = TH;
  const ctx = canvas.getContext('2d');
  ctx.imageSmoothingQuality = 'high';
  ctx.fillStyle = '#101614';
  ctx.fillRect(0, 0, canvas.width, canvas.height);

  for (let i = 0; i < count; i++) {
    const t = ((i + 0.5) / count) * dur;
    try {
      v.currentTime = Math.min(t, Math.max(0, (v.duration || dur) - 0.05));
      await once(v, 'seeked');
      drawCover(ctx, v, i * TW, 0, TW, TH);
    } catch { break; }
    // show the strip filling in rather than nothing until the last frame
    if (onPartial && i > 0 && i % 5 === 0) onPartial(canvas.toDataURL('image/jpeg', JPEG_Q));
  }
  v.removeAttribute('src'); v.load();  // release the decoder
  return canvas.toDataURL('image/jpeg', JPEG_Q);
}

async function generateWaveform(url, displayWidthPx) {
  const resp = await fetch(url);
  const arr = await resp.arrayBuffer();
  const AC = window.AudioContext || window.webkitAudioContext;
  const ac = new AC();
  const audioBuf = await ac.decodeAudioData(arr);
  const data = audioBuf.getChannelData(0);
  const W = Math.max(900, Math.min(4000, Math.round((displayWidthPx || 900) * DPR)));
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
