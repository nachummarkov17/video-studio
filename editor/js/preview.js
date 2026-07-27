export class Preview {
  constructor(canvas, project, assetUrl){
    this.cv = canvas; this.ctx = canvas.getContext('2d');
    this.assetUrl = assetUrl; this.media = new Map(); this._t = 0; this.playing=false; this._seq = 0;
    this.setProject(project);
  }
  setProject(p){ this.project = p; this.cv.width = p.canvas.width; this.cv.height = p.canvas.height; this._ensureMedia(); this.setTime(this._t); }
  _ensureMedia(){
    for(const a of this.project.assets){
      if(this.media.has(a.id)) continue;
      if(a.type==='image'){ const img=new Image(); img.src=this.assetUrl(a.id); this.media.set(a.id,{kind:'image',el:img}); }
      else { const v=document.createElement('video'); v.src=this.assetUrl(a.id); v.muted=(a.type!=='audio'? false:false); v.preload='auto'; v.crossOrigin='anonymous'; this.media.set(a.id,{kind:a.type,el:v}); }
    }
  }
  _clipsAt(t){ // bottom-to-top: main track first, then overlay tracks in order
    const out=[];
    for(const tr of this.project.tracks){ if(tr.kind==='audio') continue;
      for(const c of tr.clips){ if(t>=c.start && t < c.start+c.duration) out.push({tr,c}); } }
    return out;
  }
  async setTime(t){
    this._t=t; const token = ++this._seq; const ctx=this.ctx, W=this.cv.width, H=this.cv.height;
    ctx.clearRect(0,0,W,H); ctx.fillStyle='#000'; ctx.fillRect(0,0,W,H);
    for(const {tr,c} of this._clipsAt(t)){
      const m=this.media.get(c.assetId); if(!m) continue;
      const src = m.el; const local = c.in + (t - c.start);
      if(m.kind!=='image'){ if(Math.abs(src.currentTime-local)>0.05 && !this.playing){ src.currentTime=local; await new Promise(r=>{ src.onseeked=r; setTimeout(r,120);}); if (token !== this._seq) return; } }
      const nw = (m.kind==='image'? src.naturalWidth: src.videoWidth)||W;
      const nh = (m.kind==='image'? src.naturalHeight: src.videoHeight)||H;
      ctx.globalAlpha = c.opacity ?? 1;
      if(tr.kind==='main'){ // cover the full canvas
        const s=Math.max(W/nw,H/nh); const dw=nw*s, dh=nh*s; ctx.drawImage(src,(W-dw)/2,(H-dh)/2,dw,dh);
      } else { // overlay: place at x,y at scale (fraction of canvas width)
        const dw=nw*(c.scale??1), dh=nh*(c.scale??1); ctx.drawImage(src, c.x??0, c.y??0, dw, dh);
      }
      ctx.globalAlpha=1;
    }
  }
  play(){ this.playing = true; }
  pause(){ this.playing = false; }
  get time(){ return this._t; }
}
