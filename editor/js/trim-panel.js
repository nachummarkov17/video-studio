// trim-panel.js — pick the piece of a b-roll clip you actually want, before it
// touches the timeline.
//
// It takes over the preview area (the biggest picture available) rather than
// opening its own player: a cramped thumbnail is no use for judging a shot. The
// project preview underneath is left completely alone and comes straight back
// when the panel closes.
import { clampSelection, selectionToClip, PHOTO_DEFAULT_SEC, MIN_SELECTION_SEC } from './broll.js';
import { mediaUrl, getTrim, setTrim, saveBrollClip } from './assets.js';
import { previewUrl } from './preview-source.js';

const fmt = (s) => {
  const t = Math.max(0, s || 0);
  const m = Math.floor(t / 60);
  const sec = (t % 60).toFixed(1).padStart(4, '0');
  return `${m}:${sec}`;
};

export class TrimPanel {
  constructor(stageEl, app) {
    this.stage = stageEl;      // .preview-stage - we overlay inside it
    this.app = app;
    this.item = null;
    this.el = null;
    this.media = null;
    this.sel = { in: 0, out: 0 };
    this.duration = 0;
    this._raf = null;
    this._onKey = (e) => { if (e.key === 'Escape') this.close(); };
  }

  get isOpen() { return !!this.item; }

  open(item) {
    this.close();
    this.item = item;
    if (this.app.pausePlayback) this.app.pausePlayback();

    this.el = document.createElement('div');
    this.el.className = 'trim-panel';
    this.stage.appendChild(this.el);
    document.addEventListener('keydown', this._onKey);

    if (item.type === 'image') this._buildImage();
    else this._buildVideo();
  }

  close() {
    if (this._raf) { cancelAnimationFrame(this._raf); this._raf = null; }
    document.removeEventListener('keydown', this._onKey);
    if (this.media && this.media.pause) { try { this.media.pause(); } catch {} }
    if (this.media && this.media.tagName === 'VIDEO') {
      this.media.removeAttribute('src');
      this.media.load();               // release the decoder immediately
    }
    if (this.el && this.el.parentNode) this.el.remove();
    this.el = null; this.media = null; this.item = null;
    if (this.app.refreshPreview) this.app.refreshPreview();   // project preview back
  }

  // ---- photos: no trim bar, just how long it should be on screen ----------

  _buildImage() {
    const item = this.item;
    const saved = getTrim(item.path);
    const seconds = saved ? (saved.out - saved.in) : PHOTO_DEFAULT_SEC;

    const img = document.createElement('img');
    img.className = 'trim-media';
    img.src = mediaUrl(item.path);   // a still needs no proxy
    this.media = img;

    const bar = document.createElement('div');
    bar.className = 'trim-bar-row';
    bar.innerHTML =
      '<label class="trim-label">Show for</label>' +
      '<input class="trim-secs" type="number" min="0.1" step="0.5">' +
      '<span class="trim-label">seconds</span>';
    const input = bar.querySelector('.trim-secs');
    input.value = String(seconds);

    this.el.appendChild(img);
    this.el.appendChild(this._chrome(bar, () => {
      const v = Math.max(MIN_SELECTION_SEC, parseFloat(input.value) || PHOTO_DEFAULT_SEC);
      setTrim(item.path, { in: 0, out: v });
      return { in: 0, duration: v };
    }));
  }

  // ---- video: scrub, set in and out, preview only the selection -----------

  _buildVideo() {
    const item = this.item;
    const v = document.createElement('video');
    v.className = 'trim-media';
    v.preload = 'metadata';
    v.src = previewUrl(item.path);   // the proxy seeks far faster while you trim
    this.media = v;
    this.el.appendChild(v);

    const bar = document.createElement('div');
    bar.className = 'trim-bar-row trim-bar-video';
    bar.innerHTML =
      '<button class="btn trim-play" type="button">&#9654;</button>' +
      '<div class="trim-track">' +
        '<div class="trim-range"></div>' +
        '<div class="trim-handle trim-in" title="Start"></div>' +
        '<div class="trim-handle trim-out" title="End"></div>' +
        '<div class="trim-head"></div>' +
      '</div>' +
      '<span class="trim-read"></span>';
    this.el.appendChild(this._chrome(bar, () => {
      setTrim(item.path, { ...this.sel });
      return selectionToClip(this.sel, this.duration);
    }));

    const track = bar.querySelector('.trim-track');
    const range = bar.querySelector('.trim-range');
    const hIn = bar.querySelector('.trim-in');
    const hOut = bar.querySelector('.trim-out');
    const head = bar.querySelector('.trim-head');
    const read = bar.querySelector('.trim-read');
    const play = bar.querySelector('.trim-play');

    const paint = () => {
      const d = this.duration || 1;
      const a = (this.sel.in / d) * 100, b = (this.sel.out / d) * 100;
      range.style.left = a + '%';
      range.style.width = Math.max(0, b - a) + '%';
      hIn.style.left = a + '%';
      hOut.style.left = b + '%';
      head.style.left = ((v.currentTime / d) * 100) + '%';
      read.textContent = `${fmt(this.sel.in)} → ${fmt(this.sel.out)}   (${fmt(this.sel.out - this.sel.in)})`;
    };
    this._paint = paint;

    v.addEventListener('loadedmetadata', () => {
      this.duration = v.duration || 0;
      const saved = getTrim(item.path);
      this.sel = clampSelection(saved || { in: 0, out: this.duration }, this.duration);
      v.currentTime = this.sel.in;
      paint();
      if (this._nameInput && !this._nameInput.value) this._nameInput.value = this._defaultName();
    });

    const timeAt = (clientX) => {
      const r = track.getBoundingClientRect();
      const frac = Math.min(1, Math.max(0, (clientX - r.left) / Math.max(1, r.width)));
      return frac * (this.duration || 0);
    };

    const dragHandle = (which) => (e) => {
      e.preventDefault(); e.stopPropagation();
      const move = (ev) => {
        const t = timeAt(ev.clientX);
        const next = which === 'in' ? { in: t, out: this.sel.out } : { in: this.sel.in, out: t };
        this.sel = clampSelection(next, this.duration);
        // scrub the picture to the handle so you can see the frame you're cutting on
        v.currentTime = which === 'in' ? this.sel.in : this.sel.out;
        paint();
      };
      const up = () => {
        document.removeEventListener('mousemove', move);
        document.removeEventListener('mouseup', up);
      };
      document.addEventListener('mousemove', move);
      document.addEventListener('mouseup', up);
    };
    hIn.addEventListener('mousedown', dragHandle('in'));
    hOut.addEventListener('mousedown', dragHandle('out'));

    // clicking the track scrubs within the clip
    track.addEventListener('mousedown', (e) => {
      if (e.target === hIn || e.target === hOut) return;
      v.currentTime = timeAt(e.clientX);
      paint();
    });

    // play loops the selection, so you hear/see exactly what you're adding
    const tick = () => {
      if (v.paused) { this._raf = null; return; }
      if (v.currentTime >= this.sel.out - 0.02) v.currentTime = this.sel.in;
      paint();
      this._raf = requestAnimationFrame(tick);
    };
    play.addEventListener('click', () => {
      if (v.paused) {
        if (v.currentTime < this.sel.in || v.currentTime >= this.sel.out) v.currentTime = this.sel.in;
        v.play().catch(() => {});
        play.innerHTML = '&#10073;&#10073;';
        if (!this._raf) this._raf = requestAnimationFrame(tick);
      } else {
        v.pause();
        play.innerHTML = '&#9654;';
      }
    });
    v.addEventListener('pause', () => { play.innerHTML = '&#9654;'; });
  }

  // A name you'd recognise later, from the file and where you cut it.
  _defaultName() {
    const base = (this.item.name || 'clip').replace(/\.[^.]+$/, '');
    const a = Math.round(this.sel.in || 0);
    return `${base} ${a}s`;
  }

  // shared footer: the trim controls, a name to save it under, then the actions
  _chrome(barEl, buildClip) {
    const foot = document.createElement('div');
    foot.className = 'trim-foot';

    const title = document.createElement('div');
    title.className = 'trim-title';
    title.textContent = this.item.name;

    const actions = document.createElement('div');
    actions.className = 'trim-actions';

    // Saving keeps the cut piece as its own small file in the library, so next
    // time this shot is a select-and-drag with no trimming to redo. Only for
    // video: a photo has nothing to cut.
    let nameInput = null;
    if (this.item.type !== 'image') {
      nameInput = document.createElement('input');
      nameInput.className = 'trim-name';
      nameInput.type = 'text';
      nameInput.placeholder = 'Name this clip';
      nameInput.title = 'Save the trimmed piece to your library under this name';

      const save = document.createElement('button');
      save.className = 'btn';
      save.textContent = 'Save to library';
      save.addEventListener('click', async () => {
        const name = (nameInput.value || '').trim() || this._defaultName();
        save.disabled = true;
        save.textContent = 'Saving…';
        const res = await saveBrollClip(this.item.path, { ...this.sel }, name);
        save.disabled = false;
        save.textContent = 'Save to library';
        if (res && res.ok) {
          save.textContent = 'Saved ✓';
          setTimeout(() => { save.textContent = 'Save to library'; }, 1600);
        } else {
          save.textContent = "Couldn't save";
          setTimeout(() => { save.textContent = 'Save to library'; }, 2200);
        }
      });
      actions.appendChild(nameInput);
      actions.appendChild(save);
    }

    const spacer = document.createElement('span');
    spacer.className = 'trim-spacer';
    actions.appendChild(spacer);

    const add = document.createElement('button');
    add.className = 'btn btn-accent';
    add.textContent = 'Add to timeline';
    const cancel = document.createElement('button');
    cancel.className = 'btn';
    cancel.textContent = 'Cancel';
    actions.appendChild(add);
    actions.appendChild(cancel);

    add.addEventListener('click', () => {
      const clip = buildClip();
      const item = this.item;
      this.close();
      if (this.app.addBrollAtPlayhead) this.app.addBrollAtPlayhead(item, clip);
    });
    cancel.addEventListener('click', () => this.close());

    this._nameInput = nameInput;
    foot.appendChild(title);
    foot.appendChild(barEl);
    foot.appendChild(actions);
    return foot;
  }
}
