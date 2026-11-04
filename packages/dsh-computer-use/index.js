import {KEY, MAX_LANES, initialState, fold, validAttachment, bypassReason} from './runtime.mjs';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {connect} from 'node:net';
import {randomBytes} from 'node:crypto';
import {homedir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
export const inject = ['sessionProjections', 'tools'];

// ── live window mirror ────────────────────────────────────────────────
// The panel must show what Computer Use is doing, not a still admitted by a
// tool result. A small loopback HTTP endpoint captures the ONE authorized
// window through the same bridge the adapter uses; the renderer polls it while
// the PiP is visible. The helper's own policy still decides what may be seen.
//
// The socket is the same one the MCP row uses, with the same precedence:
// `--socket` in argv (the streamer child), then the row's `config.socket`, then
// CMM_COMPUTER_BRIDGE_SOCKET, then the helper's default path.
function resolveSocket(configured) {
  const index = process.argv.indexOf('--socket');
  if (index >= 0 && process.argv[index + 1]) return process.argv[index + 1];
  const chosen = (typeof configured === 'string' && configured)
    || process.env.CMM_COMPUTER_BRIDGE_SOCKET
    || join(homedir(), '.cmm', 'computer-bridge', 'bridge.sock');
  return chosen.startsWith('~/') ? join(homedir(), chosen.slice(2)) : chosen;
}

// Fixed loopback endpoint. The helper's own policy still decides which single
// window may be captured; the token keeps other local processes out. A fixed
// port is deliberate: the renderer's URL is configuration, so it must not
// change between restarts of the same session projection.
const LIVE_PORT = 47183;
const LIVE_TOKEN = 'cmm-cu-live';
/** Concurrent mirrors (panel A and panel B), matching the helper's two streams. */
const MAX_SLOTS = 2;

// One request per connection, the same shape the adapter uses. The helper
// answers one line and the connection is done, so no state leaks between
// frames and a wedged call can be timed out without poisoning the mirror.
function bridgeCall(socket, operation, args, timeoutMs = 4000) {
  return new Promise((resolve, reject) => {
    const client = connect(socket);
    let buffer = '';
    const id = 'live-' + randomBytes(6).toString('hex');
    const finish = (error, value) => { client.destroy(); error ? reject(error) : resolve(value); };
    client.setTimeout(timeoutMs, () => finish(new Error('timeout')));
    client.on('error', finish);
    client.on('connect', () => client.write(JSON.stringify({
      version: 1, id, operation, arguments: args || {},
    }) + '\n'));
    client.on('data', chunk => {
      buffer += chunk;
      const newline = buffer.indexOf('\n');
      if (newline < 0) return;
      let message;
      try { message = JSON.parse(buffer.slice(0, newline)); } catch (error) { return finish(error); }
      if (message.id !== id) return;
      if (message.error) {
        const failure = new Error(message.error.code || 'refused');
        failure.code = message.error.code;
        failure.detail = message.error.detail;
        return finish(failure);
      }
      finish(null, message.result || {});
    });
  });
}

function captureOnce(socket, app, window) {
  return bridgeCall(socket, 'observation.capture_screen',
    {app, window_title: window, policy: 'background'})
    .then(result => {
      const encoded = result && result.screenshot_base64;
      if (!encoded) throw new Error('no image');
      return {
        bytes: Buffer.from(encoded, 'base64'),
        contentType: result.media_type || 'image/png',
      };
    });
}

function runStreamer(socket, port = LIVE_PORT) {
  const token = LIVE_TOKEN;
  let pending = null;
  // 0.3.3: up to MAX_SLOTS independent mirrors (panel A and panel B), each
  // with its own helper stream, counters, phase, viewers and recovery. A slot
  // is named by the panel (`slot=A`); no slot is the 0.3.2 single mirror.
  //
  // Honest liveness per slot. A multipart <img> never tells its host that the
  // stream stalled: it keeps the last decoded frame forever. These counters
  // are what lets each panel stop claiming "Live" over a frozen picture.
  const slots = new Map(); // slot -> {stats, live, transition}
  const slotOf = name => {
    let slot = slots.get(name);
    if (!slot) {
      slot = {stats: {frames: 0, lastFrameAt: 0, viewers: 0, mode: 'idle', error: null, windowId: null,
        phase: 'idle', streamId: null, frameIndex: null, recoveries: 0},
        live: null, transition: Promise.resolve()};
      slots.set(name, slot);
    }
    return slot;
  };
  const serialized = (slot, task) => {
    const run = slot.transition.then(task, task);
    slot.transition = run.catch(() => {});
    return run;
  };
  // Whether the helper keeps several streams (0.3.3 `capabilities.workspace`).
  // An older helper keeps ONE: a second slot then mirrors by capture polling
  // instead of stealing the first slot's stream.
  let multi = null;
  const helperIsMulti = async () => {
    if (multi !== null) return multi;
    try {
      const ping = await bridgeCall(socket, 'bridge.ping', {});
      multi = !!(ping && ping.capabilities && ping.capabilities.workspace);
    } catch { return false; }
    return multi;
  };
  const activeSlots = () => [...slots.values()].filter(slot => slot.live).length;

  const acquire = (name, slot, target) => serialized(slot, async () => {
    // A window id IS the window: a title change (tab switch, navigation) on
    // the same id must not restart its helper stream (F-09).
    const key = [target.app, target.windowId ? '' : target.window, target.windowId || '', target.bundle || '',
      target.pid || ''].join('\u0000');
    if (slot.live && slot.live.key === key) { slot.live.viewers += 1; slot.stats.viewers = slot.live.viewers; return slot.live; }
    if (slot.live) {
      const previous = slot.live;
      slot.live = null;
      await bridgeCall(socket, 'observation.stream_stop', previous.streamId ? {stream_id: previous.streamId} : {}).catch(() => {});
    }
    const isMulti = await helperIsMulti();
    if (name && !isMulti && activeSlots() > 0) {
      const failure = new Error('STREAM_LIMIT');
      failure.code = 'STREAM_LIMIT';
      failure.detail = 'helper_single_stream';
      throw failure;
    }
    const started = await bridgeCall(socket, 'observation.stream_start', {
      app: target.app, window_title: target.window,
      ...(target.windowId ? {window_id: target.windowId} : {}),
      ...(name && isMulti ? {stream_key: name} : {}),
      // The identity a verified observation produced: the helper checks it
      // before any surface opens, so a relaunched app is never mirrored as
      // the one the panel names.
      ...(isMulti && target.bundle ? {expected_bundle: target.bundle} : {}),
      ...(isMulti && target.pid ? {expected_pid: target.pid} : {}),
      policy: 'background',
    }, 15000);
    const identity = started.view_identity || {};
    slot.live = {key, windowId: identity.window_id === undefined ? null : identity.window_id,
      streamId: started.stream_id || null, viewers: 1};
    slot.stats.viewers = 1;
    slot.stats.windowId = slot.live.windowId;
    slot.stats.streamId = slot.live.streamId;
    return slot.live;
  });

  const release = (slot) => serialized(slot, async () => {
    if (!slot.live) return;
    slot.live.viewers -= 1;
    slot.stats.viewers = Math.max(0, slot.live.viewers);
    if (slot.live.viewers > 0) return;
    const streamId = slot.live.streamId;
    slot.live = null;
    slot.stats.windowId = null;
    slot.stats.streamId = null;
    slot.stats.mode = 'idle';
    slot.stats.phase = 'closed';
    await bridgeCall(socket, 'observation.stream_stop', streamId ? {stream_id: streamId} : {}).catch(() => {});
  });

  const write = (response, chunk) => new Promise(resolve => {
    if (response.write(chunk)) return resolve();
    // A closed viewer must not park this loop forever waiting for a drain
    // that will never come (backpressure is per viewer: one slow panel never
    // stalls the other slot).
    const done = () => {
      response.removeListener('drain', done);
      response.removeListener('close', done);
      resolve();
    };
    response.once('drain', done);
    response.once('close', done);
  });

  const writeFrame = async (slot, response, bytes, contentType) => {
    await write(response, '--cmmframe\r\nContent-Type: ' + contentType
      + '\r\nContent-Length: ' + bytes.length + '\r\n\r\n');
    await write(response, bytes);
    await write(response, '\r\n');
    slot.stats.frames += 1;
    slot.stats.lastFrameAt = Date.now();
    slot.stats.error = null;
  };

  // Live path: the helper streams the authorized window and this loop reads
  // its cached frame. A frame index that has not moved is not new output, so
  // it is not re-sent: the counted rate stays the real capture rate. The
  // helper's own phase (live / stale / error / recovering) is published as is.
  const liveFrames = async (name, slot, response, closed, target) => {
    const live = await acquire(name, slot, target);
    slot.stats.mode = 'live';
    let lastIndex = -1;
    let warming = 0;
    let recoverAfter = 0;
    try {
      while (!closed()) {
        let frame;
        try {
          frame = await bridgeCall(socket, 'observation.stream_frame',
            live.streamId ? {stream_id: live.streamId} : {policy: 'background'}, 5000);
          warming = 0;
        } catch (error) {
          // The stream answers no frame for one interval while it warms up.
          // That is the normal first instant, not a broken helper: wait for
          // it instead of dropping to the slow capture path for the session.
          if (error.detail === 'stream_warming' && warming < 50) {
            warming += 1;
            slot.stats.phase = 'warming';
            await new Promise(resolve => setTimeout(resolve, 40));
            continue;
          }
          // This slot's stream failed (window closed, capture stopped, stale):
          // recover THIS stream only, bounded by the helper's backoff. The
          // other slot is never touched.
          if (live.streamId && /^stream_(error|stale)$/.test(error.detail || '') && Date.now() >= recoverAfter) {
            slot.stats.phase = 'recovering';
            slot.stats.recoveries += 1;
            try {
              await bridgeCall(socket, 'observation.stream_recover', {stream_id: live.streamId}, 25000);
              continue;
            } catch (failure) {
              const wait = /retry_after_ms=(\d+)/.exec(failure.detail || '');
              recoverAfter = Date.now() + (wait ? Number(wait[1]) : 2000);
              if (failure.code === 'STREAM_RECOVERY_EXHAUSTED' || failure.code === 'STREAM_UNKNOWN') throw failure;
              slot.stats.phase = 'error';
              slot.stats.error = failure.code || 'recovery_failed';
              await new Promise(resolve => setTimeout(resolve, 250));
              continue;
            }
          }
          throw error;
        }
        if (closed()) break;
        slot.stats.phase = frame.phase || 'live';
        slot.stats.frameIndex = frame.frame_index === undefined ? null : frame.frame_index;
        const index = frame.frame_index === undefined ? -1 : frame.frame_index;
        if (index !== lastIndex) {
          lastIndex = index;
          const bytes = Buffer.from(frame.screenshot_base64 || '', 'base64');
          if (bytes.length) await writeFrame(slot, response, bytes, frame.media_type || 'image/jpeg');
        } else if (frame.phase === 'live' && frame.unchanged) {
          // Alive but unchanged: the helper saw idle buffers. The panel may
          // keep calling it live; the frame time stays the real one.
          slot.stats.unchangedAt = Date.now();
        }
        // Poll below the helper's 15 fps so every new frame is picked up with
        // at most one interval of latency and no busy-wait.
        await new Promise(resolve => setTimeout(resolve, 45));
      }
    } finally {
      await release(slot);
    }
  };

  // Fallback path: an older helper (no `window_stream` capability, no
  // `observation.stream_frame`) keeps the previous behaviour — one shot per
  // frame — so the mirror degrades instead of breaking. It is TIME-BOXED: a
  // transient start failure (the helper restarting, a start racing the previous
  // stream's teardown) must not park the mirror on the slow path for the whole
  // life of the connection.
  const pollFrames = async (slot, response, closed, app, window, budgetMs) => {
    slot.stats.mode = 'fallback';
    slot.stats.phase = 'fallback';
    const until = Date.now() + budgetMs;
    while (!closed() && Date.now() < until) {
      try {
        const {bytes, contentType} = await captureOnce(socket, app, window);
        if (closed()) break;
        await writeFrame(slot, response, bytes, contentType);
      } catch {}
      await new Promise(resolve => setTimeout(resolve, 120));
    }
  };

  const slotName = url => {
    const raw = url.searchParams.get('slot');
    return raw && /^[A-D]$/.test(raw) ? raw : '';
  };

  const server = createServer(async (request, response) => {
    const url = new URL(request.url || '/', 'http://127.0.0.1');
    const headers = {'Cache-Control': 'no-store', 'Access-Control-Allow-Origin': '*'};
    if (url.pathname === '/stream.mjpg') {
      if (url.searchParams.get('token') !== token) { response.writeHead(403, headers).end(); return; }
      const name = slotName(url);
      // Two mirrors at once, never a third: the helper refuses a third stream
      // and this endpoint refuses a third slot before asking it.
      if (name && !slots.has(name) && slots.size >= MAX_SLOTS) {
        response.writeHead(429, headers).end('STREAM_LIMIT');
        return;
      }
      const slot = slotOf(name);
      // Continuous multipart stream for the viewer: the element never reloads.
      // Frames come from the helper's SCStream cache, so the rate is the
      // window's real capture rate instead of one capture round trip per frame.
      response.writeHead(200, {...headers, 'Content-Type': 'multipart/x-mixed-replace; boundary=cmmframe'});
      const target = {
        app: url.searchParams.get('app') || '',
        window: url.searchParams.get('window') || '',
        windowId: Number(url.searchParams.get('window_id')) || null,
        bundle: url.searchParams.get('bundle') || '',
        pid: Number(url.searchParams.get('pid')) || null,
      };
      let shut = false;
      request.on('close', () => { shut = true; });
      const closed = () => shut || response.writableEnded;
      // Supervised: the live stream is the path, the capture loop is the
      // fallback. Each failure buys a longer stretch of fallback and then the
      // live path is tried again, so a helper restart heals the viewer instead
      // of leaving it at ~4 fps until the panel is reopened.
      let failures = 0;
      while (!closed()) {
        try {
          await liveFrames(name, slot, response, closed, target);
          break;
        } catch (error) {
          failures += 1;
          slot.stats.error = (error && (error.code || error.message)) || 'stream_failed';
          slot.stats.phase = 'error';
          // A helper restart forgets every stream: re-learn its capability.
          multi = null;
        }
        if (closed()) break;
        await pollFrames(slot, response, closed, target.app, target.window, Math.min(30000, 6000 * failures));
      }
      response.end();
      return;
    }
    if (url.pathname === '/stream/status') {
      // Liveness for the viewer only: counters and the last frame time, never
      // pixels and never a helper request of its own.
      if (url.searchParams.get('token') !== token) { response.writeHead(403, headers).end(); return; }
      const stats = (slots.get(slotName(url)) || {stats: {frames: 0, lastFrameAt: 0, viewers: 0, mode: 'idle',
        error: null, windowId: null, phase: 'idle'}}).stats;
      const body = JSON.stringify({ok: true, slot: slotName(url) || null, frames: stats.frames,
        lastFrameAt: stats.lastFrameAt, viewers: stats.viewers, mode: stats.mode, error: stats.error,
        window_id: stats.windowId, phase: stats.phase || null, stream_id: stats.streamId || null,
        frame_index: stats.frameIndex ?? null, recoveries: stats.recoveries || 0, now: Date.now()});
      response.writeHead(200, {...headers, 'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body)});
      response.end(body);
      return;
    }
    if (url.pathname !== '/frame.png') { response.writeHead(404, headers).end(); return; }
    if (url.searchParams.get('token') !== token) { response.writeHead(403, headers).end(); return; }
    try {
      // Coalesce: a slow capture must not turn parallel polls into 429s, which
      // the renderer would see as a broken stream and stop showing the mirror.
      if (!pending) {
        pending = captureOnce(socket, url.searchParams.get('app') || '',
          url.searchParams.get('window') || '').finally(() => { pending = null; });
      }
      const {bytes, contentType} = await pending;
      response.writeHead(200, {...headers, 'Content-Type': contentType, 'Content-Length': bytes.length});
      response.end(bytes);
    } catch (error) {
      response.writeHead(503, headers).end(String((error && error.message) || error));
    }
  });
  server.listen(port, '127.0.0.1', () => process.stdout.write('READY ' + server.address().port + '\n'));
  const stopAll = () => Promise.all([...slots.values()].filter(slot => slot.live).map(slot =>
    bridgeCall(socket, 'observation.stream_stop', slot.live.streamId ? {stream_id: slot.live.streamId} : {})
      .catch(() => {})));
  process.on('SIGTERM', () => {
    const done = () => { server.close(); process.exit(0); };
    stopAll().then(done, done);
    setTimeout(done, 1500).unref();
  });
  return server;
}

if (process.argv.includes('--stream')) {
  // `--port` exists for isolated tests only: production keeps LIVE_PORT,
  // which is configuration the renderer's URL depends on.
  const portIndex = process.argv.indexOf('--port');
  const port = portIndex >= 0 ? Number(process.argv[portIndex + 1]) : LIVE_PORT;
  runStreamer(resolveSocket(''), Number.isSafeInteger(port) && port >= 0 && port < 65536 ? port : LIVE_PORT);
}
export {runStreamer};

const isToken = x => x === null || (typeof x === 'string' && x.length <= 200);
const isCount = x => x === null || (Number.isSafeInteger(x) && x >= 0);
/** Helper facts are a closed record: known keys, bounded scalars, nothing else. */
function validHelper(h) {
  if (h === null) return true;
  if (!h || typeof h !== 'object' || Array.isArray(h)) return false;
  const keys = ['bridge','protocol','pid','bundle','deploymentPolicy','accessibility',
    'screenRecording','loaded','apps','default','effectiveMode'];
  if (Object.keys(h).some(k => !keys.includes(k))) return false;
  return ['bridge','bundle','deploymentPolicy','effectiveMode','default'].every(k => isToken(h[k] === undefined ? null : h[k]))
    && ['protocol','pid','apps'].every(k => isCount(h[k] === undefined ? null : h[k]))
    && ['accessibility','screenRecording'].every(k => h[k] === null
      || h[k] === 'True' || h[k] === 'False')
    && (h.loaded === null || typeof h.loaded === 'boolean');
}
function validAttempt(a) {
  if (a === null) return true;
  return !!a && typeof a === 'object' && !Array.isArray(a)
    && typeof a.name === 'string' && a.name.length <= 32
    && Number.isSafeInteger(a.at) && a.at >= 0
    && typeof a.failed === 'boolean' && isToken(a.code === undefined ? null : a.code);
}
/** 0.3.3 lanes: at most MAX_LANES panels, keyed by context id, closed shape. */
function validLanes(lanes, revision) {
  if (!lanes || typeof lanes !== 'object' || Array.isArray(lanes)) return false;
  const entries = Object.entries(lanes);
  if (entries.length > MAX_LANES) return false;
  const keys = ['label','target','frame','error','message','attempt','ledger','guiRevision','attemptRevision','lastCall'];
  return entries.every(([id, lane]) => /^ctx_[0-9a-f]{32}$/.test(id)
    && lane && typeof lane === 'object' && !Array.isArray(lane)
    && Object.keys(lane).every(k => keys.includes(k))
    && (lane.label === null || (typeof lane.label === 'string' && /^[A-D]$/.test(lane.label)))
    && ['guiRevision','attemptRevision','lastCall'].every(k => Number.isSafeInteger(lane[k]) && lane[k] >= 0)
    && lane.guiRevision <= revision && lane.lastCall <= revision
    && (lane.target === null || (typeof lane.target === 'object' && !Array.isArray(lane.target)))
    && isToken(lane.error === undefined ? null : lane.error)
    && isToken(lane.message === undefined ? null : lane.message)
    && validAttempt(lane.attempt === undefined ? null : lane.attempt)
    && (!lane.frame || validAttachment(lane.frame.attachment)));
}
// The installed registry consumes schema.parse on checkpoints and wire values.
// This bounded parser also rejects foreign/corrupt checkpoint shapes.
export const stateSchema = {parse(value) {
  if (!value || !['disconnected','compatible','denied','incompatible'].includes(value.bridge)
      || !Array.isArray(value.grants) || value.grants.length>20
      || !Number.isSafeInteger(value.guiRevision) || value.guiRevision<0 || value.guiRevision>value.revision
      || !Number.isSafeInteger(value.attemptRevision) || value.attemptRevision<0 || value.attemptRevision>value.revision
      || !Number.isSafeInteger(value.revision) || value.revision<0
      || Object.values(value.pending||{}).some(call=>!Number.isSafeInteger(call.revision)||call.revision<1||call.revision>value.revision)
      || typeof value.active!=='boolean' || typeof value.breach!=='boolean' || !value.pending
      || Object.keys(value.pending).length>32 || JSON.stringify(value).length>32768
      || !isToken(value.message === undefined ? null : value.message)
      || !validHelper(value.helper === undefined ? null : value.helper)
      || !validAttempt(value.attempt === undefined ? null : value.attempt)
      || (value.frame && !validAttachment(value.frame.attachment))
      || (value.lanes !== undefined && !validLanes(value.lanes, value.revision))) throw new Error('Invalid CMM panel checkpoint');
  return value;
}};
export function apply(ctx, config) {
  let live = null;
  let child = null;
  const socket = resolveSocket(config && config.socket);
  const startStreamer = () => {
    if (child) return;
    try {
      child = spawn(process.execPath, [fileURLToPath(import.meta.url), '--stream', '--socket', socket], {
        env: {...process.env, ELECTRON_RUN_AS_NODE: '1'},
        stdio: ['ignore', 'pipe', 'ignore'],
      });
    } catch { child = null; return; }
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', text => {
      const match = /READY (\d+)/.exec(text);
      if (match && !live) live = {port: LIVE_PORT, token: LIVE_TOKEN};
    });
    child.on('exit', () => { child = null; live = null; });
  };
  startStreamer();
  // 10: fold learned `scroll`, window-raised and helper-latch breaches.
  // 11: USER_TAKEOVER (the person took focus) drops the target without a
  // breach. 12: `released` / `stale_snapshot` refusals are named. 13: 0.3.3
  // lanes (one panel per context, two at most) and targets verified from the
  // facts an observation carries. Rebuild checkpoints from the log so resumed
  // sessions apply them.
  ctx.sessionProjections.register({key:KEY,stateVersion:13,stateSchema,
    init:initialState,apply:fold,
    wire:{viewSchema:stateSchema,view:state=>state}});
  if (typeof ctx.effect === 'function') {
    ctx.effect(() => () => { try { child && child.kill('SIGTERM'); } catch {} child = null; live = null; });
  }
  // Monotonic refusal after a verified helper breach in this session, including
  // a resumed log. No stop button: this does not cancel an in-flight tool.
  ctx.tools.guard(exec => {
    if (!exec || typeof exec.name !== 'string' || !exec.agent) return;
    const state=ctx.sessionProjections.stateOf(exec.agent.session,KEY);
    if (exec.name.startsWith('mcp__cmm-computer-use__')) {
      if(state?.breach) return 'CMM: verified breach; further Computer Use calls denied in this session.';
      return;
    }
    // A session that is doing Computer Use must not fill a capability gap with
    // its own automation (Bash/osascript/JXA/Swift/CGEvent/System Events/...).
    // Scoped to sessions that called a computer_use_* tool, so ordinary coding
    // sessions are untouched.
    if(!state || !(state.revision>0)) return;
    const reason=bypassReason(exec);
    if(reason) return `CMM: ${reason} is not an allowed route in a Computer Use session. Use computer_use_* tools only; if they cannot do it, report CAPABILITY_UNSUPPORTED to the person.`;
  });
}
