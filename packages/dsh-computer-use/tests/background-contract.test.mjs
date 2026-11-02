// Background contract, 2026-11-02 findings (see
// docs/architecture/CMM-Computer-Use-Encargo-Claude-Code-Cloud-20261102.md).
//
// The breach texts are rendered by the REAL Python adapter, not copied here:
// the projection's latch regexes and the adapter's wording are a cross-language
// contract, and a copy would let them drift apart silently.
import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {initialState, fold, parseStatus, bypassReason} from '../runtime.mjs';
import {apply, stateSchema} from '../index.js';

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const prefix = 'mcp__cmm-computer-use__computer_use_';
const CLAUDE = 'com.anthropic.claudefordesktop';
let seq = 0;
const call = (s, name, args = {}) => fold(s, {type: 'assistant/message', seq: ++seq, time: Date.now(),
  data: {message: {content: [{type: 'tool-call', id: String(seq), name: prefix + name, arguments: JSON.stringify(args)}]}}});
const result = (s, text, error = false) => fold(s, {type: 'tool/result', seq: ++seq, time: Date.now(),
  data: {message: {source: {callId: Object.keys(s.pending).at(-1)}, isError: error, content: [{type: 'text', text}]}}});

/** Render a helper error frame through the actual adapter code. */
function adapterRefusal(code, message, detail, interference) {
  const script = `
import json, sys
sys.path.insert(0, ${JSON.stringify(join(ROOT, 'adapter'))})
from cmm_computer_use.client import BridgeError
from cmm_computer_use.mcp_server import _render_refusal
a = json.loads(sys.stdin.read())
r = _render_refusal(BridgeError(a["message"], code=a["code"], detail=a["detail"], interference=a["interference"]))
print(json.dumps(r))`;
  const out = execFileSync('python3', ['-I', '-c', script], {input: JSON.stringify({code, message, detail, interference}), encoding: 'utf8'});
  const rendered = JSON.parse(out);
  return {text: rendered.content.map(b => b.text).join('\n'), isError: rendered.isError === true};
}

const STATUS_NO_NAME = 'helper: cmm-computer-use protocol=1 pid=9\n' +
  'deployment_policy: background (this adapter asks for background)\n' +
  'accessibility: True\nscreen_recording: True\n' +
  'authorization: loaded=True apps=1 default=deny\n' +
  `- authorized:  [${CLAUDE}] scopes=control,observe windows=0\n` +
  'effective_mode: background (launch=background policy=background)';
const observed = (s, name = 'Claude', app = CLAUDE) => result(call(s, 'observe', {app}),
  `frontmost: DeepSeek Harness [com.deepseek.harness]\ntarget: ${name} [${CLAUDE}] (background)\nsnapshot: 5 (pass it back with element actions)\n` +
  `cmm_view: {"bundle":"${CLAUDE}","pid":777,"snapshot":5,"window":"Claude","window_id":41}`);
const ready = () => observed(result(call(initialState(), 'status'), STATUS_NO_NAME));

const LEDGER = {verdict: 'focus_changed', frontmost_before: 'DeepSeek Harness', frontmost_after: 'Claude',
  cursor_moved: false, cursor_dx: 0, cursor_dy: 0, action_class: 'accessibility', policy: 'background',
  attributed: false, breach: true, cursor_events_posted: false, cursor_moved_by_action: false,
  focus_became_target: true, external_activity: false, sampled: 180, transient_focus_changes: 1,
  transient_cursor_max_delta: 0, restored: false, window_raised_over_person: false,
  observed_for_ms: 1130, target_front_at_ms: 620};

// ── 1. grants without a name ────────────────────────────────────────────
test('a CMM Console grant with no name, NBSP or windows=0 is valid and keyed by bundle', () => {
  for (const sep of [' ', ' ', '   ']) {
    const parsed = parseStatus(STATUS_NO_NAME.replace('- authorized:  [', `- authorized:${sep}[`));
    assert.equal(parsed.bridge, 'compatible');
    assert.equal(parsed.grants.length, 1);
    assert.equal(parsed.grants[0].bundle, CLAUDE);
    assert.equal(parsed.grants[0].name, CLAUDE, 'technical fallback only, never shown when the helper observed a name');
    assert.deepEqual(parsed.grants[0].scopes, ['control', 'observe']);
  }
});

// ── 2. human name in the PiP, not hardcoded ─────────────────────────────
test('the target shows the name the helper observed, the bundle stays the identity', () => {
  const s = ready();
  assert.equal(s.error, null);
  assert.equal(s.target.name, 'Claude');
  assert.equal(s.target.bundle, CLAUDE);
  // Any localized name works; nothing is special-cased.
  const t = observed(result(call(initialState(), 'status'), STATUS_NO_NAME), 'Claude (Beta) ñ');
  assert.equal(t.target.name, 'Claude (Beta) ñ');
  // The model may name the app either way.
  assert.equal(observed(result(call(initialState(), 'status'), STATUS_NO_NAME), 'Claude', 'Claude').target.name, 'Claude');
  assert.doesNotThrow(() => stateSchema.parse(s));
});

// ── 3. breach fail-closed, latched in DSH ───────────────────────────────
test('INTERFERENCE_BREACH rendered by the adapter latches the session', () => {
  const r = adapterRefusal('INTERFERENCE_BREACH',
    'The action brought the target application in front of the person\'s work in a mode that promised no interference.',
    'policy=background;reason=breach;kind=ui.press;action_ok=true', LEDGER);
  assert.equal(r.isError, true);
  let s = result(call(ready(), 'press', {element_id: 2, snapshot: 5}), r.text, true);
  assert.equal(s.breach, true);
  assert.equal(s.target, null);
  assert.equal(s.error, 'BREACH');
  assert.equal(s.ledger.focus_became_target, true);
  // Sticky: a later healthy status and observation do not clear it.
  s = observed(result(call(s, 'status'), STATUS_NO_NAME));
  assert.equal(s.breach, true);
});

test('a window ordered over the person (no activation) is also a verified breach', () => {
  const r = adapterRefusal('INTERFERENCE_BREACH', 'raised', 'policy=background;reason=breach;kind=ui.press',
    {...LEDGER, focus_became_target: false, window_raised_over_person: true});
  const s = result(call(ready(), 'press', {element_id: 2, snapshot: 5}), r.text, true);
  assert.equal(s.breach, true);
  assert.equal(s.ledger.window_raised_over_person, true);
});

test('the helper latch refusal (reason=breach, breach_id) latches DSH too', () => {
  const r = adapterRefusal('ACTION_FAILED',
    'An earlier action on this application took the person\'s focus; control is suspended until it is rearmed from CMM Console.',
    `policy=background;reason=breach;target=${CLAUDE};breach_id=0b8c6a3e-1f2d-4c5b-9a7e-2d1c0b9a8f7e`, null);
  const s = result(call(ready(), 'press', {element_id: 1, snapshot: 5}), r.text, true);
  assert.equal(s.breach, true);
});

test('an invalid latch file is a refusal, not a session breach', () => {
  const r = adapterRefusal('ACTION_FAILED',
    'The breach latch file cannot be read; control is suspended until CMM Console resets it.',
    'policy=background;reason=breach_latch_invalid;cause=not_json', null);
  const s = result(call(ready(), 'press', {element_id: 1, snapshot: 5}), r.text, true);
  assert.equal(s.breach, false);
  assert.equal(s.error, 'breach_latch_invalid');
});

test('an untouched ledger is not a breach, and a non-breach failure is not latched', () => {
  const r = adapterRefusal('ACTION_FAILED', 'gone', 'policy=background;reason=unknown_element',
    {...LEDGER, breach: false, focus_became_target: false, verdict: 'untouched', transient_focus_changes: 0});
  const s = result(call(ready(), 'press', {element_id: 1, snapshot: 5}), r.text, true);
  assert.equal(s.breach, false);
});

test('the guard denies further CU calls after a breach', () => {
  const r = adapterRefusal('INTERFERENCE_BREACH', 'x', 'policy=background;reason=breach;kind=ui.press', LEDGER);
  const state = result(call(ready(), 'press', {element_id: 2, snapshot: 5}), r.text, true);
  const guard = installGuard(state);
  assert.match(guard({name: prefix + 'observe', agent: {session: {}}}), /denied/);
});

// ── 5. scroll ───────────────────────────────────────────────────────────
test('computer_use_scroll is tracked as a GUI action; unsupported is an error, not a breach', () => {
  const r = adapterRefusal('CAPABILITY_UNSUPPORTED',
    'This element offers no accessibility scroll primitive; background mode will not post a scroll-wheel event.',
    'policy=background;kind=ui.scroll;reason=scroll_area_without_scrollbar;role=AXScrollArea', null);
  const s = result(call(ready(), 'scroll', {element_id: 3, snapshot: 5, direction: 'down'}), r.text, true);
  assert.equal(s.error, 'CAPABILITY_UNSUPPORTED');
  assert.equal(s.breach, false);
  assert.match(r.text, /Do not work around this/);
});

// ── 6. bypass routes ────────────────────────────────────────────────────
// apply() starts the live-mirror child; its disposer is collected and run.
const disposers = [];
test.after(() => { for (const d of disposers.splice(0)) d(); });
function installGuard(state) {
  let guard;
  const ctx = {
    sessionProjections: {register() {}, stateOf: () => state},
    tools: {guard(fn) { guard = fn; return () => {}; }},
    effect(fn) { disposers.push(fn()); },
  };
  apply(ctx, {socket: '/nonexistent/cmm-test.sock'});
  return guard;
}

test('bypassReason recognises scripting, synthetic input and ad-hoc AX', () => {
  const cases = [
    [{name: 'bash', arguments: {command: 'osascript -e \'tell application "Claude" to activate\''}}, 'osascript'],
    [{name: 'bash', arguments: {command: 'osascript -l JavaScript -e "Application(\'System Events\')"'}}, 'osascript'],
    [{name: 'shell', input: 'swift - <<EOF\nimport Cocoa\nlet e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -5, wheel2: 0, wheel3: 0)\nEOF'}, 'CGEvent'],
    [{name: 'write_file', arguments: {path: '/tmp/s.swift', content: 'CGWarpMouseCursorPosition(p)'}}, 'CGEvent'],
    [{name: 'bash', arguments: '{"command":"python3 -c \\"from Quartz import CGEventPost\\""}'}, 'CGEvent'],
    [{name: 'run_command', arguments: {cmd: 'cliclick c:100,200'}}, 'input tool'],
    [{name: 'bash', arguments: {command: 'open -a Claude'}}, 'open -a/-b (activation)'],
    [{name: 'bash', arguments: {command: 'swift - <<< "AXUIElementCreateApplication(1)"'}}, 'accessibility API'],
  ];
  for (const [exec, label] of cases) assert.equal(bypassReason(exec), label, JSON.stringify(exec));
});

test('bypassReason leaves ordinary work and the CU tools alone', () => {
  for (const exec of [
    {name: 'bash', arguments: {command: 'ls -la && git status'}},
    {name: 'bash', arguments: {command: 'swift test --filter Policy'}},
    {name: 'grep', arguments: {pattern: 'CGEvent'}},
    {name: 'read_file', arguments: {path: 'osascript.md'}},
    {name: prefix + 'press', arguments: {element_id: 1}},
    {name: 'bash'},
    null,
  ]) assert.equal(bypassReason(exec), null, JSON.stringify(exec));
});

test('the DSH guard blocks bypasses only in sessions that used Computer Use', () => {
  const bypass = {name: 'bash', arguments: {command: 'osascript -e "beep"'}, agent: {session: {}}};
  assert.equal(installGuard(initialState())(bypass), undefined, 'a coding session without CU is untouched');
  const guard = installGuard(ready());
  assert.match(guard(bypass), /osascript is not an allowed route in a Computer Use session/);
  assert.equal(guard({name: 'bash', arguments: {command: 'ls'}, agent: {session: {}}}), undefined);
  assert.equal(guard({name: prefix + 'observe', agent: {session: {}}}), undefined);
});
