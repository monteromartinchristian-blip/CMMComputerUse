import test from 'node:test';
import assert from 'node:assert/strict';
import * as r from '../runtime.mjs';
const list=(...ids)=>({byId:Object.fromEntries(ids.map(id=>[id,{id,retainedBy:{mainView:1}}]))});
test('visible selection fails closed for empty, ambiguous and non-conversation panels',()=>{
 assert.equal(typeof r.visibleSessionId,'function');
 assert.equal(r.visibleSessionId(list(),{activePanelId:null}),null);
 assert.equal(r.visibleSessionId(list('a','b'),{activePanelId:null}),null);
 assert.equal(r.visibleSessionId(list('a'),{activePanelId:'plugins'}),null);
 assert.equal(r.visibleSessionId(list('a'),{}),null);
 assert.equal(r.visibleSessionId(list('a'),{activePanelId:null}),'a');
});
test('A to B to A follows mainView only, ignoring recent and background CU sessions',()=>{
 assert.equal(typeof r.visibleSessionId,'function');
 const s=list('a');s.byId.b={id:'b',retainedBy:{computerUse:1},updatedAt:999999};
 assert.equal(r.visibleSessionId(s,{activePanelId:null}),'a');
 s.byId.a.retainedBy={};s.byId.b.retainedBy={mainView:1};
 assert.equal(r.visibleSessionId(s,{activePanelId:null}),'b');
 s.byId.a.retainedBy={mainView:1};s.byId.b.retainedBy={};
 assert.equal(r.visibleSessionId(s,{activePanelId:null}),'a');
});
test('closed viewer is hidden until another CU revision; collapse and Escape keep indicator',()=>{
 const s={...r.initialState(),active:true,revision:2,guiRevision:2,bridge:'compatible',policy:'background',target:{name:'Fixture',bundle:'fixture',background:true},grants:[{bundle:'fixture',scopes:['observe']}]};
 const closed=r.viewTransition(null,'a','close',2);
 assert.equal(r.pipPresentation(s,{sessionId:'a',view:closed}).visible,false);
 assert.equal(r.pipPresentation({...s,revision:3,guiRevision:3},{sessionId:'a',view:closed}).mode,'indicator');
 for(const name of ['collapse','Escape'])assert.equal(r.viewTransition({sessionId:'a',mode:'expanded'},'a',name,2).mode,'indicator');
});
test('frame lease revalidates context before delayed reads and after a late response',{timeout:1000},async()=>{
 let permitted=false,reads=0,resolve;
 const lease=r.frameLease({admit:()=>permitted,read:()=>{reads++;return new Promise(r=>resolve=r)},create:()=>{throw Error('foreign context image created')},revoke(){}});
 const a={attachmentId:'frame',mediaType:'image/png',width:1,height:1,bytes:24};
 const blocked=lease.load(a);assert.equal(reads,0);assert.equal(await blocked,null);
 permitted=true;const p=lease.load(a);permitted=false;
 const png=new Uint8Array(24);png.set([137,80,78,71,13,10,26,10]);png.set([73,72,68,82],12);new DataView(png.buffer).setUint32(16,1);new DataView(png.buffer).setUint32(20,1);resolve(png);
 assert.equal(await p,null);lease.dispose();
});

test('A B A B and independent window selectors never authorize another selection',()=>{
 const a=list('a'),b=list('b');
 for(const [selection,want] of [[a,'a'],[b,'b'],[a,'a'],[b,'b']]) {
  assert.equal(r.visibleSessionId(selection,{activePanelId:null}),want);
  assert.equal(r.visibleSessionId(a,{activePanelId:null}),'a');
 }
});
test('local positioning clamps every edge, including viewport shrink and zoom-sized card',()=>{
 assert.equal(typeof r.overlayPosition,'function');
 assert.deepEqual(r.overlayPosition({x:900,y:800},{width:600,height:400},{width:280,height:180}),{x:304,y:204});
 assert.deepEqual(r.overlayPosition({x:-90,y:-30},{width:600,height:400},{width:280,height:180}),{x:16,y:68});
 assert.deepEqual(r.overlayPosition(null,{width:240,height:180},{width:216,height:88}),{x:16,y:68});
});
