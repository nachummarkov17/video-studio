import { totalDuration } from './timeline.js';

// How far a media element may drift from the playback clock before we correct
// it, and how long we must wait between corrections. Both matter: a <video>
// needs a moment to spin up and to recover from a seek, so a tight threshold
// checked every animation frame re-seeks the element ~60x/second and it never
// actually plays - the picture freezes and no audio comes out.
const DRIFT_MAX_SEC = 0.3;
const DRIFT_FIX_COOLDOWN_MS = 500;

export class Preview {
  constructor(canvas, project, assetUrl){
    this.cv = canvas; this.ctx = canvas.getContext('2d');
    this.assetUrl = assetUrl; this.media = new Map(); this._t = 0; this.playing=false; this._seq = 0;
    this._raf = null; this._activeMedia = new Map(); this.onTick = null;
    this._lastFix = new Map();   // clip id -> performance.now() of its last correction
    this._wanted = new Map();    // assetId -> a seek target waiting on the current one
    this._seekBound = new Set(); // assetIds whose 'seeked' listener is attached
    this.setProject(project);
  }
  setProject(p){
    // KEEP the media elements for assets that are still in the project, and drop
    // only the ones that have gone. This runs on every clip drop and every undo;
    // tearing the whole map down each time reloaded and re-decoded every asset
    // already on the timeline, which stalled the picture and cut the audio.
    const keep = new Set(p.assets.map(a => a.id + '|' + a.path));
    for(const [id, m] of this.media){
      if(keep.has(id + '|' + (m.path ?? ''))) continue;
      if(m.el && typeof m.el.pause === 'function') m.el.pause();
      if(m.el && m.kind !== 'image'){ m.el.removeAttribute('src'); m.el.load(); }
      this.media.delete(id);
      this._seekBound.delete(id);
      this._wanted.delete(id);
    }
    this._activeMedia = new Map();
    this._lastFix = new Map();
    this.project = p;
    this.cv.width = p.canvas.width; this.cv.height = p.canvas.height;
    this._ensureMedia();
    this.setTime(this._t);
  }
  _ensureMedia(){
    for(const a of this.project.assets){
      if(this.media.has(a.id)) continue;
      if(a.type==='image'){ const img=new Image(); img.src=this.assetUrl(a.id); this.media.set(a.id,{kind:'image',el:img,path:a.path}); }
      else if(a.type==='audio'){ const el=document.createElement('audio'); el.src=this.assetUrl(a.id); el.preload='auto'; this.media.set(a.id,{kind:'audio',el,path:a.path}); }
      else { const v=document.createElement('video'); v.src=this.assetUrl(a.id); v.preload='auto'; v.crossOrigin='anonymous'; this.media.set(a.id,{kind:'video',el:v,path:a.path}); }
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
  // Scrubbing: draw whatever frames the elements currently hold IMMEDIATELY, and
  // ask for the right frames separately. Seeks are coalesced per element - only
  // one is ever in flight, and a newer target replaces a pending one - so
  // dragging the playhead runs as fast as the decoder can go instead of queueing
  // a seek per mouse move, which is what stalled the picture and cut the audio.
  setTime(t){
    this._t = t;
    this._drawVisual(t);
    if(this.playing) return;                 // playback drives its own frames
    for(const {c} of this._clipsAt(t)){
      const m = this.media.get(c.assetId);
      if(!m || m.kind === 'image') continue;
      this._requestSeek(c.assetId, m.el, c.in + (t - c.start));
    }
  }

  _requestSeek(key, el, time){
    if(!(time >= 0)) return;
    if(Math.abs(el.currentTime - time) < 0.02) return;
    if(el.seeking){ this._wanted.set(key, time); return; }   // supersede on arrival
    this._wanted.delete(key);
    el.currentTime = time;
    if(!this._seekBound.has(key)){
      this._seekBound.add(key);
      el.addEventListener('seeked', () => {
        const next = this._wanted.get(key);
        if(next != null){ this._wanted.delete(key); this._requestSeek(key, el, next); }
        else if(!this.playing) this._drawVisual(this._t);
      });
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

    // Activate newly-active clips / drift-correct already-active ones. The
    // correction is deliberately lazy: never while the element is mid-seek,
    // only past DRIFT_MAX_SEC, and at most once per DRIFT_FIX_COOLDOWN_MS.
    // Correcting harder than that starves the decoder and playback dies.
    const now = performance.now();
    for(const [clipId, {c,m}] of activeMap){
      const el = m.el;
      const expected = c.in + (t - c.start);
      const wasActive = this._activeMedia.has(clipId);
      if(!wasActive){
        el.currentTime = expected;
        this._lastFix.set(clipId, now);
        el.play().catch(e => console.warn('media play failed:', e));
      } else if(!el.seeking &&
                Math.abs(el.currentTime - expected) > DRIFT_MAX_SEC &&
                (now - (this._lastFix.get(clipId) ?? 0)) > DRIFT_FIX_COOLDOWN_MS){
        el.currentTime = expected;
        this._lastFix.set(clipId, now);
      }
      el.volume = c.volume ?? 1;
      el.muted = !!c.muted;
    }

    this._activeMedia = activeMap;
  }
  play(){
    if(this.playing) return;
    const total = totalDuration(this.project);
    if(total <= 0) return;                       // nothing on the timeline yet
    // Pressing Play with the playhead parked at the end used to end playback on
    // the very first frame, which looked exactly like "Play does nothing".
    if(this._t >= total - 0.001) this._t = 0;
    this.playing = true;
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
    this._lastFix = new Map();
  }
  get time(){ return this._t; }
}
