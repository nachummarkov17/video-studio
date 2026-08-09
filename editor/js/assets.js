import { send, onMessage, request } from './bridge.js';
import { getPoster, requestPoster, getPosterMeta } from './thumbs.js';
export const MEDIA='https://studio.media/';
export function mediaUrl(relpath){ return MEDIA + relpath.split('/').map(encodeURIComponent).join('/'); }
let _items = []; const listeners = new Set();
onMessage(m => {
  if (m.type==='assets'){ _items = Array.isArray(m.items) ? m.items : (m.items == null ? [] : [m.items]); render(); listeners.forEach(f=>f(_items)); }
  if (m.type==='reScan'){ send({type:'listAssets'}); }
});
export function onAssets(fn){ listeners.add(fn); }
export function refreshAssets(){ send({type:'listAssets'}); }
export function importAssets(){ send({type:'importAssets'}); }
export function importBroll(group){ send({type:'importBroll', group: group || null}); }
export function openBrollFolder(){ send({type:'openBrollFolder'}); }

// Paste whatever is on the Windows clipboard into the library: files you copied
// in Explorer, or an image copied from anywhere. Resolves with how many landed.
export async function pasteBroll(group){
  const r = await request('pasteBroll', { group: group || null });
  return (r && r.count) || 0;
}

// Cut the selected seconds out of a shot and keep them as their own small file.
// From then on it's a select-and-drag - no trimming to redo.
export async function saveBrollClip(path, sel, name){
  const r = await request('saveBrollClip', { path, in: sel.in, out: sel.out, name });
  return r || { ok: false };
}

// The panel that opens when you click a b-roll row. Set by app.js so this file
// stays free of trim-panel internals.
let openTrim = null;
export function onBrollClick(fn){ openTrim = fn; }

// The in/out you set on a b-roll clip, kept BETWEEN SESSIONS by the host (in
// broll-trims.txt). You usually want the same three seconds of a shot every
// time you reach for it, so it would be no use forgetting them on exit.
const trims = new Map();
export function getTrim(path){ return trims.get(path) || null; }
export function setTrim(path, sel){
  if (sel) trims.set(path, sel); else trims.delete(path);
  send({ type: 'brollTrimSet', path, in: sel ? sel.in : null, out: sel ? sel.out : null });
  render();
}

// Pull the saved trims back at startup.
export async function loadTrims(){
  const r = await request('brollTrimsGet');
  const t = r && r.trims;
  if (t) for (const k of Object.keys(t)) {
    const v = t[k];
    if (v && v.out > v.in) trims.set(k, { in: v.in, out: v.out });
  }
  render();
}

const SAVED_GROUP = 'Saved clips';
const collapsed = new Set();

// Media-bin rows carry a small preview frame so you can tell your clips apart
// without opening them. Posters go through the same one-at-a-time job queue as
// the timeline filmstrips, so building them can never compete with playback.
function render(){
  const bin = document.getElementById('media-bin'); if(!bin) return;
  bin.innerHTML='';

  const mine = _items.filter(i => !i.broll);
  const broll = _items.filter(i => i.broll);

  if(mine.length) bin.appendChild(section('Your videos', mine));

  // b-roll splits into the folders you filed it under
  const groups = new Map();
  for(const it of broll){
    const g = it.group || 'B-roll';
    if(!groups.has(g)) groups.set(g, []);
    groups.get(g).push(it);
  }
  // your cut-down pieces are the ones you reach for most, so they go first
  const order = [...groups].sort((a, b) => {
    if (a[0] === SAVED_GROUP) return -1;
    if (b[0] === SAVED_GROUP) return 1;
    return a[0].localeCompare(b[0]);
  });
  for(const [name, items] of order){
    bin.appendChild(section(name, items, true));
  }

  // Always say where the library is and how to fill it - it's a folder on disk
  // that keeps whatever you put in it, and that isn't obvious from a list.
  const foot = document.createElement('div');
  foot.className = 'bin-foot';
  foot.innerHTML =
    '<p class="bin-foot-title">' + (broll.length ? 'Your b-roll library' : 'No b-roll yet') + '</p>' +
    '<p class="bin-foot-text">Kept in the <b>broll</b> folder - it stays there for every future session. ' +
    'Add with <b>+ B-roll</b>, or copy files in Explorer and press <b>Ctrl+V</b> here. ' +
    'Make folders inside it to group them.</p>' +
    '<button type="button" class="bin-foot-link" id="bin-open-broll">Open the b-roll folder</button>';
  foot.querySelector('#bin-open-broll').addEventListener('click', () => openBrollFolder());
  bin.appendChild(foot);
}

function section(title, items, isBroll){
  const wrap = document.createElement('div');
  wrap.className = 'bin-group' + (isBroll ? ' is-broll' : '');

  const head = document.createElement('button');
  head.type = 'button';
  head.className = 'bin-group-head';
  const isShut = collapsed.has(title);
  head.innerHTML = `<span class="bin-caret">${isShut ? '▸' : '▾'}</span>` +
                   `<span class="bin-group-name"></span>` +
                   `<span class="bin-count">${items.length}</span>`;
  head.querySelector('.bin-group-name').textContent = title;
  head.addEventListener('click', () => {
    if(collapsed.has(title)) collapsed.delete(title); else collapsed.add(title);
    render();
  });
  wrap.appendChild(head);

  if(isShut) return wrap;

  for(const it of items){
    const el = document.createElement('div'); el.className='asset '+it.type;
    el.draggable = true; el.dataset.path = it.path; el.dataset.type = it.type;
    el.title = it.name;

    const thumb = document.createElement('div');
    thumb.className = 'asset-thumb';
    const poster = getPoster(it.path);
    if(poster) thumb.style.backgroundImage = `url("${poster}")`;
    else requestPoster(it.path, mediaUrl(it.path), it.type, () => render());

    const name = document.createElement('span');
    name.className = 'asset-name';
    name.textContent = it.name;

    el.appendChild(thumb);
    el.appendChild(name);

    if(isBroll){
      const t = trims.get(it.path);
      const meta = getPosterMeta(it.path);
      if(t || (meta && meta.duration > 0)){
        const badge = document.createElement('span');
        badge.className = 'asset-trim' + (t ? '' : ' is-plain');
        const secs = t ? (t.out - t.in) : meta.duration;
        badge.textContent = secs < 60 ? secs.toFixed(1) + 's'
                                      : Math.floor(secs / 60) + ':' + String(Math.round(secs % 60)).padStart(2, '0');
        badge.title = t ? 'Trimmed - this is what will be added' : 'Length';
        el.appendChild(badge);
      }
      // Click to preview and trim before it goes anywhere near the timeline.
      el.addEventListener('click', () => { if(openTrim) openTrim(it); });
    }

    el.addEventListener('dragstart', ev => {
      const payload = { ...it };
      const t = trims.get(it.path);
      if(t) { payload.trimIn = t.in; payload.trimOut = t.out; }   // arrives trimmed
      ev.dataTransfer.setData('application/x-asset', JSON.stringify(payload));
      // A second, type-bearing MIME: dataTransfer VALUES are unreadable during
      // dragover, but the type list is - so the drop strips can tell what's
      // coming and highlight the lane it will actually land in.
      ev.dataTransfer.setData('application/x-asset-' + it.type, '1');
    });
    wrap.appendChild(el);
  }
  return wrap;
}
