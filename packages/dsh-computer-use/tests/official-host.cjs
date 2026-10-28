/** Contract test against the installed official Host. No Desktop/render claim. */
const assert=require('node:assert/strict');
const path=require('node:path');
const {pathToFileURL}=require('node:url');
const fs=require('node:fs');
const vm=require('node:vm');
(async()=>{
 const root=process.env.CMM_DSH_APP||'/Applications/DeepSeek Harness.app';
 const base=root+'/Contents/Resources/app.asar/dsh/node_modules/@deepseek-ai/';
 const pkg=path.resolve(process.argv[2]);
 const {Context}=await import(base+'cordis/lib/index.js');
 const {SessionProjectionRegistry}=await import(base+'dsh-session-projection/lib/index.js');
 const host=await import(pathToFileURL(pkg+'/index.js').href);
 const {KEY,initialState}=await import(pathToFileURL(pkg+'/runtime.mjs').href);
 const ctx=new Context();new SessionProjectionRegistry(ctx);
 let guard;ctx.provide('tools',{guard(fn){guard=fn;return ()=>{guard=undefined}}});
 host.apply(ctx);
 const events=[];
 const session={header:{},inheritedEventCount:0,seq:0,snapshotEvents:()=>events,eventAt:i=>events[i]};
 assert.equal(ctx.sessionProjections.stateOf(session,KEY).bridge,'disconnected');
 console.log('PASS official registry accepts projection and reads initial state');
 const checkpoint=ctx.sessionProjections.checkpoint(session);
 assert.deepEqual(checkpoint[KEY].val,initialState());
 assert.equal(ctx.sessionProjections.viewCheckpoint(checkpoint)[KEY].bridge,'disconnected');
 console.log('PASS official checkpoint + wire parser');
 assert.throws(()=>host.stateSchema.parse({...initialState(),frame:{attachment:{data:'private'}}}));
 const missingRevision={...initialState()};delete missingRevision.revision;
 assert.throws(()=>host.stateSchema.parse(missingRevision));
 console.log('PASS corrupt checkpoint and missing call revision rejected');
 events.push({seq:0,time:Date.now(),type:'assistant/message',data:{message:{content:[{type:'tool-call',id:'a',name:'mcp__cmm-computer-use__computer_use_press',arguments:'{}'}]}}});
 events.push({seq:1,time:Date.now(),type:'tool/result',data:{message:{source:{callId:'a'},isError:true,content:[{type:'text',text:'attributable: cursor_events_posted=False cursor_moved_by_action=False focus_became_target=True external_activity=False\nSTOP: breach recorded (policy=background). Do not retry this action; report it and let the operator review the ledger.'}]}}});session.seq=2;
 assert.match(guard({name:'mcp__cmm-computer-use__computer_use_press',agent:{session}}),/denied/);
 assert.equal(guard({name:'unrelated',agent:{session}}),undefined);
 console.log('PASS resumed breach denies next CU call; unrelated tool unaffected');
 await ctx.fiber.dispose();
 assert.equal(ctx.sessionProjections?.stateOf(session,KEY),undefined);
 console.log('PASS official registry resources disposed');
 // Validate module registration only. Do not render React or emulate a DOM.
 let loaded;vm.runInNewContext(fs.readFileSync(pkg+'/dist/client.js','utf8'),{window:{__ModuleLoader__:{load:d=>loaded=d}}});
 assert.equal(loaded.id,'@cmm/dsh-computer-use');
 const client=loaded.factory(name=>{assert.equal(name,'react');return {}});
 const disposers=[],locales=new Map();let slot,component;
 const clientCtx={effect:fn=>{const d=fn();disposers.push(d);return d},
 locale:{register(ns,lang,dict){locales.set(lang,dict);return()=>locales.delete(lang)},bind:()=>k=>k},
 slots:{inject(name,fn){assert.equal(name,'shell.overlay');const d=fn();disposers.push(d)},register(opts,view){slot=opts;component=view;return()=>{slot=null;component=null}}}};
 client.apply(clientCtx);assert.equal(slot.name,'shell.overlay');assert.equal(slot.id,'cmm-computer-use-pip');assert.equal(typeof component,'function');assert.equal(locales.size,2);
 for(const d of disposers.reverse())d();assert.equal(slot,null);assert.equal(locales.size,0);
 console.log('PASS Client lazy module, official slot options, locale cleanup (registration unit; no render)');
})().catch(e=>{console.error(e);process.exitCode=1});
