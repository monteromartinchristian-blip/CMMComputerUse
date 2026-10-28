import {KEY, initialState, fold, validAttachment} from './runtime.mjs';
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

function runStreamer(socket) {
  const token = LIVE_TOKEN;
  let pending = null;
  // Honest liveness for the viewer. A multipart <img> never tells its host that
  // the stream stalled: it keeps the last decoded frame forever. These counters
  // are what lets the PiP stop claiming "Live" over a frozen picture.
  const stats = {frames: 0, lastFrameAt: 0, viewers: 0, mode: 'idle', error: null, windowId: null};
  const state = phase => { stats.mode = phase; };

  // ONE stream per helper, shared by every viewer. The helper keeps a single
  // SCStream open (a second start replaces the first), so two viewers — the
  // PiP and a measurement on curl — must share it instead of fighting over it.
  let live = null; // {key, windowId, viewers}
  let transition = Promise.resolve();
  const serialized = task => {
    const run = transition.then(task, task);
    transition = run.catch(() => {});
    return run;
  };

  const acquire = (app, window, windowId) => serialized(async () => {
    const key = [app, window, windowId || ''].join('\u0000');
    if (live && live.key === key) { live.viewers += 1; stats.viewers = live.viewers; return live; }
    if (live) {
      const previous = live;
      live = null;
      await bridgeCall(socket, 'observation.stream_stop', {}).catch(() => {});
      previous.viewers = 0;
    }
    const started = await bridgeCall(socket, 'observation.stream_start', {
      app, window_title: window,
      ...(windowId ? {window_id: windowId} : {}),
      policy: 'background',
    }, 15000);
    const identity = started.view_identity || {};
    live = {key, windowId: identity.window_id === undefined ? null : identity.window_id, viewers: 1};
    stats.viewers = live.viewers;
    stats.windowId = live.windowId;
    return live;
  });

  const release = () => serialized(async () => {
    if (!live) return;
    live.viewers -= 1;
    stats.viewers = Math.max(0, live.viewers);
    if (live.viewers > 0) return;
    live = null;
    stats.windowId = null;
    state('idle');
    await bridgeCall(socket, 'observation.stream_stop', {}).catch(() => {});
  });

  const write = (response, chunk) => new Promise(resolve => {
    if (response.write(chunk)) return resolve();
    // A closed viewer must not park this loop forever waiting for a drain
    // that will never come.
    const done = () => {
      response.removeListener('drain', done);
      response.removeListener('close', done);
      resolve();
    };
    response.once('drain', done);
    response.once('close', done);
  });

  const writeFrame = async (response, bytes, contentType) => {
    await write(response, '--cmmframe\r\nContent-Type: ' + contentType
      + '\r\nContent-Length: ' + bytes.length + '\r\n\r\n');
    await write(response, bytes);
    await write(response, '\r\n');
    stats.frames += 1;
    stats.lastFrameAt = Date.now();
    stats.error = null;
  };

  // Live path: the helper streams the authorized window and this loop reads
  // its cached frame. A frame index that has not moved is not new output, so
  // it is not re-sent: the counted rate stays the real capture rate.
  const liveFrames = async (response, closed, app, window, windowId) => {
    await acquire(app, window, windowId);
    state('live');
    let lastIndex = -1;
    let warming = 0;
    try {
      while (!closed()) {
        let frame;
        try {
          frame = await bridgeCall(socket, 'observation.stream_frame',
            {policy: 'background'}, 5000);
          warming = 0;
        } catch (error) {
          // The stream answers no frame for one interval while it warms up.
          // That is the normal first instant, not a broken helper: wait for
          // it instead of dropping to the slow capture path for the session.
          if (error.detail === 'stream_warming' && warming < 50) {
            warming += 1;
            await new Promise(resolve => setTimeout(resolve, 40));
            continue;
          }
          throw error;
        }
        if (closed()) break;
        const index = frame.frame_index === undefined ? -1 : frame.frame_index;
        if (index !== lastIndex) {
          lastIndex = index;
          const bytes = Buffer.from(frame.screenshot_base64 || '', 'base64');
          if (bytes.length) await writeFrame(response, bytes, frame.media_type || 'image/jpeg');
        }
        // Poll below the helper's 15 fps so every new frame is picked up with
        // at most one interval of latency and no busy-wait.
        await new Promise(resolve => setTimeout(resolve, 45));
      }
    } finally {
      await release();
    }
  };

  // Fallback path: an older helper (no `window_stream` capability, no
  // `observation.stream_frame`) keeps the previous behaviour — one shot per
  // frame — so the mirror degrades instead of breaking. It is TIME-BOXED: a
  // transient start failure (the helper restarting, a start racing the previous
  // stream's teardown) must not park the mirror on the slow path for the whole
  // life of the connection.
  const pollFrames = async (response, closed, app, window, budgetMs) => {
    state('fallback');
    const until = Date.now() + budgetMs;
    while (!closed() && Date.now() < until) {
      try {
        const {bytes, contentType} = await captureOnce(socket, app, window);
        if (closed()) break;
        await writeFrame(response, bytes, contentType);
      } catch {}
      await new Promise(resolve => setTimeout(resolve, 120));
    }
  };

  const server = createServer(async (request, response) => {
    const url = new URL(request.url || '/', 'http://127.0.0.1');
    const headers = {'Cache-Control': 'no-store', 'Access-Control-Allow-Origin': '*'};
    if (url.pathname === '/stream.mjpg') {
      if (url.searchParams.get('token') !== token) { response.writeHead(403, headers).end(); return; }
      // Continuous multipart stream for the viewer: the element never reloads.
      // Frames come from the helper's SCStream cache, so the rate is the
      // window's real capture rate instead of one capture round trip per frame.
      response.writeHead(200, {...headers, 'Content-Type': 'multipart/x-mixed-replace; boundary=cmmframe'});
      const app = url.searchParams.get('app') || '';
      const window = url.searchParams.get('window') || '';
      const windowId = Number(url.searchParams.get('window_id')) || null;
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
          await liveFrames(response, closed, app, window, windowId);
          break;
        } catch (error) {
          failures += 1;
          stats.error = (error && (error.code || error.message)) || 'stream_failed';
        }
        if (closed()) break;
        await pollFrames(response, closed, app, window, Math.min(30000, 6000 * failures));
      }
      response.end();
      return;
    }
    if (url.pathname === '/stream/status') {
      // Liveness for the viewer only: counters and the last frame time, never
      // pixels and never a helper request of its own.
      if (url.searchParams.get('token') !== token) { response.writeHead(403, headers).end(); return; }
      const body = JSON.stringify({ok: true, frames: stats.frames, lastFrameAt: stats.lastFrameAt,
        viewers: stats.viewers, mode: stats.mode, error: stats.error, window_id: stats.windowId,
        now: Date.now()});
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
  server.listen(LIVE_PORT, '127.0.0.1', () => process.stdout.write('READY ' + LIVE_PORT + '\n'));
  process.on('SIGTERM', () => {
    const done = () => { server.close(); process.exit(0); };
    bridgeCall(socket, 'observation.stream_stop', {}).then(done, done);
    setTimeout(done, 1500).unref();
  });
}

if (process.argv.includes('--stream')) {
  runStreamer(resolveSocket(''));
}

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
      || (value.frame && !validAttachment(value.frame.attachment))) throw new Error('Invalid CMM panel checkpoint');
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
  ctx.sessionProjections.register({key:KEY,stateVersion:8,stateSchema,
    init:initialState,apply:fold,
    wire:{viewSchema:stateSchema,view:state=>state}});
  if (typeof ctx.effect === 'function') {
    ctx.effect(() => () => { try { child && child.kill('SIGTERM'); } catch {} child = null; live = null; });
  }
  // Monotonic refusal after a verified helper breach in this session, including
  // a resumed log. No stop button: this does not cancel an in-flight tool.
  ctx.tools.guard(exec => {
    if (!exec.name.startsWith('mcp__cmm-computer-use__') || !exec.agent) return;
    const state=ctx.sessionProjections.stateOf(exec.agent.session,KEY);
    if(state?.breach) return 'CMM: verified breach; further Computer Use calls denied in this session.';
  });
}
