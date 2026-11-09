// P1 (0.3.3 closing): two panels must be BORN side by side, never stacked.
// The default position of a panel is derived from the previous panel's real
// box (anchored to the viewport, re-derived on resize); a manual drag still
// wins afterwards. A single panel keeps exactly its 0.3.2 default.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import * as r from '../runtime.mjs';

const G = r.GUTTER;
const box = (p, card) => ({x: p.x, y: p.y, width: card.width, height: card.height});
const overlap = (a, b) => a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;
const inside = (b, frame) => b.x >= 0 && b.y >= 0 && b.x + b.width <= frame.width && b.y + b.height <= frame.height;

test('a single panel keeps its 0.3.2 default (no previous panel)', () => {
  const frame = {width: 1200, height: 900}, card = {width: 320, height: 232};
  assert.equal(typeof r.autoPosition, 'function');
  assert.deepEqual(r.autoPosition(null, frame, card), r.overlayPosition(null, frame, card));
  assert.deepEqual(r.autoPosition(undefined, frame, card), {x: 1200 - 320 - G, y: 68});
});

test('the second panel is born beside the first, on the same row', () => {
  const frame = {width: 1200, height: 900}, card = {width: 320, height: 232};
  const a = r.autoPosition(null, frame, card);
  const b = r.autoPosition(box(a, card), frame, card);
  assert.deepEqual(b, {x: a.x - G - card.width, y: a.y});
  assert.equal(overlap(box(a, card), box(b, card)), false);
});

test('an expanded first panel does not cover the second', () => {
  const frame = {width: 1400, height: 900};
  const big = {width: 640, height: 480}, small = {width: 320, height: 232};
  const a = r.autoPosition(null, frame, big);
  const b = r.autoPosition(box(a, big), frame, small);
  assert.equal(overlap(box(a, big), box(b, small)), false);
  assert.equal(inside(box(b, small), frame), true);
});

test('a window too narrow for two columns stacks the second panel below the first', () => {
  const frame = {width: 600, height: 900}, card = {width: 320, height: 232};
  const a = r.autoPosition(null, frame, card);
  const b = r.autoPosition(box(a, card), frame, card);
  assert.deepEqual(b, {x: a.x, y: a.y + card.height + G});
  assert.equal(overlap(box(a, card), box(b, card)), false);
  assert.equal(inside(box(b, card), frame), true);
});

test('after a resize the default is re-derived and still never overlaps when it fits', () => {
  const card = {width: 320, height: 232};
  for (const width of [1600, 1280, 1000, 760, 700, 640, 600, 480, 360]) {
    const frame = {width, height: 900};
    const a = r.autoPosition(null, frame, card);
    const b = r.autoPosition(box(a, card), frame, card);
    assert.equal(overlap(box(a, card), box(b, card)), false, 'overlap at width ' + width);
    assert.equal(inside(box(b, card), frame), true, 'outside at width ' + width);
  }
});

test('when nothing fits, the second panel still stays inside the window', () => {
  const frame = {width: 340, height: 300}, card = {width: 320, height: 232};
  const a = r.autoPosition(null, frame, card);
  const b = r.autoPosition(box(a, card), frame, card);
  assert.equal(inside(box(b, card), frame), true);
});

test('the manual position still wins and is clamped as in 0.3.2', () => {
  const frame = {width: 1200, height: 900}, card = {width: 320, height: 232};
  assert.deepEqual(r.overlayPosition({x: -999, y: -999}, frame, card), {x: G, y: 68});
  assert.deepEqual(r.overlayPosition({x: 5000, y: 5000}, frame, card), {x: 1200 - 320 - G, y: 900 - 232 - G});
});

test('the template derives the default from the previous panel and only a drag makes it manual', () => {
  const src = fs.readFileSync(new URL('../client.template.js', import.meta.url), 'utf8');
  assert.match(src, /autoPosition\(/, 'the template must use the auto layout');
  assert.doesNotMatch(src, /right:16\+index\*336/, 'the dead fixed offset must be gone');
  assert.match(src, /manual\.current/, 'an automatic layout must stay automatic until the user moves the panel');
});
