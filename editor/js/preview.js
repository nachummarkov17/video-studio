import { totalDuration } from './timeline.js';

export class Preview {
  constructor(canvas, project, assetUrl){
    this.cv = canvas; this.ctx = canvas.getContext('2d');
    this.assetUrl = assetUrl; this.media = new Map(); this._t = 0; this.playing=false; this._seq = 0;
    this._raf = null; this._activeMedia = new Map(); this.onTick = null;
    this.setProject(project);
  }
  setProject(p){
    // Pause and drop every existing media element before rebuilding - without
    // this, repeated Open actions (loading a new project over an old one)
    // leak orphaned <video>/<audio>/<img> elements that keep playing/decoding
    // in the background forever. _ensureMedia() re-creates whatever the new
    // project needs from a clean map.
    for(const [, m] of this.media){ if(m.el && typeof m.el.pause === 'function') m.el.pause(); }
    this.media = new Map();
    this._activeMedia = new Map();
    this.project = p; this.cv.width = p.canvas.width; this.cv.height = p.canvas.height; this._ensureMedia(); this.setTime(this._t);
  }
  _ensureMedia(){
    for(const a of this.project.assets){
      if(this.media.has(a.id)) continue;
      if(a.type==='image'){ const img=new Image(); img.src=this.assetUrl(a.id); this.media.set(a.id,{kind:'image',el:img}); }
      else if(a.type==='audio'){ const el=document.createElement('audio'); el.src=this.assetUrl(a.id); el.preload='auto'; this.media.set(a.id,{kind:'audio',el}); }
      else { const v=document.createElement('video'); v.src=this.assetUrl(a.id); v.preload='auto'; v.crossOrigin='anonymous'; this.media.set(a.id,{kind:'video',el:v}); }
    }
  }
  _clipsAt(t){ // bottom-to-top: main track first, then overlay tracks in order
    const out=[];
    for(const tr of this.project.tracks){ if(tr.kind==='audio') continue;
      for(const c of tr.clips){ if(t>=c.start && t < c.start+c.duration) out.push({tr,c}); } }
    return out;
  }
  // Every clip (on any track) whose media actually plays back (video or
  // audio elements) — main/overlay video clips contribute their own embedded
  // audio (muted per-clip), and dedicated audio-track clips contribute theirs.
  // Images are excluded: they have no play/pause/currentTime concept.
  _playableClipsAt(t){
    const out=[];
    for(const tr of this.project.tracks){
      for(const c of tr.clips){
        if(t>=c.start && t < c.start+c.duration){
          const m=this.media.get(c.assetId);
          if(m && (m.kind==='video' || m.kind==='audio')) out.push({tr,c,m});
        }
      }
    }
    return out;
  }
  // Draws one composited layer (video frame or image) onto the canvas using
  // whatever frame the element currently holds — no seeking here, so this is
  // safe to call every rAF frame during playback as well as from setTime.
  _compositeClip(ctx, W, H, tr, c, m){
    const src = m.el;
    const nw = (m.kind==='image'? src.naturalWidth: src.videoWidth)||W;
    const nh = (m.kind==='image'? src.naturalHeight: src.videoHeight)||H;
    ctx.globalAlpha = c.opacity ?? 1;
    if(tr.kind==='main'){ // cover the full canvas
      const s=Math.max(W/nw,H/nh); const dw=nw*s, dh=nh*s; ctx.drawImage(src,(W-dw)/2,(H-dh)/2,dw,dh);
    } else { // overlay: place at x,y at scale (fraction of canvas width)
      const dw=nw*(c.scale??1), dh=nh*(c.scale??1); ctx.drawImage(src, c.x??0, c.y??0, dw, dh);
    }
    ctx.globalAlpha=1;
  }
  _drawVisual(t){
    const ctx=this.ctx, W=this.cv.width, H=this.cv.height;
    ctx.clearRect(0,0,W,H); ctx.fillStyle='#000'; ctx.fillRect(0,0,W,H);
    for(const {tr,c} of this._clipsAt(t)){
      const m=this.media.get(c.assetId); if(!m) continue;
      this._compositeClip(ctx,W,H,tr,c,m);
    }
  }
  async setTime(t){
    this._t=t; const token = ++this._seq; const ctx=this.ctx, W=this.cv.width, H=this.cv.height;
    ctx.clearRect(0,0,W,H); ctx.fillStyle='#000'; ctx.fillRect(0,0,W,H);
    for(const {tr,c} of this._clipsAt(t)){
      const m=this.media.get(c.assetId); if(!m) continue;
      const src = m.el; const local = c.in + (t - c.start);
      if(m.kind!=='image'){ if(Math.abs(src.currentTime-local)>0.05 && !this.playing){ src.currentTime=local; await new Promise(r=>{ src.onseeked=r; setTimeout(r,120);}); if (token !== this._seq) return; } }
      this._compositeClip(ctx,W,H,tr,c,m);
    }
  }
  // Activate/deactivate/drift-correct every playable (video/audio) clip for
  // the current instant, without ever seeking an element that is already
  // correctly positioned (only on activation or when drift exceeds 50ms).
  _updateMedia(t){
    const activeMap = new Map();
    for(const {c,m} of this._playableClipsAt(t)) activeMap.set(c.id, {c,m});

    // Deactivate elements whose clip is no longer active this frame.
    for(const [clipId, info] of this._activeMedia){
      if(!activeMap.has(clipId)) info.m.el.pause();
    }

    // Activate newly-active clips / drift-correct already-active ones.
    for(const [clipId, {c,m}] of activeMap){
      const el = m.el;
      const expected = c.in + (t - c.start);
      const wasActive = this._activeMedia.has(clipId);
      if(!wasActive){
        el.currentTime = expected;
        el.play().catch(()=>{});
      } else if(Math.abs(el.currentTime - expected) > 0.05){
        el.currentTime = expected;
      }
      el.volume = c.volume ?? 1;
      el.muted = !!c.muted;
    }

    this._activeMedia = activeMap;
  }
  play(){
    if(this.playing) return;
    this.playing = true;
    const total = totalDuration(this.project);
    const anchorPerf = performance.now();
    const anchorT = this._t;
    const loop = (now) => {
      if(!this.playing) return;
      let t = anchorT + (now - anchorPerf)/1000;
      let ended = false;
      if(t >= total){ t = total; ended = true; }
      this._t = t;
      this._updateMedia(t);
      this._drawVisual(t);
      if(ended){ this.pause(); }
      if(this.onTick) this.onTick(t);
      if(!ended){ this._raf = requestAnimationFrame(loop); }
    };
    this._raf = requestAnimationFrame(loop);
  }
  pause(){
    this.playing = false;
    if(this._raf){ cancelAnimationFrame(this._raf); this._raf = null; }
    for(const [, info] of this._activeMedia) info.m.el.pause();
    this._activeMedia = new Map();
  }
  get time(){ return this._t; }
}
