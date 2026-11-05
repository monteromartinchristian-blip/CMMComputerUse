// Audit X-01, B-12, B-13 and the /frame.png coalescing finding, against a
// scripted helper on a temporary Unix socket and an ephemeral HTTP port (never
// the production streamer's 47183).
//   X-01  no wildcard CORS; Host must be loopback+port (DNS rebinding); an
//         Origin must be the DSH renderer's dsh-app: scheme; the token stays
//         required.
//   B-12  panels that closed never block the next one (the default panel plus
//         A, closed, must not leave B at 429 for ever); two OPEN mirrors still
//         refuse a third.
//   B-13  a viewer whose target was replaced by another viewer of the same slot
//         must not take a viewer (or the stream) away from the replacement.
//   frame.png  a capture in flight for one window is never the answer to a
//         request for another.
import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:net';
import {request as httpRequest} from 'node:http';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {runStreamer, requestGuard} from '../index.js';

const JPEG = Buffer.from('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==', 'base64').toString('base64');

function fakeHelper({captureDelay = 0} = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'cmm-sh-'));
  const path = join(dir, 'h.sock');
  const calls = [];
  const streams = new Map();
  let next = 0;
  const answer = async request => {
    const args = request.arguments || {};
    calls.push({operation: request.operation, args});
    switch (request.operation) {
    case 'bridge.ping':
      return {bridge: 'cmm-computer-use', protocol: 1, capabilities: {window_stream: true, workspace: {max_streams: 2}}};
    case 'observation.stream_start': {
      const id = 'str_' + (args.stream_key || 'legacy') + '_' + (++next);
      streams.set(id, {index: 0, windowId: args.window_id || null});
      return {stream: 'started', stream_id: id, view_identity: {window_id: args.window_id || 1}};
    }
    case 'observation.stream_frame': {
      const stream = streams.get(args.stream_id);
      if (!stream) return {error: {code: 'ACTION_FAILED', detail: 'stream_not_active'}};
      stream.index += 1;
      return {screenshot_base64: JPEG, media_type: 'image/jpeg', frame_index: stream.index, phase: 'live', stream_id: args.stream_id};
    }
    case 'observation.stream_stop':
      if (args.stream_id) streams.delete(args.stream_id);
      return {stopped: true, stream_id: args.stream_id || null};
    case 'observation.capture_screen':
      if (captureDelay) await new Promise(resolve => setTimeout(resolve, captureDelay));
      return {screenshot_base64: JPEG, media_type: 'image/jpeg', title_asked: args.window_title};
    default:
      return {error: {code: 'CAPABILITY_UNSUPPORTED'}};
    }
  };
  const server = createServer(socket => {
    let buffer = '';
    socket.on('data', async chunk => {
      buffer += chunk;
      const newline = buffer.indexOf('\n');
      if (newline < 0) return;
      const request = JSON.parse(buffer.slice(0, newline));
      buffer = buffer.slice(newline + 1);
      const out = await answer(request);
      const frame = out && out.error ? {version: 1, id: request.id, ok: false, error: out.error}
        : {version: 1, id: request.id, ok: true, result: out};
      socket.end(JSON.stringify(frame) + '\n');
    });
    socket.on('error', () => {});
  });
  return new Promise(resolve => server.listen(path, () => resolve({path, calls, streams,
    close: () => new Promise(done => server.close(() => { rmSync(dir, {recursive: true, force: true}); done(); }))})));
}

async function streamer(socketPath) {
  const server = runStreamer(socketPath, 0);
  if (!server.listening) await new Promise(resolve => server.once('listening', resolve));
  const port = server.address().port;
  assert.notEqual(port, 47183);
  return {port, close: () => new Promise(resolve => { server.closeAllConnections?.(); server.close(() => resolve()); })};
}

/** One HTTP request with chosen headers; resolves {status, headers, body}. */
function fetchRaw(port, path, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = httpRequest({host: '127.0.0.1', port, path, method: 'GET', headers}, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks)}));
    });
    req.on('error', reject);
    req.end();
  });
}

/** Open a mirror and keep it open; resolves once the first frame arrived. */
function openMirror(port, query) {
  return new Promise((resolve, reject) => {
    const req = httpRequest({host: '127.0.0.1', port, path: '/stream.mjpg?token=cmm-cu-live&' + query}, response => {
      if (response.statusCode !== 200) { response.resume(); resolve({status: response.statusCode, close: () => req.destroy()}); return; }
      response.once('data', () => resolve({status: 200, close: () => req.destroy()}));
    });
    req.on('error', () => {});
    req.on('close', () => {});
    req.end();
    setTimeout(() => reject(new Error('no frame')), 5000).unref();
  });
}

const settle = ms => new Promise(resolve => setTimeout(resolve, ms));

// ── X-01 ────────────────────────────────────────────────────────────────

test('X-01: the guard accepts only loopback Host with the streamer port and a dsh-app: Origin', () => {
  const ask = (headers) => requestGuard({headers}, 5000);
  assert.equal(ask({host: '127.0.0.1:5000'}).ok, true);
  assert.deepEqual(ask({host: '127.0.0.1:5000'}).headers, {}, 'no Origin: not a CORS request, no CORS header');
  assert.equal(ask({host: 'localhost:5000'}).ok, true);
  assert.equal(ask({host: 'evil.example:5000'}).ok, false, 'DNS rebinding');
  assert.equal(ask({host: '127.0.0.1:5001'}).ok, false);
  assert.equal(ask({}).ok, false);
  assert.equal(ask({host: '127.0.0.1:5000', origin: 'https://evil.example'}).ok, false);
  assert.equal(ask({host: '127.0.0.1:5000', origin: 'null'}).ok, false);
  assert.equal(ask({host: '127.0.0.1:5000', origin: 'http://127.0.0.1:5000'}).ok, false);
  const ok = ask({host: '127.0.0.1:5000', origin: 'dsh-app://app'});
  assert.equal(ok.ok, true);
  assert.equal(ok.headers['Access-Control-Allow-Origin'], 'dsh-app://app', 'granted to that origin, never a wildcard');
  assert.equal(ok.headers.Vary, 'Origin');
});

test('X-01: over HTTP a web origin is refused, the renderer origin is served, no wildcard anywhere', async () => {
  const helper = await fakeHelper();
  const s = await streamer(helper.path);
  try {
    const status = '/stream/status?token=cmm-cu-live&slot=A';
    const web = await fetchRaw(s.port, status, {Origin: 'https://evil.example'});
    assert.equal(web.status, 403);
    assert.equal(web.headers['access-control-allow-origin'], undefined);
    const rebinding = await fetchRaw(s.port, status, {Host: 'evil.example:' + s.port});
    assert.equal(rebinding.status, 403);
    const app = await fetchRaw(s.port, status, {Origin: 'dsh-app://app'});
    assert.equal(app.status, 200);
    assert.equal(app.headers['access-control-allow-origin'], 'dsh-app://app');
    assert.equal(JSON.parse(app.body).ok, true);
    const bare = await fetchRaw(s.port, status);
    assert.equal(bare.status, 200);
    assert.equal(bare.headers['access-control-allow-origin'], undefined, 'never "*"');
    const noToken = await fetchRaw(s.port, '/stream/status?slot=A', {Origin: 'dsh-app://app'});
    assert.equal(noToken.status, 403, 'the token is still required');
    // A refused request must not have reached the helper at all.
    const refusedFrame = await fetchRaw(s.port, '/frame.png?token=cmm-cu-live&app=X&window=Y', {Origin: 'https://evil.example'});
    assert.equal(refusedFrame.status, 403);
    assert.equal(helper.calls.filter(call => call.operation === 'observation.capture_screen').length, 0);
  } finally { await s.close(); await helper.close(); }
});

// ── B-12 ────────────────────────────────────────────────────────────────

test('B-12: closed panels never block the next one; two OPEN mirrors still refuse a third', async () => {
  const helper = await fakeHelper();
  const s = await streamer(helper.path);
  try {
    const base = (name, window) => `app=App&window=W${window}&window_id=${window}${name ? '&slot=' + name : ''}`;
    const fallback = await openMirror(s.port, base('', 10));
    const a = await openMirror(s.port, base('A', 11));
    assert.equal(fallback.status, 200);
    assert.equal(a.status, 200);
    const blocked = await openMirror(s.port, base('B', 12));
    assert.equal(blocked.status, 429, 'default + A are open: B is the third');
    fallback.close();
    a.close();
    await settle(400);
    const b = await openMirror(s.port, base('B', 12));
    assert.equal(b.status, 200, 'B after the default panel and A closed (it used to be 429 for ever)');
    const c = await openMirror(s.port, base('C', 13));
    assert.equal(c.status, 200);
    const d = await openMirror(s.port, base('D', 14));
    assert.equal(d.status, 429, 'two open mirrors: a third is refused');
    b.close();
    c.close();
  } finally { await s.close(); await helper.close(); }
});

// ── B-13 ────────────────────────────────────────────────────────────────

test('B-13: a replaced viewer leaving does not stop the replacement\'s stream', async () => {
  const helper = await fakeHelper();
  const s = await streamer(helper.path);
  try {
    const first = await openMirror(s.port, 'app=App&window=W1&window_id=11&slot=A&bundle=com.example.a&pid=501');
    const second = await openMirror(s.port, 'app=App&window=W2&window_id=12&slot=A&bundle=com.example.a&pid=501');
    assert.equal(first.status, 200);
    assert.equal(second.status, 200);
    await settle(300);
    const live = [...helper.streams.values()].filter(stream => stream.windowId === 12);
    assert.equal(live.length, 1, 'the replacement has its helper stream');
    first.close();
    await settle(500);
    assert.equal([...helper.streams.values()].filter(stream => stream.windowId === 12).length, 1,
      'the replaced viewer leaving must not stop the replacement\'s stream');
    const status = JSON.parse((await fetchRaw(s.port, '/stream/status?token=cmm-cu-live&slot=A')).body);
    assert.equal(status.viewers, 1, 'one viewer left on the slot');
    second.close();
    await settle(400);
    assert.equal(helper.streams.size, 0, 'the last viewer leaving stops the stream');
  } finally { await s.close(); await helper.close(); }
});

// ── frame.png ───────────────────────────────────────────────────────────

test('frame.png: concurrent requests for two windows each capture their own window', async () => {
  const helper = await fakeHelper({captureDelay: 250});
  const s = await streamer(helper.path);
  try {
    const [one, two] = await Promise.all([
      fetchRaw(s.port, '/frame.png?token=cmm-cu-live&app=AppA&window=Alpha'),
      fetchRaw(s.port, '/frame.png?token=cmm-cu-live&app=AppB&window=Beta'),
    ]);
    assert.equal(one.status, 200);
    assert.equal(two.status, 200);
    const asked = helper.calls.filter(call => call.operation === 'observation.capture_screen')
      .map(call => call.args.window_title).sort();
    assert.deepEqual(asked, ['Alpha', 'Beta'], 'each window is captured on its own');
    const same = await Promise.all([
      fetchRaw(s.port, '/frame.png?token=cmm-cu-live&app=AppA&window=Alpha'),
      fetchRaw(s.port, '/frame.png?token=cmm-cu-live&app=AppA&window=Alpha'),
    ]);
    assert.equal(same.every(response => response.status === 200), true);
    const alphaCalls = helper.calls.filter(call => call.operation === 'observation.capture_screen'
      && call.args.window_title === 'Alpha').length;
    assert.equal(alphaCalls, 2, 'the same window is still coalesced (one more capture for two requests)');
  } finally { await s.close(); await helper.close(); }
});
