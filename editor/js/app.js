// app.js — coordinator: builds the project, wires model + preview +
// timeline-ui + inspector + bridge together, and owns the toolbar.
import { newProject, addAsset, addClip, getTrack, getAsset, findClip, pruneEmptyTracks } from './model.js';
import { rippleMain, splitClip, deleteClip } from './timeline.js';
import { Preview } from './preview.js';
import { TimelineUI } from './timeline-ui.js';
import { Inspector } from './inspector.js';
import { History } from './history.js';
import { send, onMessage } from './bridge.js';
import { mediaUrl, refreshAssets, importAssets } from './assets.js';

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

  // Scrubbing while the clock is running would just fight it - the playback
  // loop overwrites the time every frame - so grabbing the playhead stops it.
  pausePlayback() {
    if (!preview.playing) return;
    preview.pause();
    btnPlay.innerHTML = '&#9654; Play';
  },

  commit() {
    app.timeline.render();
    app.refreshPreview();
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

// Drive the playhead from the playback clock every rAF frame.
preview.onTick = (t) => {
  app.playhead = t;
  app.timeline.setPlayhead(t);
  // Playback can end on its own (reaching the end of the timeline), in which
  // case preview.pause() already ran before this tick fires — reflect that
  // in the toolbar without waiting for another click.
  if (!preview.playing) btnPlay.innerHTML = '&#9654; Play';
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

async function addAssetAndClip(assetInfo, trackId, dropTime) {
  const { duration, naturalW, naturalH } = await probeMedia(assetInfo);

  const assetId = addAsset(project, {
    path: assetInfo.path,
    type: assetInfo.type,
    naturalW,
    naturalH,
    duration,
  });
  const clipId = addClip(project, trackId, {
    assetId,
    start: Math.max(0, dropTime),
    in: 0,
    duration,
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
btnPlay.addEventListener('click', () => {
  if (preview.playing) {
    preview.pause();
    btnPlay.innerHTML = '&#9654; Play';
  } else {
    preview.play();
    // play() declines when there's nothing on the timeline - don't claim otherwise
    btnPlay.innerHTML = preview.playing ? '&#10073;&#10073; Pause' : '&#9654; Play';
  }
});

document.getElementById('btn-split').addEventListener('click', () => {
  if (!app.selectedId) return;
  app.pushHistory();
  splitClip(project, app.selectedId, app.playhead);
  app.commit();
});

document.getElementById('btn-del').addEventListener('click', () => {
  if (!app.selectedId) return;
  app.pushHistory();
  deleteClip(project, app.selectedId);
  pruneEmptyTracks(project);        // removing the last clip removes its lane
  app.selectedId = null;
  app.inspector.clear();
  app.commit();
});

// ---- undo / redo -----------------------------------------------------------
document.addEventListener('keydown', (e) => {
  if (!(e.ctrlKey || e.metaKey)) return;
  const t = e.target;
  // never steal the shortcut from a field the user is typing in
  if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return;
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
    statusText.textContent = 'Opened “' + (app.project.name || 'Untitled') + '”';
    statusPill.classList.add('is-ok');
  }
});
send({ type: 'ping', echo: 'hello' });

refreshAssets();
