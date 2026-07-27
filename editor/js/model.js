export const PRESETS = {
  '9:16': { width:1080, height:1920 }, '16:9': { width:1920, height:1080 }, '1:1': { width:1080, height:1080 }
};
let _n = 0;
export function uid(prefix='id'){ _n++; return `${prefix}_${Date.now().toString(36)}_${_n}`; }
export function newProject(preset='9:16', name='Untitled'){
  const c = PRESETS[preset] || PRESETS['9:16'];
  return { version:1, name, canvas:{ width:c.width, height:c.height, fps:30 }, assets:[],
    tracks:[ {id:uid('t'),kind:'main',clips:[]}, {id:uid('t'),kind:'overlay',clips:[]}, {id:uid('t'),kind:'audio',clips:[]} ] };
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
