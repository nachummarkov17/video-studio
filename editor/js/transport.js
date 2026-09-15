// transport.js — the play button, the timecode readouts and the scrub bar.
//
// One object owns all three so they cannot disagree about where the playhead
// is: whatever moves it calls update(), and every readout comes from the same
// numbers.

import { totalDuration } from './timeline.js';
import { timecode } from './timecode.js';
import { setThumbsDeferred } from './thumbs.js';

const PLAY_GLYPH = '&#9654; Play';
const PAUSE_GLYPH = '&#10073;&#10073; Pause';

export class Transport {
  constructor(app, els) {
    this.app = app;
    this.btnPlay = els.play;
    this.timeEl = els.time;
    this.durEl = els.duration;
    this.scrub = els.scrub;

    if (this.btnPlay) this.btnPlay.addEventListener('click', () => this.toggle());

    if (this.scrub) {
      this.scrub.step = 'any';
      this.scrub.addEventListener('input', () => {
        this.pause();
        this.app.playhead = parseFloat(this.scrub.value) || 0;
        this.app.timeline.setPlayhead(this.app.playhead);
        this.app.refreshPreview();
        this.update();
      });
    }

    // Pre-roll shows up here instead of looking like a hang.
    this.busyPill = document.createElement('div');
    this.busyPill.className = 'busy-pill';
    this.busyPill.innerHTML = '<span class="boot-spinner"></span><span>Buffering&hellip;</span>';
    document.body.appendChild(this.busyPill);

    const preview = this.app.preview;
    preview.onBuffering = (on) => this.busyPill.classList.toggle('is-on', !!on);
    preview.onTick = (t) => {
      // While the playhead is being dragged it belongs to the pointer, not to
      // the clock - otherwise the two fight and the line snaps back every frame.
      if (preview.isScrubbing && preview.isScrubbing()) return;
      this.app.playhead = t;
      this.app.timeline.setPlayhead(t);
      this.update();
      // Playback can end on its own by reaching the end of the timeline, in
      // which case pause() already ran before this tick fired.
      if (!preview.playing) this._reflect(false);
    };
  }

  update() {
    const fps = (this.app.project.canvas && this.app.project.canvas.fps) || 30;
    const total = totalDuration(this.app.project);
    if (this.timeEl) this.timeEl.textContent = timecode(this.app.playhead, fps);
    if (this.durEl) this.durEl.textContent = timecode(total, fps);
    if (this.scrub) {
      this.scrub.disabled = !(total > 0);
      this.scrub.max = String(Math.max(0.001, total));
      if (!this.scrub.matches(':active')) {
        this.scrub.value = String(Math.min(this.app.playhead, total));
      }
    }
  }

  // The single entry point for play/pause, so the button, the spacebar and
  // anything else can't disagree about the state.
  toggle() {
    const preview = this.app.preview;
    if (preview.playing) { this.pause(); return; }
    // play() pre-rolls before starting the clock, so it resolves later; the
    // button reflects the intent straight away.
    const started = preview.play();
    this._reflect(preview.playing);
    if (started && started.catch) started.catch(() => {});
  }

  // Grabbing the playhead while the clock runs would just fight it, so anything
  // that takes ownership of the time stops playback first.
  pause() {
    const preview = this.app.preview;
    if (!preview.playing) return;
    preview.pause();
    this._reflect(false);
  }

  _reflect(playing) {
    if (this.btnPlay) this.btnPlay.innerHTML = playing ? PAUSE_GLYPH : PLAY_GLYPH;
    // Playback owns the decoder: hold off on generating filmstrips until it stops.
    setThumbsDeferred(playing);
  }
}
