import test from 'node:test';
import assert from 'node:assert/strict';
import { createSeedState } from '../src/domain/seed.js';
import { sortedRoster, assetRanks } from '../src/domain/roster.js';

test('all roster sorts keep active and bench in separate ordered groups', () => {
  const state = createSeedState();
  state.assets = structuredClone(state.assets);
  state.assets.find(a=>a.id==='asset-20').pointsForTeam=9999;
  for(const key of ['NAME','SPORT','POINTS','PREVIOUS','RANK','WATCH','KEEPER','STATUS']) {
    for(const direction of ['ASC','DESC']) {
      const rows=sortedRoster(state,state.currentTeamId,{key,direction},{},['asset-1','asset-20'],['asset-2','asset-18']);
      assert.equal(rows.length,20);
      assert.ok(rows.slice(0,15).every(r=>r.lineupStatus==='ACTIVE'),`${key} ${direction} active first`);
      assert.ok(rows.slice(15).every(r=>r.lineupStatus==='BENCH'),`${key} ${direction} bench last`);
    }
  }
  for(const direction of ['ASC','DESC']) {
    const rows=sortedRoster(state,state.currentTeamId,{key:'POINTS',direction});
    for(const group of [rows.slice(0,15),rows.slice(15)]) {
      assert.deepEqual(group.map(r=>r.points),group.map(r=>r.points).sort((a,b)=>direction==='ASC'?a-b:b-a));
    }
  }
  assert.equal(sortedRoster(state,state.currentTeamId,{key:'RANK',direction:'ASC'}, {sport:'Tennis'}).length,2);
  assert.equal(sortedRoster(state,state.currentTeamId,{key:'NAME',direction:'ASC'}, {query:'alcaraz'})[0].asset.name,'Carlos Alcaraz');
  assert.equal(sortedRoster(state,state.currentTeamId,{key:'WATCH',direction:'DESC'}, {watch:'WATCHED'},['asset-20'])[0].assetId,'asset-20');
  assert.ok(assetRanks(state)['asset-20'].overall>0);
});
