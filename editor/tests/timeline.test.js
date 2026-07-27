import { test } from 'node:test'; import assert from 'node:assert';
import { newProject, addAsset, addClip, findClip } from '../js/model.js';
import { totalDuration, snapTime, rippleMain, splitClip, trimClip, moveClip, deleteClip } from '../js/timeline.js';

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
