// broll.js — the in/out selection you set on a b-roll clip before it goes onto
// the timeline. Pure maths, kept out of the panel so it can be tested directly.

export const MIN_SELECTION_SEC = 0.1;   // you can't add a clip of nothing
export const PHOTO_DEFAULT_SEC = 5;     // a still has no length of its own

// Pulls a selection back inside the source and keeps in strictly before out,
// whichever handle was dragged. Dragging one handle past the other pins them
// MIN_SELECTION_SEC apart rather than letting the selection invert.
export function clampSelection(sel, sourceDuration) {
  const dur = sourceDuration > 0 ? sourceDuration : MIN_SELECTION_SEC;
  const min = Math.min(MIN_SELECTION_SEC, dur);

  let a = Number.isFinite(sel && sel.in) ? sel.in : 0;
  let b = Number.isFinite(sel && sel.out) ? sel.out : dur;

  a = Math.min(Math.max(0, a), dur);
  b = Math.min(Math.max(0, b), dur);

  if (b - a < min) {
    // keep the pair inside the source: push out forward if there's room,
    // otherwise pull in backward
    if (a + min <= dur) b = a + min;
    else { b = dur; a = Math.max(0, dur - min); }
  }
  return { in: a, out: b };
}

// What a selection contributes to a clip.
export function selectionToClip(sel, sourceDuration) {
  const s = clampSelection(sel, sourceDuration);
  return { in: s.in, duration: s.out - s.in };
}
