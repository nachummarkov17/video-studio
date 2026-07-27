// thumbs.js — client-side clip visuals: filmstrips for video clips, waveforms for
// audio clips. Generated in the browser (no ffmpeg round-trip, no host UI freeze),
// cached per asset id. Each strip/waveform spans its asset's FULL duration; the
// timeline maps the visible in/out window onto it via background-size/position.
const cache = new Map();    // assetId -> dataURL
const pending = new Set();  // assetIds currently generating

export function getThumb(asset) {
  return (asset && cache.get(asset.id)) || null;
}

// Kick off generation if not cached/in-flight. Calls onReady(assetId) when done.
export function requestThumb(asset, url, onReady) {
  if (!asset || cache.has(asset.id) || pending.has(asset.id)) return;
  if (asset.type !== 'video' && asset.type !== 'audio') return;
  pending.add(asset.id);
  const job = asset.type === 'audio' ? generateWaveform(url) : generateFilmstrip(url, asset.duration);
  job.then((dataUrl) => {
    pending.delete(asset.id);
    if (dataUrl) { cache.set(asset.id, dataUrl); if (onReady) onReady(asset.id); }
  }).catch(() => { pending.delete(asset.id); });
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

async function generateFilmstrip(url, duration) {
  const v = document.createElement('video');
  v.preload = 'auto'; v.muted = true; v.crossOrigin = 'anonymous'; v.src = url;
  await once(v, 'loadedmetadata');
  const dur = duration || v.duration || 1;
  const H = 48;
  const aspect = (v.videoWidth && v.videoHeight) ? (v.videoWidth / v.videoHeight) : 1.6;
  const W = Math.max(24, Math.round(H * aspect));
  const count = Math.max(6, Math.min(24, Math.round(dur / 2)));
  const canvas = document.createElement('canvas');
  canvas.width = W * count; canvas.height = H;
  const ctx = canvas.getContext('2d');
  for (let i = 0; i < count; i++) {
    const t = ((i + 0.5) / count) * dur;
    try {
      v.currentTime = Math.min(t, Math.max(0, (v.duration || dur) - 0.05));
      await once(v, 'seeked');
      ctx.drawImage(v, i * W, 0, W, H);
    } catch { break; }
  }
  v.removeAttribute('src'); v.load();  // release the decoder
  return canvas.toDataURL('image/jpeg', 0.6);
}

async function generateWaveform(url) {
  const resp = await fetch(url);
  const arr = await resp.arrayBuffer();
  const AC = window.AudioContext || window.webkitAudioContext;
  const ac = new AC();
  const audioBuf = await ac.decodeAudioData(arr);
  const data = audioBuf.getChannelData(0);
  const W = 900, H = 48, mid = H / 2;
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
