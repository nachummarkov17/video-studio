// preview.js — the playback clock and the schedule that keeps the media pool
// one step ahead of it. Drawing lives in compositor.js; element ownership lives
// in media-pool.js. This file decides WHAT should be on screen and WHEN.
//
// The scheduler is the whole point. For any instant t it cares about two sets:
//
//   ACTIVE   clips covering t          -> playing, at the right position
//   UPCOMING clips starting soon after -> paused, ALREADY SEEKED to their
//                                         in-point, buffered
//
// Reaching a cut therefore costs one play() call. Before this, a cut meant
// seeking the single shared element from wherever the outgoing clip ended to
// wherever the incoming clip starts - a jump of minutes in a real edit - and
// playback froze for as long as that took.

import { totalDuration } from './timeline.js';
import { getAsset } from './model.js';
import { MediaPool } from './media-pool.js';
import { Compositor } from './compositor.js';

// How far ahead a clip counts as "coming up".
const LOOKAHEAD_SEC = 2.5;
// How far a playing element may drift from the clock before it is nudged, and
// how long we must leave it alone between nudges. Correcting harder than this
// starves the decoder and playback dies rather than tightens up.
const DRIFT_MAX_SEC = 0.3;
const DRIFT_FIX_COOLDOWN_MS = 500;
// A trim, a split and a delete in quick succession should cost ONE decoder
// round trip when the dust settles, not one each.
const REFINE_DEBOUNCE_MS = 120;
// How long we'll wait for the clips under the playhead to become playable
// before starting the clock anyway.
const PREROLL_TIMEOUT_MS = 1500;

export class Preview {
  constructor(canvas, project, assetUrl) {
    this.assetUrl = assetUrl;
    this.compositor = new Compositor(canvas);
    this.pool = new MediaPool((asset) => this.assetUrl(asset.id));
    this.playing = false;
    this.onTick = null;
    this.onBuffering = null;
    this._t = 0;
    this._raf = null;
    this._scrubbing = false;
    this._refineTimer = null;
    this._lastFix = new Map();
    this._playToken = 0;
    // a seek landing while paused means a better frame is available now
    this.pool.onSeeked = () => { if (!this.playing) this._draw(this._t); };
    this.setProject(project);
  }

  setProject(p) {
    this.project = p;
    const alive = new Set();
    for (const tr of p.tracks) for (const c of tr.clips) alive.add(c.id);
    this.pool.retain(alive);
    this.compositor.resize(p.canvas.width, p.canvas.height);
    this._lastFix = new Map();
    this.setTime(this._t);
  }

  // Called when the host finishes building a preview proxy: idle elements are
  // dropped so they pick the new URL up next time they're bound. Anything
  // playing right now keeps its current source until it is released, which is
  // what stops the picture blinking mid-playback.
  refreshSources() {
    this.pool.dropIdle();
    if (!this.playing) this.setTime(this._t);
  }

  get time() { return this._t; }

  // ---- what is on screen at t ------------------------------------------

  _clipsAt(t) {
    const out = [];
    for (const tr of this.project.tracks) {
      for (const c of tr.clips) {
        if (t >= c.start && t < c.start + c.duration) out.push({ tr, c });
      }
    }
    return out;
  }

  _upcoming(t) {
    const out = [];
    const until = t + LOOKAHEAD_SEC;
    for (const tr of this.project.tracks) {
      for (const c of tr.clips) {
        if (c.start > t && c.start <= until) out.push({ tr, c });
      }
    }
    return out;
  }

  // ---- the scheduler ---------------------------------------------------

  _schedule(t, playing) {
    const active = this._clipsAt(t);
    const soon = this._upcoming(t);

    const keep = new Set();
    for (const { c } of active) keep.add(c.id);
    for (const { c } of soon) keep.add(c.id);
    this.pool.retain(keep);

    const now = (typeof performance !== 'undefined' ? performance.now() : Date.now());

    for (const { c } of active) {
      const asset = getAsset(this.project, c.assetId);
      if (!asset || asset.type === 'image') continue;
      const entry = this.pool.bind(c, asset);
      if (!entry) continue;
      const el = entry.el;
      el.preload = 'auto';
      el.volume = c.volume ?? 1;
      el.muted = !!c.muted;
      const expected = c.in + (t - c.start);

      if (!playing) { if (!el.paused) el.pause(); continue; }

      if (el.paused) {
        // Pre-rolled clips are already here, so this is usually a no-op - which
        // is exactly why crossing a cut no longer stalls.
        if (Math.abs(el.currentTime - expected) > 0.08) this.pool.seek(entry, expected);
        this._lastFix.set(c.id, now);
        const p = el.play();
        if (p && p.catch) p.catch(e => console.warn('media play failed:', e));
      } else if (!el.seeking &&
                 Math.abs(el.currentTime - expected) > DRIFT_MAX_SEC &&
                 (now - (this._lastFix.get(c.id) ?? 0)) > DRIFT_FIX_COOLDOWN_MS) {
        el.currentTime = expected;
        this._lastFix.set(c.id, now);
      }
    }

    // Park the next clips on their first frame while there's still time.
    for (const { c } of soon) {
      const asset = getAsset(this.project, c.assetId);
      if (!asset || asset.type === 'image') continue;
      const entry = this.pool.bind(c, asset);
      if (!entry) continue;
      if (!entry.el.paused) entry.el.pause();
      this.pool.preroll(entry, c.in);
    }
  }

  _layers(t) {
    const out = [];
    for (const tr of this.project.tracks) {
      if (tr.kind === 'audio') continue;                  // contributes no picture
      for (const c of tr.clips) {
        if (!(t >= c.start && t < c.start + c.duration)) continue;
        const asset = getAsset(this.project, c.assetId);
        if (!asset) continue;
        const local = c.in + (t - c.start);
        const common = {
          cover: tr.kind === 'main',
          assetId: c.assetId,
          localTime: local,
          sourceDuration: asset.duration,
          opacity: c.opacity, x: c.x, y: c.y, scale: c.scale,
        };
        if (asset.type === 'image') {
          out.push({ ...common, ...this.pool.image(asset) });
          continue;
        }
        const entry = this.pool.get(c.id);
        const el = entry ? entry.el : null;
        // While dragging, never trust the element: it is wherever the last
        // completed seek left it, which lags the pointer badly.
        const exact = this._scrubbing ? false
          : this.playing ? !!(el && el.readyState >= 2 && !el.seeking)
          : this.pool.frameIsAt(entry, local);
        out.push({ ...common, el, kind: 'video', exact });
      }
    }
    return out;
  }

  _draw(t) { this.compositor.draw(this._layers(t)); }

  // ---- public surface --------------------------------------------------

  setTime(t) {
    this._t = t;
    // Mid-drag we draw from filmstrips and touch nothing else. Seeking a
    // full-size clip per mouse move is what made scrubbing crawl.
    if (this._scrubbing) { this._draw(t); return; }
    this._schedule(t, this.playing);
    this._draw(t);
    if (!this.playing) this.refineFrame();
  }

  setScrubbing(on) {
    const was = this._scrubbing;
    this._scrubbing = !!on;
    if (!was || this._scrubbing) return;
    if (this.playing) this.reanchor(this._t);
    else { this._schedule(this._t, false); this.refineFrame(true); }
  }

  isScrubbing() { return !!this._scrubbing; }

  // Carry on playing from t. Dragging the playhead mid-playback shouldn't stop
  // the video, it should pick up from wherever you dropped it.
  reanchor(t) {
    this._t = t;
    this._anchorT = t;
    this._anchorPerf = performance.now();
    this.pool.pauseAll();
    this._lastFix = new Map();
    this._schedule(t, true);
  }

  // Fetch the true frame for the current time. Debounced by default so a burst
  // of edits costs one decoder round trip rather than one each.
  refineFrame(immediate) {
    if (this.playing) return;
    if (this._refineTimer) { clearTimeout(this._refineTimer); this._refineTimer = null; }
    const run = () => {
      this._refineTimer = null;
      if (this.playing) return;
      for (const { c } of this._clipsAt(this._t)) {
        const asset = getAsset(this.project, c.assetId);
        if (!asset || asset.type === 'image') continue;
        const entry = this.pool.bind(c, asset);
        if (entry) this.pool.seek(entry, c.in + (this._t - c.start));
      }
    };
    if (immediate) run(); else this._refineTimer = setTimeout(run, REFINE_DEBOUNCE_MS);
  }

  async play() {
    if (this.playing) return;
    const total = totalDuration(this.project);
    if (total <= 0) return;
    // Pressing Play parked at the end used to end playback on the first frame,
    // which looked exactly like "Play does nothing".
    if (this._t >= total - 0.001) this._t = 0;
    this.playing = true;
    const token = ++this._playToken;

    this._schedule(this._t, false);        // bind + position without starting
    const entries = this._clipsAt(this._t)
      .map(x => this.pool.get(x.c.id))
      .filter(Boolean);
    if (this.onBuffering) this.onBuffering(true);
    await this.pool.waitReady(entries, PREROLL_TIMEOUT_MS);
    if (this.onBuffering) this.onBuffering(false);
    if (token !== this._playToken || !this.playing) return;

    this._anchorPerf = performance.now();
    this._anchorT = this._t;
    const loop = (now) => { if (this._tick(now)) this._raf = requestAnimationFrame(loop); };
    this._raf = requestAnimationFrame(loop);
  }

  // One frame of playback. Split out of the rAF loop so a test can drive it
  // directly - requestAnimationFrame is unreliable headless, and a probe that
  // reimplements this by hand proves nothing about the code that runs.
  _tick(now) {
    if (!this.playing) return false;

    // WHILE DRAGGING, THE POINTER OWNS THE TIME. The clock freezes and keeps
    // re-basing onto wherever the scrub put us, so letting go carries on from
    // there instead of snapping back to where playback had wandered to.
    if (this._scrubbing) {
      this._anchorT = this._t;
      this._anchorPerf = now;
      return true;
    }

    const total = totalDuration(this.project);
    let t = this._anchorT + (now - this._anchorPerf) / 1000;
    let ended = false;
    if (t >= total) { t = total; ended = true; }
    this._t = t;
    this._schedule(t, true);
    this._draw(t);
    if (ended) this.pause();
    if (this.onTick) this.onTick(t);
    return !ended;
  }

  pause() {
    this.playing = false;
    this._playToken++;                    // abandon any pre-roll in flight
    if (this._raf) { cancelAnimationFrame(this._raf); this._raf = null; }
    this.pool.pauseAll();
    this._lastFix = new Map();
  }
}
