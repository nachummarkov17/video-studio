// app.js — coordinator: builds the project, wires model + preview +
// timeline-ui + inspector + bridge together, and owns the toolbar.
import { newProject, addAsset, addClip, getTrack, getAsset, uid, findClip } from './model.js';
import { rippleMain, splitClip, deleteClip } from './timeline.js';
import { Preview } from './preview.js';
import { TimelineUI } from './timeline-ui.js';
import { Inspector } from './inspector.js';
import { send, onMessage } from './bridge.js';
import { mediaUrl, refreshAssets, importAssets } from './assets.js';

const project = newProject('9:16');

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

  refreshPreview() {
    preview.setTime(app.playhead);
  },

  commit() {
    app.timeline.render();
    app.refreshPreview();
  },

  addAssetAndClip,
};

app.timeline = new TimelineUI(document.getElementById('timeline'), app);
app.inspector = new Inspector(document.getElementById('inspector'), app);

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
      img.addEventListener('error', reject, { once: true });
      img.src = url;
    });
    return { duration: 5, naturalW: img.naturalWidth, naturalH: img.naturalHeight };
  }
  const el = document.createElement(assetInfo.type === 'audio' ? 'audio' : 'video');
  el.preload = 'metadata';
  el.muted = true;
  await new Promise((resolve, reject) => {
    el.addEventListener('loadedmetadata', resolve, { once: true });
    el.addEventListener('error', reject, { once: true });
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
}

// ---- toolbar ----

const btnPlay = document.getElementById('btn-play');
btnPlay.addEventListener('click', () => {
  if (preview.playing) {
    preview.pause();
    btnPlay.innerHTML = '&#9654; Play';
  } else {
    preview.play();
    btnPlay.innerHTML = '&#10073;&#10073; Pause';
  }
});

document.getElementById('btn-split').addEventListener('click', () => {
  if (!app.selectedId) return;
  splitClip(project, app.selectedId, app.playhead);
  app.commit();
});

document.getElementById('btn-del').addEventListener('click', () => {
  if (!app.selectedId) return;
  deleteClip(project, app.selectedId);
  app.selectedId = null;
  app.inspector.clear();
  app.commit();
});

document.getElementById('btn-add-video').addEventListener('click', () => {
  project.tracks.push({ id: uid('t'), kind: 'overlay', clips: [] });
  app.timeline.render();
});

document.getElementById('btn-add-audio').addEventListener('click', () => {
  project.tracks.push({ id: uid('t'), kind: 'audio', clips: [] });
  app.timeline.render();
});

document.getElementById('btn-zoom-in').addEventListener('click', () => app.timeline.zoom(20));
document.getElementById('btn-zoom-out').addEventListener('click', () => app.timeline.zoom(-20));

const btnSnap = document.getElementById('btn-snap');
btnSnap.addEventListener('click', () => {
  app.snapping = !app.snapping;
  btnSnap.classList.toggle('is-active', app.snapping);
});

document.getElementById('btn-import').addEventListener('click', () => importAssets());

// Deliberate stubs — implemented in later tasks (Save/Open: Task 10-11 project
// persistence; Export: Task 11 render pipeline).
document.getElementById('btn-save').addEventListener('click', () => {
  console.log('[app] Save not implemented yet (Task 10/11)');
});
document.getElementById('btn-open').addEventListener('click', () => {
  console.log('[app] Open not implemented yet (Task 10/11)');
});
document.getElementById('btn-export').addEventListener('click', () => {
  console.log('[app] Export not implemented yet (Task 11)');
});

// ---- bridge status pill + initial asset load ----

const statusPill = document.getElementById('status');
const statusText = document.getElementById('status-text');

onMessage((m) => {
  if (m.type === 'pong') {
    statusText.textContent = 'bridge OK: ' + m.echo;
    statusPill.classList.add('is-ok');
  }
});
send({ type: 'ping', echo: 'hello' });

refreshAssets();
