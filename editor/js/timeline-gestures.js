// timeline-gestures.js — the three things you do with the mouse on a timeline:
// scrub the playhead, move a clip, trim an edge.
//
// SNAPPING RULE. Clip edges snap only when you LET GO; snapping them
// continuously fought the pointer, and on the gapless main track a snapped edge
// re-rippled every clip after it, so nudging one clip appeared to shove the
// whole row. The PLAYHEAD is the exception: it magnets live, because "cut
// exactly where I'm paused" is the thing you actually aim for.
//
// THE PLAYHEAD FOLLOWS THE CONTENT. A ripple edit slides everything after it;
// leaving the line where it was means the picture changes under it. After a
// magnetic-track trim, the playhead moves by however much the content did.

import { findClip, getAsset, addTrackForType, pruneEmptyTracks } from './model.js';
import { moveClip, trimClip, snapToPlayhead, snapEdge, playheadAfterRipple } from './timeline.js';

export class TimelineGestures {
  constructor(timeline, app) {
    this.tl = timeline;
    this.app = app;
    this._settleTimer = null;
  }

  // ---- playhead --------------------------------------------------------

  // Press on the ruler (or empty lane space, or the playhead's own grab bar)
  // and drag: the red line follows the pointer until you let go.
  startScrub(e) {
    e.preventDefault();
    // Deliberately does NOT pause: you didn't ask for one, so playback keeps
    // running and picks up from wherever you drop the playhead.
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

  // The red line AND the preview clock both move IMMEDIATELY and must not drift
  // apart. They used to: the preview was updated on a throttled frame, so a
  // quick click released before that frame ever fired, playback re-anchored to
  // the preview's stale time, and the playhead was yanked back. Both updates are
  // cheap during a scrub - the preview only redraws a filmstrip tile.
  _scrubTo(clientX) {
    const t = this.tl.clientXToTime(clientX);
    this.tl.setPlayhead(t);
    if (this.app.preview) this.app.preview.setTime(t);
    // Resting the pointer fetches the REAL frame. That one is expensive, so it
    // stays on a timer.
    if (this._settleTimer) clearTimeout(this._settleTimer);
    this._settleTimer = setTimeout(() => {
      this._settleTimer = null;
      if (this.app.preview) this.app.preview.refineFrame();
    }, 140);
  }

  // ---- moving a clip ---------------------------------------------------

  startClipDrag(e, clipId) {
    e.preventDefault();
    const found = findClip(this.app.project, clipId);
    if (!found) return;
    const grabOffset = this.tl.clientXToTime(e.clientX) - found.clip.start;
    this.tl.select(clipId);
    this.app.pushHistory();          // one snapshot per gesture, not per mousemove

    let currentTrackId = found.track.id;
    let rawStart = found.clip.start;
    let stripEl = null;              // set while hovering a "new lane" strip

    // ripple:false while dragging - re-laying the main track out gapless on
    // every mousemove is what made a clip appear not to move at all.
    const apply = (start, trackId, ripple) => {
      moveClip(this.app.project, clipId, trackId, start,
               { snapCandidates: [], pxPerSec: this.tl.pxPerSec, ripple: !!ripple });
    };

    const onMove = (ev) => {
      rawStart = Math.max(0, this.tl.clientXToTime(ev.clientX) - grabOffset);
      const hit = document.elementFromPoint(ev.clientX, ev.clientY);
      const overStrip = hit && hit.closest ? hit.closest('.drop-strip, .timeline-empty') : null;
      if (stripEl && stripEl !== overStrip) stripEl.classList.remove('is-over');
      stripEl = overStrip;
      if (stripEl) stripEl.classList.add('is-over');
      const rowEl = hit && hit.closest ? hit.closest('.track') : null;
      currentTrackId = (rowEl && rowEl.dataset.trackId) || currentTrackId;
      const liveStart = this.app.snapping
        ? snapToPlayhead(rawStart, this.app.playhead, this.tl.pxPerSec) : rawStart;
      this.tl.setSnapIndicator(liveStart !== rawStart);
      apply(liveStart, currentTrackId, false);
      this.tl.renderGeometry();       // geometry only: no rebuild, no preview seek
    };

    const onUp = () => {
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
      this.tl.setSnapIndicator(false);
      // now, and only now, let it snap and let the main track close its gaps
      apply(this.tl.snapped(rawStart, clipId), currentTrackId, true);
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

  // ---- trimming an edge ------------------------------------------------

  startTrim(e, clipId, edge) {
    e.preventDefault();
    const found = findClip(this.app.project, clipId);
    if (!found) return;
    this.tl.select(clipId);
    this.app.pushHistory();

    const magnetic = found.track.kind === 'main';
    const startBefore = found.clip.start;
    const endBefore = startBefore + found.clip.duration;
    // Where the edge is versus where you grabbed it. Without this the edge
    // teleports to the cursor the instant you press, which is both a surprise
    // and a few pixels of accuracy lost right where you need it most.
    const edgeAt = edge === 'L' ? found.clip.start : endBefore;
    const grabOffset = this.tl.clientXToTime(e.clientX) - edgeAt;

    let rawTime = edgeAt;
    // ripple:false while dragging: the edge you hold follows the mouse and the
    // opposite edge stays put. Rippling mid-drag pulled the whole row along.
    const apply = (t, ripple) => {
      trimClip(this.app.project, clipId, edge, t,
               { snapCandidates: [], pxPerSec: this.tl.pxPerSec, ripple: !!ripple });
    };

    const onMove = (ev) => {
      rawTime = this.tl.clientXToTime(ev.clientX) - grabOffset;
      // Park the playhead where you want the cut, drag the edge to it, and it
      // grabs on - live, like CapCut.
      const live = this.app.snapping
        ? snapToPlayhead(rawTime, this.app.playhead, this.tl.pxPerSec) : rawTime;
      this.tl.setSnapIndicator(live !== rawTime);
      apply(live, false);
      this.tl.renderGeometry();
    };

    const onUp = () => {
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
      this.tl.setSnapIndicator(false);
      apply(this.tl.snapped(rawTime, clipId), true);

      // WHICH EDGE YOU DRAGGED DECIDES WHERE THE CONTENT STARTS MOVING.
      //
      // Trim the RIGHT edge and everything inside the clip stays put; only what
      // follows it slides. Trim the LEFT edge and the ripple pulls the clip's
      // start back to where it was, so the whole clip's contents shift - the
      // frame that was at 5s is now at 4s. Using the clip's END for both is
      // what left the playhead sitting on a different shot after a left trim.
      if (magnetic) {
        const after = findClip(this.app.project, clipId);
        if (after) {
          const endAfter = after.clip.start + after.clip.duration;
          const delta = endAfter - endBefore;
          const editPoint = edge === 'L'
            ? Math.min(startBefore, after.clip.start)
            : Math.min(endBefore, endAfter);
          if (delta) {
            this.app.playhead = playheadAfterRipple(this.app.playhead, editPoint, delta);
            this.tl.setPlayhead(this.app.playhead);
          }
        }
      }
      this.app.commit();
    };

    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
  }

  // ---- snapping helpers ------------------------------------------------

  // Where an edge lands once you let go. With Snap off it lands exactly where
  // you dropped it.
  snapped(t, excludeClipId) {
    if (!this.app.snapping) return t;
    return snapEdge(t, this.app.playhead, this._candidates(excludeClipId), this.tl.pxPerSec);
  }

  // Other clips' edges. The playhead is deliberately NOT in here - snapEdge
  // gives it priority and a wider reach of its own.
  _candidates(excludeClipId) {
    const out = [];
    for (const t of this.app.project.tracks) {
      for (const c of t.clips) {
        if (c.id === excludeClipId) continue;
        out.push(c.start, c.start + c.duration);
      }
    }
    return out;
  }
}
