// Timeline UI: renders tracks/clips, and drives drag-move, trim, split-select,
// playhead scrub, and drag-drop-from-media-bin interactions.
//
// Coordinate model: all horizontal math is done relative to the stable
// `#tracks` element's left edge (it is only ever mutated via innerHTML, never
// replaced, so its bounding rect is always valid — even mid-drag while a
// commit() is re-rendering the clip DOM underneath the pointer). Every lane
// starts LABEL_WIDTH px to the right of that edge, matching the CSS
// `.track-label{width:64px}` layout.
//
// Performance note: clip elements are CREATED ONCE and reused across renders,
// keyed by clip id. Rebuilding them meant re-assigning each clip's filmstrip -
// a ~150KB base64 data URL - on every mousemove, which measured at 26ms per
// render with 20 clips. Reuse plus the geometry-only fast path below keeps
// dragging smooth. Because elements outlive any single project object (undo
// swaps in a clone), their listeners look their clip up BY ID at event time
// rather than closing over a clip object that may have been replaced.
import { getAsset, findClip, addTrackForType, pruneEmptyTracks, laneRows } from './model.js';
import { secToPx, pxToSec, totalDuration, moveClip, trimClip, fitPxPerSec, snapEdge } from './timeline.js';
import { mediaUrl } from './assets.js';
import { getThumb, requestThumb } from './thumbs.js';

const LABEL_WIDTH = 64;
const DEFAULT_PX_PER_SEC = 100;
const MIN_PX_PER_SEC = 10;
const MAX_PX_PER_SEC = 800;
const MIN_CONTENT_SEC = 30;
const TAIL_PADDING_SEC = 10;
const FIT_PADDING_PX = 24;   // breathing room so a fitted clip isn't flush to the edge
const SETTLE_MS = 140;       // pointer-at-rest delay before fetching the exact frame

export class TimelineUI {
  constructor(root, app) {
    this.root = root;
    this.app = app;
    this.ruler = root.querySelector('#ruler');
    this.tracksEl = root.querySelector('#tracks');
    this.playheadEl = root.querySelector('#playhead');

    this._clipEls = new Map();   // clip id -> its (reused) DOM element
    this._laneEls = new Map();   // track id -> its lane element, rebuilt per render
    this._scrubRaf = null;

    if (this.app.pxPerSec == null) this.app.pxPerSec = DEFAULT_PX_PER_SEC;

    // Scrub by pressing anywhere on the ruler, or by grabbing the playhead
    // itself. Both elements are stable, so these are wired once.
    if (this.ruler) this.ruler.addEventListener('mousedown', (e) => this._startScrub(e));
    const grab = this.playheadEl && this.playheadEl.querySelector('.playhead-grab');
    if (grab) grab.addEventListener('mousedown', (e) => { e.stopPropagation(); this._startScrub(e); });

    this.render();
  }

  get pxPerSec() { return this.app.pxPerSec; }
  set pxPerSec(v) { this.app.pxPerSec = v; }

  zoom(delta) {
    this.pxPerSec = Math.min(MAX_PX_PER_SEC, Math.max(MIN_PX_PER_SEC, this.pxPerSec + delta));
    this.render();
  }

  // Show the whole timeline at once. Runs after every drop/import/load, so a
  // clip you just dragged in is visible end to end instead of only its first
  // couple of seconds. Manual zoom still wins until the next drop.
  zoomToFit() {
    const viewport = (this.root.clientWidth || 0) - LABEL_WIDTH - FIT_PADDING_PX;
    const content = totalDuration(this.app.project);
    if (!(content > 0)) return;
    this.pxPerSec = fitPxPerSec(viewport, content, MIN_PX_PER_SEC, MAX_PX_PER_SEC);
    this.render();
  }

  render() {
    this._contentSec = Math.max(totalDuration(this.app.project) + TAIL_PADDING_SEC, MIN_CONTENT_SEC);
    this._contentPx = secToPx(this._contentSec, this.pxPerSec);
    this._totalPx = LABEL_WIDTH + this._contentPx;
    this._renderRuler();
    this._renderTracks();
    this.setPlayhead(this.app.playhead || 0);
  }

  // Geometry-only update: moves and resizes the clip elements that already
  // exist, and nothing else. This is what runs during a drag or trim, at one
  // update per animation frame - no DOM rebuilds, no filmstrip re-assignment.
  renderGeometry() {
    for (const track of this.app.project.tracks) {
      const lane = this._laneEls.get(track.id);
      for (const clip of track.clips) {
        const el = this._clipEls.get(clip.id);
        if (!el) { this.render(); return; }        // something new appeared
        if (lane && el.parentNode !== lane) lane.appendChild(el);
        this._placeClipEl(el, clip);
      }
    }
  }

  setPlayhead(t) {
    this.app.playhead = Math.max(0, t);
    const px = secToPx(this.app.playhead, this.pxPerSec);
    if (this.playheadEl) this.playheadEl.style.left = (LABEL_WIDTH + px) + 'px';
    if (this.app.onPlayheadChange) this.app.onPlayheadChange();
  }

  // ---- rendering ----

  _renderRuler() {
    if (!this.ruler) return;
    this.ruler.innerHTML = '';
    this.ruler.style.position = 'relative';
    this.ruler.style.backgroundImage = 'none';
    this.ruler.style.width = this._totalPx + 'px';

    const ticks = document.createElement('div');
    ticks.className = 'ruler-ticks';
    ticks.style.cssText = `position:absolute; left:${LABEL_WIDTH}px; top:0; bottom:0; width:${this._contentPx}px;`;

    const step = this._tickStep();
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
  // (video/image above, audio below), never by which strip you used - that way
  // you can't create a nonsense lane.
  _renderTracks() {
    if (!this.tracksEl) return;
    this.tracksEl.innerHTML = '';     // detaches clip elements; we re-append them
    this.tracksEl.style.width = this._totalPx + 'px';
    this._laneEls.clear();

    const rows = laneRows(this.app.project);
    if (rows.length === 0) {
      this.tracksEl.appendChild(this._renderEmptyArea());
    } else {
      this.tracksEl.appendChild(this._renderDropStrip());
      for (const track of rows) this.tracksEl.appendChild(this._renderTrackRow(track));
      this.tracksEl.appendChild(this._renderDropStrip());
    }

    // drop elements for clips that no longer exist (deleted, or undone away)
    const alive = new Set();
    for (const t of this.app.project.tracks) for (const c of t.clips) alive.add(c.id);
    for (const [id, el] of this._clipEls) {
      if (!alive.has(id)) { el.remove(); this._clipEls.delete(id); }
    }
  }

  _renderEmptyArea() {
    const el = document.createElement('div');
    el.className = 'timeline-empty';
    el.textContent = 'Drag material here';
    el.style.width = this._totalPx + 'px';
    this._wireLaneCreator(el);
    el.addEventListener('mousedown', (e) => { if (e.target === el) this._startScrub(e); });
    return el;
  }

  _renderDropStrip() {
    const el = document.createElement('div');
    el.className = 'drop-strip';
    el.textContent = 'Drop here to add a lane';
    el.style.width = this._totalPx + 'px';
    this._wireLaneCreator(el);
    el.addEventListener('mousedown', (e) => { if (e.target === el) this._startScrub(e); });
    return el;
  }

  _wireLaneCreator(el) {
    el.addEventListener('dragover', (e) => { e.preventDefault(); el.classList.add('is-over'); });
    el.addEventListener('dragleave', () => el.classList.remove('is-over'));
    el.addEventListener('drop', (e) => { el.classList.remove('is-over'); this._onDropNewLane(e); });
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
    lane.addEventListener('drop', (e) => this._onDrop(e, track.id, lane));
    lane.addEventListener('mousedown', (e) => {
      if (e.target !== lane) return;   // empty space in the lane, not a clip
      this._startScrub(e);
    });

    for (const clip of track.clips) lane.appendChild(this._clipEl(clip, track));

    row.appendChild(label);
    row.appendChild(lane);
    return row;
  }

  _placeClipEl(el, clip) {
    el.style.left = secToPx(clip.start, this.pxPerSec) + 'px';
    el.style.width = Math.max(secToPx(clip.duration, this.pxPerSec), 4) + 'px';
    // trimming the left edge moves the in-point, which slides the filmstrip
    if (el.__bgUrl) el.style.backgroundPositionX = `${-secToPx(clip.in || 0, this.pxPerSec)}px`;
  }

  // Get-or-create the element for this clip, then bring it up to date.
  _clipEl(clip, track) {
    let el = this._clipEls.get(clip.id);
    if (!el) {
      el = document.createElement('div');
      el.dataset.clipId = clip.id;

      const label = document.createElement('span');
      label.className = 'clip-label';
      el.appendChild(label);

      const handleL = document.createElement('div');
      handleL.className = 'clip-handle clip-handle-l';
      const handleR = document.createElement('div');
      handleR.className = 'clip-handle clip-handle-r';
      el.appendChild(handleL);
      el.appendChild(handleR);

      // Look the clip up by id at event time: undo replaces the project with a
      // clone, so the object captured here would otherwise go stale.
      handleL.addEventListener('mousedown', (e) => { e.stopPropagation(); this._startTrim(e, clip.id, 'L'); });
      handleR.addEventListener('mousedown', (e) => { e.stopPropagation(); this._startTrim(e, clip.id, 'R'); });
      el.addEventListener('mousedown', (e) => {
        if (e.target.classList && e.target.classList.contains('clip-handle')) return;
        this._startClipDrag(e, clip.id);
      });

      this._clipEls.set(clip.id, el);
    }

    const asset = getAsset(this.app.project, clip.assetId);
    const classes = ['clip', track.kind];
    if (asset && asset.type === 'image') classes.push('image');
    if (clip.id === this.app.selectedId) classes.push('is-selected');
    el.className = classes.join(' ');

    const name = asset ? String(asset.path).split(/[\\/]/).pop() : clip.id;
    el.title = name;
    el.firstChild.textContent = name;

    // Clip visual: filmstrip (video), waveform (audio), or the image itself. The
    // strip/waveform spans the asset's full duration; we window it to [in, in+dur]
    // via background-size (full duration in px) + a negative x offset (the in-point).
    if (asset) {
      if (asset.type === 'image') {
        const url = mediaUrl(asset.path);
        if (el.__bgUrl !== url) {
          el.style.backgroundImage = `url("${url}")`;
          el.style.backgroundSize = 'cover';
          el.style.backgroundPosition = 'center';
          el.style.backgroundRepeat = 'no-repeat';
          el.__bgUrl = url;
        }
      } else if (asset.type === 'video' || asset.type === 'audio') {
        const fullW = Math.max(1, secToPx(asset.duration || clip.duration, this.pxPerSec));
        const thumb = getThumb(asset);
        if (thumb) {
          // Only touch backgroundImage when the strip actually changed: the data
          // URL is huge and re-assigning it every render is what made dragging lag.
          if (el.__bgUrl !== thumb) {
            el.style.backgroundImage = `url("${thumb}")`;
            el.style.backgroundRepeat = 'no-repeat';
            el.style.backgroundPositionY = 'center';
            el.__bgUrl = thumb;
          }
          el.style.backgroundSize = `${fullW}px 100%`;
        }
        // Safe to call every render: it no-ops once the asset has been queued.
        requestThumb(asset, mediaUrl(asset.path), fullW, () => this.render());
      }
    }

    this._placeClipEl(el, clip);
    return el;
  }

  // ---- interactions ----

  _assetFromDrop(e) {
    const data = e.dataTransfer.getData('application/x-asset');
    if (!data) return null;
    try { return JSON.parse(data); } catch { return null; }
  }

  _addAt(info, trackId, clientX) {
    const dropTime = this._clientXToTime(clientX);
    this.app.addAssetAndClip(info, trackId, dropTime).catch((err) => {
      console.error('[drop] Failed to add asset:', err);
      const statusPill = document.getElementById('status-text');
      if (statusPill) {
        statusPill.textContent = "Couldn't add that file";
        setTimeout(() => { statusPill.textContent = 'bridge OK'; }, 2500);
      }
    });
  }

  _onDrop(e, trackId, lane) {
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

  // ---- playhead scrubbing ----

  // Press anywhere on the ruler, on empty lane space, or on the playhead's grab
  // bar, then drag: the red line follows the pointer until you let go.
  _startScrub(e) {
    e.preventDefault();
    if (this.app.pausePlayback) this.app.pausePlayback();
    // Proxy frames from here until mouseup: no <video> seeks while dragging.
    if (this.app.preview) this.app.preview.setScrubbing(true);
    const move = (ev) => this._scrubTo(ev.clientX);
    const up = () => {
      document.removeEventListener('mousemove', move);
      document.removeEventListener('mouseup', up);
      document.body.classList.remove('is-scrubbing');
      if (this._settleTimer) { clearTimeout(this._settleTimer); this._settleTimer = null; }
      if (this.app.preview) this.app.preview.setScrubbing(false);   // fetches the exact frame
    };
    document.body.classList.add('is-scrubbing');
    document.addEventListener('mousemove', move);
    document.addEventListener('mouseup', up);
    this._scrubTo(e.clientX);
  }

  // The red line follows the pointer IMMEDIATELY - it's one style write. Only
  // the preview refresh is throttled to a frame, because that seeks a <video>
  // and firing those per mousemove is what stalls the decoder.
  _scrubTo(clientX) {
    this.setPlayhead(this._clientXToTime(clientX));
    if (!this._scrubRaf) {
      this._scrubRaf = requestAnimationFrame(() => {
        this._scrubRaf = null;
        this.app.refreshPreview();     // proxy tile while scrubbing: no decode
      });
    }
    // Rest the pointer for a moment and we fetch the real frame, so pausing
    // part-way through a drag still shows you exactly where you are.
    if (this._settleTimer) clearTimeout(this._settleTimer);
    this._settleTimer = setTimeout(() => {
      this._settleTimer = null;
      if (this.app.preview) this.app.preview.refineFrame();
    }, SETTLE_MS);
  }

  // ---- clip drag / trim ----
  //
  // Snapping is applied ONLY when you let go. Snapping continuously fought the
  // pointer, and on the gapless main track a snapped edge re-rippled every clip
  // after it, so nudging one clip appeared to shove the whole row.

  _startClipDrag(e, clipId) {
    e.preventDefault();
    const found = findClip(this.app.project, clipId);
    if (!found) return;
    const grabOffset = this._clientXToTime(e.clientX) - found.clip.start;
    this._select(clipId);
    this.app.pushHistory();          // one snapshot per gesture, not per mousemove

    let currentTrackId = found.track.id;
    let rawStart = found.clip.start;
    let stripEl = null;              // set while hovering a "new lane" strip

    // ripple:false while dragging - re-laying the main track out gapless on
    // every mousemove is what made a clip appear not to move at all.
    const apply = (start, trackId, ripple) => {
      moveClip(this.app.project, clipId, trackId, start,
               { snapCandidates: [], pxPerSec: this.pxPerSec, ripple: !!ripple });
    };

    const onMove = (ev) => {
      rawStart = Math.max(0, this._clientXToTime(ev.clientX) - grabOffset);
      const hit = document.elementFromPoint(ev.clientX, ev.clientY);
      const overStrip = hit && hit.closest ? hit.closest('.drop-strip, .timeline-empty') : null;
      if (stripEl && stripEl !== overStrip) stripEl.classList.remove('is-over');
      stripEl = overStrip;
      if (stripEl) stripEl.classList.add('is-over');
      const rowEl = hit && hit.closest ? hit.closest('.track') : null;
      currentTrackId = (rowEl && rowEl.dataset.trackId) || currentTrackId;
      apply(rawStart, currentTrackId, false);
      this.renderGeometry();       // geometry only: no rebuild, no preview seek
    };

    const onUp = () => {
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
      // now, and only now, let it snap and let the main track close its gaps
      apply(this._snapped(rawStart, clipId), currentTrackId, true);
      if (stripEl) {
        stripEl.classList.remove('is-over');
        const cur = findClip(this.app.project, clipId);
        const asset = cur ? getAsset(this.app.project, cur.clip.assetId) : null;
        const newTrackId = addTrackForType(this.app.project, asset ? asset.type : 'video');
        apply(cur ? cur.clip.start : rawStart, newTrackId, true);
      }
      // Lanes only disappear once the drag is over - doing it mid-drag would
      // make the timeline jump around under the cursor.
      pruneEmptyTracks(this.app.project);
      this.app.commit();
    };

    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
  }

  _startTrim(e, clipId, edge) {
    e.preventDefault();
    this._select(clipId);
    this.app.pushHistory();          // one snapshot per gesture, not per mousemove

    let rawTime = this._clientXToTime(e.clientX);
    // ripple:false while dragging: the edge you hold follows the mouse and the
    // opposite edge stays put. Rippling mid-drag pulled the whole row along.
    const apply = (t, ripple) => {
      trimClip(this.app.project, clipId, edge, t,
               { snapCandidates: [], pxPerSec: this.pxPerSec, ripple: !!ripple });
    };

    const onMove = (ev) => {
      rawTime = this._clientXToTime(ev.clientX);
      apply(rawTime, false);
      this.renderGeometry();
    };

    const onUp = () => {
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
      apply(this._snapped(rawTime, clipId), true);
      this.app.commit();
    };

    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
  }

  _select(id) {
    this.app.selectedId = id;
    const found = findClip(this.app.project, id);
    if (found && this.app.inspector) this.app.inspector.show(found.clip);
    else if (this.app.inspector) this.app.inspector.clear();
    this.render();
  }

  // ---- helpers ----

  // Where an edge lands once you let go. With Snap off it lands exactly where
  // you dropped it.
  _snapped(t, excludeClipId) {
    if (!this.app.snapping) return t;
    return snapEdge(t, this.app.playhead, this._snapCandidates(excludeClipId), this.pxPerSec);
  }

  // Other clips' edges. The playhead is deliberately NOT in here - snapEdge
  // gives it priority and a wider reach of its own.
  _snapCandidates(excludeClipId) {
    const out = [];
    for (const t of this.app.project.tracks) {
      for (const c of t.clips) {
        if (c.id === excludeClipId) continue;
        out.push(c.start, c.start + c.duration);
      }
    }
    return out;
  }

  _clientXToTime(clientX) {
    const rect = this.tracksEl.getBoundingClientRect();
    return Math.max(0, pxToSec(clientX - rect.left - LABEL_WIDTH, this.pxPerSec));
  }

  _tickStep() {
    if (this.pxPerSec >= 150) return 1;
    if (this.pxPerSec >= 60) return 2;
    if (this.pxPerSec >= 30) return 5;
    return 10;
  }

  _formatTime(s) {
    const m = Math.floor(s / 60);
    const sec = Math.floor(s % 60);
    return `${m}:${String(sec).padStart(2, '0')}`;
  }
}
