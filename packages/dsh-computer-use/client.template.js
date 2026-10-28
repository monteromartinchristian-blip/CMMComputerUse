window.__ModuleLoader__.load({
  id: '@cmm/dsh-computer-use',
  factory(require) {
    const React=require('react'), h=React.createElement;
    /*__CMM_RUNTIME__*/
    const dictionaries=/*__CMM_LOCALES__*/;
        const ns='cmm-computer-use', empty=initialState();
    // Every measurement and pointer interaction belongs to this overlay only.
    // The card is sized so the window frame, not the chrome, fills the PiP.
    const css=`
.cmm-cu-pip{box-sizing:border-box;position:absolute;top:68px;right:16px;width:max-content;max-width:calc(100% - 32px);pointer-events:auto;color:var(--dsw-alias-label-primary);font:inherit;font-size:12px;line-height:1.35;z-index:1}
.cmm-cu-pip *{box-sizing:border-box}
.cmm-cu-pill{display:flex;align-items:center;gap:6px;height:28px;max-width:240px;padding:0 10px;border:1px solid var(--dsw-alias-border-l1);border-radius:14px;background:var(--dsw-alias-bg-base);color:inherit;font:inherit;cursor:pointer}
.cmm-cu-pill:focus-visible{outline:2px solid var(--dsw-alias-brand-primary);outline-offset:2px}
.cmm-cu-pill-name{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:600}
.cmm-cu-card{display:flex;flex-direction:column;width:320px;max-width:100%;border:1px solid var(--dsw-alias-border-l1);border-radius:12px;background:var(--dsw-alias-bg-base);box-shadow:0 8px 28px rgba(0,0,0,.22);overflow:hidden}
.cmm-cu-pip[data-mode=expanded] .cmm-cu-card{width:640px}
.cmm-cu-dot{flex:none;width:8px;height:8px;border-radius:50%;background:var(--dsw-alias-label-secondary,#8b949e)}
.cmm-cu-dot[data-tone=ok]{background:var(--dsw-alias-positive-primary,#2ea043)}
.cmm-cu-dot[data-tone=wait]{background:var(--dsw-alias-warning-primary,#d29922)}
.cmm-cu-dot[data-tone=error]{background:var(--dsw-alias-negative-primary,#f85149)}
.cmm-cu-head{display:flex;align-items:center;gap:4px;height:32px;padding:0 4px 0 10px;flex:none;user-select:none;touch-action:none;cursor:default}
.cmm-cu-head:focus-visible{outline:2px solid var(--dsw-alias-brand-primary);outline-offset:-3px}
.cmm-cu-title{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:600}
.cmm-cu-head button{flex:none;display:grid;place-items:center;width:26px;height:26px;padding:0;border:0;border-radius:6px;background:transparent;color:var(--dsw-alias-label-secondary);font:inherit;font-size:13px;cursor:pointer}
.cmm-cu-head button:hover{background:var(--dsw-alias-bg-layer-1);color:var(--dsw-alias-label-primary)}
.cmm-cu-head button:focus-visible{outline:2px solid var(--dsw-alias-brand-primary);outline-offset:-2px}
.cmm-cu-stage{position:relative;display:flex;align-items:center;justify-content:center;min-height:0;max-height:240px;overflow:hidden;background:#101317}
.cmm-cu-pip[data-mode=expanded] .cmm-cu-stage{max-height:min(58vh,520px)}
.cmm-cu-stage img{display:block;width:100%;height:100%;min-height:0;object-fit:contain}
.cmm-cu-stage-empty{min-height:96px;padding:18px 14px}
.cmm-cu-msg{margin:0;text-align:center;color:var(--dsw-alias-label-secondary)}
.cmm-cu-msg strong{display:block;color:var(--dsw-alias-label-primary);font-weight:600;font-size:12px}
.cmm-cu-msg span{display:block;margin-top:2px;font-size:11px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.cmm-cu-msg button{margin-top:8px;padding:3px 8px;border:1px solid var(--dsw-alias-border-l1);border-radius:6px;background:var(--dsw-alias-bg-layer-1);color:inherit;font:inherit;font-size:11px;cursor:pointer}
.cmm-cu-msg button:focus-visible{outline:2px solid var(--dsw-alias-brand-primary);outline-offset:-2px}
.cmm-cu-stale{position:absolute;left:0;right:0;bottom:0;padding:3px 8px;text-align:center;font-size:11px;color:#fff;background:rgba(0,0,0,.55)}
.cmm-cu-caption{position:absolute;left:0;right:0;bottom:0;padding:3px 8px;text-align:center;font-size:11px;color:#fff;background:rgba(0,0,0,.55);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.cmm-cu-foot{display:flex;gap:5px;padding:4px 10px 6px;flex:none;font-size:11px;color:var(--dsw-alias-label-secondary);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.cmm-cu-foot span{min-width:0;overflow:hidden;text-overflow:ellipsis}
.cmm-cu-details{flex:none;max-height:190px;overflow:auto;padding:8px 10px;border-top:1px solid var(--dsw-alias-border-l1);font-size:11px}
.cmm-cu-details:focus-visible{outline:2px solid var(--dsw-alias-brand-primary);outline-offset:-2px}
.cmm-cu-details dl{display:grid;grid-template-columns:auto 1fr;gap:2px 10px;margin:0}
.cmm-cu-details dt{color:var(--dsw-alias-label-secondary)}
.cmm-cu-details dd{margin:0;overflow-wrap:anywhere}
.cmm-cu-details button{margin-top:8px;padding:3px 8px;border:1px solid var(--dsw-alias-border-l1);border-radius:6px;background:var(--dsw-alias-bg-layer-1);color:inherit;font:inherit;font-size:11px;cursor:pointer}
.cmm-cu-sr{position:absolute;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0}
@media(prefers-reduced-motion:reduce){.cmm-cu-pip,.cmm-cu-pip *{animation:none;transition:none}}
`;
    return {inject:['slots','locale','sessions','layout'],apply(ctx) {
      ctx.effect(()=>ctx.locale.register(ns,'en',dictionaries.en));
      ctx.effect(()=>ctx.locale.register(ns,'es',dictionaries.es));
      const t=ctx.locale.bind(ns);
      const currentSession=()=>visibleSessionId(ctx.sessions.list.getSnapshot(),ctx.layout.panelInfo.getSnapshot());

      /** Decode exactly one admitted frame; validate bytes and context twice. */
      function useFrameMedia({binding,face,frame,sessionId,lastRead,active,enabled}) {
        const [media,setMedia]=React.useState({url:null,failed:false,frame:null});
        // Session handles can be fresh objects on every render: keep them in refs
        // so the effect only re-runs when the frame (or access) really changes.
        const bindingRef=React.useRef(binding),faceRef=React.useRef(face);
        bindingRef.current=binding;faceRef.current=face;
        React.useEffect(()=>{
          let mounted=true;
          const binding=bindingRef.current,face=faceRef.current;
          setMedia(old=>(old.url===null&&old.failed===false&&old.frame===frame)
            ?old:{url:null,failed:false,frame});
          if(!enabled||!frame||!face||frameLabel(frame,Date.now(),!active)==='none')return;
          const lease=frameLease({
            admit:()=>currentSession()===sessionId&&face.getSnapshot().frame===frame
              &&pipPresentation(face.getSnapshot(),{sessionId,view:{sessionId,mode:'mini'}}).canRead,
            read:async id=>{
              lastRead.current=Date.now();
              const result=await binding.session.readAttachment(id);
              if(!result.ok)throw new Error('attachment unavailable');
              const a=result.value.attachment,expected=frame.attachment;
              if(a.attachmentId!==id||a.mediaType!==expected.mediaType||a.bytes!==expected.bytes
                ||a.width!==expected.width||a.height!==expected.height)throw new Error('attachment mismatch');
              return Uint8Array.from(result.value.data);
            },
            create:(data,type)=>URL.createObjectURL(new Blob([data],{type})),
            revoke:url=>URL.revokeObjectURL(url)
          });
          lease.load(frame.attachment,Math.max(0,lastRead.current+1000-Date.now())).then(url=>{
            if(mounted)setMedia(url?{url,failed:false,frame}:{url:null,failed:true,frame});
          });
          return ()=>{mounted=false;lease.dispose();};
        },[frame,sessionId,active,enabled]);
        return media.frame===frame?media:{url:null,failed:false,frame:null};
      }

      function Pip({sessionId,view,onView,lastRead,frameRef}) {
        React.useSyncExternalStore(React.useCallback(fn=>ctx.locale.subscribe(fn),[]),React.useCallback(()=>ctx.locale.getSnapshot(),[]));
        const binding=ctx.sessions.binding(sessionId);
        const face=binding?.session.projections.faceOf(KEY);
        const state=React.useSyncExternalStore(React.useCallback(fn=>face?face.subscribe(fn):()=>{},[face]),React.useCallback(()=>face?.getSnapshot()||empty,[face]));
        const indicator=React.useRef(null),firstControl=React.useRef(null),box=React.useRef(null),drag=React.useRef(null);
        const [position,setPosition]=React.useState(null),[returnFocus,setReturnFocus]=React.useState(null);
        const [details,setDetails]=React.useState(false);
        const [brokenUrl,setBrokenUrl]=React.useState(null),[tick,setTick]=React.useState(0);
        const model=pipPresentation(state,{sessionId,view});
        const open=model.mode!=='indicator';
        const media=useFrameMedia({binding,face,frame:state.frame,sessionId,lastRead,active:state.active,enabled:model.canRead});
        // Live mirror: the PiP polls the loopback streamer while it is visible,
        // so it shows what Computer Use is doing instead of a still admitted by
        // a tool result. The admitted frame remains the fallback.
        const target=state.target;
        const liveEnabled=!!(target&&model.visible&&open);
        const [liveTick,setLiveTick]=React.useState(0),[liveBroken,setLiveBroken]=React.useState(false);
        const [streamNonce,setStreamNonce]=React.useState(0);
        const rearm=React.useRef(0);
        // True while the viewer is actually decoding frames of the authorized
        // window. The label follows the pixels: a mirror that is showing the
        // window must not claim it is "waiting for the first capture".
        const [liveOk,setLiveOk]=React.useState(false);
        React.useEffect(()=>{
          if(!liveEnabled){setLiveBroken(false);return;}
          setLiveBroken(false);
          return undefined;
        },[liveEnabled,target&&target.bundle,target&&target.window,target&&target.windowId]);
        // The window id travels with the request: a title follows the active
        // tab, so a mirror keyed on it dies on the next navigation, while the
        // id keeps resolving for the life of the window. `window` stays for
        // the capture fallback, which only knows titles.
        const liveUrl=liveEnabled?'http://127.0.0.1:47183/stream.mjpg?token=cmm-cu-live'
          +'&app='+encodeURIComponent(target.bundle)+'&window='+encodeURIComponent(target.window)
          +(target.windowId?'&window_id='+target.windowId:'')
          +(streamNonce?'&rearm='+streamNonce:''):null;
        React.useEffect(()=>{setLiveOk(false);},[liveUrl]);
        // The pixels are only "live" while the streamer keeps producing frames.
        // A stalled multipart stream leaves the last picture on screen forever,
        // so the label is driven by the streamer's counters, not by the <img>.
        React.useEffect(()=>{
          if(!liveUrl) return undefined;
          let stop=false;
          const statusUrl=liveUrl.replace('/stream.mjpg','/stream/status');
          const probe=async()=>{
            try{
              const response=await fetch(statusUrl,{cache:'no-store'});
              const status=await response.json();
              if(stop)return;
              const fresh=mirrorFreshness(status,Date.now());
              setLiveOk(fresh);
              // A stalled stream is not revived in place: reopen it, at most
              // once every few seconds, so a helper restart heals the mirror.
              if(!fresh&&Date.now()-rearm.current>4000){rearm.current=Date.now();setStreamNonce(n=>n+1);}
            }catch{if(!stop)setLiveOk(false);}
          };
          probe();
          const timer=setInterval(probe,1500);
          return ()=>{stop=true;clearInterval(timer);};
        },[liveUrl]);
        // Re-render once when the frame becomes stale and once when it expires.
        React.useEffect(()=>{
          if(!model.visible||model.mode==='indicator'||!model.frameAt)return;
          const now=Date.now(), due=[model.frameAt+STALE_MS,model.frameAt+RETENTION_MS].filter(x=>x>now);
          if(!due.length)return;
          const timers=due.map(x=>setTimeout(()=>setTick(v=>v+1),x-now+80));
          return ()=>timers.forEach(id=>clearTimeout(id));
        },[model.visible,model.mode,model.frameAt]);
        const bound=React.useCallback(point=>{
          const parent=frameRef.current,card=box.current;
          if(!parent||!card)return;
          const next=overlayPosition(point,{width:parent.clientWidth,height:parent.clientHeight},{width:card.offsetWidth,height:card.offsetHeight});
          setPosition(old=>old?.x===next.x&&old?.y===next.y?old:next);
        },[frameRef]);
        React.useLayoutEffect(()=>{
          if(!model.visible)return;
          bound(position);
          const observer=new ResizeObserver(()=>bound(position));
          if(frameRef.current)observer.observe(frameRef.current);
          if(box.current)observer.observe(box.current);
          return ()=>observer.disconnect();
        },[model.visible,model.mode,bound,position]);
        React.useEffect(()=>{
          if(!model.visible||currentSession()!==sessionId)return;
          if(returnFocus==='view'&&open){firstControl.current?.focus({preventScroll:true});setReturnFocus(null);}
          if(returnFocus==='indicator'&&!open){indicator.current?.focus({preventScroll:true});setReturnFocus(null);}
        },[returnFocus,open,model.visible]);
        const action=name=>{
          onView(viewTransition(view,sessionId,name,activityRevision(state)));
          if(name==='collapse')setReturnFocus('indicator');
          if(name==='open')setReturnFocus('view');
          if(name==='close')setDetails(false);
        };
        if(!model.visible||currentSession()!==sessionId)return null;
        const title=model.app||t('title');
        // The mirror can be live before any capture is admitted: the label has
        // to follow what is on screen, not the admission state alone.
        const shownPhase=displayPhase(model.phase,{mirrorLive:liveOk&&!liveBroken});
        const errorPhase=shownPhase==='denied'||shownPhase==='incompatible'||shownPhase==='error';
        const headline=shownPhase==='mirror-live'?'live':shownPhase==='observed-no-frame'?'waiting':shownPhase==='expired'?'expired'
          :shownPhase==='denied'?'errorPermission':shownPhase==='error'&&state.breach?'errorBreach':'errorWindow';
        // The visible state follows the same phase the card claims: a mirror
        // showing frames is "live", never "waiting for the first capture".
        const shownStatus=shownPhase==='mirror-live'?'live':model.status;
        const dot=h('span',{className:'cmm-cu-dot','data-tone':model.tone,'aria-hidden':true});
        const status=h('span',{className:'cmm-cu-sr',role:'status','aria-live':'polite'},t(shownStatus));
        const iconButton=(label,icon,onClick,extra={})=>h('button',{type:'button','aria-label':t(label),title:t(label),onClick,...extra},h('span',{'aria-hidden':true},icon));
        const toggleDetails=()=>setDetails(v=>!v);
        const move={
          onPointerDown:e=>{if(e.button!==0)return;if(e.target&&e.target.closest&&e.target.closest('button'))return;e.preventDefault();drag.current={id:e.pointerId,x:e.clientX,y:e.clientY,left:box.current.offsetLeft,top:box.current.offsetTop};e.currentTarget.setPointerCapture(e.pointerId);},
          onPointerMove:e=>{const d=drag.current;if(d?.id===e.pointerId)bound({x:d.left+e.clientX-d.x,y:d.top+e.clientY-d.y});},
          onPointerUp:e=>{drag.current=null;if(e.currentTarget.hasPointerCapture(e.pointerId))e.currentTarget.releasePointerCapture(e.pointerId);},
          onPointerCancel:()=>{drag.current=null;},
          onKeyDown:e=>{const delta={ArrowLeft:[-16,0],ArrowRight:[16,0],ArrowUp:[0,-16],ArrowDown:[0,16]}[e.key];if(delta){e.preventDefault();e.stopPropagation();bound({x:box.current.offsetLeft+delta[0],y:box.current.offsetTop+delta[1]});}}
        };
        const facts=model.technical||{},rows=[];
        const row=(label,value)=>{if(value!==null&&value!==undefined&&value!=='')rows.push([label,value]);};
        row('helper',[facts.bridge,facts.protocol!==null?'protocol '+facts.protocol:null,facts.pid!==null?'pid '+facts.pid:null].filter(Boolean).join(' · '));
        row('authorization',facts.authorization
          ?'loaded='+String(facts.authorization.loaded)+' apps='+facts.authorization.apps+' default='+facts.authorization.default:null);
        row('permissions',[facts.accessibility?'accessibility '+facts.accessibility:null,
          facts.screenRecording?'screen_recording '+facts.screenRecording:null].filter(Boolean).join(' · '));
        row('policy',[facts.policy?'session '+facts.policy:null,
          facts.deploymentPolicy?'deployment '+facts.deploymentPolicy:null,
          facts.effectiveMode?'effective '+facts.effectiveMode:null].filter(Boolean).join(' · '));
        row('target',facts.target?facts.target.bundle+' · pid '+facts.target.pid+' · snapshot '+facts.target.snapshot
          +(facts.target.windowId?' · window '+facts.target.windowId:''):null);
        row('errorCode',facts.error);
        row('technical',facts.message);
        const frameStage=()=>{
          const a=state.frame?.attachment;
          const broken=!!media.url&&brokenUrl===media.url;
          return h('div',{className:'cmm-cu-stage',style:a?{aspectRatio:a.width+' / '+a.height}:undefined},
            liveUrl&&!liveBroken?h('img',{src:liveUrl,alt:t('windowFrame'),
              onLoad:e=>{const img=e.currentTarget;if(img&&img.naturalWidth>0)setLiveOk(true);},
              onError:()=>{setLiveOk(false);setLiveBroken(true);setTimeout(()=>setLiveBroken(false),2000);}})
              :media.url&&!broken?h('img',{src:media.url,alt:t('windowFrame'),onError:()=>setBrokenUrl(media.url)})
              :h('p',{className:'cmm-cu-msg'},h('strong',null,t(media.failed||broken?'windowUnavailable':'loading')),h('span',null,title)),
            state.attempt?h('span',{style:{position:'absolute',left:8,bottom:8,padding:'2px 6px',borderRadius:6,background:'rgba(0,0,0,.66)',color:'#fff',fontSize:11,lineHeight:'15px',pointerEvents:'none'}},
              (state.attempt.failed?'✗ ':'✓ ')+state.attempt.name):null,
            !a&&model.window?h('span',{className:'cmm-cu-caption'},model.window):null,
            model.phase==='frame-stale'?h('span',{className:'cmm-cu-stale',role:'status'},t('pausedBadge')):null);
        };
        const emptyStage=()=>h('div',{className:'cmm-cu-stage cmm-cu-stage-empty'},
          h('p',{className:'cmm-cu-msg'},
            h('strong',null,t(headline)),
            h('span',null,errorPhase?t('errorHint'):(model.window||t('expiredHint'))),
            errorPhase?h('button',{type:'button','aria-label':t('details'),'aria-expanded':details,onClick:toggleDetails},t('details')):null));
        const detailPanel=details&&open?h('div',{className:'cmm-cu-details',role:'region','aria-label':t('details'),tabIndex:0,
          onKeyDown:e=>{if(e.key==='Escape'){e.preventDefault();e.stopPropagation();setDetails(false);}}},
          h('dl',null,rows.flatMap(([label,value])=>[h('dt',{key:'t-'+label},t(label)),h('dd',{key:'d-'+label},String(value))]))):null;
        const card=h('section',{className:'cmm-cu-card'},
          h('header',{ref:firstControl,className:'cmm-cu-head',tabIndex:0,'aria-label':t('move'),...move},
            dot,
            h('span',{className:'cmm-cu-title'},title),
            status,
            iconButton(model.mode==='expanded'?'shrink':'expand',model.mode==='expanded'?'↙':'↗',
              ()=>action(model.mode==='expanded'?'shrink':'expand'),{'aria-expanded':model.mode==='expanded'}),
            iconButton('collapse','−',()=>action('collapse'),{'aria-expanded':true}),
            iconButton('closeView','×',()=>action('close'))),
          liveUrl&&!liveBroken?frameStage()
          :model.phase==='frame-live'||model.phase==='frame-stale'?frameStage():emptyStage(),
          model.mode==='expanded'&&(model.phase==='frame-live'||model.phase==='frame-stale')
            ?h('div',{className:'cmm-cu-foot'},h('span',null,title),model.window?h('span',null,'· '+model.window):null,
                model.ageMs!==null?h('span',null,'· '+t('updated')+' '+Math.round(model.ageMs/1000)+'s'):null)
            :null,
          detailPanel);
        return h('section',{ref:box,className:'cmm-cu-pip','data-mode':model.mode,'data-phase':shownPhase,'aria-label':t('title'),
          onKeyDown:e=>{
            if(e.key!=='Escape')return;
            if(details){e.preventDefault();e.stopPropagation();setDetails(false);return;}
            if(!open)return;
            e.preventDefault();e.stopPropagation();action('collapse');
          },
          style:position?{left:position.x,top:position.y,right:'auto'}:undefined},
          h('style',null,css),
          !open?h('button',{ref:indicator,className:'cmm-cu-pill',type:'button','aria-label':t('openView')+' · '+title,'aria-expanded':false,onClick:()=>action('open')},
            dot,h('span',{className:'cmm-cu-pill-name'},title),status)
          :card);
      }

      function Overlay(props) {
        // Public root selector hooks, supplied by ui-session and ui-layout.
        // Missing hook face => no subscriptions to sessions and no disclosure.
        if(typeof props.useSessions!=='function'||typeof props.usePanelInfo!=='function')return null;
        return h(SelectedOverlay,props);
      }
      function SelectedOverlay({useSessions,usePanelInfo}) {
        const panel=usePanelInfo(info=>info);
        const sessionId=useSessions(list=>visibleSessionId(list,panel));
        const [views,setViews]=React.useState({});
        const reads=React.useRef(new Map()),frameRef=React.useRef(null);
        if(!sessionId)return null;
        if(!reads.current.has(sessionId)){
          if(reads.current.size>=32)reads.current.delete(reads.current.keys().next().value);
          reads.current.set(sessionId,{current:0});
        }
        return h('div',{ref:frameRef,style:{position:'absolute',inset:0,pointerEvents:'none'}},
          h(Pip,{key:sessionId,sessionId,frameRef,view:views[sessionId],lastRead:reads.current.get(sessionId),
            onView:view=>setViews(old=>Object.fromEntries([...Object.entries(old).filter(([id])=>id!==sessionId).slice(-31),[sessionId,view]]))}));
      }
      ctx.slots.inject('shell.overlay',()=>ctx.slots.register({
        name:'shell.overlay',id:'cmm-computer-use-pip',order:60,locale:ns,label:()=>t('title')
      },Overlay));
    }};
  }
});
