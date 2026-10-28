// Shared descriptor-level harness for the PiP client component. No DOM, no
// pixels, no real React: it only proves which elements the component asks for
// and which view transitions its own controls request.
import fs from 'node:fs';
import vm from 'node:vm';

export function seat(state) {
  let definition, entry, slots=[], cursor=0, effects=[], effectCursor=0, effectSlots=[], writes=0;
  let current=state;
  const react={
    createElement:(type,props,...children)=>({type,props:props||{},children}),
    useState:init=>{
      const n=cursor++;
      if(!(n in slots)) slots[n]=typeof init==='function'?init():init;
      return [slots[n],v=>{slots[n]=typeof v==='function'?v(slots[n]):v}];
    },
    useRef:init=>{const n=cursor++;return slots[n]??=({current:init});},
    useCallback:fn=>fn,
    // Per-call-order deps, like React: re-register only when a dep changed.
    useEffect:(fn,deps)=>{
      const n=effectCursor++;
      const same=effectSlots[n]&&Array.isArray(deps)&&Array.isArray(effectSlots[n].deps)
        &&deps.length===effectSlots[n].deps.length&&deps.every((v,i)=>Object.is(v,effectSlots[n].deps[i]));
      if(!same){effectSlots[n]={deps,fn};effects.push(fn);}
    },
    useLayoutEffect:()=>{},
    useSyncExternalStore:(_subscribe,get)=>get()
  };
  let source=fs.readFileSync(new URL('../client.template.js',import.meta.url),'utf8')
    .replace('/*__CMM_RUNTIME__*/',fs.readFileSync(new URL('../runtime.mjs',import.meta.url),'utf8').replace(/\bexport (?=(?:const|function) )/g,''))
    .replace('/*__CMM_LOCALES__*/',JSON.stringify(Object.fromEntries(['en','es'].map(lang=>[lang,JSON.parse(fs.readFileSync(new URL('../locale/'+lang+'.json',import.meta.url))).panel]))));
  const timers=[];
  // The mirror's status probe is an interval, not a one-shot: record it apart
  // from the stale/expiry timers so a test can assert the bounded polling.
  const intervals=[];
  const liveFeed={current:{ok:true,frames:0,lastFrameAt:0,viewers:0,mode:'idle'}};
  vm.runInNewContext(source,{window:{__ModuleLoader__:{load:d=>definition=d}},Date,Map,Uint8Array,
    setTimeout:(fn,ms)=>{timers.push({fn,ms});return timers.length},clearTimeout(){},
    setInterval:(fn,ms)=>{intervals.push({fn,ms});return intervals.length},clearInterval(){},
    fetch:async()=>({json:async()=>liveFeed.current})});
  const selected={byId:{a:{id:'a',retainedBy:{mainView:1}}}};
  const ctx={effect:fn=>fn(),locale:{register:()=>()=>{},bind:()=>k=>k,subscribe:()=>()=>{},getSnapshot:()=>0},
    slots:{inject:(_name,fn)=>fn(),register:(_opts,view)=>{entry=view;return()=>{}}},
    sessions:{list:{getSnapshot:()=>selected},binding:()=>({session:{projections:{faceOf:()=>({getSnapshot:()=>current,subscribe:()=>()=>{}})},readAttachment:()=>{throw Error('control invoked attachment authority')}}})},
    layout:{panelInfo:{getSnapshot:()=>({activePanelId:null})}}};
  definition.factory(name=>{if(name!=='react')throw Error('unexpected host module');return react}).apply(ctx);
  let view;
  const props={sessionId:'a',view:null,onView:v=>{view=v},lastRead:{current:0},frameRef:{current:null}};
  const outer=entry({useSessions:()=>{},usePanelInfo:()=>{}});
  cursor=0;
  const wrapper=outer.type({useSessions:fn=>fn(selected),usePanelInfo:fn=>fn({activePanelId:null})});
  const pip=wrapper.children.find(x=>x&&typeof x.type==='function');
  return {
    draw(v){cursor=0;effectCursor=0;effects=[];props.view=v;return pip.type(props);},
    get writes(){return writes;},
    setState(next){current=next;},
    getView:()=>view,
    select(id){selected.byId={[id]:{id,retainedBy:{mainView:1}}};},
    effects:()=>effects,
    timers,
    intervals,
    setLive(status){liveFeed.current=status;},
    // Runs (and drains) the effects a render actually re-registered.
    runEffects(){const pending=effects;effects=[];for(const effect of pending)effect();}
  };
}

export function nodes(tree,type) {
  if(!tree||typeof tree!=='object')return [];
  return [...(tree.type===type?[tree]:[]),
    ...(tree.children||[]).flat(Infinity).flatMap(child=>nodes(child,type))];
}

export function text(tree) {
  if(tree===null||tree===undefined||typeof tree==='boolean')return '';
  if(typeof tree==='string'||typeof tree==='number')return String(tree);
  // Inline CSS is not user-visible copy: never let a selector satisfy a string assertion.
  if(tree.type==='style'||tree.type==='script')return '';
  return (tree.children||[]).flat(Infinity).map(text).join(' ');
}
