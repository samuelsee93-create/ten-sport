import test from 'node:test';
import assert from 'node:assert/strict';
import { LocalLeagueService } from '../src/services/localLeagueService.js';
import { createSeedState } from '../src/domain/seed.js';
import { SPORTS } from '../src/domain/constants.js';
import { rankedAssets, draftEligibility, remainingPickSeconds } from '../src/domain/draft.js';
import { draftOrder } from '../src/domain/selectors.js';

globalThis.localStorage = { getItem: () => null, setItem: () => {} };
function league() {
  const service = new LocalLeagueService();
  service.state = createSeedState();
  service.state.rosterMemberships = [];
  service.state.assets.forEach(asset => { if (asset.sport === '6 Nations') asset.sport = 'Super Rugby Pacific'; });
  service.state.draft.rounds = 20;
  service.state.draft.preferences = [];
  service.setDraftStatus('LIVE');
  return service;
}

test('countdown, timer update and pause/resume use deadline', () => {
  const service = league();
  const draft = service.state.draft;
  const deadline = Date.parse(draft.pickDeadlineAt);
  assert.equal(remainingPickSeconds(draft, deadline - 10200), 11);
  assert.equal(remainingPickSeconds(draft, deadline + 3000), 0);
  service.state.draft.pickDeadlineAt = new Date(Date.now() + 12000).toISOString();
  service.setDraftStatus('PAUSED');
  assert.equal(service.state.draft.pausedSeconds, 12);
  service.setDraftStatus('LIVE');
  assert.equal(remainingPickSeconds(service.state.draft), 12);
  service.setDraftTimer(30);
  assert.equal(remainingPickSeconds(service.state.draft), 30);
  assert.throws(() => service.setDraftTimer(0));
});

test('queue-first timeout skips already taken assets; absent queue uses highest rank', () => {
  const service = league();
  const ranked = rankedAssets(service.state);
  const taken = ranked[0], wanted = ranked.at(-1);
  service.state.rosterMemberships.push({teamId:'other',assetId:taken.id,lineupStatus:'ACTIVE'});
  service.state.draft.preferences = [{assetId:taken.id,queuePosition:1},{assetId:wanted.id,queuePosition:2}];
  service.state.draft.pickDeadlineAt = new Date(Date.now() - 1000).toISOString();
  service.syncDraftClock();
  assert.equal(service.state.draft.selections[0].assetId, wanted.id);
  assert.equal(service.state.draft.selections[0].autoPicked, true);
  assert.equal(service.state.rosterMemberships.length, 2);
  const nextTeam = draftOrder(service.state)[1].currentTeamId;
  const expected = rankedAssets(service.state).find(asset => !draftEligibility(service.state, nextTeam, asset));
  service.state.draft.pickDeadlineAt = new Date(Date.now() - 1000).toISOString();
  service.syncDraftClock();
  assert.equal(service.state.draft.selections[1].assetId, expected.id);
});

test('last roster slot reserves missing sport and swapped picks retain their owner', () => {
  const service = league();
  const s = service.state;
  const required = SPORTS.filter(sport => sport !== 'Tennis').map(sport => s.assets.find(a => a.sport === sport));
  const repeats = Array.from({length:10}, (_, i) => ({id:`repeat-${i}`,sport:'NHL',name:`Repeat ${i}`}));
  s.assets.push(...repeats);
  s.rosterMemberships = [...required,...repeats].map(a => ({teamId:s.currentTeamId,assetId:a.id,lineupStatus:'ACTIVE'}));
  const nhl = s.assets.find(a => a.sport === 'NHL' && !s.rosterMemberships.some(m => m.assetId === a.id));
  assert.equal(draftEligibility(s,s.currentTeamId,nhl),'Need a missing sport');
  assert.equal(draftEligibility(s,s.currentTeamId,s.assets.find(a => a.sport === 'Tennis')),null);
  const pick = s.draftPicks.find(p => p.round === 1 && p.originalTeamId === s.currentTeamId);
  pick.currentTeamId = 'team-akash';
  assert.equal(draftOrder(s)[0].currentTeamId,'team-akash');
});

test('swap preserves full 15/5 lineup; locked second asset leaves original lineup intact', () => {
  const service = league();
  const s = service.state;
  s.rosterMemberships = s.assets.slice(0,20).map((a,i) => ({teamId:s.currentTeamId,assetId:a.id,lineupStatus:i<15?'ACTIVE':'BENCH'}));
  const a=s.rosterMemberships[0].assetId,b=s.rosterMemberships[19].assetId;
  s.lockedAssetIds=[b];
  assert.throws(() => service.swapLineupAssets(s.currentTeamId,a,b), /locked/);
  assert.equal(service.state.rosterMemberships[0].lineupStatus,'ACTIVE');
  s.lockedAssetIds=[];
  service.swapLineupAssets(s.currentTeamId,a,b);
  assert.equal(service.state.rosterMemberships.filter(m=>m.lineupStatus==='ACTIVE').length,15);
  assert.equal(service.state.rosterMemberships[0].lineupStatus,'BENCH');
});
