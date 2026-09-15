export const PRESETS = {
  '9:16': { width:1080, height:1920 }, '16:9': { width:1920, height:1080 }, '1:1': { width:1080, height:1080 }
};
let _n = 0;
export function uid(prefix='id'){ _n++; return `${prefix}_${Date.now().toString(36)}_${_n}`; }
// No lanes up front: like CapCut, the timeline is an empty drop area until you
// put something in it, and lanes appear as you need them.
export function newProject(preset='9:16', name='Untitled'){
  const c = PRESETS[preset] || PRESETS['9:16'];
  return { version:1, name, canvas:{ width:c.width, height:c.height, fps:30 }, assets:[], tracks:[] };
}

// Creates the lane an asset of this type belongs in, and returns its id.
// `tracks` is kept in DRAW order - main first, then overlays bottom-to-top,
// then audio - because preview.js and EditorRender.ps1 both composite in that
// order. Screen order is a separate concern; see laneRows().
export function addTrackForType(p, assetType){
  const t = { id:uid('t'), kind:'overlay', clips:[] };
  if (assetType === 'audio'){ t.kind = 'audio'; p.tracks.push(t); return t.id; }
  if (!p.tracks.some(x => x.kind === 'main')){ t.kind = 'main'; p.tracks.unshift(t); return t.id; }
  let idx = p.tracks.length;
  for (let i = p.tracks.length - 1; i >= 0; i--){
    if (p.tracks[i].kind === 'overlay' || p.tracks[i].kind === 'main'){ idx = i + 1; break; }
  }
  p.tracks.splice(idx, 0, t);
  return t.id;
}

// Drops every lane that has nothing in it. Called after a drag finishes (never
// mid-drag, or the timeline would jump under the cursor) and on project load,
// which is also what tidies up projects saved with the old fixed three lanes.
export function pruneEmptyTracks(p){
  p.tracks = p.tracks.filter(t => t.clips && t.clips.length > 0);
  return p;
}

// Top-to-bottom SCREEN order: overlay lanes stack upward above main, audio
// hangs below it.
export function laneRows(p){
  const overlays = p.tracks.filter(t => t.kind === 'overlay');
  const main     = p.tracks.filter(t => t.kind === 'main');
  const audio    = p.tracks.filter(t => t.kind === 'audio');
  return overlays.slice().reverse().concat(main, audio);
}
// ---- overlays sit ON the video, they don't replace it ----------------------
//
// A clip on an overlay lane is drawn at its own natural pixel size times
// `scale`. Defaulting scale to 1 meant a 3000px-wide photo was drawn 3000px
// wide on a 1080px canvas - so "show an image" filled the screen and hid the
// video behind it. An overlay therefore gets a placement when it is added:
// a sensible fraction of the frame, positioned clear of the captions.
export const OVERLAY_FRACTION = 0.45;      // of the frame's width
export const OVERLAY_SIZES = { small: 0.28, medium: 0.45, large: 0.66 };

// anchorX/anchorY are 0..1 across the space the picture doesn't fill:
// 0 = hard left/top, 0.5 = centred, 1 = hard right/bottom.
export function overlayPlacement(canvas, naturalW, naturalH, opts = {}) {
  const fraction = opts.fraction ?? OVERLAY_FRACTION;
  const anchorX = opts.anchorX ?? 0.5;
  const anchorY = opts.anchorY ?? 0.3;     // upper third: clear of burned captions
  const cw = (canvas && canvas.width) || 1080;
  const ch = (canvas && canvas.height) || 1920;
  if (!(naturalW > 0) || !(naturalH > 0)) return { scale: 1, x: 0, y: 0 };

  let scale = (cw * fraction) / naturalW;
  // ...and never taller than the same fraction of the frame, so a very tall
  // picture doesn't run off the top and bottom of a 9:16 canvas
  const maxH = ch * fraction;
  if (naturalH * scale > maxH) scale = maxH / naturalH;

  const w = naturalW * scale, h = naturalH * scale;
  return {
    scale,
    x: Math.round((cw - w) * anchorX),
    y: Math.round((ch - h) * anchorY),
  };
}

export function addAsset(p, a){ const id=uid('a'); p.assets.push({ id, x:0, ...a }); return id; }
export function getTrack(p, tid){ return p.tracks.find(t=>t.id===tid); }
export function addClip(p, tid, c){
  const id=uid('c'); const clip={ id, assetId:c.assetId, start:c.start??0, in:c.in??0, duration:c.duration??1,
    x:c.x??0, y:c.y??0, scale:c.scale??1, opacity:c.opacity??1, volume:c.volume??1, muted:c.muted??false };
  getTrack(p,tid).clips.push(clip); return id;
}
export function findClip(p, cid){ for(const t of p.tracks){ const clip=t.clips.find(c=>c.id===cid); if(clip) return {track:t, clip}; } return null; }
export function getAsset(p, aid){ return p.assets.find(a=>a.id===aid); }
