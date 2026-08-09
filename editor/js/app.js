// app.js — coordinator: builds the project, wires model + preview +
// timeline-ui + inspector + bridge together, and owns the toolbar.
import { newProject, addAsset, addClip, getTrack, getAsset, findClip, pruneEmptyTracks, addTrackForType } from './model.js';
import { rippleMain, splitClip, deleteClip, totalDuration } from './timeline.js';
import { Preview } from './preview.js';
import { TimelineUI } from './timeline-ui.js';
import { Inspector } from './inspector.js';
import { History } from './history.js';
import { send, onMessage } from './bridge.js';
import { mediaUrl, refreshAssets, importAssets, importBroll, onBrollClick, getTrim, pasteBroll, loadTrims } from './assets.js';
import { TrimPanel } from './trim-panel.js';
import { setThumbsDeferred } from './thumbs.js';
import { timecode } from './timecode.js';

// `let`, not `const`: on projectLoaded we swap in a freshly-loaded project.
// Every function below that reads the bare `project` binding (assetUrl,
// addAssetAndClip, split/delete, the add-track buttons) reads it live at
// call time, so reassigning here — kept in lockstep with app.project — is
// enough to make them all operate on the loaded project instead of a stale
// reference to the original one.
let project = newProject('9:16');

const assetUrl = (assetId) => mediaUrl(getAsset(project, assetId).path);

const canvas = document.getElementById('preview-canvas');
const preview = new Preview(canvas, project, assetUrl);

// Declared up here on purpose: TimelineUI renders in its constructor, which
// moves the playhead, which calls updateTransport() - so these must already be
// initialised by then or that first render dies on a temporal-dead-zone error.
const transportTime = document.getElementById('transport-time');
const transportDur = document.getElementById('transport-duration');
const scrub = document.querySelector('.scrub');


const app = {
  project,
  preview,
  timeline: null,
  inspector: null,
  selectedId: null,
  playhead: 0,
  pxPerSec: 100,
  snapping: true,
  history: new History(50),

  refreshPreview() {
    preview.setTime(app.playhead);
  },

  // Called by the timeline whenever the playhead moves for ANY reason, so the
  // timecode and the scrub bar can't drift out of step with the red line.
  onPlayheadChange() {
    updateTransport();
  },

  // Scrubbing while the clock is running would just fight it - the playback
  // loop overwrites the time every frame - so grabbing the playhead stops it.
  pausePlayback() {
    if (!preview.playing) return;
    preview.pause();
    btnPlay.innerHTML = '&#9654; Play';
    setThumbsDeferred(false);
  },

  commit() {
    app.timeline.render();
    app.refreshPreview();
    updateTransport();
  },

  // The single entry point for play/pause, so the button, the spacebar and
  // anything else can't disagree about the state.
  togglePlay() {
    if (preview.playing) { app.pausePlayback(); return; }
    // play() pre-rolls before starting the clock, so it resolves later; the
    // button reflects the intent straight away.
    const started = preview.play();
    btnPlay.innerHTML = preview.playing ? '&#10073;&#10073; Pause' : '&#9654; Play';
    // Playback owns the decoder: hold off on generating filmstrips until it stops.
    setThumbsDeferred(preview.playing);
    if (started && started.catch) started.catch(() => {});
  },

  // Snapshot the project as it is right now, BEFORE the action about to run.
  // Called once per gesture (mousedown of a drag, not every mousemove).
  pushHistory() {
    app.history.push(project);
  },

  // Swap a remembered state in and put the UI back in sync with it.
  applyState(state) {
    if (!state) return;
    preview.pause();
    btnPlay.innerHTML = '&#9654; Play';
    project = state;
    app.project = project;
    preview.setProject(project);
    // keep the selection if that clip survived the undo
    if (app.selectedId && !findClip(project, app.selectedId)) app.selectedId = null;
    const found = app.selectedId ? findClip(project, app.selectedId) : null;
    if (found) app.inspector.show(found.clip); else app.inspector.clear();
    app.commit();
  },

  undo() { app.applyState(app.history.undo(project)); },
  redo() { app.applyState(app.history.redo(project)); },

  addAssetAndClip,
};

app.timeline = new TimelineUI(document.getElementById('timeline'), app);
app.inspector = new Inspector(document.getElementById('inspector'), app);

// ---- b-roll ----------------------------------------------------------------

const trimPanel = new TrimPanel(document.querySelector('.preview-stage'), app);
onBrollClick((item) => trimPanel.open(item));

// B-roll is cutaway footage by definition, so it goes on an overlay lane above
// the main clip - never displacing it. The topmost existing overlay lane is
// reused; a new one is only created when there isn't one.
app.addBrollAtPlayhead = (item, trim) => {
  app.pushHistory();
  const overlays = project.tracks.filter(t => t.kind === 'overlay');
  const trackId = overlays.length ? overlays[overlays.length - 1].id
                                  : addTrackForType(project, item.type === 'image' ? 'image' : 'video');
  addAssetAndClip(item, trackId, app.playhead, trim).catch((err) => {
    console.error('[b-roll] could not add:', err);
    statusText.textContent = "Couldn't add that b-roll";
  });
};

const btnBroll = document.getElementById('btn-broll');
if (btnBroll) btnBroll.addEventListener('click', () => importBroll());

// Copy clips in Explorer, press Ctrl+V here, and they join the library.
document.addEventListener('paste', async (e) => {
  if (isTypingIn(e.target)) return;
  e.preventDefault();
  statusText.textContent = 'Pasting…';
  const n = await pasteBroll();
  statusText.textContent = n
    ? (n === 1 ? 'Added 1 clip to your b-roll' : `Added ${n} items to your b-roll`)
    : 'Nothing on the clipboard to add';
});

// ---- transport: timecode readouts + the scrub bar --------------------------

function updateTransport() {
  const fps = (project.canvas && project.canvas.fps) || 30;
  const total = totalDuration(project);
  if (transportTime) transportTime.textContent = timecode(app.playhead, fps);
  if (transportDur) transportDur.textContent = timecode(total, fps);
  if (scrub) {
    scrub.disabled = !(total > 0);
    scrub.max = String(Math.max(0.001, total));
    if (!scrub.matches(':active')) scrub.value = String(Math.min(app.playhead, total));
  }
}

if (scrub) {
  scrub.step = 'any';
  scrub.addEventListener('input', () => {
    app.pausePlayback();
    app.playhead = parseFloat(scrub.value) || 0;
    app.timeline.setPlayhead(app.playhead);
    app.refreshPreview();
    updateTransport();
  });
}

// Pre-roll before playback shows up here instead of looking like a hang.
const busyPill = document.createElement('div');
busyPill.className = 'busy-pill';
busyPill.innerHTML = '<span class="boot-spinner"></span><span>Buffering…</span>';
document.body.appendChild(busyPill);
preview.onBuffering = (on) => busyPill.classList.toggle('is-on', !!on);

// Drive the playhead from the playback clock every rAF frame.
preview.onTick = (t) => {
  // While the playhead is being dragged it belongs to the pointer, not to the
  // clock - otherwise the two fight and the line snaps back every frame.
  if (preview.isScrubbing && preview.isScrubbing()) return;
  app.playhead = t;
  app.timeline.setPlayhead(t);
  updateTransport();
  // Playback can end on its own (reaching the end of the timeline), in which
  // case preview.pause() already ran before this tick fires — reflect that
  // in the toolbar without waiting for another click.
  if (!preview.playing) { btnPlay.innerHTML = '&#9654; Play'; setThumbsDeferred(false); }
};

// ---- asset probing + clip creation (drag-drop from the media bin) ----

// Reads real duration/dimensions off the media before it becomes part of the
// project, per the task-7 brief: video/audio via a temp <video>/<audio> and
// `loadedmetadata`, images via a temp Image() and `onload`. Images get a
// default 5s duration since a still has no intrinsic length.
async function probeMedia(assetInfo) {
  const url = mediaUrl(assetInfo.path);
  if (assetInfo.type === 'image') {
    const img = new Image();
    await new Promise((resolve, reject) => {
      img.addEventListener('load', resolve, { once: true });
      img.onerror = () => reject(new Error('Could not read image: ' + url));
      img.src = url;
    });
    return { duration: 5, naturalW: img.naturalWidth, naturalH: img.naturalHeight };
  }
  const el = document.createElement(assetInfo.type === 'audio' ? 'audio' : 'video');
  el.preload = 'metadata';
  el.muted = true;
  await new Promise((resolve, reject) => {
    el.addEventListener('loadedmetadata', resolve, { once: true });
    el.addEventListener('error', () => reject(new Error('Could not read media: ' + url)), { once: true });
    el.src = url;
  });
  return {
    duration: el.duration,
    naturalW: el.videoWidth || 0,
    naturalH: el.videoHeight || 0,
  };
}

// `trim` is optional: {in, duration}. B-roll dropped or added after being
// trimmed arrives as that piece; everything else behaves exactly as before.
async function addAssetAndClip(assetInfo, trackId, dropTime, trim) {
  const { duration, naturalW, naturalH } = await probeMedia(assetInfo);

  const assetId = addAsset(project, {
    path: assetInfo.path,
    type: assetInfo.type,
    naturalW,
    naturalH,
    duration,
  });
  const inPoint = trim && trim.in > 0 ? Math.min(trim.in, Math.max(0, duration - 0.1)) : 0;
  const clipLen = trim && trim.duration > 0
    ? Math.min(trim.duration, Math.max(0.1, duration - inPoint))
    : duration;
  const clipId = addClip(project, trackId, {
    assetId,
    start: Math.max(0, dropTime),
    in: inPoint,
    duration: clipLen,
  });

  const track = getTrack(project, trackId);
  if (track && track.kind === 'main') rippleMain(track);

  // Preview only knows about assets that existed at the last setProject() /
  // construction time — re-run it so the new asset's media element exists
  // before commit() asks the canvas to draw it.
  preview.setProject(project);

  const found = findClip(project, clipId);
  app.selectedId = clipId;
  if (found) app.inspector.show(found.clip);
  app.commit();
  // show the WHOLE clip you just dropped, not just its first couple of seconds
  app.timeline.zoomToFit();
}

// ---- toolbar ----

const btnPlay = document.getElementById('btn-play');
btnPlay.addEventListener('click', () => app.togglePlay());

function doSplit(clipId) {
  const id = clipId || app.selectedId;
  if (!id) return;
  app.pushHistory();
  splitClip(project, id, app.playhead);
  app.commit();
}

function doDelete(clipId) {
  const id = clipId || app.selectedId;
  if (!id) return;
  app.pushHistory();
  deleteClip(project, id);
  pruneEmptyTracks(project);        // removing the last clip removes its lane
  if (app.selectedId === id) { app.selectedId = null; app.inspector.clear(); }
  app.commit();
}

function doToggleMute(clipId) {
  const found = findClip(project, clipId || app.selectedId);
  if (!found) return;
  app.pushHistory();
  found.clip.muted = !found.clip.muted;
  app.commit();
}

document.getElementById('btn-split').addEventListener('click', () => doSplit());
document.getElementById('btn-del').addEventListener('click', () => doDelete());

// ---- keyboard --------------------------------------------------------------

const TEXT_INPUT_TYPES = new Set(['text','search','email','url','tel','password','number']);
const isTypingIn = (t) => {
  if (!t) return false;
  if (t.isContentEditable || t.tagName === 'TEXTAREA') return true;
  // NOT every <input> takes typing: the scrub bar is a range, and treating it
  // as a text field is what made clicking the time bar kill the spacebar.
  return t.tagName === 'INPUT' && TEXT_INPUT_TYPES.has((t.type || 'text').toLowerCase());
};

// Space is ALWAYS play/pause. Buttons keep focus after a click, so without this
// the spacebar just re-fired whatever you last pressed (Split, Delete...).
document.addEventListener('keydown', (e) => {
  if (e.code !== 'Space' && e.key !== ' ') return;
  if (isTypingIn(e.target)) return;
  e.preventDefault();
  e.stopPropagation();
  if (e.target && e.target.blur) e.target.blur();   // stop the button re-triggering
  app.togglePlay();
}, true);   // capture: get there before the focused button does

// Split (S) and Delete (Del / Backspace) - the shortcuts the toolbar tooltips
// have always advertised but nothing ever listened for.
document.addEventListener('keydown', (e) => {
  if (e.ctrlKey || e.metaKey || e.altKey) return;
  if (isTypingIn(e.target)) return;
  const k = (e.key || '').toLowerCase();
  if (k === 's') { e.preventDefault(); doSplit(); }
  else if (e.key === 'Delete' || e.key === 'Backspace') { e.preventDefault(); doDelete(); }
  else if (k === 'm') { e.preventDefault(); doToggleMute(); }
});

// ---- right-click a clip ----------------------------------------------------

// WebView2 would otherwise show the browser's own menu (Reload, Save as...),
// which is meaningless here.
document.addEventListener('contextmenu', (e) => e.preventDefault());

let ctxMenu = null;
function closeClipMenu() {
  if (ctxMenu) { ctxMenu.remove(); ctxMenu = null; }
}
document.addEventListener('mousedown', (e) => {
  if (ctxMenu && !ctxMenu.contains(e.target)) closeClipMenu();
});
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeClipMenu(); });

app.showClipMenu = (clipId, x, y) => {
  closeClipMenu();
  const found = findClip(project, clipId);
  if (!found) return;
  const clip = found.clip;

  ctxMenu = document.createElement('div');
  ctxMenu.className = 'ctx-menu';
  const add = (label, key, fn) => {
    const item = document.createElement('div');
    item.className = 'ctx-item';
    const text = document.createElement('span');
    text.textContent = label;
    item.appendChild(text);
    if (key) {
      const k = document.createElement('span');
      k.className = 'ctx-key';
      k.textContent = key;
      item.appendChild(k);
    }
    item.addEventListener('click', () => { closeClipMenu(); fn(); });
    ctxMenu.appendChild(item);
    return item;
  };
  const sep = () => {
    const d = document.createElement('div');
    d.className = 'ctx-sep';
    ctxMenu.appendChild(d);
  };

  add(clip.muted ? 'Unmute audio' : 'Mute audio', 'M', () => doToggleMute(clipId));
  sep();
  add('Split at playhead', 'S', () => doSplit(clipId));
  add('Delete clip', 'Del', () => doDelete(clipId));

  ctxMenu.style.visibility = 'hidden';
  document.body.appendChild(ctxMenu);
  // keep it on screen when you right-click near an edge
  const r = ctxMenu.getBoundingClientRect();
  ctxMenu.style.left = Math.min(x, window.innerWidth - r.width - 8) + 'px';
  ctxMenu.style.top = Math.min(y, window.innerHeight - r.height - 8) + 'px';
  ctxMenu.style.visibility = 'visible';
};

// ---- undo / redo -----------------------------------------------------------
document.addEventListener('keydown', (e) => {
  if (!(e.ctrlKey || e.metaKey)) return;
  if (isTypingIn(e.target)) return;   // never steal it from a field being typed in
  const k = (e.key || '').toLowerCase();
  if (k === 'z' && !e.shiftKey) { e.preventDefault(); app.undo(); }
  else if ((k === 'z' && e.shiftKey) || k === 'y') { e.preventDefault(); app.redo(); }
});

document.getElementById('btn-zoom-in').addEventListener('click', () => app.timeline.zoom(20));
document.getElementById('btn-zoom-out').addEventListener('click', () => app.timeline.zoom(-20));
document.getElementById('btn-fit').addEventListener('click', () => app.timeline.zoomToFit());

const btnSnap = document.getElementById('btn-snap');
btnSnap.addEventListener('click', () => {
  app.snapping = !app.snapping;
  btnSnap.classList.toggle('is-active', app.snapping);
});

document.getElementById('btn-import').addEventListener('click', () => importAssets());

document.getElementById('btn-save').addEventListener('click', () => {
  const name = window.prompt('Save project as:', project.name || 'Untitled');
  if (!name) return;
  project.name = name;
  statusText.textContent = 'Saving…';
  send({ type: 'saveProject', name, project });
});

document.getElementById('btn-open').addEventListener('click', () => {
  send({ type: 'listProjects' });
});
const btnExport = document.getElementById('btn-export');
const btnExportLabel = btnExport.textContent;
btnExport.addEventListener('click', () => {
  btnExport.disabled = true;
  btnExport.textContent = 'Rendering…';
  statusText.textContent = 'Rendering…';
  send({ type: 'export', project });
});

// ---- bridge status pill + initial asset load ----

const statusPill = document.getElementById('status');
const statusText = document.getElementById('status-text');

onMessage((m) => {
  if (m.type === 'pong') {
    statusText.textContent = 'bridge OK: ' + m.echo;
    statusPill.classList.add('is-ok');
  }
  if (m.type === 'exportProgress') {
    statusText.textContent = 'Rendering… ' + (m.pct ?? 0) + '%';
  }
  if (m.type === 'exportDone') {
    btnExport.disabled = false;
    btnExport.textContent = btnExportLabel;
    if (m.ok) {
      statusText.textContent = 'Exported to output — continue in Video Studio';
      statusPill.classList.add('is-ok');
    } else {
      statusText.textContent = 'Export failed';
      statusPill.classList.remove('is-ok');
    }
  }
  if (m.type === 'projectSaved') {
    if (m.ok === false) {
      statusText.textContent = 'Save failed' + (m.error ? (': ' + m.error) : '');
      statusPill.classList.remove('is-ok');
    } else {
      statusText.textContent = 'Saved “' + m.name + '”';
      statusPill.classList.add('is-ok');
    }
  }
  if (m.type === 'projects') {
    const names = m.names || [];
    if (!names.length) {
      window.alert('No saved projects yet.');
      return;
    }
    const pick = window.prompt(
      'Open which project?\n\n' + names.join('\n'),
      names[0]
    );
    if (!pick) return;
    send({ type: 'loadProject', name: pick });
  }
  if (m.type === 'projectLoaded') {
    if (m.ok === false || !m.project) {
      statusText.textContent = "Couldn't open that project";
      statusPill.classList.remove('is-ok');
      return;
    }
    // Pause any in-flight playback before swapping the project out from
    // under the Preview - an Open mid-playback would otherwise leave stale
    // media elements running / glitch the transition.
    preview.pause();
    btnPlay.innerHTML = '&#9654; Play';
    project = m.project;
    // projects saved before lanes were dynamic carry three fixed lanes, two of
    // them usually empty - drop them so the timeline opens clean
    pruneEmptyTracks(project);
    app.project = project;
    app.history.clear();          // an opened project is a fresh undo baseline
    preview.setProject(app.project);
    app.selectedId = null;
    app.inspector.clear();
    app.playhead = 0;
    app.timeline.render();
    app.timeline.zoomToFit();
    app.refreshPreview();
    updateTransport();
    statusText.textContent = 'Opened “' + (app.project.name || 'Untitled') + '”';
    statusPill.classList.add('is-ok');
  }
});
// The window is up as soon as the modules have run and the first asset scan has
// answered (or after a moment, if the host is slow to reply).
let bootHidden = false;
function hideBoot() {
  if (bootHidden) return;
  bootHidden = true;
  const boot = document.getElementById('boot');
  if (!boot) return;
  boot.classList.add('is-gone');
  setTimeout(() => boot.remove(), 300);
}
onMessage((m) => { if (m.type === 'assets') hideBoot(); });
setTimeout(hideBoot, 2500);

send({ type: 'ping', echo: 'hello' });

refreshAssets();
loadTrims();          // the trims you set in earlier sessions
updateTransport();
requestAnimationFrame(hideBoot);
