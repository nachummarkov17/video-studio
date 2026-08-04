import { findClip, getTrack, getAsset, uid } from './model.js';

const MIN_DUR = 0.05;

export function totalDuration(project) {
  let max = 0;
  for (const t of project.tracks) for (const c of t.clips) max = Math.max(max, c.start + c.duration);
  return max;
}

export function secToPx(sec, pxPerSec) { return sec * pxPerSec; }
export function pxToSec(px, pxPerSec) { return px / pxPerSec; }

// Zoom level that makes contentSec exactly fill viewportPx, clamped to the
// timeline's zoom range. Empty content falls back to the minimum so a fresh
// project isn't zoomed to absurdity.
export function fitPxPerSec(viewportPx, contentSec, min, max) {
  if (!(contentSec > 0) || !(viewportPx > 0)) return min;
  return Math.min(max, Math.max(min, viewportPx / contentSec));
}

export function snapTime(t, candidates, pxPerSec, thresholdPx = 8) {
  let best = t;
  let bestDist = thresholdPx / pxPerSec;
  for (const c of candidates) {
    const d = Math.abs(c - t);
    if (d < bestDist) { bestDist = d; best = c; }
  }
  return best;
}

// Snapping for a clip edge you've just let go of. The PLAYHEAD wins over
// everything else and gets a wider reach, because "cut/trim to exactly where
// I'm paused" is the thing you actually want to hit; other clips' edges are a
// weaker, tighter magnet. Thresholds are in pixels, so they stay the same size
// on screen at any zoom.
const PLAYHEAD_SNAP_PX = 12;
const EDGE_SNAP_PX = 8;

// The playhead magnet on its own. This one is applied LIVE while you drag an
// edge, so parking the playhead where you want the cut and dragging up to it
// grabs on, the way CapCut does. It's safe to apply mid-drag where the edge
// magnets are not: it never re-orders or ripples anything.
export function snapToPlayhead(t, playhead, pxPerSec) {
  if (playhead == null) return t;
  return Math.abs(playhead - t) < PLAYHEAD_SNAP_PX / pxPerSec ? playhead : t;
}

export function snapEdge(t, playhead, candidates, pxPerSec) {
  if (snapToPlayhead(t, playhead, pxPerSec) !== t) return playhead;
  return snapTime(t, candidates, pxPerSec, EDGE_SNAP_PX);
}

// Sorts a track's clips by start time and re-lays them out gapless from 0.
export function rippleMain(track) {
  track.clips.sort((a, b) => a.start - b.start);
  let x = 0;
  for (const c of track.clips) { c.start = x; x += c.duration; }
  return track;
}

function isMain(track) { return track.kind === 'main'; }

// Splits the clip straddling atTime into two clips. The left piece keeps the
// original clip's identity (mutated in place); the right piece is a new clip
// whose in-point is advanced by the same amount its start moved. Total
// duration is preserved, so a gapless main track stays gapless after a split.
export function splitClip(project, clipId, atTime) {
  const found = findClip(project, clipId);
  if (!found) return project;
  const { track, clip } = found;
  if (atTime <= clip.start || atTime >= clip.start + clip.duration) return project;

  const left = atTime - clip.start;
  const right = clip.duration - left;
  const newClip = { ...clip, id: uid('c'), start: atTime, in: clip.in + left, duration: right };
  clip.duration = left;

  const i = track.clips.indexOf(clip);
  track.clips.splice(i + 1, 0, newClip);

  if (isMain(track)) rippleMain(track);
  return project;
}

// Trims one edge of a clip.
// Left edge: moves clip.start and clip.in together by the same delta (the
//   visible timeline position of the clip's opposite edge never moves).
//   Clamped so clip.in never goes below 0 and duration stays > 0.
// Right edge: only clip.duration changes. Clamped so clip.in + clip.duration
//   never exceeds the source asset's duration, and duration stays > 0.
export function trimClip(project, clipId, edge, newStart, { snapCandidates = [], pxPerSec = 100, ripple = true } = {}) {
  const found = findClip(project, clipId);
  if (!found) return project;
  const { track, clip } = found;
  const srcDuration = getAsset(project, clip.assetId)?.duration ?? Infinity;
  const snapped = snapTime(newStart, snapCandidates, pxPerSec);

  if (edge === 'L') {
    const end = clip.start + clip.duration;
    // lower must satisfy BOTH: clip.in stays >=0 (start-in) AND clip.start stays >=0.
    // Free (never-rippled) tracks have nothing else to pull a negative start back to sane.
    const lower = Math.max(0, clip.start - clip.in);
    const upper = end - MIN_DUR;             // keeps clip.duration > 0
    const ns = Math.min(Math.max(snapped, lower), upper);
    const delta = ns - clip.start;
    clip.start += delta;
    clip.in += delta;
    clip.duration -= delta;
  } else {
    let newDuration = snapped - clip.start;
    const maxDuration = srcDuration - clip.in; // keeps clip.in + clip.duration <= source duration
    // Source ceiling must be applied LAST so it always wins: if maxDuration < MIN_DUR
    // (clip.in within MIN_DUR of the source end), flooring first then capping would
    // still allow duration to exceed maxDuration and violate in+duration<=source.
    newDuration = Math.min(Math.max(MIN_DUR, newDuration), maxDuration);
    clip.duration = newDuration;
  }

  if (ripple && isMain(track)) rippleMain(track);
  return project;
}

// Moves a clip to a (possibly different) track at newStart. Main track(s)
// involved ripple to stay gapless; overlay/audio tracks are free (no ripple).
export function moveClip(project, clipId, toTrackId, newStart, { snapCandidates = [], pxPerSec = 100, ripple = true } = {}) {
  const found = findClip(project, clipId);
  if (!found) return project;
  const { track, clip } = found;
  const dest = getTrack(project, toTrackId) || track;

  if (dest !== track) {
    track.clips.splice(track.clips.indexOf(clip), 1);
    dest.clips.push(clip);
  }
  clip.start = Math.max(0, snapTime(newStart, snapCandidates, pxPerSec));

  if (ripple && isMain(dest)) rippleMain(dest);
  if (ripple && isMain(track) && track !== dest) rippleMain(track);
  return project;
}

// Removes a clip from its track. Main track ripples to close the gap.
export function deleteClip(project, clipId) {
  const found = findClip(project, clipId);
  if (!found) return project;
  const { track, clip } = found;
  track.clips.splice(track.clips.indexOf(clip), 1);
  if (isMain(track)) rippleMain(track);
  return project;
}
