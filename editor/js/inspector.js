// Inspector: shows editable numeric/range fields for the selected clip and
// writes changes straight back onto the clip object (the same object the
// project tree holds — no cloning), then asks the app to redraw the preview.
import { findClip, getAsset, overlayPlacement, OVERLAY_SIZES } from './model.js';

// Where a pop-up picture can sit, as anchors across the space it doesn't fill.
const SPOTS = [
  { label: '↖', x: 0,   y: 0,   title: 'Top left' },
  { label: '↑', x: 0.5, y: 0,   title: 'Top' },
  { label: '↗', x: 1,   y: 0,   title: 'Top right' },
  { label: '←', x: 0,   y: 0.3, title: 'Left' },
  { label: '·', x: 0.5, y: 0.5, title: 'Centre' },
  { label: '→', x: 1,   y: 0.3, title: 'Right' },
  { label: '↙', x: 0,   y: 0.8, title: 'Bottom left (above the captions)' },
  { label: '↓', x: 0.5, y: 0.8, title: 'Bottom' },
  { label: '↘', x: 1,   y: 0.8, title: 'Bottom right' },
];

const FIELDS = [
  { key: 'x', label: 'X', type: 'number', step: 1, mainDisabled: true },
  { key: 'y', label: 'Y', type: 'number', step: 1, mainDisabled: true },
  { key: 'scale', label: 'Scale', type: 'range', min: 0.05, max: 5, step: 0.01, mainDisabled: true },
  { key: 'opacity', label: 'Opacity', type: 'range', min: 0, max: 1, step: 0.01, mainDisabled: false },
  { key: 'volume', label: 'Volume', type: 'range', min: 0, max: 1, step: 0.01, mainDisabled: false },
];

export class Inspector {
  constructor(root, app) {
    this.root = root;
    this.app = app;
    this.clear();
  }

  clear() {
    this.root.innerHTML = '<p class="empty-hint">Select a clip to edit its properties.</p>';
  }

  show(clip) {
    this.root.innerHTML = '';
    const found = findClip(this.app.project, clip.id);
    const isMain = !!(found && found.track.kind === 'main');

    // A pop-up picture is placed far more often than it is nudged by a pixel,
    // so the size and the spot come first, as one click each.
    if (!isMain) this._placementRow(clip);

    for (const f of FIELDS) {
      const row = document.createElement('div');
      row.className = 'inspector-row';
      row.style.cssText = 'display:flex; align-items:center; gap:8px; padding:6px 12px;';

      const label = document.createElement('label');
      label.textContent = f.label;
      label.style.cssText = 'flex:0 0 56px; font-size:11px; color:var(--text-dim);';

      const input = document.createElement('input');
      input.type = f.type;
      if (f.min !== undefined) input.min = String(f.min);
      if (f.max !== undefined) input.max = String(f.max);
      if (f.step !== undefined) input.step = String(f.step);
      input.value = String(clip[f.key] ?? 0);
      input.style.flex = '1 1 auto';
      input.disabled = isMain && f.mainDisabled;

      // One undo step per editing session, not per slider pixel: snapshot on
      // the first change after the field takes focus.
      let fresh = true;
      input.addEventListener('focus', () => { fresh = true; });
      input.addEventListener('blur', () => { fresh = true; });
      input.addEventListener('input', () => {
        if (fresh) { this.app.pushHistory(); fresh = false; }
        clip[f.key] = parseFloat(input.value);
        this.app.refreshPreview();
      });

      row.appendChild(label);
      row.appendChild(input);
      this.root.appendChild(row);
    }

    const muteRow = document.createElement('div');
    muteRow.className = 'inspector-row';
    muteRow.style.cssText = 'display:flex; align-items:center; gap:8px; padding:6px 12px;';

    const muteLabel = document.createElement('label');
    muteLabel.textContent = 'Muted';
    muteLabel.style.cssText = 'flex:0 0 56px; font-size:11px; color:var(--text-dim);';

    const muteInput = document.createElement('input');
    muteInput.type = 'checkbox';
    muteInput.checked = !!clip.muted;
    muteInput.addEventListener('input', () => {
      this.app.pushHistory();
      clip.muted = muteInput.checked;
      this.app.refreshPreview();
    });

    muteRow.appendChild(muteLabel);
    muteRow.appendChild(muteInput);
    this.root.appendChild(muteRow);
  }

  // Size + spot for an overlay: "put this picture there, that big".
  _placementRow(clip) {
    const asset = getAsset(this.app.project, clip.assetId);
    if (!asset || !(asset.naturalW > 0)) return;

    const apply = (opts) => {
      this.app.pushHistory();
      Object.assign(clip, overlayPlacement(this.app.project.canvas, asset.naturalW, asset.naturalH, opts));
      this.app.refreshPreview();
      this.show(clip);                       // reflect the new numbers in the fields
    };

    // Which size is on now, so the buttons can show it and the spot buttons
    // can keep it when they move the picture.
    const currentFraction = (clip.scale * asset.naturalW) / (this.app.project.canvas.width || 1080);
    const nearestSize = Object.entries(OVERLAY_SIZES)
      .reduce((a, b) => Math.abs(b[1] - currentFraction) < Math.abs(a[1] - currentFraction) ? b : a);

    const wrap = document.createElement('div');
    wrap.className = 'inspector-place';
    wrap.style.cssText = 'padding:8px 12px; border-bottom:1px solid var(--border);';

    const heading = document.createElement('div');
    heading.textContent = 'Pop it up';
    heading.style.cssText = 'font-size:11px; color:var(--text-dim); margin-bottom:6px;';
    wrap.appendChild(heading);

    const sizes = document.createElement('div');
    sizes.style.cssText = 'display:flex; gap:4px; margin-bottom:6px;';
    for (const [name, fraction] of Object.entries(OVERLAY_SIZES)) {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'btn' + (name === nearestSize[0] ? ' is-active' : '');
      b.textContent = name;
      b.style.cssText = 'flex:1 1 0; font-size:11px; text-transform:capitalize;';
      b.title = `${Math.round(fraction * 100)}% of the frame`;
      b.addEventListener('click', () => apply({ fraction, anchorX: this._anchorX(clip, asset), anchorY: this._anchorY(clip, asset) }));
      sizes.appendChild(b);
    }
    wrap.appendChild(sizes);

    const grid = document.createElement('div');
    grid.style.cssText = 'display:grid; grid-template-columns:repeat(3,1fr); gap:4px;';
    for (const spot of SPOTS) {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'btn';
      b.textContent = spot.label;
      b.title = spot.title;
      b.style.cssText = 'font-size:13px; padding:3px 0;';
      b.addEventListener('click', () => apply({ fraction: nearestSize[1], anchorX: spot.x, anchorY: spot.y }));
      grid.appendChild(b);
    }
    wrap.appendChild(grid);
    this.root.appendChild(wrap);
  }

  // Turn the clip's current x/y back into anchors, so changing the SIZE keeps
  // the picture roughly where you put it instead of jumping to the middle.
  _anchorX(clip, asset) {
    const free = (this.app.project.canvas.width || 1080) - asset.naturalW * clip.scale;
    return free > 1 ? Math.min(1, Math.max(0, (clip.x || 0) / free)) : 0.5;
  }
  _anchorY(clip, asset) {
    const free = (this.app.project.canvas.height || 1920) - asset.naturalH * clip.scale;
    return free > 1 ? Math.min(1, Math.max(0, (clip.y || 0) / free)) : 0.3;
  }
}
