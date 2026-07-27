// Inspector: shows editable numeric/range fields for the selected clip and
// writes changes straight back onto the clip object (the same object the
// project tree holds — no cloning), then asks the app to redraw the preview.
import { findClip } from './model.js';

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

      input.addEventListener('input', () => {
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
      clip.muted = muteInput.checked;
      this.app.refreshPreview();
    });

    muteRow.appendChild(muteLabel);
    muteRow.appendChild(muteInput);
    this.root.appendChild(muteRow);
  }
}
