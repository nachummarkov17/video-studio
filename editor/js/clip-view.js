// clip-view.js — the DOM element for one clip on the timeline.
//
// Elements are CREATED ONCE and reused across renders, keyed by clip id.
// Rebuilding them meant re-assigning each clip's filmstrip on every mousemove,
// which measured at ~26 ms per render with 20 clips. Because an element
// outlives any single project object (undo swaps in a clone), its listeners
// look their clip up BY ID at event time rather than closing over a clip that
// may have been replaced.

import { getAsset } from './model.js';
import { secToPx } from './timeline.js';
import { previewUrl } from './preview-source.js';
import { mediaUrl } from './assets.js';
import { getThumb, requestThumb, getStrip } from './thumbs.js';

export class ClipViews {
  // hooks: { onDrag(e, clipId), onTrim(e, clipId, edge), onMenu(e, clipId), onStripReady() }
  constructor(app, hooks) {
    this.app = app;
    this.hooks = hooks;
    this._els = new Map();
  }

  get(clipId) { return this._els.get(clipId) || null; }

  // Drop elements for clips that no longer exist (deleted, or undone away).
  prune(aliveIds) {
    for (const [id, el] of this._els) {
      if (!aliveIds.has(id)) { el.remove(); this._els.delete(id); }
    }
  }

  // Get-or-create this clip's element, then bring it fully up to date.
  sync(clip, track, pxPerSec) {
    let el = this._els.get(clip.id);
    if (!el) { el = this._create(clip.id); this._els.set(clip.id, el); }

    const asset = getAsset(this.app.project, clip.assetId);
    const classes = ['clip', track.kind];
    if (asset && asset.type === 'image') classes.push('image');
    if (clip.muted) classes.push('is-muted');
    if (clip.id === this.app.selectedId) classes.push('is-selected');
    el.className = classes.join(' ');

    const name = asset ? String(asset.path).split(/[\\/]/).pop() : clip.id;
    el.title = name;
    el.firstChild.textContent = name;

    if (asset) this._paint(el, clip, asset, pxPerSec);
    this.place(el, clip, pxPerSec);
    return el;
  }

  // Geometry only: what runs during a drag or a trim, once per animation frame.
  place(el, clip, pxPerSec) {
    el.style.left = secToPx(clip.start, pxPerSec) + 'px';
    el.style.width = Math.max(secToPx(clip.duration, pxPerSec), 4) + 'px';
    if (!el.__bgUrl) return;
    // trimming the left edge moves the in-point, which slides the filmstrip
    const asset = getAsset(this.app.project, clip.assetId);
    const strip = asset ? getStrip(asset.id) : null;
    if (strip && strip.tileCssW) {
      const stripW = strip.count * strip.tileCssW;
      const frac = (clip.in || 0) / ((asset && asset.duration) || 1);
      el.style.backgroundPositionX = `${-frac * stripW}px`;
    } else {
      el.style.backgroundPositionX = `${-secToPx(clip.in || 0, pxPerSec)}px`;
    }
  }

  // ---- internals -------------------------------------------------------

  _create(clipId) {
    const el = document.createElement('div');
    el.dataset.clipId = clipId;

    const label = document.createElement('span');
    label.className = 'clip-label';
    el.appendChild(label);

    const handleL = document.createElement('div');
    handleL.className = 'clip-handle clip-handle-l';
    const handleR = document.createElement('div');
    handleR.className = 'clip-handle clip-handle-r';
    el.appendChild(handleL);
    el.appendChild(handleR);

    handleL.addEventListener('mousedown', (e) => { e.stopPropagation(); this.hooks.onTrim(e, clipId, 'L'); });
    handleR.addEventListener('mousedown', (e) => { e.stopPropagation(); this.hooks.onTrim(e, clipId, 'R'); });
    el.addEventListener('mousedown', (e) => {
      if (e.target.classList && e.target.classList.contains('clip-handle')) return;
      this.hooks.onDrag(e, clipId);
    });
    el.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      e.stopPropagation();
      this.hooks.onMenu(e, clipId);
    });
    return el;
  }

  // The clip's visual: filmstrip (video), waveform (audio) or the image itself.
  // The strip spans the asset's FULL duration; we window it to [in, in+dur] via
  // background-size plus a negative x offset.
  _paint(el, clip, asset, pxPerSec) {
    if (asset.type === 'image') {
      const url = mediaUrl(asset.path);
      if (el.__bgUrl !== url) {
        el.style.backgroundImage = `url("${url}")`;
        el.style.backgroundSize = 'cover';
        el.style.backgroundPosition = 'center';
        el.style.backgroundRepeat = 'no-repeat';
        el.__bgUrl = url;
      }
      return;
    }
    if (asset.type !== 'video' && asset.type !== 'audio') return;

    const fullW = Math.max(1, secToPx(asset.duration || clip.duration, pxPerSec));
    const thumb = getThumb(asset);
    if (thumb) {
      // Only touch backgroundImage when the strip actually changed: assigning it
      // every render is what made dragging lag.
      if (el.__bgUrl !== thumb) {
        el.style.backgroundImage = `url("${thumb}")`;
        el.style.backgroundPositionY = 'center';
        el.__bgUrl = thumb;
      }
      const strip = getStrip(asset.id);
      if (strip && strip.tileCssW) {
        // Size the strip by its OWN tile geometry, never by the clip's width.
        // Stretching it to fit is what squashed portrait frames into wide boxes.
        const stripW = strip.count * strip.tileCssW;
        el.style.backgroundRepeat = 'repeat-x';
        el.style.backgroundSize = `${stripW}px 100%`;
      } else {
        // waveforms have no tiles; stretching one along time is correct
        el.style.backgroundRepeat = 'no-repeat';
        el.style.backgroundSize = `${fullW}px 100%`;
      }
    }
    // Safe to call every render: it no-ops once the asset has been queued. Built
    // from the PROXY when there is one - far fewer bytes to decode per frame.
    requestThumb(asset, previewUrl(asset.path), fullW, () => this.hooks.onStripReady());
  }
}
