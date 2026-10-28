import test from 'node:test';
import assert from 'node:assert/strict';
import * as r from '../runtime.mjs';
let seq=0;
const app='com.example.computer-use-fixture';
const identity={bundle:app,pid:123,snapshot:3,window:'Fixture',window_id:42};
const invoke=(s,name,args={})=>r.fold(s,{type:'assistant/message',data:{message:{content:[{type:'tool-call',id:String(++seq),name:'mcp__cmm-computer-use__computer_use_'+name,arguments:JSON.stringify(args)}]}}});
const reply=(s,text,extra=[],id=Object.keys(s.pending).at(-1),isError=false)=>r.fold(s,{type:'tool/result',time:1000,seq:++seq,data:{message:{source:{callId:id},isError,content:[{type:'text',text},...extra]}}});
const ready=()=>reply(invoke(r.initialState(),'status'),'deployment_policy: background \nauthorization: loaded=True apps=1 default=deny\n- authorized: Fixture [com.example.computer-use-fixture] scopes=control,observe windows=1\neffective_mode: background ');
const observe=(s=ready(),i=identity)=>reply(invoke(s,'observe',{app}),'target: Fixture [com.example.computer-use-fixture] (background)\ncmm_view: '+JSON.stringify(i));
const attachment={type:'image',attachment:{attachmentId:'frame',mediaType:'image/png',width:1,height:1,bytes:24}};
const frame=(s=observe(),i=identity)=>reply(invoke(s,'capture_window',{app,window_title:'Fixture'}),'Captured one window (scope=window).\ncmm_view: '+JSON.stringify(i),[attachment]);
test('idle session contributes no visible UI or reads',()=>{assert.equal(typeof r.pipPresentation,'function');const idle=r.pipPresentation(r.initialState(),{sessionId:'a',view:null,now:1000});
assert.equal(idle.visible,false);assert.equal(idle.status,'idle');assert.equal(idle.mode,'indicator');assert.equal(idle.canRead,false);});
test('view actions only change session-local size; close leaves real task active',()=>{assert.equal(typeof r.viewTransition,'function');let v=r.viewTransition(null,'a','open');assert.deepEqual(v,{sessionId:'a',mode:'mini'});v=r.viewTransition(v,'a','expand');assert.equal(v.mode,'expanded');assert.equal(r.viewTransition(v,'b','expand').mode,'indicator');assert.equal(r.viewTransition(v,'a','close').mode,'closed');const s=observe();assert.equal(r.pipPresentation(s,{sessionId:'a',view:v,now:1000}).status,'waiting');});
// DSH-07: a NEWER generation of the same window/bundle/pid/session is the same
// causal line (the helper's counter is process-wide), while an OLDER one is
// stale and any identity mismatch still fails. The product assertion — a frame
// binds pid, bundle, full window and window id — is unchanged.
test('frames bind PID, snapshot, full window and tool call',()=>{const s=frame();assert.equal(s.target.pid,123);assert.equal(s.target.snapshot,3);assert.equal(s.frame.windowId,42);assert.equal(s.frame.callId,String(seq-1));
const newer=frame(observe(),{...identity,snapshot:4});
assert.equal(newer.error,null);assert.equal(newer.frame.windowId,42);assert.equal(newer.target.snapshot,3);
const stale=frame(observe(),{...identity,snapshot:2});
assert.equal(stale.frame,null);assert.equal(stale.error,'snapshot_stale');
for(const i of [{...identity,pid:124},{...identity,window:'Fixture 2'},{...identity,bundle:'other'},{...identity,window_id:99}])assert.equal(frame(observe(),i).frame,null);});
test('legacy result never supplies a PiP image without helper identity',()=>{const s=reply(invoke(observe(),'capture_window',{app,window_title:'Fixture'}),'Captured one window (scope=window).',[attachment]);assert.equal(s.frame,null);assert.equal(s.error,'UNVERIFIED_CAPTURE');});
test('replacement window ID invalidates instead of retaining old pixels',()=>{let s=frame();s=frame(s,{...identity,window_id:99});assert.equal(s.frame,null);assert.equal(s.error,'window_changed');});
test('pending observation and interaction immediately invalidate old preview',()=>{for(const name of ['observe','press','set_value'])assert.equal(invoke(frame(),name,{app,snapshot:3}).frame,null);});
test('late capture cannot attach to newer observation of same target',()=>{let s=invoke(observe(),'capture_window',{app,window_title:'Fixture'});const id=Object.keys(s.pending).at(-1);s=observe(s,{...identity,snapshot:4});s=reply(s,'Captured one window (scope=window).\ncmm_view: '+JSON.stringify(identity),[attachment],id);assert.equal(s.frame,null);});
test('turn end retains authorized frame as previous and rejects late results',()=>{const before=frame();const s=r.fold(before,{type:'turn/end'});assert.equal(s.target,before.target);assert.equal(s.frame,before.frame);assert.deepEqual(s.pending,{});const model=r.pipPresentation(s,{sessionId:'a',view:{sessionId:'a',mode:'mini'},now:1000});assert.equal(model.visible,true);assert.equal(model.status,'live');assert.equal(model.canRead,true);assert.equal(r.fold(r.initialState(),{type:'turn/end'}).lastAt,0);});
test('indicator and expired frame never read; visible mini reads only its session',()=>{const s=frame();for(const [view,now,want] of [[null,1000,false],[{sessionId:'b',mode:'mini'},1000,false],[{sessionId:'a',mode:'mini'},1000,true],[{sessionId:'a',mode:'expanded'},62000,false]])assert.equal(r.pipPresentation(s,{sessionId:'a',view,now}).canRead,want);});
test('reason-specific refusals clear identity and pixels without leaking raw data',()=>{for(const reason of ['app_not_granted','window_changed','pid_changed','expired','global_input_not_scoped','breach']){const s=reply(invoke(frame(),'press',{snapshot:3}),'REFUSED ACTION_FAILED: private\npolicy: policy=background;reason='+reason,[],undefined,true);assert.equal(s.frame,null);assert.equal(s.target,null);assert.equal(s.error,reason);assert.ok(!JSON.stringify(s).includes('private'));}});
test('status-only, pending unverified observation, legacy helper and refusal stay invisible',()=>{
 for(const s of [invoke(r.initialState(),'status'),ready(),invoke(ready(),'observe',{app}),reply(invoke(ready(),'status'),'helper: old'),reply(invoke(ready(),'status'),'REFUSED COMPUTER_PERMISSION_DENIED',[],undefined,true)]) {
  const model=r.pipPresentation(s,{sessionId:'a',view:null,now:1000});assert.equal(model.visible,false);assert.equal(model.canRead,false);
 }
});
test('newer observation wins when replies arrive in reverse order',()=>{let s=invoke(observe(),'observe',{app});const old=Object.keys(s.pending).at(-1);s=observe(s,{...identity,snapshot:4});s=reply(s,'target: Fixture [com.example.computer-use-fixture] (background)\ncmm_view: '+JSON.stringify(identity),[],old);assert.equal(s.target.snapshot,4);});
test('newer capture wins when replies arrive in reverse order',()=>{let s=invoke(observe(),'capture_window',{app,window_title:'Fixture'});const old=Object.keys(s.pending).at(-1);s=frame(s);s=reply(s,'Captured one window (scope=window).\ncmm_view: '+JSON.stringify(identity),[{...attachment,attachment:{...attachment.attachment,attachmentId:'old'}}],old);assert.equal(s.frame.attachment.attachmentId,'frame');});
test('adapter bracketed refusal keeps exact reason code',()=>{const s=reply(invoke(observe(),'press',{snapshot:3}),'REFUSED CAPABILITY_UNSUPPORTED: denied [policy=background;reason=global_input_not_scoped]',[],undefined,true);assert.equal(s.error,'global_input_not_scoped');});
test('late policy revocation invalidates newer in-flight capture authority',()=>{
 let s=invoke(observe(),'status');const statusId=Object.keys(s.pending).at(-1);
 s=invoke(s,'capture_window',{app,window_title:'Fixture'});const captureId=Object.keys(s.pending).at(-1);
 s=reply(s,'deployment_policy: background \nauthorization: loaded=False apps=0 default=deny\neffective_mode: background ',[],statusId);
 assert.equal(s.bridge,'denied');assert.equal(s.target,null);assert.deepEqual(s.grants,[]);
 s=reply(s,'Captured one window (scope=window).\ncmm_view: '+JSON.stringify(identity),[attachment],captureId);
 assert.equal(s.frame,null);assert.equal(r.pipPresentation(s,{sessionId:'a',view:{sessionId:'a',mode:'mini'},now:1000}).canRead,false);
});
test('late old-helper status cannot leave authorized pixels readable',()=>{
 let s=invoke(observe(),'status');const statusId=Object.keys(s.pending).at(-1);
 s=frame(s);s=reply(s,'helper: old',[],statusId);
 assert.equal(s.bridge,'incompatible');assert.equal(s.target,null);assert.equal(s.frame,null);
});
test('failed status invalidates authority of observations already pending',()=>{
 for(const code of ['TIMEOUT','APPROVAL_REJECTED','COMPUTER_PERMISSION_DENIED']){
  let s=invoke(observe(),'status');const id=Object.keys(s.pending).at(-1);
  s=invoke(s,'observe',{app});const observationId=Object.keys(s.pending).at(-1);
  s=reply(s,'REFUSED '+code+': hidden',[],id,true);
  assert.deepEqual(s.grants,[]);assert.deepEqual(s.pending,{});
  s=reply(s,'target: Fixture [com.example.computer-use-fixture] (background)\ncmm_view: '+JSON.stringify(identity),[],observationId);
  assert.equal(s.target,null);assert.equal(s.frame,null);
 }
});
test('completed turn retains indicator but historical frame still expires',()=>{
 const s=r.fold(frame(),{type:'turn/end'});
 const model=r.pipPresentation(s,{sessionId:'a',view:{sessionId:'a',mode:'mini'},now:121000});
 assert.equal(model.visible,true);assert.equal(model.status,'waiting');assert.equal(model.canRead,false);
 assert.equal(model.phase,'expired');
 assert.equal(r.frameLabel(s.frame,121000,true),'none');
 assert.equal(r.pipPresentation(invoke(s,'observe',{app}),{sessionId:'a',view:{sessionId:'a',mode:'mini'},now:121000}).canRead,false);
});

test('verified GUI work alone earns a collapsed named indicator, never LIVE without frame',()=>{
 const s=observe();const model=r.pipPresentation(s,{sessionId:'a',now:1000});
 assert.equal(model.visible,true);assert.equal(model.mode,'indicator');assert.equal(model.canRead,false);
 assert.equal(s.target.name,'Fixture');assert.notEqual(model.status,'real');
 // A GUI attempt may surface a short error card, but never a name or pixels.
 for(const invalid of [reply(invoke(ready(),'observe',{app}),'target: Fixture [com.example.computer-use-fixture] (background)'),observe(ready(),{...identity,pid:0}),reply(invoke(ready(),'observe',{app}),'target: Fixture [com.example.computer-use-fixture] (frontmost)\ncmm_view: '+JSON.stringify(identity))]) {
  const m=r.pipPresentation(invalid,{sessionId:'a'});
  assert.equal(m.canRead,false);assert.equal(m.app,null);assert.equal(m.window,null);assert.equal(m.phase,'error');
 }
});
test('closing hides until next authorized GUI task; status and refused tasks cannot reopen',()=>{
 let s=observe();const closed=r.viewTransition(null,'a','close',s.guiRevision);
 assert.equal(r.pipPresentation(s,{sessionId:'a',view:closed}).visible,false);
 s=reply(invoke(s,'status'),'helper: old');
 assert.equal(r.pipPresentation(s,{sessionId:'a',view:closed}).visible,false);
 s=observe(ready());
 const v=r.viewTransition(null,'a','close',s.guiRevision);
 s=observe(s);assert.equal(r.pipPresentation(s,{sessionId:'a',view:v}).visible,true);
 assert.equal(r.pipPresentation(s,{sessionId:'a',view:v}).mode,'indicator');
 const collapsed=r.viewTransition(null,'a','collapse',s.guiRevision);
 assert.equal(r.pipPresentation(s,{sessionId:'a',view:collapsed}).visible,true);
});
test('viewer controls do not mutate authority, task, pixels or invoke tool code',()=>{
 const s=frame(),before=JSON.stringify(s);let v;
 for(const name of ['open','expand','shrink','collapse','Escape','close']) v=r.viewTransition(v,'a',name,s.guiRevision);
 assert.equal(JSON.stringify(s),before);assert.equal(v.mode,'closed');
});
test('revocation, release and changed identity cannot retain a visible unauthorized name',()=>{
 // Release leaves no surface; revocation and a changed window may show a short
 // error card, but never the previous name, window or pixels.
 const released=reply(invoke(frame(),'release'),'released');
 assert.equal(r.pipPresentation(released,{sessionId:'a',view:{sessionId:'a',mode:'mini'},now:1000}).visible,false);
 for(const [s,phase] of [[reply(invoke(frame(),'status'),'helper: old'),'incompatible'],[frame(observe(),{...identity,window_id:99}),'error']]) {
  const model=r.pipPresentation(s,{sessionId:'a',view:{sessionId:'a',mode:'mini'},now:1000});
  assert.equal(model.canRead,false);assert.equal(model.app,null);assert.equal(model.window,null);assert.equal(model.phase,phase);
 }
});

test('a live mirror is never labelled as waiting, and never admits itself',()=>{
  const s=observe();                                  // authorized target, no admitted frame
  assert.equal(r.pipPhase(s),'observed-no-frame');     // admitted truth unchanged
  assert.equal(r.displayPhase('observed-no-frame',{mirrorLive:true}),'mirror-live');
  assert.equal(r.displayPhase('observed-no-frame',{mirrorLive:false}),'observed-no-frame');
  assert.equal(r.displayPhase('frame-live',{mirrorLive:true}),'frame-live');
  assert.equal(r.displayPhase('expired',{mirrorLive:true}),'mirror-live');
  assert.equal(r.displayPhase('error',{mirrorLive:true}),'error');
  const model=r.pipPresentation(s,{sessionId:'a',view:{sessionId:'a',mode:'mini'},now:1000});
  assert.equal(model.status,'waiting');
  assert.equal(model.canRead,false);                   // the mirror grants no attachment
});
