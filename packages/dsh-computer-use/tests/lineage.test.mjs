// DSH-07 — snapshot lineage. Every fixture is the LITERAL shape the shipped
// adapter emits (`_render_status`, `_render_observation`, capture result), taken
// from a real session of `com.example.computer-use-fixture`, so the projection is tested against
// the adapter and not against a hand-written approximation.
//
// The defect these tests close: the helper's `observationGeneration` is a
// PROCESS-WIDE counter bumped by every `observation.describe` of ANY client.
// Requiring equality with the generation of the observation that produced the
// element handles therefore rejected real captures of the very window it had
// just admitted, and the PiP painted a false error over a live mirror.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as r from '../runtime.mjs';
import {stateSchema} from '../index.js';

const PREFIX='mcp__cmm-computer-use__computer_use_';
const APP='com.example.computer-use-fixture';
const WINDOW='Fixture QA';
const WINDOW_ID=18340;
const PID=80606;
let seq=0;

const call=(s,name,args={},time=1000)=>r.fold(s,{type:'assistant/message',seq:++seq,time,
  data:{message:{content:[{type:'tool-call',id:'c'+(++seq),name:PREFIX+name,arguments:JSON.stringify(args)}]}}});
const reply=(s,content,id,isError=false,time=1000)=>r.fold(s,{type:'tool/result',time,seq:++seq,
  data:{message:{source:{callId:id??Object.keys(s.pending).at(-1)},isError,content}}});
const say=(s,body,time=1000)=>reply(s,[{type:'text',text:body}],undefined,false,time);

// ── literal adapter output ────────────────────────────────────────────────
const STATUS=[
  'helper: cmm-computer-use protocol=1 pid=71581',
  'bundle: com.cmm.chat.computer-use',
  'deployment_policy: background (this adapter asks for background)',
  'accessibility: True',
  'screen_recording: True',
  'authorization: *** apps=1 default=deny',
  '- authorized: Fixture QA [com.example.computer-use-fixture] scopes=control,observe windows=0',
  'effective_mode: background (launch=background policy=background)',
].join('\n');
const view=(snapshot)=>({bundle:APP,pid:PID,snapshot,window:WINDOW,window_id:WINDOW_ID});
const OBSERVE=(snapshot)=>[
  'frontmost: Google Chrome [com.google.Chrome]',
  'target: Fixture QA [com.example.computer-use-fixture] (background)',
  'snapshot: '+snapshot+' (pass it back with element actions)',
  'cmm_view: '+JSON.stringify(view(snapshot)),
  'windows on screen (1):',
  '- Fixture QA / "'+WINDOW+'" (1512x898 at 0,33)',
].join('\n');
const CAPTURE=(snapshot)=>'Captured one window (scope=window).\ncmm_view: '+JSON.stringify(view(snapshot));
const attachment={type:'image',attachment:{attachmentId:'sha256:f36ae920722136696ee7bb11028d864a06f52a7a11e970bb43cc2e35e2cb67dc',
  mediaType:'image/webp',bytes:71528,width:1512,height:898}};

const ready=(time=1000)=>say(call(r.initialState(),'status',{},time),STATUS,time);
const observe=(s,target=9,time=1000)=>{
  const next=call(s??ready(time),'observe',{app:APP},time);
  return say(next,OBSERVE(target),time);
};
const PRESS='ui.press: pressed\ninterference: verdict=cursor_moved cursor_moved=True policy=background\nattributable: cursor_events_posted=False cursor_moved_by_action=False focus_became_target=False external_activity=True';
const press=(s,snapshot,time=1000)=>say(call(s,'press',{element_id:9,snapshot},time),PRESS,time);
const capture=(s,snapshot,{time=1000,img=attachment,text=CAPTURE(snapshot)}={})=>
  reply(call(s,'capture_window',{app:APP,window_title:WINDOW},time),[{type:'text',text},img],undefined,false,time);
const model=(s,extra={})=>r.pipPresentation(s,{sessionId:'a',view:{sessionId:'a',mode:'mini'},now:1000,...extra});

// ── the case the bug was reported for ─────────────────────────────────────

test('observe N → action on N → capture N+1 on the same window is admitted',()=>{
  let s=observe(undefined,9);
  assert.equal(s.target.snapshot,9);
  s=press(s,9);
  assert.equal(s.error,null);
  assert.equal(s.ledger.cursor_moved_by_action,false);
  s=capture(s,10);                                   // another client observed in between
  assert.equal(s.error,null);
  assert.equal(s.frame!==null,true);
  assert.equal(s.frame.windowId,WINDOW_ID);
  assert.equal(s.frame.attachment.attachmentId,attachment.attachment.attachmentId);
  assert.equal(s.target.snapshot,9,'the target still names the observation that produced the handles');
  assert.equal(r.pipPhase(s,1000),'frame-live');
  const m=model(s);
  assert.equal(m.phase,'frame-live');
  assert.equal(m.canRead,true);
  assert.equal(m.code,null);
  assert.equal(m.app,'Fixture QA');
  assert.equal(m.window,WINDOW);
  assert.doesNotThrow(()=>stateSchema.parse(JSON.parse(JSON.stringify(s))));
});

test('the admitted frame is the POST-ACTION one, not the previous capture',()=>{
  let s=capture(observe(undefined,9),9);
  const before=s.frame;
  s=press(s,9);
  s=capture(s,10,{img:{type:'image',attachment:{...attachment.attachment,attachmentId:'sha256:post-action'}}});
  assert.equal(s.error,null);
  assert.notEqual(s.frame.attachment.attachmentId,before.attachment.attachmentId);
  assert.equal(s.frame.attachment.attachmentId,'sha256:post-action');
  assert.ok(s.frame.at>=before.at);
});

// ── refusals: a bigger number alone proves nothing ────────────────────────

test('an older generation is stale and keeps failing closed',()=>{
  let s=observe(undefined,10);
  s=press(s,10);
  s=capture(s,9);
  assert.equal(s.frame,null);
  assert.equal(s.error,'snapshot_stale');
  assert.equal(s.attempt.code,'snapshot_stale');
  assert.equal(r.pipPhase(s),'error');
});

test('cross-target with a BIGGER snapshot still fails',()=>{
  const s0=observe(undefined,9);
  for(const other of [
    {...view(99),bundle:'com.cmm.chat.other'},
    {...view(99),pid:99999},
    {...view(99),window:'Fixture QA — otra'},
    {...view(99),window_id:55555},
  ]) {
    const s=capture(s0,99,{text:'Captured one window (scope=window).\ncmm_view: '+JSON.stringify(other)});
    assert.equal(s.frame,null,JSON.stringify(other));
    assert.ok(['UNVERIFIED_CAPTURE','window_changed'].includes(s.error));
  }
});

test('a different app or window in the call fails even with the same identity',()=>{
  const s0=observe(undefined,9);
  for(const args of [{app:'com.cmm.chat.other',window_title:WINDOW},{app:APP,window_title:'Otra ventana'}]) {
    const s=reply(call(s0,'capture_window',args),[{type:'text',text:CAPTURE(10)},attachment]);
    assert.equal(s.frame,null);
    assert.equal(s.error,'UNVERIFIED_CAPTURE');
  }
});

test('an observation that arrives in between still voids the late capture',()=>{
  let s=call(observe(undefined,9),'capture_window',{app:APP,window_title:WINDOW});
  const callId=Object.keys(s.pending).at(-1);
  s=observe(s,10);                                    // newer observation wins the target
  s=reply(s,[{type:'text',text:CAPTURE(9)},attachment],callId);
  // The stale reply is dropped by the revision barrier before it can touch
  // pixels; the newer target survives and no error is painted for it.
  assert.equal(s.frame,null);
  assert.equal(s.target.snapshot,10);
  assert.equal(s.error,null);
  // The rule itself still refuses a capture issued against another target,
  // which is what the barrier protects (proven directly in 07-11).
  assert.equal(r.captureLineage({target:s.target,call:{app:APP,window:WINDOW,target:{...view(9),window:WINDOW}},
    identity:view(9),at:1000,previousAt:1000}),'UNVERIFIED_CAPTURE');
});

test('a capture older than the observation or the action is stale',()=>{
  let s=observe(undefined,9,5000);
  s=press(s,9,6000);
  s=capture(s,10,{time:5500});                        // between observe and action
  assert.equal(s.frame,null);
  assert.equal(s.error,'snapshot_stale');
  let t=observe(undefined,9,5000);
  t=capture(t,10,{time:4000});                        // before the observation itself
  assert.equal(t.frame,null);
  assert.equal(t.error,'snapshot_stale');
});

test('no valid observation keeps the capture fail-closed',()=>{
  const s=capture(ready(),10);
  assert.equal(s.frame,null);
  assert.equal(s.error,'UNVERIFIED_CAPTURE');
  assert.equal(model(s).canRead,false);
});

test('a capture from another session never touches this projection',()=>{
  const s=observe(undefined,9);
  const foreign=r.fold(s,{type:'tool/result',time:1000,seq:++seq,
    data:{message:{source:{callId:'call-from-another-session'},isError:false,
      content:[{type:'text',text:CAPTURE(10)},attachment]}}});
  assert.equal(foreign.frame,null);
  assert.equal(foreign.error,null);
  assert.equal(foreign.target,s.target);
  // Two projections do not share lineage: session B never reads A's frame.
  const b=observe(undefined,12);
  assert.equal(model(foreign,{sessionId:'b'}).canRead,false);
  assert.equal(r.pipPresentation(b,{sessionId:'a',now:1000,view:{sessionId:'a',mode:'mini'}}).canRead,false);
});

// ── mirror race ───────────────────────────────────────────────────────────

test('the mirror keeps the card live while the post-action capture is admitted',()=>{
  let s=observe(undefined,9);
  s=press(s,9);
  s=capture(s,10);
  // The mirror is producing frames at the same time: the label follows the
  // admitted post-action frame, and no error is painted.
  assert.equal(r.displayPhase(r.pipPhase(s,1000),{mirrorLive:true}),'frame-live');
  assert.equal(model(s).tone,'ok');
  // If the admitted frame ages out, the live mirror still labels the pixels
  // instead of claiming that nothing is being shown.
  const aged=r.pipPresentation(s,{sessionId:'a',view:{sessionId:'a',mode:'mini'},now:1000+r.STALE_MS+1});
  assert.equal(aged.phase,'frame-stale');
  assert.equal(r.displayPhase(aged.phase,{mirrorLive:true}),'mirror-live');
  assert.equal(r.displayPhase(aged.phase,{mirrorLive:false}),'frame-stale');
  // And a mirror never turns a real admission failure into "live".
  assert.equal(r.displayPhase('error',{mirrorLive:true}),'error');
});

// ── the pure rule, exhaustively ───────────────────────────────────────────

test('captureLineage classifies every fact independently',()=>{
  const target={name:'Fixture QA',bundle:APP,window:WINDOW,pid:PID,snapshot:9,windowId:WINDOW_ID,observedAt:1000};
  const issued={bundle:APP,pid:PID,snapshot:9,windowId:WINDOW_ID,window:WINDOW};
  const base={target,call:{app:APP,window:WINDOW,target:issued},identity:view(10),at:1100,previousAt:1050};
  assert.equal(r.captureLineage(base),null);
  for(const [patch,want] of [
    [{identity:{...view(10),snapshot:8}},'snapshot_stale'],
    [{identity:{...view(10),pid:1}},'UNVERIFIED_CAPTURE'],
    [{identity:{...view(10),bundle:'other'}},'UNVERIFIED_CAPTURE'],
    [{identity:{...view(10),window:'otra'}},'UNVERIFIED_CAPTURE'],
    [{identity:{...view(10),window_id:1}},'window_changed'],
    [{call:{app:'other',window:WINDOW,target:issued}},'UNVERIFIED_CAPTURE'],
    [{call:{app:APP,window:'otra',target:issued}},'UNVERIFIED_CAPTURE'],
    [{call:{app:APP,window:WINDOW,target:{...issued,snapshot:8}}},'UNVERIFIED_CAPTURE'],
    [{call:{app:APP,window:WINDOW,target:{...issued,windowId:1}}},'UNVERIFIED_CAPTURE'],
    [{at:999},'snapshot_stale'],
    [{at:1049},'snapshot_stale'],
    [{target:null},'UNVERIFIED_CAPTURE'],
    [{identity:null},'UNVERIFIED_CAPTURE'],
  ]) assert.equal(r.captureLineage({...base,...patch}),want,JSON.stringify(patch));
});
