// P2 (0.3.3 closing): the PiP follows the CURRENT use of Computer Use, not
// only the `context_open` event of the session that created the context.
// A context created in session A and reused by session B (the helper keeps it)
// must produce its panel in session B the moment B observes or acts on it,
// without duplicates, and a dismissal belongs to a session's view only.
import test from 'node:test';
import assert from 'node:assert/strict';
import {initialState, fold, laneView, pipPanels, pipPresentation, viewTransition, activityRevision, MAX_LANES} from '../runtime.mjs';
import {stateSchema} from '../index.js';

const PREFIX = 'mcp__cmm-computer-use__computer_use_';
const SAFARI = 'com.apple.Safari', NOTES = 'com.apple.Notes', MAIL = 'com.apple.mail';
const CTX_A = 'ctx_' + 'a'.repeat(32), CTX_B = 'ctx_' + 'b'.repeat(32), CTX_C = 'ctx_' + 'c'.repeat(32);
let seq = 0;

const call = (s, name, args = {}) => {
  const id = 'i' + (++seq);
  return [fold(s, {type: 'assistant/message', seq, time: Date.now(),
    data: {message: {content: [{type: 'tool-call', id, name: PREFIX + name, arguments: JSON.stringify(args)}]}}}), id];
};
const result = (s, id, text, isError = false) => fold(s, {type: 'tool/result', seq: ++seq, time: Date.now(),
  data: {message: {source: {callId: id}, isError, content: [{type: 'text', text}]}}});
const run = (s, name, args, text, isError = false) => {
  const [next, id] = call(s, name, args);
  return result(next, id, text, isError);
};

const facts = bundles => 'helper: cmm-computer-use protocol=1 pid=9\nbundle: com.cmm.chat.computer-use\n' +
  'deployment_policy: background\neffective_mode: background\n' +
  'authorization: *** loaded=True apps=3 default=deny\n' +
  bundles.map(([name, bundle]) => `- authorized: ${name} [${bundle}] scopes=control,observe windows=0`).join('\n');
const statusText = facts([['Safari', SAFARI], ['Notes', NOTES], ['Mail', MAIL]]) + '\naccessibility: True\nscreen_recording: True';
const observation = (name, bundle, pid, windowId, snapshot, context, label) =>
  `frontmost: DeepSeek Harness [com.deepseek.harness]\ntarget: ${name} [${bundle}] (background)\n` +
  `snapshot: ${snapshot} (pass it back with element actions)\n` +
  `cmm_view: ${JSON.stringify({bundle, pid, snapshot, window: name + ' window', window_id: windowId,
    context_id: context, context_label: label})}\n` +
  `context: ${label} ${context} (pass it as \`context\` with this snapshot)\n` +
  'ax_access: actionable content=1 elements=1';
const opened = (label, id) => `context opened: ${label} ${id}\nPass \`context: ${id}\` to computer_use_observe.`;

/** Session B: brand new projection that never saw a `context_open`. */
const freshSession = () => run(initialState(), 'status', {}, statusText);

test('a reused context produces its panel on the first observation', () => {
  let s = freshSession();
  assert.deepEqual(Object.keys(s.lanes), []);
  s = run(s, 'observe', {app: SAFARI, context: CTX_A}, observation('Safari', SAFARI, 501, 11, 7, CTX_A, 'A'));
  assert.deepEqual(Object.keys(s.lanes), [CTX_A]);
  assert.equal(s.lanes[CTX_A].label, 'A');
  assert.equal(s.lanes[CTX_A].target.bundle, SAFARI);
  assert.equal(s.lanes[CTX_A].target.windowId, 11);
  assert.deepEqual(pipPanels(s).map(p => p.label), ['A']);
  const view = laneView(s, CTX_A);
  assert.equal(pipPresentation(view, {sessionId: 'b', view: null}).visible, true, 'the panel is shown');
});

test('two inherited contexts give two panels, each with its own target', () => {
  let s = freshSession();
  s = run(s, 'observe', {app: SAFARI, context: CTX_A}, observation('Safari', SAFARI, 501, 11, 7, CTX_A, 'A'));
  s = run(s, 'observe', {app: NOTES, context: CTX_B}, observation('Notes', NOTES, 502, 12, 3, CTX_B, 'B'));
  assert.deepEqual(pipPanels(s).map(p => p.label), ['A', 'B']);
  assert.equal(s.lanes[CTX_B].target.bundle, NOTES);
  assert.equal(s.lanes[CTX_A].target.bundle, SAFARI, 'B never touches A');
});

test('an inherited context never duplicates a panel that already exists', () => {
  let s = freshSession();
  s = run(s, 'observe', {app: SAFARI, context: CTX_A}, observation('Safari', SAFARI, 501, 11, 7, CTX_A, 'A'));
  s = run(s, 'observe', {app: SAFARI, context: CTX_A}, observation('Safari', SAFARI, 501, 11, 8, CTX_A, 'A'));
  s = run(s, 'context_open', {app: SAFARI}, opened('A', CTX_A));
  assert.deepEqual(Object.keys(s.lanes), [CTX_A]);
  assert.deepEqual(pipPanels(s).map(p => p.label), ['A']);
  assert.equal(s.lanes[CTX_A].target.snapshot, 8, 'the lane follows the latest observation');
});

test('a context opened in this session and later observed is still one panel', () => {
  let s = freshSession();
  s = run(s, 'context_open', {app: SAFARI}, opened('A', CTX_A));
  s = run(s, 'observe', {app: SAFARI, context: CTX_A}, observation('Safari', SAFARI, 501, 11, 1, CTX_A, 'A'));
  assert.deepEqual(pipPanels(s).map(p => p.label), ['A']);
});

test('adoption never exceeds the two-panel limit and never evicts', () => {
  let s = freshSession();
  s = run(s, 'observe', {app: SAFARI, context: CTX_A}, observation('Safari', SAFARI, 501, 11, 1, CTX_A, 'A'));
  s = run(s, 'observe', {app: NOTES, context: CTX_B}, observation('Notes', NOTES, 502, 12, 1, CTX_B, 'B'));
  s = run(s, 'observe', {app: MAIL, context: CTX_C}, observation('Mail', MAIL, 503, 13, 1, CTX_C, 'C'));
  assert.equal(Object.keys(s.lanes).length, MAX_LANES);
  assert.deepEqual(Object.keys(s.lanes).sort(), [CTX_A, CTX_B]);
});

test('a refused or unknown-context result never creates a panel', () => {
  let s = freshSession();
  s = run(s, 'observe', {app: SAFARI, context: CTX_A}, 'REFUSED CONTEXT_UNKNOWN: no such context', true);
  assert.deepEqual(Object.keys(s.lanes), []);
  s = run(s, 'observe', {app: SAFARI, context: CTX_A}, 'REFUSED ACTION_FAILED: window_not_granted', false);
  assert.deepEqual(Object.keys(s.lanes), []);
});

test('the identity must match the call: a foreign context id or label is not adopted', () => {
  let s = freshSession();
  // The result names ANOTHER context than the one the call asked for.
  s = run(s, 'observe', {app: SAFARI, context: CTX_A}, observation('Safari', SAFARI, 501, 11, 1, CTX_B, 'B'));
  assert.deepEqual(Object.keys(s.lanes), []);
  // A label outside A-D.
  s = run(s, 'observe', {app: SAFARI, context: CTX_A}, observation('Safari', SAFARI, 501, 11, 1, CTX_A, 'Z'));
  assert.deepEqual(Object.keys(s.lanes), []);
  // A label already used by another panel would collide on the streamer slot.
  s = run(s, 'observe', {app: SAFARI, context: CTX_A}, observation('Safari', SAFARI, 501, 11, 1, CTX_A, 'A'));
  s = run(s, 'observe', {app: NOTES, context: CTX_B}, observation('Notes', NOTES, 502, 12, 1, CTX_B, 'A'));
  assert.deepEqual(Object.keys(s.lanes), [CTX_A]);
});

test('an action on an inherited context folds into its adopted lane, not the default panel', () => {
  let s = freshSession();
  s = run(s, 'observe', {app: SAFARI, context: CTX_A}, observation('Safari', SAFARI, 501, 11, 7, CTX_A, 'A'));
  const before = laneView(s, CTX_A).attemptRevision;
  s = run(s, 'press', {element_id: 3, snapshot: 7, context: CTX_A}, 'pressed [3]\nattributable: cursor_events_posted=False cursor_moved_by_action=False focus_became_target=False external_activity=False');
  assert.equal(s.target, null, 'the default panel stays empty');
  assert.ok(laneView(s, CTX_A).attemptRevision > before);
});

test('the adopted projection survives the checkpoint schema', () => {
  let s = freshSession();
  s = run(s, 'observe', {app: SAFARI, context: CTX_A}, observation('Safari', SAFARI, 501, 11, 7, CTX_A, 'A'));
  assert.doesNotThrow(() => stateSchema.parse(JSON.parse(JSON.stringify(s))));
});

test('a dismissal belongs to its session view: it never silences the context elsewhere', () => {
  let s = freshSession();
  s = run(s, 'observe', {app: SAFARI, context: CTX_A}, observation('Safari', SAFARI, 501, 11, 7, CTX_A, 'A'));
  const lane = laneView(s, CTX_A);
  // Session 'one' closed the panel for the activity it had at that time.
  const closedInOne = viewTransition(null, 'one', 'close', activityRevision(lane));
  assert.equal(pipPresentation(lane, {sessionId: 'one', view: closedInOne}).visible, false);
  // The same context in session 'two' is not affected by that view state...
  assert.equal(pipPresentation(lane, {sessionId: 'two', view: closedInOne}).visible, true);
  // ...and even in session 'one' it comes back with new activity.
  const later = run(s, 'observe', {app: SAFARI, context: CTX_A}, observation('Safari', SAFARI, 501, 11, 8, CTX_A, 'A'));
  const closedLow = viewTransition(null, 'one', 'close', activityRevision(lane));
  assert.equal(pipPresentation(laneView(later, CTX_A), {sessionId: 'one', view: closedLow}).visible, true);
});
