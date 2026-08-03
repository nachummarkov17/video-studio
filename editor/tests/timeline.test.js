import { test } from 'node:test'; import assert from 'node:assert';
import { newProject, addAsset, addClip, findClip } from '../js/model.js';
import { totalDuration, snapTime, rippleMain, splitClip, trimClip, moveClip, deleteClip, fitPxPerSec } from '../js/timeline.js';

function mainProj(){
  const p=newProject(); const a=addAsset(p,{path:'x.mp4',type:'video',naturalW:1080,naturalH:1920,duration:30});
  const t=p.tracks[0].id; addClip(p,t,{assetId:a,start:0,in:0,duration:4}); addClip(p,t,{assetId:a,start:4,in:10,duration:6}); return p;
}
test('totalDuration = end of last clip', () => { assert.equal(totalDuration(mainProj()), 10); });
test('rippleMain closes gaps and left-aligns', () => {
  const p=mainProj(); p.tracks[0].clips[1].start=9; rippleMain(p.tracks[0]);
  assert.deepEqual(p.tracks[0].clips.map(c=>c.start), [0,4]);
});
test('splitClip splits the straddling clip and main stays gapless', () => {
  const p=mainProj(); const id=p.tracks[0].clips[0].id; splitClip(p,id,2);
  const starts=p.tracks[0].clips.map(c=>c.start); assert.deepEqual(starts,[0,2,4]);
  assert.equal(p.tracks[0].clips[0].duration,2); assert.equal(p.tracks[0].clips[1].duration,2);
  assert.equal(p.tracks[0].clips[1].in, 2); // second half's in-point advanced
});
test('trimClip right edge shortens duration and clamps to source length', () => {
  const p=mainProj(); const id=p.tracks[0].clips[1].id; // in=10,dur=6, source dur=30 -> max end in-source=30
  trimClip(p,id,'R', 4+9, {snapCandidates:[],pxPerSec:100}); // ask to extend to 9s long
  const { clip }=findClip(p,id); assert.ok(clip.in+clip.duration<=30); assert.ok(clip.duration>0);
});
test('trimClip left edge advances start+in together and shrinks duration (main clip)', () => {
  const p=mainProj(); const id=p.tracks[0].clips[1].id; // start4,in10,duration6
  const before = { ...findClip(p,id).clip };
  trimClip(p,id,'L', 6, {snapCandidates:[],pxPerSec:100}); // drag left edge later by 2s
  const { clip } = findClip(p,id);
  const delta = clip.in - before.in;
  assert.equal(delta, 2); // in advanced by the requested delta
  assert.equal(clip.duration, before.duration - delta); // duration shrank by the same delta
  assert.equal(clip.in + clip.duration, before.in + before.duration); // content's right edge unchanged
  assert.ok(clip.in >= 0 && clip.duration > 0);
  // main track stays gapless after the edit
  assert.deepEqual(p.tracks[0].clips.map(c=>c.start), [0, p.tracks[0].clips[0].duration]);
});
test('trimClip left edge clamps start to >=0 on a free (overlay) track', () => {
  const p=newProject(); const a=addAsset(p,{path:'x.mp4',type:'video',naturalW:1,naturalH:1,duration:30});
  const ov=p.tracks[1].id; const c=addClip(p,ov,{assetId:a,start:3,in:10,duration:5});
  trimClip(p,c,'L',-100,{snapCandidates:[],pxPerSec:100}); // drag far past the start of the timeline
  const { clip } = findClip(p,c);
  assert.ok(clip.start >= 0); // overlay track never ripples this back to sanity
  assert.ok(clip.in >= 0);
  assert.ok(clip.duration > 0);
});
test('trimClip right edge caps to source ceiling even when requested duration is below the MIN_DUR floor', () => {
  const p=newProject(); const a=addAsset(p,{path:'x.mp4',type:'video',naturalW:1,naturalH:1,duration:30});
  const m=p.tracks[0].id; const c=addClip(p,m,{assetId:a,start:0,in:29.97,duration:0.03}); // maxDuration = 0.03 < MIN_DUR
  trimClip(p,c,'R', 10, {snapCandidates:[],pxPerSec:100}); // ask for a much longer duration
  const { clip } = findClip(p,c);
  assert.ok(clip.in + clip.duration <= 30 + 1e-9); // source ceiling must win over the MIN_DUR floor
  assert.ok(clip.duration > 0);
});
test('moveClip moves a clip from overlay to main; main ripples gapless afterward', () => {
  const p=newProject(); const a=addAsset(p,{path:'x.mp4',type:'video',naturalW:1,naturalH:1,duration:30});
  const main=p.tracks[0].id; const ov=p.tracks[1].id;
  addClip(p,main,{assetId:a,start:0,in:0,duration:4});
  const c=addClip(p,ov,{assetId:a,start:20,in:0,duration:3});
  moveClip(p,c,main,50,{snapCandidates:[],pxPerSec:100});
  const { clip, track } = findClip(p,c);
  assert.equal(track.kind, 'main');
  assert.equal(clip.start, 4); // gapless-ripple placed it right after the existing main clip
  assert.deepEqual(p.tracks[0].clips.map(cl=>cl.start), [0,4]);
  assert.equal(p.tracks[1].clips.length, 0); // removed from the overlay track
});
test('snapTime snaps within threshold', () => {
  assert.equal(snapTime(2.03,[2,5],100,8), 2); assert.equal(snapTime(2.5,[2,5],100,8), 2.5);
});
test('moveClip on overlay keeps position (no ripple), main ripples', () => {
  const p=newProject(); const a=addAsset(p,{path:'x.mp4',type:'video',naturalW:1,naturalH:1,duration:30});
  const ov=p.tracks[1].id; const c=addClip(p,ov,{assetId:a,start:3,in:0,duration:2});
  moveClip(p,c,ov,7,{snapCandidates:[],pxPerSec:100}); assert.equal(findClip(p,c).clip.start,7);
});
test('deleteClip ripples main', () => {
  const p=mainProj(); const id=p.tracks[0].clips[0].id; deleteClip(p,id);
  assert.deepEqual(p.tracks[0].clips.map(c=>c.start), [0]);
});

// --- zoom-to-fit: dropping a clip in should show the WHOLE clip, not its first
// two seconds. The maths lives in timeline.js so it's testable without a DOM.
test('fitPxPerSec fills the viewport with the content', () => {
  assert.equal(fitPxPerSec(1000, 10, 10, 800), 100);
});
test('fitPxPerSec clamps to the max zoom for very short content', () => {
  assert.equal(fitPxPerSec(1000, 0.5, 10, 800), 800);
});
test('fitPxPerSec clamps to the min zoom for very long content', () => {
  assert.equal(fitPxPerSec(1000, 1000, 10, 800), 10);
});
test('fitPxPerSec falls back to the min zoom for empty content', () => {
  assert.equal(fitPxPerSec(1000, 0, 10, 800), 10);
});
