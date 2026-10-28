// PiP UX contract. Every fixture below is the LITERAL text the real
// MCP adapter emits (cmm_computer_use._render_status / _render_observation /
// capture result), so a mismatch between the projection and the shipped adapter
// fails here instead of in the overlay.
import test from 'node:test';
import fs from 'node:fs';
import assert from 'node:assert/strict';
import * as r from '../runtime.mjs';
import {stateSchema} from '../index.js';
import {seat,nodes,text} from './seat.mjs';

const PREFIX='mcp__cmm-computer-use__computer_use_';
const APP='com.example.computer-use-fixture';
const WINDOW='CMM Computer Use Fixture — ensayo';
let seq=0;

const call=(s,name,args={},time=1000)=>r.fold(s,{type:'assistant/message',seq:++seq,time,
  data:{message:{content:[{type:'tool-call',id:String(++seq),name:PREFIX+name,arguments:JSON.stringify(args)}]}}});
const reply=(s,content,id,isError=false,time=1000)=>r.fold(s,{type:'tool/result',time,seq:++seq,
  data:{message:{source:{callId:id??Object.keys(s.pending).at(-1)},isError,content}}});
const say=(s,body,time=1000)=>reply(s,[{type:'text',text:body}],undefined,false,time);

// ── literal adapter output, captured from tools/computer-use ──────────────
const STATUS_OK=[
  'helper: cmm-computer-use protocol=1 pid=69752',
  'bundle: com.cmm.chat.computer-use',
  'deployment_policy: background (this adapter asks for background)',
  'accessibility: True',
  'screen_recording: True',
  'authorization: *** loaded=True apps=1 default=deny',
  '- authorized: CMM Computer Use Fixture [com.example.computer-use-fixture] scopes=observe,control windows=1',
  'effective_mode: background (launch=background policy=background)',
].join('\n');
const STATUS_DENIED=STATUS_OK.replace('accessibility: True','accessibility: False');
const STATUS_NO_CONSENT=STATUS_OK
  .replace('authorization: *** loaded=True apps=1 default=deny','authorization: *** loaded=False apps=0 default=deny');
const STATUS_OLD=[
  'helper: cmm-computer-use protocol=1 pid=69752',
  'bundle: com.cmm.chat.computer-use',
  'deployment_policy: None (this adapter asks for background)',
  'accessibility: True',
  'screen_recording: True',
].join('\n');
const STATUS_PROTOCOL_2=STATUS_OK.replace('protocol=1','protocol=2');
const view={bundle:APP,pid:69640,snapshot:7,window:WINDOW,window_id:13063};
const OBSERVE=[
  'frontmost: DeepSeek Harness [com.deepseek.dsh]',
  'target: CMM Computer Use Fixture [com.example.computer-use-fixture] (background)',
  'snapshot: 7 (pass it back with element actions)',
  'cmm_view: '+JSON.stringify(view).replace('—','\\u2014'),
  'windows on screen (1):',
  '- CMM Computer Use Fixture / "'+WINDOW+'" (900x620 at 120,140)',
  'readable content (1, read-only):',
  '- AXStaticText "contador 3"',
].join('\n');
const CAPTURE='Captured one window (scope=window).\ncmm_view: '+JSON.stringify(view).replace('—','\\u2014');
const attachment={type:'image',attachment:{attachmentId:'att-7',mediaType:'image/png',bytes:24,width:1440,height:992}};

const ready=(body=STATUS_OK,time=1000)=>{const s=call(r.initialState(),'status',{},time);return say(s,body,time);};
const observed=(s,time=1000)=>say(call(s??ready(STATUS_OK,time),'observe',{app:APP},time),OBSERVE,time);
const captured=(s,time=1000)=>reply(call(s??observed(undefined,time),'capture_window',{app:APP,window_title:WINDOW},time),
  [{type:'text',text:CAPTURE},attachment],undefined,false,time);
const live=()=>captured(undefined,Date.now());
const model=(s,extra={})=>r.pipPresentation(s,{sessionId:'a',now:5000,...extra});
// A GUI attempt is what makes an error surface: status alone never does.
const deniedSurface=()=>say(call(observed(),'status'),STATUS_DENIED);
const oldSurface=()=>say(call(observed(),'status'),STATUS_OLD);

// ── projection / classification ───────────────────────────────────────────

test('the real adapter status is compatible, never "old or incompatible"',()=>{
  const s=ready();
  assert.equal(s.bridge,'compatible');
  assert.equal(s.policy,'background');
  assert.equal(s.grants.length,1);
  assert.equal(s.grants[0].bundle,APP);
  assert.equal(s.helper.protocol,1);
  assert.equal(s.helper.pid,69752);
  assert.equal(s.helper.loaded,true);
  assert.equal(s.helper.apps,1);
  assert.equal(s.helper.effectiveMode,'background');
});

test('status + observe with no frame is "waiting", not error/unknown/incompatible',()=>{
  const s=observed();
  assert.equal(s.error,null);
  assert.equal(s.target.window,WINDOW);
  const m=model(s);
  assert.equal(m.visible,true);
  assert.equal(m.phase,'observed-no-frame');
  assert.equal(m.status,'waiting');
  assert.equal(m.tone,'wait');
  assert.equal(m.canRead,false);
  for(const bad of ['error','unknown','incompatible','denied']) assert.notEqual(m.status,bad);
});

test('a verified capture is frame-live and exposes app and window',()=>{
  const m=model(captured(),{view:{sessionId:'a',mode:'mini'}});
  assert.equal(m.phase,'frame-live');
  assert.equal(m.status,'live');
  assert.equal(m.tone,'ok');
  assert.equal(m.canRead,true);
  assert.equal(m.app,'CMM Computer Use Fixture');
  assert.equal(m.window,WINDOW);
  assert.equal(m.ageMs,4000);
});

test('a frame older than the stale threshold keeps the image and says paused',()=>{
  const s=captured();
  const stale=r.pipPresentation(s,{sessionId:'a',view:{sessionId:'a',mode:'mini'},now:5000+r.STALE_MS+1000});
  assert.equal(stale.phase,'frame-stale');
  assert.equal(stale.status,'paused');
  assert.equal(stale.canRead,true);
  assert.equal(stale.ageMs>=r.STALE_MS,true);
  const expired=r.pipPresentation(s,{sessionId:'a',now:5000+r.RETENTION_MS+1});
  assert.equal(expired.phase,'expired');
  assert.equal(expired.canRead,false);
});

test('a real permission failure is a short "denied" state',()=>{
  const s=ready(STATUS_DENIED);
  assert.equal(s.bridge,'denied');
  const m=model(s);
  assert.equal(m.phase,'denied');
  assert.equal(m.status,'denied');
  assert.equal(m.tone,'error');
  assert.equal(m.canRead,false);
  assert.equal(m.technical.accessibility,'False');
});

test('unloaded authorization is denied, not incompatible',()=>{
  assert.equal(ready(STATUS_NO_CONSENT).bridge,'denied');
});

test('incompatible requires proof, never a missing frame',()=>{
  assert.equal(ready(STATUS_OLD).bridge,'incompatible');
  assert.equal(ready(STATUS_PROTOCOL_2).bridge,'incompatible');
  assert.equal(model(ready(STATUS_OLD)).phase,'incompatible');
  assert.equal(model(ready(STATUS_PROTOCOL_2)).phase,'incompatible');
  // The same session, before any capture, is waiting — not incompatible.
  assert.equal(model(observed()).phase,'observed-no-frame');
});

test('target and window changes invalidate the previous frame immediately',()=>{
  const fresh=captured();
  assert.equal(fresh.frame!==null,true);
  const reobserved=call(fresh,'observe',{app:APP});
  assert.equal(reobserved.frame,null);
  const changed=reply(call(fresh,'capture_window',{app:APP,window_title:WINDOW}),
    [{type:'text',text:CAPTURE.replace('13063','99999')},attachment]);
  assert.equal(changed.frame,null);
  assert.equal(changed.error,'window_changed');
  assert.equal(model(changed).phase,'error');
});

test('another session never reads this frame',()=>{
  const s=captured();
  for(const extra of [{sessionId:'b'},{sessionId:'a',view:{sessionId:'b',mode:'mini'}},
    {sessionId:'a',view:{sessionId:'a',mode:'indicator'}}]) {
    const m=r.pipPresentation(s,{now:5000,...extra});
    assert.equal(m.canRead,false);
  }
});

test('close hides the view and new GUI activity reopens it',()=>{
  let s=observed();
  const closed=r.viewTransition(null,'a','close',r.activityRevision(s));
  assert.equal(r.pipPresentation(s,{sessionId:'a',view:closed,now:5000}).visible,false);
  s=observed(s);
  assert.equal(r.pipPresentation(s,{sessionId:'a',view:closed,now:5000}).visible,true);
  assert.equal(r.pipPresentation(s,{sessionId:'a',view:closed,now:5000}).mode,'indicator');
});

test('a bare status call never creates a surface',()=>{
  for(const s of [ready(),ready(STATUS_OLD),ready(STATUS_DENIED)]) {
    assert.equal(r.pipPresentation(s,{sessionId:'a',view:null,now:5000}).visible,false);
  }
});

// ── component (descriptor) contract ──────────────────────────────────────

const stateFor=(s)=>s;
const strip=(tree)=>JSON.stringify(tree);

test('compact PiP is one 32px header line: dot, app name, three icon controls',()=>{
  const s=seat(stateFor(live()));
  const tree=s.draw({sessionId:'a',mode:'mini'});
  const heads=nodes(tree,'header');
  assert.equal(heads.length,1);
  const buttons=nodes(heads[0],'button');
  assert.deepEqual(buttons.map(b=>b.props['aria-label']),['expand','collapse','closeView']);
  const dot=nodes(heads[0],'span').find(x=>x.props.className==='cmm-cu-dot');
  assert.equal(dot.props['data-tone'],'ok');
  assert.equal(dot.props['aria-hidden'],true);
  assert.equal(text(heads[0]).includes('CMM Computer Use Fixture'),true);
  for(const bad of ['pid','Unknown','helper','policy','scopes','bundle'])
    assert.equal(JSON.stringify(heads[0]).includes(bad),false,'header leaked '+bad);
});

test('waiting state renders "Esperando primera captura…" and the window, never jargon',()=>{
  const s=seat(observed(undefined,Date.now()));
  const tree=s.draw({sessionId:'a',mode:'mini'});
  const body=text(tree);
  assert.equal(body.includes('waiting'),true);
  assert.equal(body.includes(WINDOW),true);
  for(const bad of ['error','unknown','incompatible','none','showTest'])
    assert.equal(body.includes(bad),false,'waiting state leaked '+bad);
  // before the first admitted capture the card may already paint the live
  // mirror of the authorized window, but the phase still must not claim a frame
  // and nothing but that mirror may be drawn (never a test/demo or old image).
  assert.equal(tree.props['data-phase'],'observed-no-frame');
  assert.equal(nodes(tree,'img').filter(i=>!String(i.props.src).startsWith('http://127.0.0.1:47183/stream.mjpg?')).length,0);
});

test('technical details stay closed by default and Esc closes them, not the PiP',()=>{
  const s=seat(deniedSurface());
  const mini={sessionId:'a',mode:'mini'};
  let tree=s.draw(mini);
  assert.equal(nodes(tree,'dl').length,0);
  const open=nodes(tree,'button').find(b=>b.props['aria-label']==='details');
  assert.ok(open,'the short error state offers a Details control');
  open.props.onClick();
  tree=s.draw(mini);
  assert.equal(nodes(tree,'dl').length,1);
  assert.equal(text(tree).includes('authorization'),true);
  let stopped=false;
  tree.props.onKeyDown({key:'Escape',preventDefault(){},stopPropagation(){stopped=true}});
  tree=s.draw(mini);
  assert.equal(nodes(tree,'dl').length,0);
  assert.equal(stopped,true);
  assert.equal(s.getView(),undefined,'Esc on details must not collapse the view');
  tree.props.onKeyDown({key:'Escape',preventDefault(){},stopPropagation(){}});
  assert.equal(s.getView().mode,'indicator');
});

test('the normal build has no test image and no demo control anywhere',()=>{
  const s=seat(live());
  let tree=s.draw({sessionId:'a',mode:'mini'});
  const open=nodes(tree,'button').find(b=>b.props['aria-label']==='details');
  assert.equal(open,undefined,'no Details control in a healthy live view');
  assert.equal(strip(tree).includes('data:image/png'),false);
  tree.props.onKeyDown({key:'Escape',preventDefault(){},stopPropagation(){}});
});

test('the published client carries no test-image mechanism at all',()=>{
  // A public release has no rehearsal image, no demo control and no marker for
  // one: the shipped client is the rendered file, and the only image it can
  // ever draw is the admitted attachment or the live mirror.
  const template=fs.readFileSync(new URL('../client.template.js',import.meta.url),'utf8');
  assert.equal(template.includes('__CMM_TEST_IMAGE__'),false,'template carries no test-image marker');
  const dist=fs.readFileSync(new URL('../dist/client.js',import.meta.url),'utf8');
  assert.equal(dist.includes('__CMM_TEST_IMAGE__'),false,'rendered client carries no test-image marker');
  assert.equal(dist.includes('data:image/png;base64,demo'),false);
  const s=seat(live());
  const mini={sessionId:'a',mode:'mini'};
  let tree=s.draw(mini);
  assert.equal(nodes(tree,'img').filter(i=>String(i.props.src).startsWith('data:')).length,0);
  const demo=nodes(tree,'button').find(b=>/demo/i.test(String(b.props['aria-label'])));
  assert.equal(demo,undefined,'no demo control exists in any state');
});

test('compact, expanded and collapsed keep the same phase and state',()=>{
  const s=live();
  const base=model(s);
  for(const view of [null,{sessionId:'a',mode:'mini'},{sessionId:'a',mode:'expanded'}]) {
    const m=r.pipPresentation(s,{sessionId:'a',view,now:Date.now()});
    assert.equal(m.phase,base.phase);
    assert.equal(m.status,base.status);
    if(view)assert.equal(m.canRead,true);
  }
  const seatMini=seat(s);
  const mini=seatMini.draw({sessionId:'a',mode:'mini'});
  const expanded=seatMini.draw({sessionId:'a',mode:'expanded'});
  assert.equal(text(mini).includes('CMM Computer Use Fixture'),true);
  assert.equal(text(expanded).includes('CMM Computer Use Fixture'),true);
  assert.equal(nodes(expanded,'header').length,1);
  const shrunk=nodes(expanded,'button').find(b=>b.props['aria-label']==='shrink');
  assert.ok(shrunk,'expanded exposes shrink');
  assert.equal(text(expanded).includes('updated'),true,'expanded carries the one-line footer');
  const pill=seatMini.draw({sessionId:'a',mode:'indicator'});
  assert.equal(nodes(pill,'button').length,1);
  assert.equal(nodes(pill,'header').length,0);
  assert.equal(text(pill).includes('CMM Computer Use Fixture'),true);
  // A pill schedules nothing: only an open view arms the stale/expiry reminders.
  seatMini.runEffects();
  assert.equal(seatMini.timers.length,0,'the collapsed pill must not schedule timers');
  seatMini.draw({sessionId:'a',mode:'mini'});
  seatMini.runEffects();
  assert.equal(seatMini.timers.length,2,'the open view arms stale and expiry');
});

test('every control is named, focusable and state is not conveyed by colour alone',()=>{
  for(const state of [captured(),observed(),deniedSurface(),oldSurface()]) {
    const s=seat(state);
    for(const mode of ['indicator','mini','expanded']) {
      const tree=s.draw({sessionId:'a',mode});
      for(const button of nodes(tree,'button')) {
        assert.ok(button.props['aria-label'],'unnamed control');
        assert.equal(button.props.type,'button');
      }
      const statuses=nodes(tree,'span').filter(x=>x.props.role==='status');
      assert.equal(statuses.length>=1,true,'state must be announced in text');
      assert.ok(text(statuses[0]).length>0);
    }
  }
});

test('opening focuses the internal header, Escape returns focus to the pill',()=>{
  const s=seat(live());
  let tree=s.draw(null);
  nodes(tree,'button')[0].props.onClick();
  tree=s.draw(s.getView());
  const head=nodes(tree,'header')[0];
  assert.ok(head.props.ref,'the header must be a focus destination');
  assert.equal(head.props.tabIndex,0);
  let focused=0;
  head.props.ref.current={focus:opts=>{assert.equal(opts.preventScroll,true);focused++;}};
  s.runEffects();
  assert.equal(focused,1);
  tree.props.onKeyDown({key:'Escape',preventDefault(){},stopPropagation(){}});
  tree=s.draw(s.getView());
  const pill=nodes(tree,'button')[0];
  let returned=0;
  pill.props.ref.current={focus:()=>returned++};
  s.runEffects();
  assert.equal(returned,1);
});

test('the PiP never covers the composer region: gutter and top margin are pinned',()=>{
  const frame={width:1200,height:900},card={width:320,height:232};
  assert.deepEqual(r.overlayPosition(null,frame,card),{x:1200-320-16,y:68});
  assert.deepEqual(r.overlayPosition({x:-999,y:-999},frame,card),{x:16,y:68});
  assert.deepEqual(r.overlayPosition({x:5000,y:5000},frame,card),{x:1200-320-16,y:900-232-16});
});

test('every projected state survives the checkpoint schema',()=>{
  for(const s of [r.initialState(),ready(),observed(),captured(),ready(STATUS_DENIED),ready(STATUS_OLD),deniedSurface(),oldSurface()])
    assert.doesNotThrow(()=>stateSchema.parse(JSON.parse(JSON.stringify(s))));
  assert.throws(()=>stateSchema.parse({...r.initialState(),attemptRevision:99}));
  assert.throws(()=>stateSchema.parse({...r.initialState(),helper:{secret:'x'}}));
  assert.throws(()=>stateSchema.parse({...r.initialState(),attempt:{name:'observe',at:1,failed:false,code:null},attemptRevision:1}));
});

test('a re-render with fresh session handles does not re-arm decoding',()=>{
  const s=seat(live());
  s.draw({sessionId:'a',mode:'mini'});
  s.runEffects();
  assert.equal(s.timers.length,2,'the open view arms stale and expiry once');
  const writes=s.writes;
  s.draw({sessionId:'a',mode:'mini'});
  s.runEffects();
  assert.equal(s.timers.length,2,'an unchanged frame must not re-arm or re-read');
  assert.equal(s.writes,writes,'an unchanged frame must not write state again');
});

test('the mirror claims live only while the streamer reports current frames',()=>{
  // A multipart <img> keeps its last picture when the stream stalls, so the
  // freshness signal has to come from the streamer's own counters.
  assert.equal(r.mirrorFreshness(null,1000),false);
  assert.equal(r.mirrorFreshness({frames:0,lastFrameAt:0},1000),false);
  assert.equal(r.mirrorFreshness({frames:4,lastFrameAt:0},1000),false);
  assert.equal(r.mirrorFreshness({frames:4,lastFrameAt:900},1000),true);
  assert.equal(r.mirrorFreshness({frames:4,lastFrameAt:1000-r.MIRROR_STALE_MS-1},1000),false);
  const s=seat(observed());
  const tree=s.draw({sessionId:'a',mode:'mini'});
  s.runEffects();
  // One bounded status poll while the card is open, none for the pill.
  assert.equal(s.intervals.length,1,'open card polls the stream status once');
  const pill=seat(observed());
  pill.draw({sessionId:'a',mode:'indicator'});
  pill.runEffects();
  assert.equal(pill.intervals.length,0,'the collapsed pill polls nothing');
  // Before the streamer reports a frame the card stays "waiting", never live.
  assert.equal(tree.props['data-phase'],'observed-no-frame');
});

test('a frontmost target is a fail-closed error, never idle',()=>{
  const frontmost=say(call(ready(),'observe',{app:APP}),
    'target: CMM Computer Use Fixture [com.example.computer-use-fixture] (frontmost)\ncmm_view: '+JSON.stringify(view));
  assert.equal(frontmost.error,'TARGET_NOT_BACKGROUND');
  assert.equal(frontmost.target,null);
  const m=r.pipPresentation(frontmost,{sessionId:'a',now:1000});
  assert.equal(m.phase,'error');
  assert.equal(m.canRead,false);
  assert.equal(m.app,null);
  assert.equal(m.window,null);
});

test('the stale badge is rendered over the kept frame',()=>{
  const s=seat(captured(undefined,Date.now()-15000));
  const tree=s.draw({sessionId:'a',mode:'mini'});
  assert.equal(text(tree).includes('pausedBadge'),true,'stale frame must say "View paused"');
  assert.equal(text(tree).includes('Esperando'),false);
});
