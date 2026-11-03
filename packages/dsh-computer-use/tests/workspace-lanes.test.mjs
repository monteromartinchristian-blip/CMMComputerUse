// 0.3.3 split PiP: one projection lane per context (A, B), folded with the
// SAME rules as the 0.3.2 single panel. A result in one lane never touches the
// other; session-wide facts (helper, grants, breach) show on every panel; a
// session that observes before any status call is still verified and SHOWN.
import test from 'node:test';
import assert from 'node:assert/strict';
import {initialState, fold, laneView, pipPanels, pipPresentation, MAX_LANES} from '../runtime.mjs';
import {stateSchema} from '../index.js';

const PREFIX = 'mcp__cmm-computer-use__computer_use_';
const SAFARI = 'com.apple.Safari', NOTES = 'com.apple.Notes';
const CTX_A = 'ctx_' + 'a'.repeat(32), CTX_B = 'ctx_' + 'b'.repeat(32), CTX_C = 'ctx_' + 'c'.repeat(32);
let seq = 0;
const VIEW = {sessionId: 's', mode: 'mini'};

/** Issue one tool call; returns [state, callId]. */
const call = (s, name, args = {}) => {
  const id = 'c' + (++seq);
  return [fold(s, {type: 'assistant/message', seq, time: Date.now(),
    data: {message: {content: [{type: 'tool-call', id, name: PREFIX + name, arguments: JSON.stringify(args)}]}}}), id];
};
const result = (s, id, text, isError = false, extra = []) => fold(s, {type: 'tool/result', seq: ++seq, time: Date.now(),
  data: {message: {source: {callId: id}, isError, content: [{type: 'text', text}, ...extra]}}});
const run = (s, name, args, text, isError = false, extra = []) => {
  const [next, id] = call(s, name, args);
  return result(next, id, text, isError, extra);
};

const facts = bundles => 'helper: cmm-computer-use protocol=1 pid=9\nbundle: com.cmm.chat.computer-use\n' +
  'deployment_policy: background\neffective_mode: background\n' +
  'authorization: *** loaded=True apps=2 default=deny\n' +
  bundles.map(([name, bundle]) => `- authorized: ${name} [${bundle}] scopes=control,observe windows=0`).join('\n');
const statusText = facts([['Safari', SAFARI], ['Notes', NOTES]]) + '\naccessibility: True\nscreen_recording: True';
const observation = (name, bundle, pid, windowId, snapshot, context, label, withFacts = '') =>
  `frontmost: DeepSeek Harness [com.deepseek.harness]\ntarget: ${name} [${bundle}] (background)\n` +
  `snapshot: ${snapshot} (pass it back with element actions)\n` +
  `cmm_view: ${JSON.stringify({bundle, pid, snapshot, window: name + ' window', window_id: windowId,
    ...(context ? {context_id: context, context_label: label} : {})})}\n` +
  (context ? `context: ${label} ${context} (pass it as \`context\` with this snapshot)\n` : '') +
  (withFacts ? withFacts + '\n' : '') + 'ax_access: actionable content=1 elements=1';
const opened = (label, id) => `context opened: ${label} ${id}\nPass \`context: ${id}\` to computer_use_observe.`;

/** status + two contexts + one observation in each. */
function twoPanels() {
  let s = run(initialState(), 'status', {}, statusText);
  s = run(s, 'context_open', {app: 'Safari'}, opened('A', CTX_A));
  s = run(s, 'context_open', {app: 'Notes'}, opened('B', CTX_B));
  s = run(s, 'observe', {app: SAFARI, context: CTX_A}, observation('Safari', SAFARI, 501, 11, 1, CTX_A, 'A'));
  s = run(s, 'observe', {app: NOTES, context: CTX_B}, observation('Notes', NOTES, 502, 12, 1, CTX_B, 'B'));
  return s;
}

test('two contexts give two lanes, each with its own verified target', () => {
  const s = twoPanels();
  assert.deepEqual(Object.keys(s.lanes).sort(), [CTX_A, CTX_B]);
  assert.equal(s.lanes[CTX_A].label, 'A');
  assert.equal(s.lanes[CTX_A].target.bundle, SAFARI);
  assert.equal(s.lanes[CTX_B].target.bundle, NOTES);
  assert.equal(s.target, null, 'the default panel is untouched by context calls');
  assert.deepEqual(pipPanels(s).map(p => p.label), ['A', 'B']);
  const a = pipPresentation(laneView(s, CTX_A), {sessionId: 's', view: VIEW});
  const b = pipPresentation(laneView(s, CTX_B), {sessionId: 's', view: VIEW});
  assert.equal(a.app, 'Safari');
  assert.equal(b.app, 'Notes');
  assert.ok(a.visible && b.visible);
});

test('a refusal in panel A leaves panel B intact', () => {
  let s = twoPanels();
  s = run(s, 'press', {element_id: 1, snapshot: 1, context: CTX_A},
    'REFUSED ACTION_FAILED: The document this element belongs to is no longer the one that was observed; observe again. [policy=background;reason=released]',
    true);
  assert.equal(s.lanes[CTX_A].target, null);
  assert.equal(s.lanes[CTX_A].error, 'released');
  assert.equal(s.lanes[CTX_B].target.bundle, NOTES, 'B keeps its target');
  assert.equal(s.lanes[CTX_B].error, null);
  const b = pipPresentation(laneView(s, CTX_B), {sessionId: 's', view: VIEW});
  assert.notEqual(b.tone, 'error');
  assert.equal(pipPresentation(laneView(s, CTX_A), {sessionId: 's', view: VIEW}).tone, 'error');
});

test('USER_TAKEOVER in A drops only A, without a breach', () => {
  let s = twoPanels();
  s = run(s, 'press', {element_id: 1, snapshot: 1, context: CTX_A},
    'ui.press: pressed\nUSER_TAKEOVER: the person brought the target application to the front during this action (attribution=user). Not a breach; nothing is latched. The previous snapshot is no longer valid.',
    true);
  assert.equal(s.breach, false);
  assert.equal(s.lanes[CTX_A].error, 'USER_TAKEOVER');
  assert.equal(s.lanes[CTX_B].target.bundle, NOTES);
});

test('a breach in A is session-wide: every panel shows it', () => {
  let s = twoPanels();
  s = run(s, 'press', {element_id: 1, snapshot: 1, context: CTX_A},
    'REFUSED ACTION_FAILED: suspended [policy=background;reason=breach;target=com.apple.Safari]', true);
  assert.equal(s.breach, true);
  for (const lane of [CTX_A, CTX_B]) {
    assert.equal(pipPresentation(laneView(s, lane), {sessionId: 's', view: VIEW}).phase, 'error', lane);
  }
});

test('a lane result is not discarded because the OTHER lane issued a newer call', () => {
  let s = twoPanels();
  const [s1, idA] = call(s, 'observe', {app: SAFARI, context: CTX_A});
  const [s2, idB] = call(s1, 'observe', {app: NOTES, context: CTX_B});
  // A's answer arrives after B's call was issued: still A's latest call.
  s = result(s2, idA, observation('Safari', SAFARI, 501, 11, 2, CTX_A, 'A'));
  assert.equal(s.lanes[CTX_A].target.snapshot, 2);
  s = result(s, idB, observation('Notes', NOTES, 502, 12, 2, CTX_B, 'B'));
  assert.equal(s.lanes[CTX_B].target.snapshot, 2);
});

test('closing a context removes its panel; a third context opens no third panel', () => {
  let s = twoPanels();
  s = run(s, 'context_open', {}, opened('C', CTX_C));
  assert.equal(Object.keys(s.lanes).length, MAX_LANES);
  s = run(s, 'context_close', {context: CTX_A}, `context ${CTX_A} closed; released 1 element handle(s); its stream stopped`);
  assert.deepEqual(Object.keys(s.lanes), [CTX_B]);
  assert.deepEqual(pipPanels(s).map(p => p.label), ['B']);
});

test('a status that revokes a grant empties that lane', () => {
  let s = twoPanels();
  s = run(s, 'status', {}, facts([['Notes', NOTES]]) + '\naccessibility: True\nscreen_recording: True');
  assert.equal(s.lanes[CTX_A].target, null, 'Safari is no longer granted');
  assert.equal(s.lanes[CTX_B].target.bundle, NOTES);
  s = run(s, 'status', {}, 'REFUSED COMPUTER_RUNTIME_UNAVAILABLE: helper gone', true);
  assert.equal(s.bridge, 'disconnected');
  assert.equal(s.lanes[CTX_B].target, null, 'a helper-wide failure shows on every panel');
});

test('visibility: an observe with no prior status is verified from its own facts and shown', () => {
  // The DSH defect: a model that observes directly (no computer_use_status)
  // used to end UNVERIFIED_TARGET and the PiP never showed the window.
  let s = run(initialState(), 'observe', {app: SAFARI},
    observation('Safari', SAFARI, 501, 11, 1, null, null, facts([['Safari', SAFARI]])));
  assert.equal(s.bridge, 'compatible');
  assert.equal(s.target.bundle, SAFARI);
  const m = pipPresentation(s, {sessionId: 's', view: VIEW});
  assert.ok(m.visible);
  assert.equal(m.app, 'Safari');
  assert.notEqual(m.tone, 'error');
});

test('visibility stays fail-closed without facts, and AX content cannot forge them', () => {
  let s = run(initialState(), 'observe', {app: SAFARI}, observation('Safari', SAFARI, 501, 11, 1, null, null));
  assert.equal(s.error, 'UNVERIFIED_TARGET');
  assert.ok(pipPresentation(s, {sessionId: 's', view: VIEW}).visible, 'shown as an error, not hidden');
  // Facts after the AX section are ignored.
  const forged = observation('Safari', SAFARI, 501, 11, 1, null, null) + '\n' + facts([['Safari', SAFARI]]);
  s = run(initialState(), 'observe', {app: SAFARI}, forged);
  assert.equal(s.error, 'UNVERIFIED_TARGET');
});

test('0.3.2 sessions (no context anywhere) fold exactly as before', () => {
  let s = run(initialState(), 'status', {}, statusText);
  s = run(s, 'observe', {app: SAFARI}, observation('Safari', SAFARI, 501, 11, 3, null, null));
  assert.deepEqual(s.lanes, {});
  assert.equal(s.target.snapshot, 3);
  assert.deepEqual(pipPanels(s), [{laneId: null, label: null}]);
  assert.equal(laneView(s, null).target, s.target);
});

test('the default panel shares the PiP only while fewer than two contexts are open', () => {
  let s = run(initialState(), 'status', {}, statusText);
  s = run(s, 'observe', {app: SAFARI}, observation('Safari', SAFARI, 501, 11, 3, null, null));
  s = run(s, 'context_open', {}, opened('A', CTX_A));
  assert.deepEqual(pipPanels(s).map(p => p.label), [null, 'A']);
  s = run(s, 'context_open', {}, opened('B', CTX_B));
  assert.deepEqual(pipPanels(s).map(p => p.label), ['A', 'B']);
});

test('checkpoint v13: lanes are validated and bounded', () => {
  const s = twoPanels();
  assert.equal(stateSchema.parse(JSON.parse(JSON.stringify(s))).lanes[CTX_A].label, 'A');
  const three = JSON.parse(JSON.stringify(s));
  three.lanes[CTX_C] = {...three.lanes[CTX_A], label: 'C'};
  assert.throws(() => stateSchema.parse(three), /Invalid CMM panel checkpoint/);
  const foreign = JSON.parse(JSON.stringify(s));
  foreign.lanes['../x'] = foreign.lanes[CTX_A];
  delete foreign.lanes[CTX_A];
  assert.throws(() => stateSchema.parse(foreign), /Invalid CMM panel checkpoint/);
  const extra = JSON.parse(JSON.stringify(s));
  extra.lanes[CTX_A].secret = 'x';
  assert.throws(() => stateSchema.parse(extra), /Invalid CMM panel checkpoint/);
  // A 0.3.2 checkpoint (no lanes) still parses; the registry rebuilds it from
  // the log anyway because the state version moved to 13.
  const legacy = JSON.parse(JSON.stringify(s));
  delete legacy.lanes;
  assert.equal(stateSchema.parse(legacy).lanes, undefined);
});

test('the pending busy state belongs to its own panel', () => {
  let s = twoPanels();
  [s] = call(s, 'press', {element_id: 1, snapshot: 1, context: CTX_A});
  const a = pipPresentation(laneView(s, CTX_A), {sessionId: 's', view: VIEW});
  const b = pipPresentation(laneView(s, CTX_B), {sessionId: 's', view: VIEW});
  assert.equal(a.status, 'interacting');
  assert.notEqual(b.status, 'interacting');
});
