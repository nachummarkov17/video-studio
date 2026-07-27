// Timeline UI: renders tracks/clips, and drives drag-move, trim, split-select,
// playhead scrub, and drag-drop-from-media-bin interactions.
//
// Coordinate model: all horizontal math is done relative to the stable
// `#tracks` element's left edge (it is only ever mutated via innerHTML, never
// replaced, so its bounding rect is always valid — even mid-drag while a
// commit() is re-rendering the clip DOM underneath the pointer). Every lane
// starts LABEL_WIDTH px to the right of that edge, matching the CSS
// `.track-label{width:64px}` layout.
import { getAsset, findClip } from './model.js';
import { secToPx, pxToSec, totalDuration, moveClip, trimClip } from './timeline.js';

const LABEL_WIDTH = 64;
const DEFAULT_PX_PER_SEC = 100;
const MIN_PX_PER_SEC = 10;
const MAX_PX_PER_SEC = 800;
const MIN_CONTENT_SEC = 30;
const TAIL_PADDING_SEC = 10;

export class TimelineUI {
  constructor(root, app) {
    this.root = root;
    this.app = app;
    this.ruler = root.querySelector('#ruler');
    this.tracksEl = root.querySelector('#tracks');
    this.playheadEl = root.querySelector('#playhead');

    if (this.app.pxPerSec == null) this.app.pxPerSec = DEFAULT_PX_PER_SEC;

    this.render();
  }

  get pxPerSec() { return this.app.pxPerSec; }
  set pxPerSec(v) { this.app.pxPerSec = v; }

  zoom(delta) {
    this.pxPerSec = Math.min(MAX_PX_PER_SEC, Math.max(MIN_PX_PER_SEC, this.pxPerSec + delta));
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

  setPlayhead(t) {
    this.app.playhead = Math.max(0, t);
    const px = secToPx(this.app.playhead, this.pxPerSec);
    if (this.playheadEl) this.playheadEl.style.left = (LABEL_WIDTH + px) + 'px';
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
    ticks.addEventListener('mousedown', (e) => {
      this.setPlayhead(this._clientXToTime(e.clientX));
      this.app.refreshPreview();
    });

    this.ruler.appendChild(ticks);
  }

  _renderTracks() {
    if (!this.tracksEl) return;
    this.tracksEl.innerHTML = '';
    this.tracksEl.style.width = this._totalPx + 'px';

    for (const track of this.app.project.tracks) {
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

      lane.addEventListener('dragover', (e) => e.preventDefault());
      lane.addEventListener('drop', (e) => this._onDrop(e, track.id, lane));
      lane.addEventListener('mousedown', (e) => {
        if (e.target !== lane) return; // empty area, not a clip
        this.setPlayhead(this._clientXToTime(e.clientX));
        this.app.refreshPreview();
      });

      for (const clip of track.clips) {
        lane.appendChild(this._renderClip(clip, track));
      }

      row.appendChild(label);
      row.appendChild(lane);
      this.tracksEl.appendChild(row);
    }
  }

  _renderClip(clip, track) {
    const asset = getAsset(this.app.project, clip.assetId);
    const el = document.createElement('div');
    const classes = ['clip', track.kind];
    if (asset && asset.type === 'image') classes.push('image');
    if (clip.id === this.app.selectedId) classes.push('is-selected');
    el.className = classes.join(' ');
    el.dataset.clipId = clip.id;
    el.style.left = secToPx(clip.start, this.pxPerSec) + 'px';
    el.style.width = Math.max(secToPx(clip.duration, this.pxPerSec), 4) + 'px';
    const name = asset ? String(asset.path).split(/[\\/]/).pop() : clip.id;
    el.title = name;
    el.textContent = name;

    const handleL = document.createElement('div');
    handleL.className = 'clip-handle clip-handle-l';
    handleL.style.cssText = 'position:absolute; left:0; top:0; bottom:0; width:6px; cursor:ew-resize;';
    const handleR = document.createElement('div');
    handleR.className = 'clip-handle clip-handle-r';
    handleR.style.cssText = 'position:absolute; right:0; top:0; bottom:0; width:6px; cursor:ew-resize;';
    el.appendChild(handleL);
    el.appendChild(handleR);

    handleL.addEventListener('mousedown', (e) => { e.stopPropagation(); this._startTrim(e, clip, 'L'); });
    handleR.addEventListener('mousedown', (e) => { e.stopPropagation(); this._startTrim(e, clip, 'R'); });
    el.addEventListener('mousedown', (e) => {
      if (e.target === handleL || e.target === handleR) return;
      this._startClipDrag(e, track.id, clip);
    });

    return el;
  }

  // ---- interactions ----

  _onDrop(e, trackId, lane) {
    e.preventDefault();
    const data = e.dataTransfer.getData('application/x-asset');
    if (!data) return;
    let info;
    try { info = JSON.parse(data); } catch { return; }
    const dropTime = this._clientXToTime(e.clientX);
    this.app.addAssetAndClip(info, trackId, dropTime).catch((err) => {
      console.error('[drop] Failed to add asset:', err);
      const statusPill = document.getElementById('status-text');
      if (statusPill) {
        statusPill.textContent = "Couldn't add that file";
        setTimeout(() => { statusPill.textContent = 'bridge OK'; }, 2500);
      }
    });
  }

  _startClipDrag(e, initialTrackId, clip) {
    e.preventDefault();
    const grabOffset = this._clientXToTime(e.clientX) - clip.start;
    this._select(clip.id);

    let currentTrackId = initialTrackId;
    const onMove = (ev) => {
      const newStart = Math.max(0, this._clientXToTime(ev.clientX) - grabOffset);
      const hit = document.elementFromPoint(ev.clientX, ev.clientY);
      const rowEl = hit && hit.closest ? hit.closest('.track') : null;
      const targetTrackId = (rowEl && rowEl.dataset.trackId) || currentTrackId;
      const snapCandidates = this.app.snapping ? this._snapCandidates(clip.id) : [];
      moveClip(this.app.project, clip.id, targetTrackId, newStart, { snapCandidates, pxPerSec: this.pxPerSec });
      currentTrackId = targetTrackId;
      this.app.commit();
    };
    const onUp = () => {
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
    };
    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
  }

  _startTrim(e, clip, edge) {
    e.preventDefault();
    this._select(clip.id);

    const onMove = (ev) => {
      const t = this._clientXToTime(ev.clientX);
      const snapCandidates = this.app.snapping ? this._snapCandidates(clip.id) : [];
      trimClip(this.app.project, clip.id, edge, t, { snapCandidates, pxPerSec: this.pxPerSec });
      this.app.commit();
    };
    const onUp = () => {
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
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

  _snapCandidates(excludeClipId) {
    const out = [this.app.playhead || 0];
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
