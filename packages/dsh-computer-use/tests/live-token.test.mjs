// Audit X-01, second half: the PiP streamer's token is a per-start secret, not a
// public literal. Pins:
//   * no fixed token anywhere in what is distributed (source, renderer, dist);
//   * every streamer instance draws its own random token; a request with no
//     token, a wrong one, a wrong-length one or a foreign Origin never reads
//     /stream.mjpg, /frame.png or /stream/status, whatever else it sends;
//   * the Host hands the token to the streamer through its stdin (not argv or
//     env, which any process of the same user can read) and to the renderer
//     through the session projection's *view* (never the persisted state);
//   * the renderer builds its URL from that view and has none without it;
//   * the streamer listens on loopback only.
import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:net';
import {request as httpRequest} from 'node:http';
import {spawn} from 'node:child_process';
import {mkdtempSync, readFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {runStreamer, apply, newLiveToken, isLiveToken} from '../index.js';
import {initialState} from '../runtime.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const JPEG = Buffer.from('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==', 'base64').toString('base64');

function fakeHelper() {
  const dir = mkdtempSync(join(tmpdir(), 'cmm-tok-'));
  const path = join(dir, 'h.sock');
  const server = createServer(socket => {
    let buffer = '';
    socket.on('data', chunk => {
      buffer += chunk;
      const newline = buffer.indexOf('\n');
      if (newline < 0) return;
      const request = JSON.parse(buffer.slice(0, newline));
      const op = request.operation;
      const result = op === 'bridge.ping'
        ? {bridge: 'cmm-computer-use', protocol: 1, capabilities: {window_stream: true, workspace: {max_streams: 2}}}
        : op === 'observation.stream_start' ? {stream: 'started', stream_id: 'str_1', view_identity: {window_id: 1}}
        : op === 'observation.stream_frame' ? {screenshot_base64: JPEG, media_type: 'image/jpeg', frame_index: 1, phase: 'live', stream_id: 'str_1'}
        : op === 'observation.capture_screen' ? {screenshot_base64: JPEG, media_type: 'image/jpeg'}
        : {stopped: true};
      socket.end(JSON.stringify({version: 1, id: request.id, ok: true, result}) + '\n');
    });
    socket.on('error', () => {});
  });
  return new Promise(resolve => server.listen(path, () => resolve({path,
    close: () => new Promise(done => server.close(() => { rmSync(dir, {recursive: true, force: true}); done(); }))})));
}

async function streamer(socketPath, options) {
  const server = runStreamer(socketPath, 0, options);
  if (!server.listening) await new Promise(resolve => server.once('listening', resolve));
  return {server, port: server.address().port, token: server.liveToken,
    close: () => new Promise(resolve => { server.closeAllConnections?.(); server.close(() => resolve()); })};
}

function fetchRaw(port, path, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = httpRequest({host: '127.0.0.1', port, path, method: 'GET', headers}, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks)}));
      // A multipart stream never ends: the status line is all that is needed.
      if (path.startsWith('/stream.mjpg') && response.statusCode === 200) { response.destroy(); resolve({status: 200, headers: response.headers, body: Buffer.alloc(0)}); }
    });
    req.on('error', reject);
    req.end();
  });
}

const PATHS = token => ({
  stream: '/stream.mjpg?app=com.example.A&window=W&window_id=11&slot=A&bundle=com.example.A&pid=501' + token,
  frame: '/frame.png?app=com.example.A&window=W' + token,
  status: '/stream/status?slot=A' + token,
});

// ── nothing fixed is distributed ──────────────────────────────────────────
test('no fixed token literal is shipped in the source, the renderer template or the built client', () => {
  for (const file of ['index.js', 'client.template.js', 'dist/client.js', 'runtime.mjs', 'cordis.patch.yml']) {
    const text = readFileSync(join(root, file), 'utf8');
    assert.ok(!/cmm-cu-live/.test(text), file + ' still carries the old fixed token');
    assert.ok(!/token=[A-Za-z0-9_-]{6,}['"&]/.test(text.replace(/token=['"]\s*\+/g, '')), file + ' carries a literal token in a URL');
  }
  assert.ok(!/\bLIVE_TOKEN\b/.test(readFileSync(join(root, 'index.js'), 'utf8')), 'no fixed-token constant');
});

test('the token generator is cryptographically shaped and never repeats', () => {
  const tokens = new Set(Array.from({length: 64}, () => newLiveToken()));
  assert.equal(tokens.size, 64);
  for (const token of tokens) {
    assert.ok(isLiveToken(token), token);
    assert.ok(token.length >= 43, 'at least 256 bits of base64url');
  }
  for (const bad of [undefined, null, '', 'cmm-cu-live', 'a'.repeat(42), 'a'.repeat(44), 'a'.repeat(42) + '!', 42]) {
    assert.equal(isLiveToken(bad), false, String(bad));
  }
});

// ── the streamer refuses whoever does not hold this run's token ───────────
test('each streamer draws its own token and an injected token must itself be well formed', async () => {
  const helper = await fakeHelper();
  const a = await streamer(helper.path);
  const b = await streamer(helper.path);
  try {
    assert.ok(isLiveToken(a.token) && isLiveToken(b.token));
    assert.notEqual(a.token, b.token, 'two runs never share a token');
  } finally { await a.close(); await b.close(); await helper.close(); }
  assert.throws(() => runStreamer(helper.path, 0, {token: 'cmm-cu-live'}), /token/i);
});

test('without the run token /stream.mjpg, /frame.png and /stream/status are refused', async () => {
  const helper = await fakeHelper();
  const s = await streamer(helper.path);
  const wrong = newLiveToken();
  try {
    const attempts = [
      ['none', ''],
      ['the old public literal', '&token=cmm-cu-live'],
      ['another run\'s token', '&token=' + wrong],
      ['empty', '&token='],
      ['a prefix of the real one', '&token=' + s.token.slice(0, 20)],
      ['the real one plus junk', '&token=' + s.token + 'x'],
      ['duplicated (wrong first)', '&token=' + wrong + '&token=' + s.token],
    ];
    for (const [label, suffix] of attempts) {
      for (const [name, path] of Object.entries(PATHS(suffix))) {
        const answer = await fetchRaw(s.port, path);
        assert.equal(answer.status, 403, label + ' / ' + name);
        assert.equal(answer.headers['access-control-allow-origin'], undefined, label + ' / ' + name + ': no CORS for a refused request');
      }
    }
    // The right token works, so the refusals above are about the token.
    for (const [name, path] of Object.entries(PATHS('&token=' + s.token))) {
      const answer = await fetchRaw(s.port, path);
      assert.equal(answer.status, 200, name);
    }
  } finally { await s.close(); await helper.close(); }
});

test('the right token is still useless from a foreign origin or a foreign Host', async () => {
  const helper = await fakeHelper();
  const s = await streamer(helper.path);
  try {
    for (const [name, path] of Object.entries(PATHS('&token=' + s.token))) {
      for (const headers of [{Origin: 'https://evil.example'}, {Origin: 'http://127.0.0.1:' + s.port}, {Origin: 'null'},
        {Host: 'evil.example:' + s.port}, {Host: 'attacker.test'}]) {
        const answer = await fetchRaw(s.port, path, headers);
        assert.equal(answer.status, 403, name + ' ' + JSON.stringify(headers));
        assert.equal(answer.headers['access-control-allow-origin'], undefined);
      }
      const renderer = await fetchRaw(s.port, path, {Origin: 'dsh-app://app'});
      assert.equal(renderer.status, 200, name + ' from the renderer');
      assert.equal(renderer.headers['access-control-allow-origin'], 'dsh-app://app', 'CORS names the renderer, never *');
    }
  } finally { await s.close(); await helper.close(); }
});

test('the streamer listens on the loopback interface only', async () => {
  const helper = await fakeHelper();
  const s = await streamer(helper.path);
  try { assert.equal(s.server.address().address, '127.0.0.1'); } finally { await s.close(); await helper.close(); }
});

// ── the Host hands the token over without a literal, argv or env ──────────
test('the child streamer takes its token from stdin; none or a bad one and it refuses to start', async () => {
  const helper = await fakeHelper();
  const run = (stdinText) => new Promise(resolve => {
    const child = spawn(process.execPath, [join(root, 'index.js'), '--stream', '--socket', helper.path, '--port', '0'], {
      env: {...process.env, ELECTRON_RUN_AS_NODE: ''}, stdio: ['pipe', 'pipe', 'ignore']});
    let out = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', text => { out += text; const m = /READY (\d+)/.exec(out); if (m) resolve({child, out, port: Number(m[1])}); });
    child.on('exit', code => resolve({child, out, code}));
    if (stdinText !== null) child.stdin.write(stdinText);
    else child.stdin.end();
    setTimeout(() => resolve({child, out, hung: true}), 4000).unref();
  });
  const good = newLiveToken();
  const ok = await run(good + '\n');
  try {
    assert.ok(ok.port, 'a well formed token starts it: ' + ok.out);
    assert.equal((await fetchRaw(ok.port, '/stream/status?slot=A&token=' + good)).status, 200);
    assert.equal((await fetchRaw(ok.port, '/stream/status?slot=A&token=cmm-cu-live')).status, 403);
    assert.equal((await fetchRaw(ok.port, '/stream/status?slot=A&token=' + newLiveToken())).status, 403);
  } finally { ok.child.kill('SIGKILL'); }
  for (const bad of [null, 'cmm-cu-live\n', '\n', 'x'.repeat(10) + '\n']) {
    const refused = await run(bad);
    refused.child.kill('SIGKILL');
    assert.ok(!refused.port, 'a missing or malformed token never opens a listener: ' + JSON.stringify(bad));
    assert.match(refused.out, /^ERROR /, JSON.stringify(bad));
  }
  await helper.close();
});

test('the Host source never puts the token in argv or the environment of the child', () => {
  const source = readFileSync(join(root, 'index.js'), 'utf8');
  const spawnCall = source.slice(source.indexOf('child = spawn('), source.indexOf('} catch { child = null; return; }'));
  assert.match(spawnCall, /stdio:\s*\['pipe'/, 'stdin is a pipe');
  assert.ok(!/liveToken/.test(spawnCall.split('stdio')[0]), 'the token is not in argv/env');
  assert.match(source, /child\.stdin\.(write|end)\(/, 'the token is written to the child\'s stdin');
});

// ── the renderer receives it through the view, never the persisted state ──
function register() {
  const registered = [];
  const disposers = [];
  const ctx = {
    sessionProjections: {register: definition => { registered.push(definition); return () => {}; }, stateOf: () => undefined},
    tools: {guard() { return () => {}; }},
    effect(fn) { disposers.push(fn()); },
  };
  // The streamer child is spawned on a dead socket: only the projection is inspected.
  apply(ctx, {socket: '/nonexistent/cmm-token-test.sock'});
  return {definition: registered[0], stop: () => { for (const d of disposers.splice(0)) d(); }};
}

test('the view carries {port, token} for the renderer; the persisted state and checkpoint never do', () => {
  const one = register(), two = register();
  try {
    const state = initialState();
    const viewOne = one.definition.wire.view(state), viewTwo = two.definition.wire.view(state);
    assert.ok(isLiveToken(viewOne.live.token), 'a random token reaches the renderer');
    assert.equal(viewOne.live.port, 47183, 'the port is configuration, the token is the secret');
    assert.notEqual(viewOne.live.token, viewTwo.live.token, 'a new start, a new token');
    assert.ok(Object.is(viewOne, one.definition.wire.view(state)), 'a stable view reference: no republication per event');
    assert.ok(!('live' in state) && !JSON.stringify(state).includes(viewOne.live.token), 'the state (persisted) has no token');
    assert.ok(!JSON.stringify(one.definition.init({})).includes(viewOne.live.token));
    // The view is validated like any other value, with its own extra field.
    assert.doesNotThrow(() => one.definition.wire.viewSchema.parse(viewOne));
    assert.throws(() => one.definition.wire.viewSchema.parse({...viewOne, live: {port: 47183, token: 'cmm-cu-live'}}));
    assert.throws(() => one.definition.wire.viewSchema.parse({...viewOne, live: {port: 70000, token: viewOne.live.token}}));
    assert.throws(() => one.definition.wire.viewSchema.parse({...viewOne, live: {port: 47183, token: viewOne.live.token, extra: 1}}));
    // The stored state still rejects a token smuggled into it? It is not a state field at all.
    assert.doesNotThrow(() => one.definition.stateSchema.parse(state));
  } finally { one.stop(); two.stop(); }
});

test('the renderer builds the stream URL from the view and has no URL without it', () => {
  const source = readFileSync(join(root, 'client.template.js'), 'utf8');
  assert.match(source, /state\.live/, 'the token comes from the projection view');
  assert.ok(!/127\.0\.0\.1:47183/.test(source), 'the port is not hard-coded in the renderer');
  assert.match(source, /encodeURIComponent\(live\.token\)/, 'the token is encoded into the query');
  const built = readFileSync(join(root, 'dist/client.js'), 'utf8');
  assert.ok(!/cmm-cu-live/.test(built) && !/127\.0\.0\.1:47183/.test(built));
});
