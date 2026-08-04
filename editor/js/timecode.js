// timecode.js — hh:mm:ss:ff for the transport readouts.
const p2 = (n) => String(n).padStart(2, '0');

export function timecode(sec, fps = 30) {
  const rate = fps > 0 ? fps : 30;
  const s = (typeof sec === 'number' && isFinite(sec) && sec > 0) ? sec : 0;
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const ss = Math.floor(s % 60);
  // clamp: at 0.9999s a naive floor gives frame 30 of a 30fps second
  const f = Math.min(rate - 1, Math.floor((s - Math.floor(s)) * rate));
  return `${p2(h)}:${p2(m)}:${p2(ss)}:${p2(f)}`;
}
