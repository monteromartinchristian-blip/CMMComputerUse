/** Pure, bounded projection. Never retain tool arguments, text, or image bytes. */
export const KEY = 'cmm.computer-use.panel.v1';
export const MAX_BYTES = 1024 * 1024;
export const RETENTION_MS = 60000;
/** A frame older than this is shown, but labelled as paused: never as current. */
export const STALE_MS = 10000;
const PREFIX = 'mcp__cmm-computer-use__computer_use_';
const TOOLS = new Set(['status','list_apps','observe','capture_window','press','set_value','release']);
/** Results that mean "the agent tried to show or touch a window". */
const GUI = new Set(['observe','capture_window','press','set_value']);
const clean = x => typeof x === 'string' ? x.replace(/[\u0000-\u001f\u007f]/g,'').slice(0,200) : '';
const token = x => typeof x === 'string' ? x.replace(/[^\w.:/@-]/g,'').slice(0,80) : '';
export function initialState() {
  return {bridge:'disconnected', policy:null, grants:[], target:null, frame:null,
    error:null, message:null, helper:null, attempt:null, ledger:null, breach:false, pending:{},
    lastAt:0, active:false, revision:0, guiRevision:0, attemptRevision:0};
}
export function validAttachment(a) {
  // The durable store names an attachment `sha256:<hex>`; the id is a bounded
  // opaque token, never a path, and the digest prefix is part of it.
  return a && typeof a.attachmentId === 'string' && /^[\w:.-]{1,160}$/.test(a.attachmentId)
    && FRAME_MEDIA.includes(a.mediaType) && Number.isInteger(a.bytes) && a.bytes>0 && a.bytes<=MAX_BYTES
    && Number.isInteger(a.width) && a.width>0 && a.width<=4096
    && Number.isInteger(a.height) && a.height>0 && a.height<=4096 && a.width*a.height<=8000000;
}
/**
 * Container formats the durable store can hand back for a capture. DSH
 * re-encodes an admitted PNG as WebP before storing it, so a projection that
 * only accepted `image/png` refused every real frame the host actually saved.
 * The type is never trusted: `imageHeader` proves it from the bytes.
 */
export const FRAME_MEDIA = ['image/png','image/webp','image/jpeg','image/gif'];
/** Real dimensions read from the container header, or null. Fail-closed. */
export function imageHeader(d, mediaType) {
  if(!(d instanceof Uint8Array) || d.length<16) return null;
  const view=new DataView(d.buffer,d.byteOffset,d.byteLength);
  const ascii=(from,to)=>String.fromCharCode(...d.slice(from,to));
  if(mediaType==='image/png'){
    if(ascii(1,4)!=='PNG'||![137,80,78,71,13,10,26,10].every((n,i)=>d[i]===n)||ascii(12,16)!=='IHDR') return null;
    return {width:view.getUint32(16),height:view.getUint32(20)};
  }
  if(mediaType==='image/webp'){
    if(ascii(0,4)!=='RIFF'||ascii(8,12)!=='WEBP') return null;
    const chunk=ascii(12,16);
    if(chunk==='VP8X'){ if(d.length<30) return null;
      return {width:1+(d[24]|d[25]<<8|d[26]<<16),height:1+(d[27]|d[28]<<8|d[29]<<16)}; }
    if(chunk==='VP8L'){ if(d.length<25||d[20]!==0x2f) return null;
      const bits=(d[21]|d[22]<<8|d[23]<<16|d[24]<<24)>>>0;
      return {width:1+(bits&0x3fff),height:1+((bits>>>14)&0x3fff)}; }
    if(chunk==='VP8 '){ if(d.length<30||d[23]!==0x9d||d[24]!==0x01||d[25]!==0x2a) return null;
      return {width:(d[26]|d[27]<<8)&0x3fff,height:(d[28]|d[29]<<8)&0x3fff}; }
    return null;
  }
  if(mediaType==='image/gif'){
    const sig=ascii(0,6); if(sig!=='GIF87a'&&sig!=='GIF89a') return null;
    return {width:d[6]|d[7]<<8,height:d[8]|d[9]<<8};
  }
  if(mediaType==='image/jpeg'){
    if(d[0]!==0xff||d[1]!==0xd8) return null;
    let i=2;
    while(i+9<d.length){
      if(d[i]!==0xff){ i++; continue; }
      const marker=d[i+1];
      if(marker>=0xc0&&marker<=0xcf&&marker!==0xc4&&marker!==0xc8&&marker!==0xcc)
        return {width:(d[i+7]<<8)|d[i+8],height:(d[i+5]<<8)|d[i+6]};
      const len=(d[i+2]<<8)|d[i+3];
      if(len<2) return null;
      i+=2+len;
    }
    return null;
  }
  return null;
}
function viewIdentity(text) {
  // Metadata is before AX content and is never parsed out of arbitrary AX text.
  const line=text.split('\n').slice(0,4).find(l=>l.startsWith('cmm_view: '));
  try {
    const i=JSON.parse(line?.slice(10));
    if(!/^[\w.-]{1,200}$/.test(i.bundle)||!Number.isSafeInteger(i.pid)||i.pid<=0
      ||!Number.isSafeInteger(i.snapshot)||i.snapshot<=0||typeof i.window!=='string'
      ||!Number.isSafeInteger(i.window_id)||i.window_id<=0||!i.window||i.window.length>200||/[\u0000-\u001f\u007f]/.test(i.window))return null;
    return i;
  }catch{return null;}
}

/**
 * Whether a capture result belongs to the SAME causal line as the observed
 * target, or the short code that says which fact failed.
 *
 * `observationGeneration` in the helper is a PROCESS-WIDE counter: every
 * `observation.describe`, from ANY client, bumps it. It identifies a
 * generation, not a window, so a capture taken after another client observed
 * something carries a HIGHER number while still describing the very same
 * authorized surface. Equality was therefore the wrong test: it rejected real
 * frames of a window it had just admitted, and the PiP painted a false error.
 *
 * A later frame is admitted only when every fact that identifies the line
 * still matches: the same authorized grant (name/bundle, checked by the
 * caller), the same bundle, the same process, the same window title and the
 * same window id, a capture issued against the target that is current now
 * (`call.target`, so an observation that arrived in between still fails), a
 * snapshot that is not OLDER than the one that produced the element handles,
 * and a capture that is not older than the observation or the action it
 * follows. A bigger number alone proves nothing: another window, bundle, pid
 * or session still fails. A replaced window is never re-validated here.
 */
export function captureLineage({target, call, identity, at, previousAt}={}) {
  if(!target||!call||!identity) return 'UNVERIFIED_CAPTURE';
  // The capture must have been issued against the target that is current now.
  const issued=call.target;
  if(!issued||issued.bundle!==target.bundle||issued.pid!==target.pid
    ||issued.snapshot!==target.snapshot||issued.windowId!==target.windowId) return 'UNVERIFIED_CAPTURE';
  // Same application, same process, same window — proven by identity, not by
  // the generation number, which no client owns.
  if(identity.bundle!==target.bundle) return 'UNVERIFIED_CAPTURE';
  if(identity.pid!==target.pid) return 'UNVERIFIED_CAPTURE';
  if(identity.window!==target.window) return 'UNVERIFIED_CAPTURE';
  if(target.windowId&&identity.window_id!==target.windowId) return 'window_changed';
  if(!(call.app===target.name||call.app===target.bundle)) return 'UNVERIFIED_CAPTURE';
  if(!(call.window&&target.window.includes(call.window))) return 'UNVERIFIED_CAPTURE';
  // Monotonic line: an older generation is stale. A newer one is admissible
  // only because every identity fact above still matches.
  if(identity.snapshot<target.snapshot) return 'snapshot_stale';
  // The frame must not predate the observation that produced the handles or
  // the action it is meant to show.
  if(Number.isFinite(at)&&Number.isFinite(target.observedAt)
    &&target.observedAt>0&&at<target.observedAt) return 'snapshot_stale';
  if(Number.isFinite(at)&&Number.isFinite(previousAt)&&previousAt>0&&at<previousAt) return 'snapshot_stale';
  return null;
}

/**
 * Classify one `computer_use_status` result. The adapter prints its facts as
 * fixed lines (`helper: … protocol=1 pid=…`, `deployment_policy: …`,
 * `authorization: *** loaded=True apps=1 default=deny`, `effective_mode: …`),
 * so the shape — not the absence of a later frame — is what proves a helper
 * incompatible. Anything unproven stays fail-closed.
 */
export function parseStatus(text) {
  const helper = {bridge:null, protocol:null, pid:null, bundle:null, deploymentPolicy:null,
    accessibility:null, screenRecording:null, loaded:null, apps:null, default:null, effectiveMode:null};
  const head = text.match(/^helper: ([^\n]*) protocol=(\d+)(?: pid=(\d+))?$/m);
  if (head) { helper.bridge = clean(head[1]) || null; helper.protocol = Number(head[2]); helper.pid = head[3] ? Number(head[3]) : null; }
  const bundle = text.match(/^bundle: ([\w.-]{1,200})$/m); if (bundle) helper.bundle = bundle[1];
  const deploy = text.match(/^deployment_policy: (\S+)/m); if (deploy) helper.deploymentPolicy = token(deploy[1]);
  const ax = text.match(/^accessibility: (True|False)$/m); if (ax) helper.accessibility = ax[1];
  const screen = text.match(/^screen_recording: (True|False)$/m); if (screen) helper.screenRecording = screen[1];
  // The adapter prints `authorization: *** loaded=True apps=1 default=deny`; the
  // `***` and `loaded=` markers are optional so an older adapter revision still
  // classifies by the same facts instead of failing to "incompatible".
  const auth = text.match(/^authorization: (?:\*\*\* )?(?:loaded=(True|False) )?apps=(\d+) default=(\w+)$/m);
  if (auth) { helper.loaded = auth[1] ? auth[1] === 'True' : null; helper.apps = Number(auth[2]); helper.default = token(auth[3]); }
  const effective = text.match(/^effective_mode: (\S+)/m); if (effective) helper.effectiveMode = token(effective[1]);
  const grants = [];
  for (const m of text.matchAll(/^- authorized:[ \u00a0]*([^\[\n]*?)[ \u00a0]*\[([\w.-]+)\] scopes=([a-z,]+) windows=(\d+)$/gm)) {
    const scopes = m[3].split(',').filter(s => s === 'observe' || s === 'control');
    // windows=0 means "any window" in the helper's policy (windowPatterns is
    // empty); it is a valid grant, not a missing one.
    if (scopes.includes('observe')) grants.push({name:clean(m[1])||clean(m[2]), bundle:clean(m[2]), scopes});
  }
  // Proof of a modern, policy-aware helper: it reported a deployment policy, an
  // effective mode and an authorization block, and its protocol is still v1.
  const modern = !!helper.deploymentPolicy && helper.deploymentPolicy !== 'None'
    && !!helper.effectiveMode && helper.default !== null
    && (helper.protocol === null || helper.protocol === 1);
  let bridge = 'incompatible', error = null;
  if (modern) {
    if (helper.accessibility === 'False' || helper.screenRecording === 'False'
      || helper.loaded === false || helper.apps === 0) { bridge = 'denied'; error = 'PERMISSION_DENIED'; }
    else if (!['background','focus','unrestricted'].includes(helper.deploymentPolicy) || !['background','focus','unrestricted'].includes(helper.effectiveMode)) bridge = 'incompatible';
    else bridge = 'compatible';
  }
  return {bridge, error, helper, grants};
}

export function fold(state, event) {
  if(event.type==='turn/end') return state.active ? {...state,active:false,pending:{}} : state;
  if (event.type === 'assistant/message') {
    let pending = state.pending, revision=state.revision;
    for (const b of event.data?.message?.content || []) {
      if (b.type !== 'tool-call' || !b.name?.startsWith(PREFIX) || !TOOLS.has(b.name.slice(PREFIX.length))) continue;
      const name=b.name.slice(PREFIX.length);
      let args={};
      try { if (typeof b.arguments==='string' && b.arguments.length<=16384) args=JSON.parse(b.arguments); } catch {}
      // Only capture routing is retained. Text-field values never enter state.
      pending={...pending,[b.id]:{name,app:clean(args?.app),window:clean(args?.window_title),target:state.target,revision:++revision}};
    }
    if(pending===state.pending) return state;
    return {...state,active:true,revision,frame:null,pending:Object.fromEntries(Object.entries(pending).slice(-32))};
  }
  if(event.type!=='tool/result') return state;
  const msg=event.data?.message, id=msg?.source?.callId, call=state.pending[id];
  if(!call) return state;
  const pending={...state.pending}; delete pending[id];
  const text=(msg.content||[]).filter(b=>b.type==='text' && typeof b.text==='string').map(b=>b.text.slice(0,16384)).join('\n').slice(0,32768);
  const at=Number.isFinite(event.time)?event.time:Date.parse(event.time);
  let next={...state,pending,lastAt:Number.isFinite(at)?at:0};
  // Any GUI attempt is new activity for the view; only proven results grant pixels.
  if(GUI.has(call.name)) next={...next,attemptRevision:(state.attemptRevision||0)+1};
  const action=call.name==='press'||call.name==='set_value';
  if(action) {
    const ledger={};
    for(const key of ['cursor_events_posted','cursor_moved_by_action','external_activity','focus_became_target']) {
      const m=text.match(new RegExp('(?:^|[ \\n])'+key+'=(True|False)(?: |$)','m'));
      if(m) ledger[key]=m[1]==='True';
    }
    next={...next,ledger};
  }
  const verifiedBreach=action && msg.isError === true
    && /^attributable: cursor_events_posted=False cursor_moved_by_action=False focus_became_target=True external_activity=(True|False)$/m.test(text)
    && /^STOP: breach recorded(?: on a failed action)? \(policy=background\)\. Do not retry(?: this action; report it and let the operator review the ledger\.|; report it and let the operator review the ledger\.)$/m.test(text);
  if (verifiedBreach) return {...next,breach:true,target:null,frame:null,error:'BREACH',
    attempt:{name:call.name,at:next.lastAt,failed:true,code:'BREACH'}};
  if(state.breach) return next;
  // Negative status is revocation evidence even when a newer capture is pending.
  if(call.revision!==state.revision&&call.name!=='status')return {...state,pending};
  if(msg.isError || /^REFUSED /m.test(text)) {
    const code=text.match(/^REFUSED ([A-Z_]+)/m)?.[1];
    const reason=text.match(/(?:^|[; =])reason=(app_not_granted|window_changed|pid_changed|expired|global_input_not_scoped|breach)(?:[; \n\]]|$)/m)?.[1];
    const known=['APPROVAL_REJECTED','ACTION_FAILED','CAPABILITY_UNSUPPORTED','TIMEOUT','UNAVAILABLE','COMPUTER_RUNTIME_UNAVAILABLE','COMPUTER_PERMISSION_DENIED','COMPUTER_TARGET_UNAVAILABLE'];
    const statusFailure=call.name==='status';
    const failure=reason||(known.includes(code)?code:'REFUSED');
    return {...next,target:null,frame:null,error:failure,
      // Short, technical, and never the refusal's free text.
      message:code?'REFUSED '+code+(reason?' · reason='+reason:''):null,
      attempt:{name:call.name,at:next.lastAt,failed:true,code:failure},
      ...(statusFailure?{pending:{},grants:[],policy:null}:{}),
      bridge:code==='COMPUTER_PERMISSION_DENIED'||(statusFailure&&code==='APPROVAL_REJECTED')?'denied'
        :statusFailure||/RUNTIME_UNAVAILABLE|^UNAVAILABLE$/.test(code||'')?'disconnected':state.bridge};
  }
  if(call.name==='status') {
    const parsed=parseStatus(text);
    // A superseded healthy status cannot revoke; a superseded failure still can.
    if(parsed.bridge==='compatible'&&call.revision!==state.revision)return {...state,pending};
    return {...next,helper:parsed.helper,bridge:parsed.bridge,
      policy:parsed.bridge==='compatible'?(parsed.helper?.deploymentPolicy||'background'):null,
      grants:parsed.bridge==='compatible'?parsed.grants.slice(0,20):[],
      target:null,frame:null,error:parsed.error,message:null,
      ...(parsed.bridge==='compatible'?{}:{pending:{}})};
  }
  if(call.name==='release') return {...next,target:null,frame:null};
  if(call.name==='observe') {
    const m=text.match(/^target: ([^\n]+) \[([\w.-]+)\] \((background|frontmost)\)$/m);
    const grant=m&&state.grants.find(g=>g.bundle===m[2]&&(call.app===g.name||call.app===g.bundle||call.app===clean(m[1])));
    if(state.bridge!=='compatible'||!grant) return {...next,target:null,frame:null,error:'UNVERIFIED_TARGET'};
    const identity=viewIdentity(text);
    if(!identity||identity.bundle!==grant.bundle||!['background','frontmost'].includes(m[3]))return {...next,target:null,frame:null,error:'UNVERIFIED_TARGET'};
    // A target the deployment policy cannot serve in the background is not
    // "nothing to supervise": GUI work did happen and stays visible as a
    // fail-closed error. `idle` is reserved for sessions with no GUI target.
    if(m[3]!=='background')return {...next,target:null,frame:null,error:'TARGET_NOT_BACKGROUND',
      message:null,attempt:{name:'observe',at:next.lastAt,failed:true,code:'TARGET_NOT_BACKGROUND'}};
    return {...next,guiRevision:call.revision,
      target:{name:clean(m[1])||grant.name,bundle:grant.bundle,window:identity.window,pid:identity.pid,snapshot:identity.snapshot,windowId:identity.window_id,background:m[3]==='background',scopes:grant.scopes,observedAt:next.lastAt},
      frame:null,error:null,message:null,
      attempt:{name:'observe',at:next.lastAt,failed:false,code:null}};
  }
  if(call.name==='capture_window') {
    const target=state.target;
    const identity=viewIdentity(text);
    // Lineage, not equality: the helper's generation counter is process-wide,
    // so a capture of the SAME window taken after another client observed
    // something carries a higher number. See `captureLineage`.
    const lineage=captureLineage({target,call,identity,at:next.lastAt,
      previousAt:state.attempt?.at});
    if(lineage==='window_changed')
      return {...next,target:null,frame:null,error:'window_changed',
        attempt:{name:'capture_window',at:next.lastAt,failed:true,code:'window_changed'}};
    const a=(msg.content||[]).find(b=>b.type==='image')?.attachment;
    if(state.bridge!=='compatible'||lineage||!/^Captured one window \(scope=window\)\.$/m.test(text)||!validAttachment(a))
      return {...next,frame:null,error:lineage||'UNVERIFIED_CAPTURE',
        attempt:{name:'capture_window',at:next.lastAt,failed:true,code:lineage||'UNVERIFIED_CAPTURE'}};
    // Explicit whitelist: no attachment name or arbitrary fields in projection/cache.
    const {attachmentId,mediaType,bytes,width,height}=a;
    return {...next,guiRevision:call.revision,target:{...target,windowId:identity.window_id},
      frame:{callId:id,windowId:identity.window_id,attachment:{attachmentId,mediaType,bytes,width,height},at:next.lastAt,seq:event.seq},
      error:null,message:null,attempt:{name:'capture_window',at:next.lastAt,failed:false,code:null}};
  }
  if(action&&state.target&&(state.policy!=='background'||state.target.background)&&state.target.scopes?.includes('control'))
    return {...next,guiRevision:call.revision,attempt:{name:call.name,at:next.lastAt,failed:false,code:null}};
  return next;
}

/** Age of the last admitted frame, or null when there is none. */
export function frameAge(frame, now=Date.now()) {
  if(!frame||!Number.isFinite(frame.at)||!Number.isFinite(now)) return null;
  return Math.max(0, now-frame.at);
}
/** 'live' | 'stale' | 'expired' | 'none'. Retention still invalidates pixels. */
export function frameFreshness(frame, now=Date.now()) {
  const age=frameAge(frame,now);
  if(age===null) return 'none';
  if(age>=RETENTION_MS) return 'expired';
  return age<STALE_MS?'live':'stale';
}
export function frameLabel(frame, now=Date.now(), historical=false) {
  const freshness=frameFreshness(frame,now);
  if(freshness==='none'||freshness==='expired') return 'none';
  if(historical) return 'previous';
  return freshness==='live'?'real':'previous';
}
/** One decoded frame per mounted panel. Async cancellation uses a generation. */
export function frameLease({read,create,revoke,admit=()=>true,schedule=setTimeout,cancel=clearTimeout}) {
  let generation=0,url=null,closed=false,pending=null;
  const clear=()=>{generation++;if(pending){cancel(pending.timer);pending.resolve(false);pending=null;}if(url)revoke(url);url=null;};
  return {
    async load(attachment,delayMs=0) {
      clear(); const own=generation;
      if(closed||!admit()||!validAttachment(attachment))return null;
      try {
        if(delayMs>0) {
          const admitted=await new Promise(resolve=>{pending={resolve,timer:schedule(()=>{pending=null;resolve(true);},Math.min(delayMs,RETENTION_MS))};});
          if(!admitted||closed||generation!==own)return null;
        }
        if(!admit())return null;
        const data=await read(attachment.attachmentId);
        if(closed||generation!==own||!admit())return null;
        if(!(data instanceof Uint8Array)||data.byteLength!==attachment.bytes||data.byteLength>MAX_BYTES)return null;
        const header=imageHeader(data,attachment.mediaType);
        if(!header||header.width!==attachment.width||header.height!==attachment.height)return null;
        url=create(data,attachment.mediaType);return url;
      }catch{return null;}
    },
    dispose(){closed=true;clear();}
  };
}

/** View-only state. No agent operation, authority, or persisted cross-session data. */
export function viewTransition(view,sessionId,action,revision=0) {
  if(view&&view.sessionId!==sessionId)return {sessionId,mode:'indicator'};
  if(action==='close')return {sessionId,mode:'closed',revision};
  const mode=action==='open'?'mini':action==='expand'?'expanded':action==='shrink'?'mini':'indicator';
  return {sessionId,mode};
}
/** New activity = a proven GUI result or a GUI attempt (including its failure). */
export function activityRevision(state) {
  const gui=Number.isSafeInteger(state?.guiRevision)?state.guiRevision:0;
  const attempt=Number.isSafeInteger(state?.attemptRevision)?state.attemptRevision:0;
  return Math.max(gui,attempt);
}
/**
 * Whether the loopback mirror is delivering frames *now*.
 *
 * A multipart `<img>` keeps its last decoded frame when the stream stalls, so
 * "an image is on screen" is not evidence of current pixels. The streamer's own
 * counters are: a frame count above zero and a recent `lastFrameAt`.
 */
export const MIRROR_STALE_MS = 3000;
export function mirrorFreshness(status, now=Date.now(), staleMs=MIRROR_STALE_MS) {
  if(!status||typeof status!=='object') return false;
  const frames=Number(status.frames), at=Number(status.lastFrameAt);
  if(!Number.isFinite(frames)||!Number.isFinite(at)||frames<1||at<=0) return false;
  return now-at<=staleMs;
}
/**
 * The one state the PiP can be in. Incompatibility is never inferred from a
 * missing frame: only the status shape can prove it.
 */
export function pipPhase(state, now=Date.now()) {
  if(!state||typeof state!=='object') return 'idle';
  if(state.breach) return 'error';
  if(state.bridge==='denied'||state.error==='PERMISSION_DENIED') return 'denied';
  if(state.bridge==='incompatible') return 'incompatible';
  if(state.error) return 'error';
  if(!state.target) return 'idle';
  // A retained target that the background policy cannot serve is never idle:
  // the GUI attempt stays visible as a fail-closed error.
  if(state.target.background!==true) return 'error';

  const freshness=frameFreshness(state.frame,now);
  if(freshness==='none') return 'observed-no-frame';
  if(freshness==='expired') return 'expired';
  return freshness==='live'?'frame-live':'frame-stale';
}
/**
 * What the panel can honestly claim to be showing.
 *
 * `pipPhase` describes the ADMITTED frame: a capture result the host stored as
 * an attachment. The live mirror is not that, but it is not "waiting" either:
 * when the viewer is decoding frames of the authorized window, saying
 * "Waiting for the first capture…" is a false statement about what the person
 * sees. The two facts stay distinct — `mirror-live` never grants `canRead` —
 * so the label follows the pixels without pretending an attachment exists.
 */
export function displayPhase(phase,{mirrorLive=false}={}) {
  // Any phase that describes the ADMITTED image being old, absent or expired is
  // superseded by a mirror that is decoding frames right now. Error and denial
  // phases are never overridden: those are about authority, not pixels.
  if(mirrorLive===true&&['observed-no-frame','expired','frame-stale'].includes(phase)) return 'mirror-live';
  return phase;
}
const PHASE_STATUS={idle:'idle','observed-no-frame':'waiting','mirror-live':'live',
  'frame-live':'live','frame-stale':'paused',
  expired:'waiting',denied:'denied',incompatible:'incompatible',error:'error'};
const PHASE_TONE={idle:'muted','observed-no-frame':'wait','mirror-live':'ok','frame-live':'ok','frame-stale':'wait',
  expired:'wait',denied:'error',incompatible:'error',error:'error'};
function technicalFacts(state,target) {
  const h=state.helper||{};
  return {
    bridge:h.bridge||null, protocol:h.protocol??null, pid:h.pid??null, helperBundle:h.bundle||null,
    deploymentPolicy:h.deploymentPolicy||null, effectiveMode:h.effectiveMode||null,
    authorization:h.default?{loaded:h.loaded,apps:h.apps,default:h.default}:null,
    accessibility:h.accessibility||null, screenRecording:h.screenRecording||null,
    policy:state.policy||null, error:state.error||null, message:state.message||null,
    target:target?{bundle:target.bundle,pid:target.pid,snapshot:target.snapshot,windowId:target.windowId??null,window:target.window||null}:null
  };
}
export function pipPresentation(state,{sessionId,view,now=Date.now()}={}) {
  const base={visible:false,phase:'idle',status:'idle',tone:'muted',mode:'indicator',canRead:false,
    app:null,window:null,code:null,ageMs:null,frameAt:null,technical:null};
  if(!state||typeof state!=='object') return base;
  const own=!!view&&view.sessionId===sessionId;
  const activity=activityRevision(state);
  const mode=own&&view.mode!=='closed'?view.mode:'indicator';
  const phase=pipPhase(state,now);
  const closed=own&&view.mode==='closed'&&view.revision===activity;
  const target=state.target&&state.target.background===true?state.target:null;
  const grant=target?state.grants.find(g=>g.bundle===target.bundle&&g.scopes.includes('observe')):null;
  const verified=!!(target&&grant&&state.bridge==='compatible'&&['background','focus','unrestricted'].includes(state.policy));
  const freshness=verified?frameFreshness(state.frame,now):'none';
  const model={...base,phase,status:PHASE_STATUS[phase]||'idle',tone:PHASE_TONE[phase]||'muted',
    mode,code:state.error||null,technical:technicalFacts(state,target),
    frameAt:Number.isFinite(state.frame?.at)?state.frame.at:null,
    app:verified?grant.name:null,window:verified?target.window:null};
  // Nothing to supervise: no surface at all, whatever the phase says.
  if(!sessionId||activity<1||closed||phase==='idle') return model;
  // A phase that would show pixels or a name without current authority is demoted.
  if(!verified&&['frame-live','frame-stale','observed-no-frame','expired'].includes(phase))
    return {...model,visible:true,phase:'error',status:'error',tone:'error',app:null,window:null,technical:technicalFacts(state,null)};
  const pending=Object.values(state.pending||{}).at(-1)?.name;
  const busy=pending==='status'?'connecting':pending==='press'||pending==='set_value'?'interacting'
    :pending==='observe'||pending==='capture_window'?'observing':null;
  if(busy) model.status=busy;
  model.visible=true;
  const fresh=(phase==='frame-live'||phase==='frame-stale')&&freshness!=='none'&&freshness!=='expired';
  model.canRead=!!(verified&&fresh&&mode!=='indicator'&&!pending&&model.tone!=='error');
  model.ageMs=fresh?frameAge(state.frame,now):null;
  return model;
}

/** Public root hooks use the same mainView retention source as DSH's title.
 * Multiple retainers can coexist during navigation: reveal nothing in that gap. */
export function visibleSessionId(list,panel) {
  if(panel?.activePanelId!==null||!list?.byId)return null;
  const rows=Object.values(list.byId).filter(row=>row?.retainedBy?.mainView>0);
  return rows.length===1&&typeof rows[0].id==='string'&&rows[0].id ? rows[0].id : null;
}

/** Bounds from our own overlay and card only; no host DOM or composer inference. */
export const GUTTER = 16;
export function overlayPosition(position,frame,card) {
  const maxX=Math.max(GUTTER,frame.width-card.width-GUTTER),maxY=Math.max(GUTTER,frame.height-card.height-GUTTER);
  const minY=Math.min(68,maxY);
  return {x:Math.max(GUTTER,Math.min(maxX,position?.x??maxX)),
    y:Math.max(minY,Math.min(maxY,position?.y??minY))};
}
