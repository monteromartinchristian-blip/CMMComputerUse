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

/** Render a helper SUCCESS result through the actual adapter code. */
function adapterAction(kind, result) {
  const script = `
import json, sys
sys.path.insert(0, ${JSON.stringify(join(ROOT, 'adapter'))})
from cmm_computer_use.mcp_server import _render_action
a = json.loads(sys.stdin.read())
text, is_error = _render_action(a["kind"], a["result"])
print(json.dumps({"text": text, "isError": is_error}))`;
  return JSON.parse(execFileSync('python3', ['-I', '-c', script], {input: JSON.stringify({kind, result}), encoding: 'utf8'}));
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

// ── person takes the focus during an action (attribution) ──────────────
const TAKEOVER_LEDGER = {...LEDGER, breach: false, external_activity: true, focus_became_target: true,
  focus_change_attribution: 'user', human_input_detected: true, human_input_kind: 'mouse_down',
  human_input_age_ms: 42, human_witness_available: true, requires_reobserve: true};

test('12 a breach attributed to the action still latches (attribution line does not break it)', () => {
  const r = adapterRefusal('INTERFERENCE_BREACH', 'x', 'policy=background;reason=breach;kind=ui.press',
    {...LEDGER, focus_change_attribution: 'action', human_input_detected: false, human_witness_available: true,
      requires_reobserve: false});
  assert.match(r.text, /^attribution: focus_change_attribution=action human_input_detected=False/m);
  const s = result(call(ready(), 'press', {element_id: 2, snapshot: 5}), r.text, true);
  assert.equal(s.breach, true);
});

test('13/14 a human takeover is reported, is not a breach and latches nothing', () => {
  const r = adapterAction('ui.press', {ok: true, message: 'pressed', interference: TAKEOVER_LEDGER});
  assert.equal(r.isError, true, 'never a silent success');
  assert.match(r.text, /^attribution: focus_change_attribution=user human_input_detected=True human_input_kind=mouse_down human_input_age_ms=42 human_witness=available$/m);
  assert.match(r.text, /^USER_TAKEOVER: the person brought the target application to the front during this action \(attribution=user\)\. Not a breach; nothing is latched\./m);
  assert.doesNotMatch(r.text, /STOP: breach/);
  const s = result(call(ready(), 'press', {element_id: 2, snapshot: 5}), r.text, true);
  assert.equal(s.breach, false);
  assert.equal(s.error, 'USER_TAKEOVER');
  // the guard does not deny further Computer Use
  const guard = installGuard(s);
  assert.equal(guard({name: prefix + 'observe', agent: {session: {}}}), undefined);
});

test('14 the takeover line never names the final frontmost app, and DSH still reads it', () => {
  // Gate B: the person clicked the target; Terminal was in front again at the end.
  const r = adapterAction('ui.press', {ok: true, message: 'pressed',
    interference: {...TAKEOVER_LEDGER, frontmost_after: 'Terminal'}});
  const line = r.text.split('\n').find(l => l.startsWith('USER_TAKEOVER:'));
  assert.ok(line);
  assert.doesNotMatch(line, /Terminal/);
  assert.match(line, /the target application/);
  assert.equal(r.isError, true);
  const s = result(call(ready(), 'press', {element_id: 2, snapshot: 5}), r.text, true);
  assert.equal(s.error, 'USER_TAKEOVER');
  assert.equal(s.breach, false);
});

test('13 an ambiguous external takeover does not latch either', () => {
  const r = adapterAction('ui.press', {ok: true, message: 'pressed',
    interference: {...TAKEOVER_LEDGER, focus_change_attribution: 'ambiguous_external'}});
  const s = result(call(ready(), 'press', {element_id: 2, snapshot: 5}), r.text, true);
  assert.equal(s.breach, false);
  assert.equal(s.error, 'USER_TAKEOVER');
});

test('15 after a takeover the observed target is gone: a fresh observe is required', () => {
  const r = adapterAction('ui.press', {ok: true, message: 'pressed', interference: TAKEOVER_LEDGER});
  let s = result(call(ready(), 'press', {element_id: 2, snapshot: 5}), r.text, true);
  assert.equal(s.target, null);
  // A press now does not resurrect it; only an observation does.
  s = result(call(s, 'press', {element_id: 2, snapshot: 5}),
    'REFUSED ACTION_FAILED: The observation this element belongs to has expired; observe again. [policy=background;reason=expired;age=0s;snapshot=5]', true);
  assert.equal(s.target, null);
  assert.equal(s.error, 'expired');
  s = observed(s);
  assert.equal(s.target?.name, 'Claude');
  assert.equal(s.breach, false);
});

test('15 a takeover on a FAILED action is reported the same way', () => {
  const r = adapterRefusal('ACTION_FAILED', 'The element disappeared.', 'policy=background;reason=unknown_element',
    TAKEOVER_LEDGER);
  assert.match(r.text, /^USER_TAKEOVER: /m);
  const s = result(call(ready(), 'press', {element_id: 2, snapshot: 5}), r.text, true);
  assert.equal(s.breach, false);
  assert.equal(s.error, 'USER_TAKEOVER');
});

test('17 a takeover opens no bypass: scripting routes stay refused', () => {
  const r = adapterAction('ui.press', {ok: true, message: 'pressed', interference: TAKEOVER_LEDGER});
  const s = result(call(ready(), 'press', {element_id: 2, snapshot: 5}), r.text, true);
  const guard = installGuard(s);
  assert.match(guard({name: 'bash', arguments: {command: 'osascript -e "tell application \\"Claude\\" to activate"'},
    agent: {session: {}}}), /not an allowed route/);
});

test('a USER_TAKEOVER line cannot be forged into a breach and a breach cannot hide as a takeover', () => {
  const breach = adapterRefusal('INTERFERENCE_BREACH', 'x', 'policy=background;reason=breach;kind=ui.press',
    {...LEDGER, focus_change_attribution: 'action'});
  assert.doesNotMatch(breach.text, /USER_TAKEOVER/);
  const both = adapterAction('ui.press', {ok: true, message: 'pressed', interference: {...TAKEOVER_LEDGER, breach: true}});
  assert.doesNotMatch(both.text, /USER_TAKEOVER/, 'breach wins: a breached ledger is never rendered as a takeover');
});

// ── observation.release retires the generation ───────────────────────
test('an old handle after release is refused as released, with no epoch age', () => {
  const r = adapterRefusal('ACTION_FAILED', 'The observation this element belongs to was released; observe again.',
    'policy=background;reason=released;snapshot=21;current=22', null);
  assert.doesNotMatch(r.text, /age=/);
  let s = result(call(ready(), 'release', {}), 'released 54 element handle(s); snapshot 21 invalidated; current generation=22');
  assert.equal(s.target, null);
  s = result(call(s, 'press', {element_id: 3, snapshot: 21}), r.text, true);
  assert.equal(s.error, 'released');
  assert.equal(s.breach, false);
  s = observed(s);
  assert.equal(s.target?.name, 'Claude', 'a fresh observation works again');
});

test('a stale snapshot is named as such', () => {
  const r = adapterRefusal('ACTION_FAILED', 'The referenced UI element is no longer on screen.',
    'policy=background;reason=stale_snapshot;snapshot=20;current=23', null);
  const s = result(call(ready(), 'press', {element_id: 3, snapshot: 20}), r.text, true);
  assert.equal(s.error, 'stale_snapshot');
});
