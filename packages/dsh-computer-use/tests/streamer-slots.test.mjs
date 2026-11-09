// 0.3.3 streamer: two independent mirrors (slot A, slot B) against a scripted
// helper on a temporary Unix socket. Ephemeral HTTP port: never the production
// streamer's 47183. Pins: one helper stream per slot (stream_key), frames per
// stream id, stopping A never stops B, a third slot is refused, a failing
// slot recovers ITS stream only, and an older single-stream helper never has
// its one stream stolen by a second slot.
import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:net';
import {get} from 'node:http';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {runStreamer} from '../index.js';

// A 1x1 JPEG: enough bytes to be a frame.
const JPEG = Buffer.from('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==', 'base64').toString('base64');

function fakeHelper({multi = true, failOnce = null} = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'cmm-st-'));
  const path = join(dir, 'h.sock');
  const calls = [];
  const streams = new Map();
  let next = 0;
  const failed = new Set();
  const answer = (request) => {
    const args = request.arguments || {};
    calls.push({operation: request.operation, args});
    switch (request.operation) {
    case 'bridge.ping':
      return {bridge: 'cmm-computer-use', protocol: 1,
        capabilities: multi ? {window_stream: true, workspace: {max_streams: 2}} : {window_stream: true}};
    case 'observation.stream_start': {
      const id = 'str_' + (args.stream_key || 'legacy') + '_' + (++next);
      if (!multi) for (const key of streams.keys()) streams.delete(key);
      streams.set(id, {index: 0, key: args.stream_key || null});
      return {stream: 'started', stream_id: multi ? id : undefined, view_identity: {window_id: args.window_id || 1}};
    }
    case 'observation.stream_frame': {
      const id = args.stream_id || [...streams.keys()].at(-1);
      const stream = streams.get(id);
      if (!stream) return {error: {code: 'ACTION_FAILED', detail: 'stream_not_active'}};
      if (failOnce && stream.key === failOnce && !failed.has(id)) {
        failed.add(id);
        return {error: {code: 'ACTION_FAILED', detail: 'stream_error'}};
      }
      stream.index += 1;
      return {screenshot_base64: JPEG, media_type: 'image/jpeg', frame_index: stream.index, phase: 'live', stream_id: id};
    }
    case 'observation.stream_recover':
      return {recovered: true, stream_id: args.stream_id, phase: 'warming'};
    case 'observation.stream_stop':
      if (args.stream_id) streams.delete(args.stream_id);
      return {stopped: true, stream_id: args.stream_id || null};
    case 'observation.capture_screen':
      return {screenshot_base64: JPEG, media_type: 'image/jpeg'};
    default:
      return {error: {code: 'CAPABILITY_UNSUPPORTED'}};
    }
  };
  const server = createServer(socket => {
    let buffer = '';
    socket.on('data', chunk => {
      buffer += chunk;
      const newline = buffer.indexOf('\n');
      if (newline < 0) return;
      const request = JSON.parse(buffer.slice(0, newline));
      buffer = buffer.slice(newline + 1);
      const out = answer(request);
      const frame = out && out.error ? {version: 1, id: request.id, ok: false, error: out.error}
        : {version: 1, id: request.id, ok: true, result: out};
      socket.end(JSON.stringify(frame) + '\n');
    });
    socket.on('error', () => {});
  });
  return new Promise(resolve => server.listen(path, () => resolve({path, calls, streams,
    close: () => new Promise(done => server.close(() => { rmSync(dir, {recursive: true, force: true}); done(); }))})));
}

// The run's token per ephemeral port (each streamer draws its own).
const tokens = new Map();
async function streamer(socketPath) {
  const server = runStreamer(socketPath, 0);
  if (!server.listening) await new Promise(resolve => server.once('listening', resolve));
  const port = server.address().port;
  tokens.set(port, server.liveToken);
  assert.notEqual(port, 47183, 'never the production streamer port');
  return {port, close: () => new Promise(resolve => { server.closeAllConnections?.(); server.close(() => resolve()); })};
}

/** Open a mirror; resolves once `frames` frames arrived. Returns the request. */
function mirror(port, slot, frames = 2, extra = '') {
  return new Promise((resolve, reject) => {
    const url = `http://127.0.0.1:${port}/stream.mjpg?token=${tokens.get(port)}&app=App${slot}&window=W${slot}`
      + `&window_id=${slot === 'A' ? 11 : 12}${slot ? '&slot=' + slot : ''}&bundle=com.example.${slot}&pid=50${slot ? 1 : 0}${extra}`;
    const request = get(url, response => {
      if (response.statusCode !== 200) { resolve({status: response.statusCode, request}); response.resume(); return; }
      let seen = 0;
      response.on('data', chunk => {
        seen += (chunk.toString('latin1').match(/--cmmframe/g) || []).length;
        if (seen >= frames) resolve({status: 200, request, response});
      });
    });
    request.on('error', error => { if (error.code !== 'ECONNRESET') reject(error); });
  });
}

const status = (port, slot) => new Promise((resolve, reject) => {
  get(`http://127.0.0.1:${port}/stream/status?token=${tokens.get(port)}${slot ? '&slot=' + slot : ''}`, response => {
    let body = '';
    response.on('data', c => { body += c; });
    response.on('end', () => resolve(JSON.parse(body)));
  }).on('error', reject);
});
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));

test('two slots stream two windows independently; closing A leaves B live', async () => {
  const helper = await fakeHelper();
  const live = await streamer(helper.path);
  try {
    const a = await mirror(live.port, 'A');
    const b = await mirror(live.port, 'B');
    const starts = helper.calls.filter(c => c.operation === 'observation.stream_start');
    assert.deepEqual(starts.map(c => c.args.stream_key).sort(), ['A', 'B']);
    assert.equal(starts.find(c => c.args.stream_key === 'A').args.expected_bundle, 'com.example.A');
    assert.equal(starts.find(c => c.args.stream_key === 'A').args.expected_pid, 501);
    const [sa, sb] = [await status(live.port, 'A'), await status(live.port, 'B')];
    assert.notEqual(sa.stream_id, sb.stream_id);
    assert.ok(sa.frames >= 2 && sb.frames >= 2);
    a.request.destroy();
    await wait(300);
    const stops = helper.calls.filter(c => c.operation === 'observation.stream_stop');
    assert.deepEqual(stops.map(c => c.args.stream_id), [sa.stream_id], 'only A is stopped');
    const before = (await status(live.port, 'B')).frames;
    await wait(300);
    const after = await status(live.port, 'B');
    assert.ok(after.frames > before, 'B keeps delivering after A closed');
    assert.equal(after.phase, 'live');
    b.request.destroy();
  } finally {
    await live.close();
    await helper.close();
  }
});

test('a third slot is refused before the helper is asked', async () => {
  const helper = await fakeHelper();
  const live = await streamer(helper.path);
  try {
    const a = await mirror(live.port, 'A', 1);
    const b = await mirror(live.port, 'B', 1);
    const c = await mirror(live.port, 'C', 1);
    assert.equal(c.status, 429);
    assert.equal(helper.calls.filter(x => x.operation === 'observation.stream_start').length, 2);
    a.request.destroy(); b.request.destroy();
  } finally {
    await live.close();
    await helper.close();
  }
});

test('a failing slot recovers its own stream only', async () => {
  const helper = await fakeHelper({failOnce: 'A'});
  const live = await streamer(helper.path);
  try {
    const b = await mirror(live.port, 'B', 1);
    const a = await mirror(live.port, 'A', 2);
    const recovers = helper.calls.filter(x => x.operation === 'observation.stream_recover');
    const sa = await status(live.port, 'A'), sb = await status(live.port, 'B');
    assert.deepEqual(recovers.map(x => x.args.stream_id), [sa.stream_id]);
    assert.equal(sa.recoveries, 1);
    assert.equal(sb.recoveries, 0, 'B never recovered');
    assert.equal(helper.calls.filter(x => x.operation === 'observation.stream_stop').length, 0,
      'recovery restarts nothing else');
    a.request.destroy(); b.request.destroy();
  } finally {
    await live.close();
    await helper.close();
  }
});

test('an older single-stream helper keeps its one stream; the second slot falls back', async () => {
  const helper = await fakeHelper({multi: false});
  const live = await streamer(helper.path);
  try {
    const a = await mirror(live.port, 'A', 2);
    const b = await mirror(live.port, 'B', 1);
    const starts = helper.calls.filter(x => x.operation === 'observation.stream_start');
    assert.equal(starts.length, 1, 'B did not steal A\'s stream');
    assert.ok(!('stream_key' in starts[0].args), 'an old helper is not sent 0.3.3 arguments');
    assert.ok(helper.calls.some(x => x.operation === 'observation.capture_screen'), 'B mirrors by capture');
    assert.equal((await status(live.port, 'B')).mode, 'fallback');
    a.request.destroy(); b.request.destroy();
  } finally {
    await live.close();
    await helper.close();
  }
});

test('a 0.3.2 viewer (no slot) still gets the single mirror', async () => {
  const helper = await fakeHelper();
  const live = await streamer(helper.path);
  try {
    const v = await mirror(live.port, '', 2);
    assert.equal(v.status, 200);
    const start = helper.calls.find(x => x.operation === 'observation.stream_start');
    assert.ok(!('stream_key' in start.args));
    v.request.destroy();
  } finally {
    await live.close();
    await helper.close();
  }
});

test('backpressure is per viewer: a panel that stops reading never stalls the other', async () => {
  const helper = await fakeHelper();
  const live = await streamer(helper.path);
  try {
    const a = await mirror(live.port, 'A', 1);
    const b = await mirror(live.port, 'B', 1);
    // Panel A stops consuming: its socket buffers fill and its writes wait
    // for a drain that does not come.
    a.response.pause();
    a.request.socket.setRecvBufferSize?.(1024);
    await wait(600);
    const before = await status(live.port, 'B');
    await wait(600);
    const after = await status(live.port, 'B');
    assert.ok(after.frames > before.frames, 'B keeps flowing while A is stalled');
    assert.equal(after.phase, 'live');
    const idA = (await status(live.port, 'A')).stream_id;
    assert.ok(idA);
    a.request.destroy();
    await wait(400);
    // A's stream is released once its viewer is gone, even though it stalled;
    // B's is not.
    const stops = helper.calls.filter(x => x.operation === 'observation.stream_stop').map(x => x.args.stream_id);
    assert.deepEqual(stops, [idA]);
    b.request.destroy();
  } finally {
    await live.close();
    await helper.close();
  }
});

test('F-09: a title change on the same window id keeps the helper stream (tab switch)', async () => {
  const helper = await fakeHelper();
  const live = await streamer(helper.path);
  try {
    const a = await mirror(live.port, 'A', 1);
    // The same panel re-opened after a tab switch renamed the window.
    const renamed = await new Promise((resolve, reject) => {
      const request = get(`http://127.0.0.1:${live.port}/stream.mjpg?token=${tokens.get(live.port)}&app=AppA&window=Other%20page`
        + '&window_id=11&slot=A&bundle=com.example.A&pid=501', response => {
        response.once('data', () => resolve({request}));
      });
      request.on('error', error => { if (error.code !== 'ECONNRESET') reject(error); });
    });
    const starts = helper.calls.filter(c => c.operation === 'observation.stream_start');
    assert.equal(starts.length, 1, 'no second helper stream for the same window');
    assert.equal(helper.calls.filter(c => c.operation === 'observation.stream_stop').length, 0,
      'the running stream was not torn down');
    a.request.destroy(); renamed.request.destroy();
  } finally {
    await live.close();
    await helper.close();
  }
});
