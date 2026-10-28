// Component/controller contract using element descriptors. No DOM, pixels, focus
// engine, CSS layout or claim of real React/Desktop rendering.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as r from '../runtime.mjs';
import {seat,nodes,text} from './seat.mjs';

const state=()=>({...r.initialState(),active:true,revision:2,guiRevision:2,bridge:'compatible',
  policy:'background',grants:[{name:'Fixture',bundle:'fixture',scopes:['observe']}],
  target:{name:'Fixture',bundle:'fixture',background:true,pid:123,snapshot:1,window:'Fixture — ensayo'}});

test('collapsed component exposes one named button and no debug dashboard',()=>{
  const s=seat(state(),{demo:true}),tree=s.draw(null),buttons=nodes(tree,'button');
  assert.equal(buttons.length,1);
  assert.equal(buttons[0].props['aria-expanded'],false);
  assert.ok(buttons[0].props['aria-label']);
  assert.equal(nodes(tree,'figure').length,0);
  assert.equal(nodes(tree,'dl').length,0);
  buttons[0].props.onClick();
  assert.equal(s.getView().mode,'mini');
});

test('open controls are named icons with distinct collapse, close and local Escape',()=>{
  const s=seat(state()),tree=s.draw({sessionId:'a',mode:'mini'}),buttons=nodes(tree,'button');
  for(const b of buttons)assert.ok(b.props['aria-label']);
  assert.equal(nodes(tree,'header').length,1);
  // Technical facts stay out of the everyday card: only the authorized name shows.
  const card=JSON.stringify(tree);
  for(const leaked of ['pid','snapshot','bundle','scopes','protocol'])assert.equal(card.includes(leaked),false,'leaked '+leaked);
  const close=buttons.find(b=>b.props['aria-label']==='closeView');assert.ok(close);
  close.props.onClick();assert.equal(s.getView().mode,'closed');
  const collapse=buttons.find(b=>b.props['aria-label']==='collapse');collapse.props.onClick();
  assert.equal(s.getView().mode,'indicator');
  let stopped=false,prevented=false;
  tree.props.onKeyDown({key:'Escape',stopPropagation(){stopped=true},preventDefault(){prevented=true}});
  assert.equal(s.getView().mode,'indicator');assert.equal(stopped,true);assert.equal(prevented,true);
});

test('demo bundle has no everyday debug control; explicit isolated flag is separate',()=>{
  const s=seat(state(),{demo:true}),tree=s.draw({sessionId:'a',mode:'mini'});
  assert.equal(nodes(tree,'button').some(b=>b.children.includes('showTest')),false);
  // the everyday card paints the live mirror of the authorized window, so
  // the invariant is "no test image and no admitted pixels", not "no <img>".
  assert.equal(nodes(tree,'img').filter(i=>String(i.props.src).startsWith('data:')).length,0);
  assert.equal(tree.props['data-phase'],'observed-no-frame');
});

test('selection guard hides stale session component before any attachment read',()=>{
  const s=seat(state());s.select('b');assert.equal(s.draw({sessionId:'a',mode:'mini'}),null);
});

test('open and Escape request focus only on the newly mounted internal control',()=>{
  const s=seat(state());let tree=s.draw(null);
  nodes(tree,'button')[0].props.onClick();
  tree=s.draw(s.getView());
  // The compact header doubles as the keyboard move handle: no extra glyph.
  const head=nodes(tree,'header')[0];
  assert.ok(head.props.ref,'opening must provide an internal focus destination');
  assert.equal(head.props.tabIndex,0);
  let opened=0;
  head.props.ref.current={focus:opts=>{assert.equal(opts.preventScroll,true);opened++;}};
  s.runEffects();
  assert.equal(opened,1);
  tree.props.onKeyDown({key:'Escape',preventDefault(){},stopPropagation(){}});
  tree=s.draw(s.getView());
  let collapsed=0;
  nodes(tree,'button')[0].props.ref.current={focus:()=>collapsed++};
  s.runEffects();
  assert.equal(collapsed,1);
  assert.equal(text(tree).includes('Fixture'),true);
});
