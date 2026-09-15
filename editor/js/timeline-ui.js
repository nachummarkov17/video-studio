// timeline-ui.js — the timeline's structure: zoom, the ruler, the lanes, and
// where a drop lands. Clip elements are clip-view.js; mouse gestures are
// timeline-gestures.js.
//
// Coordinate model: all horizontal maths is relative to the stable `#tracks`
// element's left edge (it is only ever mutated via innerHTML, never replaced,
// so its bounding rect stays valid even mid-drag while a commit() is
// re-rendering the clips underneath the pointer). Every lane starts LABEL_WIDTH
// px right of that edge, matching `.track-label{width:64px}`.

import { addTrackForType, laneRows, findClip } from './model.js';
import {
  secToPx, pxToSec, totalDuration, fitPxPerSec, zoomBy, clampZoom,
  tailPaddingSec, tickStep, ZOOM_FACTOR, ZOOM_MIN, ZOOM_MAX,
} from './timeline.js';
import { ClipViews } from './clip-view.js';
import { TimelineGestures } from './timeline-gestures.js';

const LABEL_WIDTH = 64;
const DEFAULT_PX_PER_SEC = 100;
const MIN_CONTENT_SEC = 15;
const FIT_PADDING_PX = 24;   // breathing room so a fitted clip isn't flush to the edge

export class TimelineUI {
  constructor(root, app) {
    this.root = root;
    this.app = app;
    this.ruler = root.querySelector('#ruler');
    this.tracksEl = root.querySelector('#tracks');
    this.playheadEl = root.querySelector('#playhead');

    this._laneEls = new Map();   // track id -> its lane element, rebuilt per render

    this.gestures = new TimelineGestures(this, app);
    this.clips = new ClipViews(app, {
      onDrag: (e, id) => this.gestures.startClipDrag(e, id),
      onTrim: (e, id, edge) => this.gestures.startTrim(e, id, edge),
      onMenu: (e, id) => {
        this.select(id);
        if (this.app.showClipMenu) this.app.showClipMenu(id, e.clientX, e.clientY);
      },
      onStripReady: () => this.render(),
    });

    if (this.app.pxPerSec == null) this.app.pxPerSec = DEFAULT_PX_PER_SEC;

    // Scrub by pressing anywhere on the ruler, or by grabbing the playhead's
    // head. Both elements are stable, so these are wired once.
    if (this.ruler) this.ruler.addEventListener('mousedown', (e) => this.gestures.startScrub(e));
    const grab = this.playheadEl && this.playheadEl.querySelector('.playhead-grab');
    if (grab) grab.addEventListener('mousedown', (e) => { e.stopPropagation(); this.gestures.startScrub(e); });

    this.render();
  }

  get pxPerSec() { return this.app.pxPerSec; }
  set pxPerSec(v) { this.app.pxPerSec = clampZoom(v); }

  // `direction` is +1 to zoom in, -1 to zoom out.
  zoom(direction) {
    this.pxPerSec = zoomBy(this.pxPerSec, direction > 0 ? ZOOM_FACTOR : 1 / ZOOM_FACTOR);
    this.render();
  }

  // Show the whole timeline at once, tail included - if Fit leaves anything off
  // screen it hasn't fitted. Runs after every drop/import/load; manual zoom wins
  // until the next one.
  zoomToFit() {
    const viewport = (this.root.clientWidth || 0) - LABEL_WIDTH - FIT_PADDING_PX;
    const content = this.contentSeconds();
    if (!(content > 0)) return;
    this.pxPerSec = fitPxPerSec(viewport, content, ZOOM_MIN, ZOOM_MAX);
    this.render();
  }

  // How much time the timeline draws: the project plus a little room to drop
  // something after it, and never so little that a nearly-empty project looks
  // broken.
  contentSeconds() {
    const total = totalDuration(this.app.project);
    return Math.max(total + tailPaddingSec(total), MIN_CONTENT_SEC);
  }

  render() {
    this._contentSec = this.contentSeconds();
    this._contentPx = secToPx(this._contentSec, this.pxPerSec);
    this._totalPx = LABEL_WIDTH + this._contentPx;
    this._renderRuler();
    this._renderTracks();
    this.setPlayhead(this.app.playhead || 0);
  }

  // Geometry-only update: moves and resizes the clip elements that already
  // exist, and nothing else. One update per animation frame during a drag - no
  // DOM rebuilds, no filmstrip re-assignment.
  renderGeometry() {
    for (const track of this.app.project.tracks) {
      const lane = this._laneEls.get(track.id);
      for (const clip of track.clips) {
        const el = this.clips.get(clip.id);
        if (!el) { this.render(); return; }        // something new appeared
        if (lane && el.parentNode !== lane) lane.appendChild(el);
        this.clips.place(el, clip, this.pxPerSec);
      }
    }
  }

  setPlayhead(t) {
    this.app.playhead = Math.max(0, t);
    const px = secToPx(this.app.playhead, this.pxPerSec);
    if (this.playheadEl) this.playheadEl.style.left = (LABEL_WIDTH + px) + 'px';
    if (this.app.onPlayheadChange) this.app.onPlayheadChange();
  }

  select(id) {
    this.app.selectedId = id;
    const found = findClip(this.app.project, id);
    if (found && this.app.inspector) this.app.inspector.show(found.clip);
    else if (this.app.inspector) this.app.inspector.clear();
    this.render();
  }

  // Light the playhead up when an edge has grabbed onto it, so it's obvious the
  // cut will land exactly there.
  setSnapIndicator(on) {
    if (this.playheadEl) this.playheadEl.classList.toggle('is-snapped', !!on);
  }

  snapped(t, excludeClipId) { return this.gestures.snapped(t, excludeClipId); }

  clientXToTime(clientX) {
    const rect = this.tracksEl.getBoundingClientRect();
    return Math.max(0, pxToSec(clientX - rect.left - LABEL_WIDTH, this.pxPerSec));
  }

  // ---- rendering -------------------------------------------------------

  _renderRuler() {
    if (!this.ruler) return;
    this.ruler.innerHTML = '';
    this.ruler.style.position = 'relative';
    this.ruler.style.backgroundImage = 'none';
    this.ruler.style.width = this._totalPx + 'px';

    const ticks = document.createElement('div');
    ticks.className = 'ruler-ticks';
    ticks.style.cssText = `position:absolute; left:${LABEL_WIDTH}px; top:0; bottom:0; width:${this._contentPx}px;`;

    // The step grows as you zoom out; at the zoom floor a fixed step would emit
    // tens of thousands of nodes.
    const step = tickStep(this.pxPerSec);
    for (let s = 0; s <= this._contentSec; s += step) {
      const x = secToPx(s, this.pxPerSec);
      const tick = document.createElement('div');
      tick.style.cssText = `position:absolute; left:${x}px; top:0; bottom:0; width:1px; background:var(--border-strong);`;
      const label = document.createElement('span');
      label.textContent = this._formatTime(s);
      label.style.cssText = `position:absolute; left:${x + 3}px; top:2px; font-size:10px; color:var(--text-dim); white-space:nowrap;`;
      ticks.appendChild(tick);
      ticks.appendChild(label);
    }
    this.ruler.appendChild(ticks);
  }

  // Nothing is pre-drawn. An empty project is one big "Drag material here"
  // area; once lanes exist, a thin drop strip sits above and below the stack so
  // dropping there adds a lane. Which KIND of lane is decided by what you drop
  // (video/image above, audio below), never by which strip you used.
  _renderTracks() {
    if (!this.tracksEl) return;
    this.tracksEl.innerHTML = '';     // detaches clip elements; we re-append them
    this.tracksEl.style.width = this._totalPx + 'px';
    this._laneEls.clear();

    const rows = laneRows(this.app.project);
    if (rows.length === 0) {
      this.tracksEl.appendChild(this._renderEmptyArea());
    } else {
      this.tracksEl.appendChild(this._renderDropStrip('above'));
      for (const track of rows) this.tracksEl.appendChild(this._renderTrackRow(track));
      this.tracksEl.appendChild(this._renderDropStrip('below'));
    }

    const alive = new Set();
    for (const t of this.app.project.tracks) for (const c of t.clips) alive.add(c.id);
    this.clips.prune(alive);
  }

  _renderEmptyArea() {
    const el = document.createElement('div');
    el.className = 'timeline-empty';
    el.textContent = 'Drag material here';
    el.style.width = this._totalPx + 'px';
    this._wireLaneCreator(el);
    el.addEventListener('mousedown', (e) => { if (e.target === el) this.gestures.startScrub(e); });
    return el;
  }

  // Two strips, each labelled with what it actually makes. Video and photos
  // always stack ABOVE the main lane (anything below it would be hidden behind
  // full-frame video); audio always hangs BELOW. Rather than silently sending a
  // video dropped on the bottom strip to the top, the strip that will really
  // receive it is the one that lights up.
  _renderDropStrip(where) {
    const el = document.createElement('div');
    el.className = 'drop-strip drop-strip-' + where;
    el.dataset.where = where;
    el.textContent = where === 'above' ? '+  Video / photo lane' : '+  Audio lane';
    el.style.width = this._totalPx + 'px';
    this._wireLaneCreator(el);
    el.addEventListener('mousedown', (e) => { if (e.target === el) this.gestures.startScrub(e); });
    return el;
  }

  // Which strip a dragged item will land in, judged from the drag's MIME types
  // (values aren't readable during dragover, but the type list is).
  _stripForDrag(dt) {
    const types = dt ? Array.from(dt.types || []) : [];
    if (types.includes('application/x-asset-audio')) return 'below';
    if (types.includes('application/x-asset-video') || types.includes('application/x-asset-image')) return 'above';
    return null;   // unknown: let whichever strip is hovered take it
  }

  _wireLaneCreator(el) {
    el.addEventListener('dragover', (e) => {
      e.preventDefault();
      const target = this._stripForDrag(e.dataTransfer);
      const mine = el.dataset.where || null;
      const lit = !target || !mine || target === mine;
      el.classList.toggle('is-over', lit);
      if (target && mine && target !== mine) {
        const other = this.tracksEl.querySelector('.drop-strip-' + target);
        if (other) other.classList.add('is-over');
      }
    });
    el.addEventListener('dragleave', () => {
      el.classList.remove('is-over');
      for (const s of this.tracksEl.querySelectorAll('.drop-strip')) s.classList.remove('is-over');
    });
    el.addEventListener('drop', (e) => {
      for (const s of this.tracksEl.querySelectorAll('.drop-strip')) s.classList.remove('is-over');
      el.classList.remove('is-over');
      this._onDropNewLane(e);
    });
  }

  _renderTrackRow(track) {
    const row = document.createElement('div');
    row.className = `track track-${track.kind}`;
    row.dataset.trackId = track.id;
    row.dataset.kind = track.kind;
    row.style.width = this._totalPx + 'px';

    const label = document.createElement('span');
    label.className = 'track-label';
    label.textContent = track.kind.charAt(0).toUpperCase() + track.kind.slice(1);

    const lane = document.createElement('div');
    lane.className = 'track-lane';
    lane.dataset.trackId = track.id;
    lane.style.width = this._contentPx + 'px';
    this._laneEls.set(track.id, lane);

    lane.addEventListener('dragover', (e) => e.preventDefault());
    lane.addEventListener('drop', (e) => this._onDrop(e, track.id));
    lane.addEventListener('mousedown', (e) => {
      if (e.target !== lane) return;   // empty space in the lane, not a clip
      this.gestures.startScrub(e);
    });

    for (const clip of track.clips) lane.appendChild(this.clips.sync(clip, track, this.pxPerSec));

    row.appendChild(label);
    row.appendChild(lane);
    return row;
  }

  // ---- drops -----------------------------------------------------------

  _assetFromDrop(e) {
    const data = e.dataTransfer.getData('application/x-asset');
    if (!data) return null;
    try { return JSON.parse(data); } catch { return null; }
  }

  _addAt(info, trackId, clientX) {
    const dropTime = this.clientXToTime(clientX);
    // a b-roll row dragged after being trimmed carries its selection with it
    const trim = (info.trimIn != null && info.trimOut > info.trimIn)
      ? { in: info.trimIn, duration: info.trimOut - info.trimIn }
      : null;
    this.app.addAssetAndClip(info, trackId, dropTime, trim).catch((err) => {
      console.error('[drop] Failed to add asset:', err);
      const statusPill = document.getElementById('status-text');
      if (statusPill) {
        statusPill.textContent = "Couldn't add that file";
        setTimeout(() => { statusPill.textContent = 'bridge OK'; }, 2500);
      }
    });
  }

  _onDrop(e, trackId) {
    e.preventDefault();
    const info = this._assetFromDrop(e);
    if (!info) return;
    this.app.pushHistory();
    this._addAt(info, trackId, e.clientX);
  }

  // Dropped on a strip (or on the empty timeline): make the lane first.
  _onDropNewLane(e) {
    e.preventDefault();
    const info = this._assetFromDrop(e);
    if (!info) return;
    this.app.pushHistory();
    const trackId = addTrackForType(this.app.project, info.type);
    this._addAt(info, trackId, e.clientX);
  }

  // ---- helpers ---------------------------------------------------------

  _formatTime(s) {
    const m = Math.floor(s / 60);
    const sec = Math.floor(s % 60);
    return `${m}:${String(sec).padStart(2, '0')}`;
  }
}
