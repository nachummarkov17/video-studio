import { send, onMessage } from './bridge.js';
export const MEDIA='https://studio.media/';
export function mediaUrl(relpath){ return MEDIA + relpath.split('/').map(encodeURIComponent).join('/'); }
let _items = []; const listeners = new Set();
onMessage(m => {
  if (m.type==='assets'){ _items = m.items; render(); listeners.forEach(f=>f(_items)); }
  if (m.type==='reScan'){ send({type:'listAssets'}); }
});
export function onAssets(fn){ listeners.add(fn); }
export function refreshAssets(){ send({type:'listAssets'}); }
export function importAssets(){ send({type:'importAssets'}); }
function render(){
  const bin = document.getElementById('media-bin'); if(!bin) return;
  bin.innerHTML='';
  for(const it of _items){
    const el = document.createElement('div'); el.className='asset '+it.type;
    el.textContent = it.name; el.draggable = true; el.dataset.path = it.path; el.dataset.type = it.type;
    el.addEventListener('dragstart', ev => ev.dataTransfer.setData('application/x-asset', JSON.stringify(it)));
    bin.appendChild(el);
  }
}
