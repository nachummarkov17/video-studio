// compositor.js — everything that is drawn on the preview canvas, and nothing
// else. It never seeks, never plays and never decides what should be on screen;
// it is handed a stack of layers and paints them.
//
// The one piece of judgement it does make is the PROXY FRAME. When a layer's
// media isn't sitting on the frame we want yet - straight after a scrub, or in
// the moment after a cut - drawing the element anyway shows a stale frame from
// somewhere else in the clip, and then jumps when the seek lands. Drawing the
// filmstrip tile for that instant instead is immediate, already decoded, and
// approximately right, so the picture tracks the pointer and simply sharpens
// when the real frame arrives.

import { getStrip } from './thumbs.js';

export class Compositor {
  constructor(canvas) {
    this.cv = canvas;
    this.ctx = canvas.getContext('2d');
  }

  resize(w, h) {
    if (this.cv.width !== w) this.cv.width = w;
    if (this.cv.height !== h) this.cv.height = h;
  }

  // layers, bottom first. Each: {
  //   el, kind, cover, exact, assetId, localTime, sourceDuration,
  //   opacity, x, y, scale
  // }
  draw(layers) {
    const ctx = this.ctx, W = this.cv.width, H = this.cv.height;
    ctx.clearRect(0, 0, W, H);
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, W, H);
    for (const layer of layers) {
      if (!layer.exact && layer.kind === 'video' && this._drawProxy(ctx, W, H, layer)) continue;
      if (layer.el) this._drawElement(ctx, W, H, layer);
    }
  }

  _drawElement(ctx, W, H, layer) {
    const src = layer.el;
    const nw = (layer.kind === 'image' ? src.naturalWidth : src.videoWidth) || W;
    const nh = (layer.kind === 'image' ? src.naturalHeight : src.videoHeight) || H;
    if (!nw || !nh) return;
    ctx.globalAlpha = layer.opacity ?? 1;
    if (layer.cover) {
      const s = Math.max(W / nw, H / nh);
      const dw = nw * s, dh = nh * s;
      ctx.drawImage(src, (W - dw) / 2, (H - dh) / 2, dw, dh);
    } else {
      const scale = layer.scale ?? 1;
      ctx.drawImage(src, layer.x ?? 0, layer.y ?? 0, nw * scale, nh * scale);
    }
    ctx.globalAlpha = 1;
  }

  // The filmstrip tile nearest this instant. Returns false when the asset
  // hasn't been stripped yet, so the caller can fall back to the element.
  _drawProxy(ctx, W, H, layer) {
    const strip = getStrip(layer.assetId);
    if (!strip || !strip.img || !strip.img.complete || !strip.count) return false;
    const dur = strip.duration > 0 ? strip.duration : (layer.sourceDuration || 1);
    const frac = dur > 0 ? (layer.localTime / dur) : 0;
    // Tile i was grabbed at ((i+0.5)/count)*duration, so the NEAREST tile is a
    // round, not a floor. Flooring biased every proxy frame up to a whole tile
    // early, which is half of why the scrub picture looked behind the pointer.
    const i = Math.max(0, Math.min(strip.count - 1, Math.round(frac * strip.count - 0.5)));
    const sx = i * strip.tileW;

    ctx.globalAlpha = layer.opacity ?? 1;
    if (layer.cover) {
      const s = Math.max(W / strip.tileW, H / strip.tileH);
      const dw = strip.tileW * s, dh = strip.tileH * s;
      ctx.drawImage(strip.img, sx, 0, strip.tileW, strip.tileH,
                    (W - dw) / 2, (H - dh) / 2, dw, dh);
    } else {
      const scale = layer.scale ?? 1;
      // match what the real element would occupy, so swapping in the true frame
      // doesn't make the overlay change size
      const dw = strip.tileW * scale, dh = strip.tileH * scale;
      ctx.drawImage(strip.img, sx, 0, strip.tileW, strip.tileH,
                    layer.x ?? 0, layer.y ?? 0, dw, dh);
    }
    ctx.globalAlpha = 1;
    return true;
  }
}
