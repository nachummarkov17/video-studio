import { send, onMessage } from './bridge.js';
import { getPoster, requestPoster } from './thumbs.js';
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

// The panel that opens when you click a b-roll row. Set by app.js so this file
// stays free of trim-panel internals.
let openTrim = null;
export function onBrollClick(fn){ openTrim = fn; }

// A trim selection per b-roll item, remembered for the session so an item you
// trimmed once keeps that selection if you come back to it. app.js reads this
// when a row is dragged so the drop arrives already trimmed.
const trims = new Map();
export function getTrim(path){ return trims.get(path) || null; }
export function setTrim(path, sel){ if (sel) trims.set(path, sel); else trims.delete(path); }

const collapsed = new Set();

// Media-bin rows carry a small preview frame so you can tell your clips apart
// without opening them. Posters go through the same one-at-a-time job queue as
// the timeline filmstrips, so building them can never compete with playback.
function render(){
  const bin = document.getElementById('media-bin'); if(!bin) return;
  bin.innerHTML='';

  const mine = _items.filter(i => !i.broll);
  const broll = _items.filter(i => i.broll);

  if(!_items.length){
    const hint = document.createElement('p');
    hint.className = 'empty-hint';
    hint.textContent = 'No media yet. Use Import for your own clips, or + B-roll for cutaways.';
    bin.appendChild(hint);
    return;
  }

  if(mine.length) bin.appendChild(section('Your videos', mine));

  // b-roll splits into the folders you filed it under
  const groups = new Map();
  for(const it of broll){
    const g = it.group || 'B-roll';
    if(!groups.has(g)) groups.set(g, []);
    groups.get(g).push(it);
  }
  for(const [name, items] of [...groups].sort((a,b) => a[0].localeCompare(b[0]))){
    bin.appendChild(section(name, items, true));
  }
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
      if(t){
        const badge = document.createElement('span');
        badge.className = 'asset-trim';
        badge.textContent = (t.out - t.in).toFixed(1) + 's';
        badge.title = 'Trimmed - this is what will be added';
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
