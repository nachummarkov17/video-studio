// media-pool.js — who owns the <video>/<audio> elements, and where each one is
// parked.
//
// THE BUG THIS FILE EXISTS TO KILL. There used to be exactly ONE element per
// ASSET. Two clips cut from the same source therefore shared it, so at every
// cut the element had to seek from wherever the outgoing clip left it to
// wherever the incoming clip starts. On a real project that is a jump of
// minutes, and a seek in a full-size H.264 file costs hundreds of milliseconds
// and leaves the decoder busy for a second or two afterwards. That is exactly
// the "it lags for a second or two when the playhead crosses a cut" report.
//
// Elements are bound to a CLIP here, and the scheduler asks for the ones that
// are ABOUT to be needed as well as the ones playing now. An upcoming clip is
// seeked to its in-point and left paused while the current clip is still
// running, so arriving at the cut costs a play() and nothing else.
//
// Elements are pooled and reused: binding is cheap when a free element already
// holds the same source, and the pool is capped so a long project can't end up
// holding a decoder open for every clip in it.

const MAX_VIDEO_ELEMENTS = 6;
const MAX_AUDIO_ELEMENTS = 4;
// Anything closer than this counts as "already there" - seeking to shave off a
// few milliseconds costs a full decoder round trip and buys nothing.
const SEEK_EPSILON = 0.04;
// How far the element may be from where we want it and still be treated as
// showing the right picture.
const FRAME_TOLERANCE = 0.25;

let uid = 0;

export class MediaPool {
  // urlFor(asset) -> the URL to load. Kept as a callback so the app can hand
  // back a small preview proxy when one exists and the master when it doesn't.
  constructor(urlFor) {
    this.urlFor = urlFor;
    this._bound = new Map();     // clipId -> entry
    this._free = [];             // entries available for reuse, oldest first
    this._images = new Map();    // assetId -> Image (cheap; not pooled)
    this._counts = { video: 0, audio: 0 };
  }

  // ---- images ----------------------------------------------------------

  image(asset) {
    let img = this._images.get(asset.id);
    if (!img || img.__url !== this.urlFor(asset)) {
      img = new Image();
      img.__url = this.urlFor(asset);
      img.src = img.__url;
      this._images.set(asset.id, img);
    }
    return { kind: 'image', el: img, exact: true };
  }

  // ---- binding ---------------------------------------------------------

  get(clipId) { return this._bound.get(clipId) || null; }

  // Get (or make) this clip's own element. Reuses a free element with the same
  // source first - that costs nothing - then any free element, then creates one
  // if we're under the cap. Returns null only if we're at the cap and every
  // element is in use, which the scheduler treats as "not ready yet".
  bind(clip, asset) {
    const existing = this._bound.get(clip.id);
    const url = this.urlFor(asset);
    if (existing) {
      if (existing.url === url) return existing;
      this.release(clip.id);                 // source changed (proxy arrived)
    }
    const kind = asset.type === 'audio' ? 'audio' : 'video';
    const entry = this._take(kind, url);
    if (!entry) return null;
    entry.clipId = clip.id;
    entry.assetId = asset.id;
    entry.target = null;
    this._bound.set(clip.id, entry);
    return entry;
  }

  release(clipId) {
    const entry = this._bound.get(clipId);
    if (!entry) return;
    this._bound.delete(clipId);
    try { entry.el.pause(); } catch {}
    entry.clipId = null;
    entry.target = null;
    entry.el.preload = 'metadata';
    entry.freedAt = ++uid;
    this._free.push(entry);
    this._trim();
  }

  pauseAll() {
    for (const [, entry] of this._bound) { try { entry.el.pause(); } catch {} }
  }

  // Release everything not in `keep` (a Set of clip ids).
  retain(keep) {
    for (const id of Array.from(this._bound.keys())) {
      if (!keep.has(id)) this.release(id);
    }
  }

  // Drop every idle element so the next bind picks up a changed URL - used when
  // a preview proxy finishes building mid-session.
  dropIdle() {
    for (const entry of this._free) this._destroy(entry);
    this._free.length = 0;
  }

  destroy() {
    for (const id of Array.from(this._bound.keys())) this.release(id);
    this.dropIdle();
    this._images.clear();
  }

  // ---- positioning -----------------------------------------------------

  // Ask this element to sit at `time`. Only ONE seek is ever in flight per
  // element; a newer request replaces a pending one rather than queueing behind
  // it, so dragging never builds up a backlog of seeks to work through.
  seek(entry, time) {
    if (!entry || !(time >= 0)) return;
    entry.target = time;
    const el = entry.el;
    if (Math.abs(el.currentTime - time) < SEEK_EPSILON) return;
    if (el.seeking) { entry.pending = time; return; }
    entry.pending = null;
    el.currentTime = time;
  }

  // True when the element is actually showing (or can immediately show) the
  // frame at `time`. The compositor uses this to decide whether to draw the
  // element or a filmstrip tile standing in for it.
  frameIsAt(entry, time) {
    if (!entry) return false;
    const el = entry.el;
    if (el.readyState < 2) return false;              // HAVE_CURRENT_DATA
    if (el.seeking) return false;
    return Math.abs(el.currentTime - time) <= FRAME_TOLERANCE;
  }

  // Everything that has to happen for a clip to start playing instantly later:
  // buffer it, and park it on its first frame.
  preroll(entry, time) {
    if (!entry) return;
    entry.el.preload = 'auto';
    this.seek(entry, time);
  }

  ready(entry) { return entry && entry.el.readyState >= 3; }   // HAVE_FUTURE_DATA

  // Wait (briefly) for these entries to be playable. Starting the clock while
  // the decoder is still fetching is what made the first second after pressing
  // play stutter with no sound.
  waitReady(entries, timeoutMs) {
    const need = entries.filter(e => e && e.el.readyState < 3).map(e => e.el);
    if (!need.length) return Promise.resolve();
    return new Promise((resolve) => {
      let done = false;
      const finish = () => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        for (const el of need) {
          el.removeEventListener('canplay', check);
          el.removeEventListener('canplaythrough', check);
          el.removeEventListener('loadeddata', check);
        }
        resolve();
      };
      const check = () => { if (need.every(el => el.readyState >= 3)) finish(); };
      for (const el of need) {
        el.preload = 'auto';               // NOT load(): that resets the position
        el.addEventListener('canplay', check);
        el.addEventListener('canplaythrough', check);
        el.addEventListener('loadeddata', check);
      }
      const timer = setTimeout(finish, timeoutMs);
      check();
    });
  }

  // ---- internals -------------------------------------------------------

  _take(kind, url) {
    // same source, already loaded: the cheapest possible reuse
    for (let i = 0; i < this._free.length; i++) {
      const e = this._free[i];
      if (e.kind === kind && e.url === url) { this._free.splice(i, 1); return e; }
    }
    const cap = kind === 'audio' ? MAX_AUDIO_ELEMENTS : MAX_VIDEO_ELEMENTS;
    if (this._counts[kind] < cap) return this._create(kind, url);
    // recycle the element that has been idle longest
    for (let i = 0; i < this._free.length; i++) {
      const e = this._free[i];
      if (e.kind !== kind) continue;
      this._free.splice(i, 1);
      this._point(e, url);
      return e;
    }
    return null;                            // everything is in use
  }

  _create(kind, url) {
    const el = document.createElement(kind === 'audio' ? 'audio' : 'video');
    el.preload = 'metadata';
    el.crossOrigin = 'anonymous';
    el.src = url;
    this._counts[kind]++;
    const entry = { id: ++uid, kind, el, url, clipId: null, assetId: null, target: null, pending: null };
    el.addEventListener('seeked', () => {
      const next = entry.pending;
      if (next != null) { entry.pending = null; this.seek(entry, next); }
      if (this.onSeeked) this.onSeeked(entry);
    });
    return entry;
  }

  _point(entry, url) {
    if (entry.url === url) return;
    entry.url = url;
    entry.el.src = url;
    entry.pending = null;
    entry.target = null;
  }

  _destroy(entry) {
    try { entry.el.pause(); entry.el.removeAttribute('src'); entry.el.load(); } catch {}
    this._counts[entry.kind]--;
  }

  // Keep the free list small - an idle <video> still holds a decoder and its
  // buffered data.
  _trim() {
    const keepFree = 3;
    while (this._free.length > keepFree) this._destroy(this._free.shift());
  }
}
