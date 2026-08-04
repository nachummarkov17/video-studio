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

// Media-bin rows carry a small preview frame so you can tell your clips apart
// without opening them. Posters go through the same one-at-a-time job queue as
// the timeline filmstrips, so building them can never compete with playback.
function render(){
  const bin = document.getElementById('media-bin'); if(!bin) return;
  bin.innerHTML='';
  if(!_items.length){
    const hint = document.createElement('p');
    hint.className = 'empty-hint';
    hint.textContent = 'No assets yet. Click Import to add media.';
    bin.appendChild(hint);
    return;
  }
  for(const it of _items){
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
    el.addEventListener('dragstart', ev => ev.dataTransfer.setData('application/x-asset', JSON.stringify(it)));
    bin.appendChild(el);
  }
}
