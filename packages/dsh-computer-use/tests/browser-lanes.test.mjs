// F-09 in the DSH projection: a tab switch, a navigation or a download step
// that did not finish is NOT the loss of the window. The panel keeps its
// verified target (same bundle, pid and window id), drops only the static
// frame of the old page, and says what happened. Authority-revoking reasons
// (grant, process, window, breach, closed browser) still clear it. Lanes stay
// independent. The literal texts are what the adapter prints.
import test from 'node:test';
import assert from 'node:assert/strict';
import {initialState, fold, laneView, pipPresentation} from '../runtime.mjs';

const PREFIX = 'mcp__cmm-computer-use__computer_use_';
const CHROME = 'com.google.Chrome', SAFARI = 'com.apple.Safari';
const CTX_A = 'ctx_' + 'a'.repeat(32), CTX_B = 'ctx_' + 'b'.repeat(32);
const TAB = 'tab_' + '1'.repeat(32);
let seq = 0;
const VIEW = {sessionId: 's', mode: 'mini'};

const call = (s, name, args = {}) => {
  const id = 'c' + (++seq);
  return [fold(s, {type: 'assistant/message', seq, time: Date.now(),
    data: {message: {content: [{type: 'tool-call', id, name: PREFIX + name, arguments: JSON.stringify(args)}]}}}), id];
};
const result = (s, id, text, isError = false) => fold(s, {type: 'tool/result', seq: ++seq, time: Date.now(),
  data: {message: {source: {callId: id}, isError, content: [{type: 'text', text}]}}});
const run = (s, name, args, text, isError = false) => {
  const [next, id] = call(s, name, args);
  return result(next, id, text, isError);
};
const statusText = 'helper: cmm-computer-use protocol=1 pid=9\nbundle: com.cmm.chat.computer-use\n' +
  'deployment_policy: background\neffective_mode: background\nauthorization: *** loaded=True apps=2 default=deny\n' +
  `- authorized: Google Chrome [${CHROME}] scopes=control,observe windows=0\n` +
  `- authorized: Safari [${SAFARI}] scopes=control,observe windows=0\naccessibility: True\nscreen_recording: True`;
const observation = (name, bundle, pid, windowId, title, context, label) =>
  `frontmost: DeepSeek Harness [com.deepseek.harness]\ntarget: ${name} [${bundle}] (background)\n` +
  `snapshot: 1 (pass it back with element actions)\n` +
  `cmm_view: ${JSON.stringify({bundle, pid, snapshot: 1, window: title, window_id: windowId,
    ...(context ? {context_id: context, context_label: label} : {})})}\n` +
  (context ? `context: ${label} ${context} (pass it as \`context\` with this snapshot)\n` : '') +
  'ax_access: actionable content=1 elements=1';
const opened = (label, id) => `context opened: ${label} ${id}\nPass \`context: ${id}\` to computer_use_observe.`;

function chromeDefault() {
  let s = run(initialState(), 'status', {}, statusText);
  return run(s, 'observe', {app: CHROME}, observation('Google Chrome', CHROME, 700, 41, 'Inbox', null, null));
}

function twoBrowsers() {
  let s = run(initialState(), 'status', {}, statusText);
  s = run(s, 'context_open', {app: 'Google Chrome'}, opened('A', CTX_A));
  s = run(s, 'context_open', {app: 'Safari'}, opened('B', CTX_B));
  s = run(s, 'observe', {app: CHROME, context: CTX_A}, observation('Google Chrome', CHROME, 700, 41, 'Inbox', CTX_A, 'A'));
  s = run(s, 'observe', {app: SAFARI, context: CTX_B}, observation('Safari', SAFARI, 701, 42, 'Docs', CTX_B, 'B'));
  return s;
}

const DOC_CHANGED = 'REFUSED ACTION_FAILED: The document this element belongs to is no longer the one that was ' +
  'observed; observe again. [policy=background;reason=document_changed]\n' +
  'meaning: document_changed — the page or tab changed; the connection and the context are intact';

test('a press refused because the page changed keeps the panel and its window', () => {
  const s = run(chromeDefault(), 'press', {element_id: 3, snapshot: 1}, DOC_CHANGED, true);
  assert.equal(s.target.bundle, CHROME, 'the verified target survives');
  assert.equal(s.target.windowId, 41, 'the live mirror stays on the same window');
  assert.equal(s.frame, null, 'the old page frame is dropped');
  assert.equal(s.error, 'document_changed');
  assert.equal(s.message, 'page changed · re-observe');
  assert.notEqual(s.bridge, 'disconnected', 'never reported as a disconnection');
  const view = pipPresentation(s, {sessionId: 's', view: VIEW});
  assert.equal(view.visible, true);
  assert.equal(view.app, 'Google Chrome');
});

test('authority-revoking reasons still clear the panel', () => {
  for (const reason of ['app_not_granted', 'pid_changed', 'window_changed', 'app_closed', 'breach']) {
    const s = run(chromeDefault(), 'press', {element_id: 3, snapshot: 1},
      `REFUSED ACTION_FAILED: no [policy=background;reason=${reason}]`, true);
    assert.equal(s.target, null, reason);
  }
  const closed = run(chromeDefault(), 'browser_state', {},
    'REFUSED COMPUTER_TARGET_UNAVAILABLE: The browser this context belongs to is not running. [reason=app_closed;transition=app_closed]', true);
  assert.equal(closed.target, null, 'a closed browser is a real loss');
});

test('a tab switch is an interaction that keeps the target', () => {
  let [s, id] = call(chromeDefault(), 'browser_select_tab', {tab_id: TAB});
  assert.equal(pipPresentation(s, {sessionId: 's', view: VIEW}).status, 'interacting');
  s = result(s, id, 'browser.select_tab: tab selected\nexecution: executed=True outcome=succeeded\n' +
    'The tab is selected; the connection is intact. Fresh observation:\n' +
    observation('Google Chrome', CHROME, 700, 41, 'Docs', null, null));
  assert.equal(s.target.bundle, CHROME);
  assert.equal(s.target.windowId, 41);
  assert.equal(s.error, null);
  assert.equal(s.attempt.name, 'browser_select_tab');
  assert.equal(s.attempt.failed, false);
});

test('reading the browser and waiting are observations, not losses', () => {
  let [s] = call(chromeDefault(), 'browser_wait', {until: 'settled'});
  assert.equal(pipPresentation(s, {sessionId: 's', view: VIEW}).status, 'observing');
  s = run(chromeDefault(), 'browser_state', {}, 'browser: Google Chrome [com.google.Chrome] family=chromium\n' +
    'since last look: tab_switched — another tab was selected; the connection is intact');
  assert.equal(s.target.bundle, CHROME);
  assert.equal(s.error, null);
});

test('a download that is not verified keeps the panel and says so', () => {
  const s = run(chromeDefault(), 'download', {element_id: 5, snapshot: 1},
    'press: succeeded\ndownload dl_x: not_started\nNOT VERIFIED: a save dialog is open: use computer_use_save_dialog', true);
  assert.equal(s.target.bundle, CHROME);
  assert.equal(s.error, 'NOT_VERIFIED');
  const conflict = run(chromeDefault(), 'save_dialog', {filename: 'a.pdf'},
    'REFUSED ACTION_FAILED: A file with that name already exists. [policy=background;kind=browser.save_dialog;reason=name_conflict]', true);
  assert.equal(conflict.target.bundle, CHROME);
  assert.equal(conflict.error, 'ACTION_FAILED');
});

test('browser trouble in lane A never touches lane B', () => {
  let s = twoBrowsers();
  s = run(s, 'press', {element_id: 1, snapshot: 1, context: CTX_A}, DOC_CHANGED, true);
  s = run(s, 'download', {element_id: 2, snapshot: 1, context: CTX_A},
    'press: unknown\nNOT VERIFIED: no download started', true);
  assert.equal(s.lanes[CTX_A].target.bundle, CHROME);
  assert.equal(s.lanes[CTX_A].error, 'NOT_VERIFIED');
  assert.equal(s.lanes[CTX_B].target.bundle, SAFARI);
  assert.equal(s.lanes[CTX_B].error, null);
  const b = pipPresentation(laneView(s, CTX_B), {sessionId: 's', view: VIEW});
  assert.notEqual(b.tone, 'error');
});
