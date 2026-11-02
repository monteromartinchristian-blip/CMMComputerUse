// PiP visible application name (bug: the title read
// `com.anthropic.claudefordesktop` although the observe had verified
// `target.name = "Claude"`). The bundle id is never the title; it stays in the
// technical facts. Authorization / verification / phase are not touched.
import test from 'node:test';
import assert from 'node:assert/strict';
import {initialState, fold, pipPresentation, displayAppName, GENERIC_APP_NAME} from '../runtime.mjs';

const PREFIX = 'mcp__cmm-computer-use__computer_use_';
const CLAUDE = 'com.anthropic.claudefordesktop';
let seq = 0;
const call = (s, name, args = {}) => fold(s, {type: 'assistant/message', seq: ++seq, time: 1000,
  data: {message: {content: [{type: 'tool-call', id: String(seq), name: PREFIX + name, arguments: JSON.stringify(args)}]}}});
const result = (s, text) => fold(s, {type: 'tool/result', seq: ++seq, time: 1000,
  data: {message: {source: {callId: Object.keys(s.pending).at(-1)}, isError: false, content: [{type: 'text', text}]}}});

/** A CMM Console grant, optionally without a human name (the real case). */
const status = (name = '') => 'helper: cmm-computer-use protocol=1 pid=9\n' +
  'deployment_policy: background (this adapter asks for background)\n' +
  'accessibility: True\nscreen_recording: True\n' +
  'authorization: loaded=True apps=1 default=deny\n' +
  `- authorized: ${name} [${CLAUDE}] scopes=control,observe windows=0\n` +
  'effective_mode: background (launch=background policy=background)';
const observe = (s, name = 'Claude') => result(call(s, 'observe', {app: CLAUDE}),
  `frontmost: DeepSeek Harness [com.deepseek.harness]\ntarget: ${name} [${CLAUDE}] (background)\n` +
  'snapshot: 5 (pass it back with element actions)\n' +
  `cmm_view: {"bundle":"${CLAUDE}","pid":777,"snapshot":5,"window":"Claude","window_id":41}`);
const session = (grantName = '', targetName = 'Claude') =>
  observe(result(call(initialState(), 'status'), status(grantName)), targetName);
const model = s => pipPresentation(s, {sessionId: 'a', view: {sessionId: 'a', mode: 'mini'}, now: 1000});

test('1. grant without a human name: the verified target name is the title', () => {
  const s = session('');
  assert.equal(s.grants[0].name, CLAUDE, 'precondition: the parser fell back to the bundle');
  assert.equal(s.target.name, 'Claude');
  assert.equal(s.target.bundle, CLAUDE);
  const m = model(s);
  assert.equal(m.app, 'Claude');
  assert.notEqual(m.app, CLAUDE);
});

test('2. target without a name, grant with a human name: the grant name', () => {
  assert.equal(displayAppName({name: '', bundle: CLAUDE}, {name: 'Claude Desktop', bundle: CLAUDE}), 'Claude Desktop');
  assert.equal(displayAppName({bundle: CLAUDE}, {name: 'Claude Desktop', bundle: CLAUDE}), 'Claude Desktop');
});

test('3. target without a name and grant.name == bundle: generic name', () => {
  assert.equal(GENERIC_APP_NAME, 'Aplicación');
  assert.equal(displayAppName({name: '', bundle: CLAUDE}, {name: CLAUDE, bundle: CLAUDE}), 'Aplicación');
  assert.equal(displayAppName({name: '   ', bundle: CLAUDE}, {name: '', bundle: CLAUDE}), 'Aplicación');
});

test('4. target.name == target.bundle is never the title', () => {
  assert.equal(displayAppName({name: CLAUDE, bundle: CLAUDE}, {name: 'Claude', bundle: CLAUDE}), 'Claude');
  assert.equal(displayAppName({name: CLAUDE, bundle: CLAUDE}, {name: CLAUDE, bundle: CLAUDE}), 'Aplicación');
  // Through the real fold: the helper reported the bundle as the name.
  const m = model(session('', CLAUDE));
  assert.equal(m.app, 'Aplicación');
  assert.notEqual(m.app, CLAUDE);
});

test('5. unverified: no name at all, as before', () => {
  const s = session('');
  assert.equal(model({...s, bridge: 'incompatible'}).app, null);
  assert.equal(model({...s, target: {...s.target, background: false}}).app, null);
  assert.equal(model({...s, grants: []}).app, null);
});

test('6. the technical facts keep the exact bundle id', () => {
  const m = model(session(''));
  assert.equal(m.technical.target.bundle, CLAUDE);
});

test('7. canRead, phase, verification and grants are unchanged by the name', () => {
  const unnamed = session('');
  const named = session('Claude');
  const a = model(unnamed), b = model(named);
  assert.equal(b.app, 'Claude');
  for (const key of ['visible', 'phase', 'status', 'tone', 'mode', 'canRead', 'window', 'code', 'ageMs', 'frameAt'])
    assert.deepEqual(a[key], b[key], key);
  assert.deepEqual(a.technical, b.technical);
  assert.deepEqual(unnamed.target, {...named.target, name: unnamed.target.name});
  assert.deepEqual(unnamed.grants.map(g => [g.bundle, g.scopes]), [[CLAUDE, ['control', 'observe']]]);
  assert.equal(unnamed.grants[0].name, CLAUDE, 'grant parsing unchanged');
});
