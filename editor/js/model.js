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
export function addAsset(p, a){ const id=uid('a'); p.assets.push({ id, x:0, ...a }); return id; }
export function getTrack(p, tid){ return p.tracks.find(t=>t.id===tid); }
export function addClip(p, tid, c){
  const id=uid('c'); const clip={ id, assetId:c.assetId, start:c.start??0, in:c.in??0, duration:c.duration??1,
    x:c.x??0, y:c.y??0, scale:c.scale??1, opacity:c.opacity??1, volume:c.volume??1, muted:c.muted??false };
  getTrack(p,tid).clips.push(clip); return id;
}
export function findClip(p, cid){ for(const t of p.tracks){ const clip=t.clips.find(c=>c.id===cid); if(clip) return {track:t, clip}; } return null; }
export function getAsset(p, aid){ return p.assets.find(a=>a.id===aid); }
