import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { createRequire } from 'node:module';
import { createSeedState } from '../src/domain/seed.js';

test('draft room queue selection, team counts, ticker, timer controls, and left-column lineup swap', async (t) => {
  let draftRoot;
  const dom = new JSDOM('<div id="root"></div>', { url: 'http://localhost' });
  Object.assign(globalThis, { window: dom.window, document: dom.window.document, localStorage: dom.window.localStorage, IS_REACT_ACT_ENVIRONMENT: true });
  const state = createSeedState();
  state.assets.forEach(a => { if (a.sport === '6 Nations') a.sport = 'Super Rugby Pacific'; });
  localStorage.setItem('ten-sport-v0.3', JSON.stringify(state));
  const bundle = await build({ entryPoints: ['src/App.jsx'], bundle: true, write: false, platform: 'node', format: 'cjs',
    external: ['react','react-dom'], define: { 'import.meta.env.VITE_SUPABASE_URL': '""', 'import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY': '""' } });
  const module = {exports:{}};
  new Function('require','module','exports',bundle.outputFiles[0].text)(createRequire(import.meta.url),module,module.exports);
  const root=createRoot(document.getElementById('root'));
  t.after(async()=>{ await act(async()=>{root.unmount();draftRoot?.unmount();});dom.window.close(); });
  const buttons=(scope=document)=>[...scope.querySelectorAll('button')];
  const click=async button=>{assert.ok(button,'Button exists');assert.equal(button.disabled,false);await act(async()=>button.click());};
  const exact=(text,scope=document)=>buttons(scope).find(b=>b.textContent===text);
  const card=(title)=>[...document.querySelectorAll('.card')].find(c=>c.querySelector('h2')?.textContent.trim()===title);
  await act(async()=>root.render(React.createElement(module.exports.default)));
  await click(exact('My Team',document.querySelector('nav')));
  assert.equal(document.querySelector('.team-roster-table th').textContent,'Pos');
  await click(exact('ACT',document.querySelector('.team-roster-table')));
  await click(exact('Swap',document.querySelector('.team-roster-table')));
  assert.equal(document.querySelectorAll('.team-roster-table .lineup-position button').length,20);
  assert.equal(buttons(document.querySelector('.team-roster-table')).filter(b=>b.textContent==='ACT').length,15);
  assert.equal(buttons(document.querySelector('.team-roster-table')).filter(b=>b.textContent==='BN').length,5);
  await act(async()=>root.unmount());

  // Fresh draft fixture, without existing roster ownership from the demo season.
  state.rosterMemberships=[];
  state.draft.preferences=[{id:'q',assetId:'asset-extra-3',queuePosition:1,starred:false}];
  state.draft.status='LIVE';
  state.draft.pickDeadlineAt=new Date(Date.now()+90000).toISOString();
  localStorage.setItem('ten-sport-v0.3',JSON.stringify(state));
  // Reload the bundle to create a fresh service singleton.
  const draftModule={exports:{}};
  new Function('require','module','exports',bundle.outputFiles[0].text)(createRequire(import.meta.url),draftModule,draftModule.exports);
  draftRoot=createRoot(document.getElementById('root'));
  await act(async()=>draftRoot.render(React.createElement(draftModule.exports.default)));
  await click(exact('Draft',document.querySelector('nav')));
  assert.ok(document.querySelector('[aria-label="Pick timer seconds"]'));
  assert.ok(document.querySelector('.draft-ticker .on-clock').textContent.includes('The Decathletes'));
  await click(buttons().find(b=>b.textContent.startsWith('My Queue')));
  const queue=card('My Draft Queue');
  assert.ok(queue, [...document.querySelectorAll('.card h2')].map(h=>h.textContent).join(' | '));
  assert.ok(queue.textContent.includes('Detroit Lions'));
  await click(exact('Draft',queue));
  assert.ok(document.querySelector('.last-pick').textContent.includes('Detroit Lions'));
  assert.ok(document.querySelector('.last-pick').textContent.includes('The Decathletes'));
  await click(exact('Team Rosters'));
  assert.ok(card('Team Rosters').textContent.includes('1/10 sports represented'));
  assert.ok(card('Team Rosters').textContent.includes('Detroit Lions'));
  await click(exact('Pause'));
  const frozen=document.querySelector('.timer').textContent;
  assert.ok(frozen.includes('Paused'));
  await click(exact('Resume'));
  assert.ok(!document.querySelector('.timer').textContent.includes('Paused'));
  await act(async()=>draftRoot.unmount());
  dom.window.close();
});
