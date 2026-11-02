// PiP visible application name (bug: the title read
// `com.anthropic.claudefordesktop` although the observe had verified
// `target.name = "Claude"`). The bundle id is never the title; it stays in the
// technical facts. With no human name the runtime only marks `appGeneric`; the
// client resolves it with the plugin's own locale dictionaries
// (es "Aplicación", en "Application"). Verification / phase / canRead are not
// touched.
import test from 'node:test';
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {initialState, fold, pipPresentation, displayAppName} from '../runtime.mjs';
import {seat, nodes, text} from './seat.mjs';

const PREFIX = 'mcp__cmm-computer-use__computer_use_';
const CLAUDE = 'com.anthropic.claudefordesktop';
const LANGS = ['es', 'en'];
const GENERIC = {es: 'Aplicación', en: 'Application'};
let seq = 0;
const call = (s, name, args = {}) => fold(s, {type: 'assistant/message', seq: ++seq, time: Date.now(),
  data: {message: {content: [{type: 'tool-call', id: String(seq), name: PREFIX + name, arguments: JSON.stringify(args)}]}}});
const result = (s, text) => fold(s, {type: 'tool/result', seq: ++seq, time: Date.now(),
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
const VIEW = {sessionId: 'a', mode: 'mini'};
const model = s => pipPresentation(s, {sessionId: 'a', view: VIEW});

/** The title the real client draws (compact header) in a language. */
const shownTitle = (state, lang) => {
  const tree = seat(state, {lang}).draw(VIEW);
  const titles = nodes(tree, 'span').filter(n => n.props.className === 'cmm-cu-title');
  assert.equal(titles.length, 1, 'one header title');
  return {title: text(titles[0]).trim(), all: text(tree)};
};

test('the locale dictionaries carry the generic name in both languages', () => {
  for (const lang of LANGS) {
    const panel = JSON.parse(fs.readFileSync(new URL(`../locale/${lang}.json`, import.meta.url))).panel;
    assert.equal(panel.appGeneric, GENERIC[lang]);
  }
});

test('1. target.name=Claude is the title in both languages (grant without a human name)', () => {
  const s = session('');
  assert.equal(s.grants[0].name, CLAUDE, 'precondition: the parser fell back to the bundle');
  assert.equal(s.target.name, 'Claude');
  const m = model(s);
  assert.equal(m.app, 'Claude');
  assert.equal(m.appGeneric, false);
  for (const lang of LANGS) assert.equal(shownTitle(s, lang).title, 'Claude', lang);
});

test('2. a human grant name is the fallback in both languages', () => {
  assert.equal(displayAppName({name: '', bundle: CLAUDE}, {name: 'Claude Desktop', bundle: CLAUDE}), 'Claude Desktop');
  assert.equal(displayAppName({bundle: CLAUDE}, {name: 'Claude Desktop', bundle: CLAUDE}), 'Claude Desktop');
  // Through the real fold: the helper reported the bundle as the name.
  const s = session('Claude Desktop', CLAUDE);
  assert.equal(model(s).app, 'Claude Desktop');
  for (const lang of LANGS) assert.equal(shownTitle(s, lang).title, 'Claude Desktop', lang);
});

test('3. no human name: es "Aplicación", en "Application"; the runtime picks no language', () => {
  assert.equal(displayAppName({name: '', bundle: CLAUDE}, {name: CLAUDE, bundle: CLAUDE}), null);
  assert.equal(displayAppName({name: '   ', bundle: CLAUDE}, {name: '', bundle: CLAUDE}), null);
  const s = session('', CLAUDE);
  const m = model(s);
  assert.equal(m.app, null);
  assert.equal(m.appGeneric, true);
  for (const lang of LANGS) assert.equal(shownTitle(s, lang).title, GENERIC[lang], lang);
  const runtime = fs.readFileSync(new URL('../runtime.mjs', import.meta.url), 'utf8');
  assert.ok(!runtime.includes('Aplicación') && !runtime.includes("'Application'"), 'no language in the runtime');
});

test('4. the bundle id never appears as the visible title', () => {
  assert.equal(displayAppName({name: CLAUDE, bundle: CLAUDE}, {name: 'Claude', bundle: CLAUDE}), 'Claude');
  for (const s of [session(''), session('', CLAUDE), session('Claude Desktop', CLAUDE)])
    for (const lang of LANGS) {
      const {title, all} = shownTitle(s, lang);
      assert.notEqual(title, CLAUDE);
      assert.ok(!all.includes(CLAUDE), `no bundle id in the compact PiP (${lang})`);
    }
});

test('5. technical.target.bundle keeps the exact bundle id', () => {
  for (const s of [session(''), session('', CLAUDE)]) assert.equal(model(s).technical.target.bundle, CLAUDE);
});

test('6. unverified: no visible app and no generic marker', () => {
  const s = session('', CLAUDE);
  for (const bad of [{...s, bridge: 'incompatible'}, {...s, target: {...s.target, background: false}}, {...s, grants: []}]) {
    const m = model(bad);
    assert.equal(m.app, null);
    assert.equal(m.appGeneric, false);
  }
  const idle = pipPresentation(initialState(), {sessionId: 'a', view: VIEW});
  assert.equal(idle.app, null);
  assert.equal(idle.appGeneric, false);
});

test('7. phase, canRead, verification and grants are unchanged by the name', () => {
  const generic = session('', CLAUDE), named = session('Claude', 'Claude');
  const a = model(generic), b = model(named);
  for (const key of ['visible', 'phase', 'status', 'tone', 'mode', 'canRead', 'window', 'code', 'ageMs', 'frameAt'])
    assert.deepEqual(a[key], b[key], key);
  assert.deepEqual(a.technical, b.technical);
  assert.deepEqual(generic.target, {...named.target, name: generic.target.name});
  assert.deepEqual(generic.grants.map(g => [g.bundle, g.scopes]), [[CLAUDE, ['control', 'observe']]]);
  assert.equal(session('').grants[0].name, CLAUDE, 'grant parsing unchanged');
});
