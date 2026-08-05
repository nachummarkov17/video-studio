import { totalDuration } from './timeline.js';
import { getStrip } from './thumbs.js';

// How far a media element may drift from the playback clock before we correct
// it, and how long we must wait between corrections. Both matter: a <video>
// needs a moment to spin up and to recover from a seek, so a tight threshold
// checked every animation frame re-seeks the element ~60x/second and it never
// actually plays - the picture freezes and no audio comes out.
const DRIFT_MAX_SEC = 0.3;
const DRIFT_FIX_COOLDOWN_MS = 500;
// How long to wait after the last edit before fetching the exact frame.
const REFINE_DEBOUNCE_MS = 130;
// How far ahead of the playhead an asset counts as "coming up". Only these get
// preload='auto'; everything else stays on 'metadata'. Creating every element
// with preload='auto' meant every source file in the project started buffering
// in full, concurrently, the moment it was added - the single biggest remaining
// stall with real phone clips.
const PREFETCH_AHEAD_SEC = 4;
const PREFETCH_BEHIND_SEC = 1;
// How long we'll wait for the clips under the playhead to become playable
// before starting the clock anyway.
const PREROLL_TIMEOUT_MS = 2000;
const READY_ENOUGH = 3;   // HAVE_FUTURE_DATA: can play forward from here

export class Preview {
  constructor(canvas, project, assetUrl){
    this.cv = canvas; this.ctx = canvas.getContext('2d');
    this.assetUrl = assetUrl; this.media = new Map(); this._t = 0; this.playing=false; this._seq = 0;
    this._raf = null; this._activeMedia = new Map(); this.onTick = null;
    this._lastFix = new Map();   // clip id -> performance.now() of its last correction
    this._wanted = new Map();    // assetId -> a seek target waiting on the current one
    this._seekBound = new Set(); // assetIds whose 'seeked' listener is attached
    this._scrubbing = false;     // true while the user is dragging the playhead
    this._refineTimer = null;
    this._perClip = new Map();   // clip id -> its own element, when it can't share
    this._playToken = 0;
    this.onBuffering = null;     // host hook: pre-roll started / finished
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
    for(const id of Array.from(this._perClip.keys())) this._disposeOwn(id);
    this.project = p;
    this.cv.width = p.canvas.width; this.cv.height = p.canvas.height;
    this._ensureMedia();
    this.setTime(this._t);
  }
  _ensureMedia(){
    for(const a of this.project.assets){
      if(this.media.has(a.id)) continue;
      if(a.type==='image'){ const img=new Image(); img.src=this.assetUrl(a.id); this.media.set(a.id,{kind:'image',el:img,path:a.path,key:a.id}); }
      else if(a.type==='audio'){ const el=document.createElement('audio'); el.preload='metadata'; el.src=this.assetUrl(a.id); this.media.set(a.id,{kind:'audio',el,path:a.path,key:a.id}); }
      else { const v=document.createElement('video'); v.preload='metadata'; v.crossOrigin='anonymous'; v.src=this.assetUrl(a.id); this.media.set(a.id,{kind:'video',el:v,path:a.path,key:a.id}); }
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
          const m=this._mediaFor(c);
          if(m && (m.kind==='video' || m.kind==='audio')) out.push({tr,c,m});
        }
      }
    }
    return out;
  }
  // Buffer only what's about to be needed. Anything with a clip inside the
  // window around t gets promoted to full buffering; everything else drops
  // back to metadata-only so it stops pulling its whole file over the host.
  _updatePrefetch(t){
    const hot = new Set();
    const from = t - PREFETCH_BEHIND_SEC, to = t + PREFETCH_AHEAD_SEC;
    for(const tr of this.project.tracks){
      for(const c of tr.clips){
        if(c.start < to && (c.start + c.duration) > from) hot.add(c.assetId);
      }
    }
    for(const [id, m] of this.media){
      if(m.kind === 'image') continue;
      const want = hot.has(id) ? 'auto' : 'metadata';
      if(m.el.preload !== want) m.el.preload = want;
    }
    for(const [, m] of this._perClip){
      if(m.kind === 'image') continue;
      if(m.el.preload !== 'auto') m.el.preload = 'auto';
    }
  }

  // Every clip active at t, on any track, regardless of media kind.
  _clipsAtAll(t){
    const out=[];
    for(const tr of this.project.tracks){
      for(const c of tr.clips){ if(t>=c.start && t < c.start+c.duration) out.push({tr,c}); }
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
      const m=this._mediaFor(c); if(!m) continue;
      // Mid-scrub, prefer a tile from the filmstrip: it's already decoded, so
      // it costs nothing and is always in sync with the pointer. The <video>
      // still holds whatever frame it last landed on, which lags the drag.
      if(this._scrubbing && m.kind === 'video' && this._drawStripTile(ctx,W,H,tr,c,t)) continue;
      this._compositeClip(ctx,W,H,tr,c,m);
    }
  }

  // Draws the filmstrip tile nearest this instant, scaled to cover the canvas.
  // Returns false if no strip has been generated for the asset yet.
  _drawStripTile(ctx,W,H,tr,c,t){
    const strip = getStrip(c.assetId);
    if(!strip || !strip.img || !strip.img.complete || !strip.count) return false;
    const local = c.in + (t - c.start);
    const frac = strip.duration > 0 ? (local / strip.duration) : 0;
    const i = Math.max(0, Math.min(strip.count - 1, Math.floor(frac * strip.count)));
    const sx = i * strip.tileW;
    const s = Math.max(W / strip.tileW, H / strip.tileH);
    const dw = strip.tileW * s, dh = strip.tileH * s;
    ctx.globalAlpha = c.opacity ?? 1;
    ctx.drawImage(strip.img, sx, 0, strip.tileW, strip.tileH,
                  (W - dw) / 2, (H - dh) / 2, dw, dh);
    ctx.globalAlpha = 1;
    return true;
  }
  // Scrubbing: draw whatever frames the elements currently hold IMMEDIATELY, and
  // ask for the right frames separately. Seeks are coalesced per element - only
  // one is ever in flight, and a newer target replaces a pending one - so
  // dragging the playhead runs as fast as the decoder can go instead of queueing
  // a seek per mouse move, which is what stalled the picture and cut the audio.
  // While a scrub gesture is in progress we draw from the cached FILMSTRIP and
  // never touch the <video> elements. Seeking a long H.264 file takes hundreds
  // of milliseconds and leaves the decoder busy for seconds afterwards, which
  // is what made jumping the playhead around stall the picture and knock the
  // audio out. The exact frame is fetched once, when you settle or let go.
  setScrubbing(on){
    const was = this._scrubbing;
    this._scrubbing = !!on;
    if(was && !this._scrubbing){
      // If the clock was left running, pick playback back up from wherever the
      // pointer put us rather than from where it had wandered to.
      if(this.playing) this.reanchor(this._t);
      // immediate, not debounced: you've stopped, so the exact frame is wanted now
      else this.refineFrame(true);
    }
  }

  isScrubbing(){ return !!this._scrubbing; }

  // Continue playing from t. Used when you drag the playhead mid-playback:
  // moving the cursor shouldn't stop the video, it should carry on from there.
  reanchor(t){
    this._t = t;
    this._anchorT = t;
    this._anchorPerf = performance.now();
    for(const [, info] of this._activeMedia){ try { info.m.el.pause(); } catch {} }
    this._activeMedia = new Map();   // forces a re-activate + one seek per clip
    this._updateMedia(t);
  }

  // Don't start the clock until the clips under the playhead can actually play.
  // Starting the instant Play was pressed meant the decoder was often still
  // fetching from wherever we'd just scrubbed to, so the first second or two
  // stuttered with no sound. Waiting briefly and then playing cleanly is better
  // than playing badly.
  _waitReady(els, timeoutMs){
    const need = els.filter(e => e && e.readyState < READY_ENOUGH);
    if(!need.length) return Promise.resolve();
    return new Promise((resolve) => {
      let done = false;
      const finish = () => { if(done) return; done = true; cleanup(); resolve(); };
      const check = () => { if(need.every(e => e.readyState >= READY_ENOUGH)) finish(); };
      const cleanup = () => {
        clearTimeout(timer);
        for(const e of need){
          e.removeEventListener('canplay', check);
          e.removeEventListener('canplaythrough', check);
          e.removeEventListener('loadeddata', check);
        }
      };
      for(const e of need){
        e.preload = 'auto';          // NOT load() - that would reset our position
        e.addEventListener('canplay', check);
        e.addEventListener('canplaythrough', check);
        e.addEventListener('loadeddata', check);
      }
      const timer = setTimeout(finish, timeoutMs);
      check();
    });
  }

  // Fetch the true frame for the current time. DEBOUNCED by default: a trim, a
  // split and a delete in quick succession should cost ONE decoder round trip
  // when the dust settles, not one each - that pile-up is what kept the picture
  // stuttering after every edit.
  refineFrame(immediate){
    if(this.playing) return;
    if(this._refineTimer){ clearTimeout(this._refineTimer); this._refineTimer = null; }
    const run = () => {
      this._refineTimer = null;
      if(this.playing) return;
      for(const {c} of this._clipsAt(this._t)){
        const m = this._mediaFor(c);
        if(!m || m.kind === 'image') continue;
        this._requestSeek(m.key, m.el, c.in + (this._t - c.start));
      }
    };
    if(immediate) run(); else this._refineTimer = setTimeout(run, REFINE_DEBOUNCE_MS);
  }

  setTime(t){
    this._t = t;
    this._updatePrefetch(t);
    this._drawVisual(t);
    if(this.playing) return;                 // playback drives its own frames
    if(this._scrubbing) return;              // proxy frames only; refine later
    this.refineFrame();
  }

  // The element a clip should use. Normally that's the one element per asset,
  // but two clips of the SAME asset can be on screen at once (an overlay over
  // the main track, or a split piece re-used) - and one <video> cannot hold two
  // positions or emit two audio streams. The second such clip gets its own
  // element so both are seen AND heard.
  _mediaFor(c){
    const own = this._perClip.get(c.id);
    if(own) return own;
    return this.media.get(c.assetId) || null;
  }

  // Hand out per-clip elements for whichever active clips collide on an asset.
  _resolveSharing(active){
    const claimed = new Set();
    for(const {c} of active){
      const base = this.media.get(c.assetId);
      if(!base) continue;
      if(!claimed.has(c.assetId)){
        claimed.add(c.assetId);
        const own = this._perClip.get(c.id);
        if(own && own.el !== base.el){ this._disposeOwn(c.id); }
        continue;
      }
      if(this._perClip.has(c.id)) continue;
      if(base.kind === 'image') continue;
      const el = document.createElement(base.kind === 'audio' ? 'audio' : 'video');
      el.preload = 'auto'; el.crossOrigin = 'anonymous'; el.src = base.el.src;
      this._perClip.set(c.id, { kind: base.kind, el, path: base.path, key: 'clip:' + c.id });
    }
  }

  _disposeOwn(clipId){
    const own = this._perClip.get(clipId);
    if(!own) return;
    try { own.el.pause(); own.el.removeAttribute('src'); own.el.load(); } catch {}
    this._perClip.delete(clipId);
    this._seekBound.delete(own.key);
    this._wanted.delete(own.key);
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
    this._updatePrefetch(t);
    // Give any clips that collide on one asset their own element FIRST, so two
    // overlapping clips are both audible instead of fighting over one <video>.
    this._resolveSharing(this._clipsAtAll(t));
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
        // Only seek if it isn't effectively there already: a redundant seek
        // costs a full decoder round trip before any audio comes out, which is
        // what made pressing play after a scrub take seconds.
        if(Math.abs(el.currentTime - expected) > 0.08) el.currentTime = expected;
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
  async play(){
    if(this.playing) return;
    const total = totalDuration(this.project);
    if(total <= 0) return;                       // nothing on the timeline yet
    // Pressing Play with the playhead parked at the end used to end playback on
    // the very first frame, which looked exactly like "Play does nothing".
    if(this._t >= total - 0.001) this._t = 0;
    this.playing = true;
    const token = ++this._playToken;

    this._updatePrefetch(this._t);
    const els = this._playableClipsAt(this._t).map(x => x.m.el);
    if(this.onBuffering) this.onBuffering(true);
    await this._waitReady(els, PREROLL_TIMEOUT_MS);
    if(this.onBuffering) this.onBuffering(false);
    if(token !== this._playToken || !this.playing) return;   // paused while waiting

    this._anchorPerf = performance.now();
    this._anchorT = this._t;
    const loop = (now) => {
      if(!this.playing) return;
      let t = this._anchorT + (now - this._anchorPerf)/1000;
      let ended = false;
      if(t >= total){ t = total; ended = true; }
      this._t = t;
      this._updateMedia(t);
      // While the playhead is being dragged, the canvas belongs to the scrub
      // (proxy frames at the pointer) and the red line belongs to the pointer.
      if(!this._scrubbing) this._drawVisual(t);
      if(ended){ this.pause(); }
      if(this.onTick) this.onTick(t);
      if(!ended){ this._raf = requestAnimationFrame(loop); }
    };
    this._raf = requestAnimationFrame(loop);
  }
  pause(){
    this.playing = false;
    this._playToken++;              // abandon any pre-roll in flight
    if(this._raf){ cancelAnimationFrame(this._raf); this._raf = null; }
    for(const [, info] of this._activeMedia) info.m.el.pause();
    this._activeMedia = new Map();
    this._lastFix = new Map();
  }
  get time(){ return this._t; }
}
