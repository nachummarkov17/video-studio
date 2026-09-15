// A DOM small enough to test the preview engine against, and honest about the
// one thing the tests care about: HOW MANY TIMES an element is asked to seek.
// Every stall the preview rewrite is about traces back to a seek, so counting
// them is the measurement.

export class FakeMedia {
  constructor(tag) {
    this.tag = tag;
    this.paused = true;
    this.readyState = 0;
    this.seeking = false;
    this.preload = '';
    this.volume = 1;
    this.muted = false;
    this.seekCount = 0;
    this.loadCount = 0;
    this.playCount = 0;
    this._src = '';
    this._time = 0;
    this._listeners = new Map();
  }
  get src() { return this._src; }
  set src(v) { this._src = v; this.loadCount++; }
  get currentTime() { return this._time; }
  set currentTime(v) { this._time = v; this.seekCount++; }
  play() { this.paused = false; this.playCount++; return Promise.resolve(); }
  pause() { this.paused = true; }
  load() {}
  removeAttribute() { this._src = ''; }
  addEventListener(k, fn) {
    if (!this._listeners.has(k)) this._listeners.set(k, []);
    this._listeners.get(k).push(fn);
  }
  removeEventListener(k, fn) {
    const l = this._listeners.get(k);
    if (l) this._listeners.set(k, l.filter(f => f !== fn));
  }
  emit(k) { for (const fn of (this._listeners.get(k) || [])) fn(); }
}

class FakeCanvasContext {
  constructor() { this.calls = []; this.globalAlpha = 1; this.fillStyle = ''; }
  clearRect() { this.calls.push('clearRect'); }
  fillRect() { this.calls.push('fillRect'); }
  drawImage(...a) { this.calls.push(['drawImage', a.length]); }
  save() {} restore() {} beginPath() {} rect() {} clip() {}
}

export function makeCanvas(w = 100, h = 100) {
  const ctx = new FakeCanvasContext();
  return { width: w, height: h, getContext: () => ctx, ctx };
}

// Installs just enough globals for the editor modules to import and run.
// `document` also carries a tiny event bus, because the drag gestures listen on
// it for mousemove/mouseup - driving those by hand is the only way to test what
// a drag actually does to the project.
export function installFakeDom() {
  const created = [];
  const listeners = new Map();
  globalThis.window = globalThis.window || {};
  globalThis.document = {
    body: { classList: { add() {}, remove() {} } },
    createElement(tag) {
      if (tag === 'canvas') return makeCanvas();
      const el = new FakeMedia(tag);
      created.push(el);
      return el;
    },
    addEventListener(type, fn) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(fn);
    },
    removeEventListener(type, fn) {
      const l = listeners.get(type);
      if (l) listeners.set(type, l.filter(f => f !== fn));
    },
    elementFromPoint() { return null; },
    fire(type, event) { for (const fn of [...(listeners.get(type) || [])]) fn(event); },
  };
  globalThis.Image = class { constructor() { this.complete = false; this.naturalWidth = 0; this.naturalHeight = 0; } };
  return created;
}
