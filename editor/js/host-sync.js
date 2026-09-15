// host-sync.js — everything that crosses the bridge to the app: saving and
// opening a project, and rendering the timeline into "Your videos".
//
// SAVE AND EXPORT ARE DIFFERENT THINGS and the UI now says so, because they
// were easy to confuse:
//
//   Save project   writes your edit to projects\ so you can come back to it.
//                  It does not produce a video.
//   Export video   renders the timeline into "Your videos", where captions,
//                  music and finishing pick it up. It leaves your source clips
//                  where they are - the export is a NEW clip, not a
//                  replacement, which is why it appears alongside them.
//
// Naming the export and confirming an overwrite happen on the host side, in the
// app's own dialogs, so it's one decision rather than a round trip.

import { send, onMessage } from './bridge.js';
import { onProxyReady } from './preview-source.js';

export function installHostSync(app, ui) {
  const { statusText, statusPill, btnExport } = ui;
  const exportLabel = btnExport ? btnExport.textContent : 'Export';

  const say = (msg, ok) => {
    if (statusText) statusText.textContent = msg;
    if (statusPill && ok != null) statusPill.classList.toggle('is-ok', !!ok);
  };

  // ---- outgoing --------------------------------------------------------

  const saveProject = () => {
    const name = window.prompt('Save this edit as:', app.project.name || 'Untitled');
    if (!name) return;
    app.project.name = name;
    say('Saving…');
    send({ type: 'saveProject', name, project: app.project });
  };

  const openProject = () => send({ type: 'listProjects' });

  const exportVideo = () => {
    if (btnExport) { btnExport.disabled = true; btnExport.textContent = 'Rendering…'; }
    say('Rendering…');
    // No name is sent: the host asks for one, with a sensible default, and
    // checks for a clash before a single frame is encoded.
    send({ type: 'export', project: app.project });
  };

  // ---- incoming --------------------------------------------------------

  onMessage((m) => {
    switch (m.type) {
      case 'pong':
        say('bridge OK: ' + m.echo, true);
        break;

      case 'exportProgress':
        say('Rendering… ' + (m.pct ?? 0) + '%');
        break;

      case 'exportDone': {
        if (btnExport) { btnExport.disabled = false; btnExport.textContent = exportLabel; }
        if (m.cancelled) { say('Export cancelled', true); break; }
        if (m.ok) {
          say('Exported “' + (m.name || 'video') + '” — it’s in Your videos now', true);
        } else {
          say('Export failed' + (m.error ? ': ' + m.error : ''), false);
        }
        break;
      }

      case 'projectSaved':
        if (m.ok === false) say('Save failed' + (m.error ? ': ' + m.error : ''), false);
        else say('Saved “' + m.name + '” — reopen it any time with Open', true);
        break;

      case 'projects': {
        const names = m.names || [];
        if (!names.length) { window.alert('No saved projects yet.'); break; }
        const pick = window.prompt('Open which project?\n\n' + names.join('\n'), names[0]);
        if (pick) send({ type: 'loadProject', name: pick });
        break;
      }

      case 'projectLoaded':
        if (m.ok === false || !m.project) { say("Couldn't open that project", false); break; }
        app.loadProject(m.project);
        say('Opened “' + (app.project.name || 'Untitled') + '”', true);
        break;
    }
  });

  // A preview proxy finished building: let the player pick it up for anything
  // it isn't already playing.
  onProxyReady(() => { if (app.preview) app.preview.refreshSources(); });

  return { saveProject, openProject, exportVideo };
}
