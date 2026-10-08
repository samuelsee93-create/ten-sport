import { SPORTS } from './constants.js';
import { rosterForTeam } from './selectors.js';

export function previousScore(state, asset) {
  return (asset?.history ?? []).find(row => row.seasonLabel !== state.league?.season) ?? null;
}

export function rankedAssets(state) {
  const compare = (a, b) => a < b ? -1 : a > b ? 1 : 0;
  return state.assets.slice().sort((a, b) =>
    (previousScore(state, b)?.points ?? 0) - (previousScore(state, a)?.points ?? 0)
    || compare(a.sport, b.sport) || compare(a.name, b.name) || compare(a.id, b.id)
  );
}

export function draftEligibility(state, teamId, asset) {
  if (!asset || !SPORTS.includes(asset.sport)) return 'Asset is not draftable';
  if (state.rosterMemberships.some(row => row.assetId === asset.id)
    || state.draft?.selections.some(row => row.assetId === asset.id)) return 'Already drafted';
  const roster = rosterForTeam(state, teamId);
  const limit = state.league.rosterSize ?? 20;
  if (roster.length >= limit) return 'Roster is full';
  const represented = new Set([...roster.map(row => row.asset?.sport), asset.sport]);
  const missing = SPORTS.filter(sport => !represented.has(sport)).length;
  return limit - roster.length - 1 < missing ? 'Need a missing sport' : null;
}

export function remainingPickSeconds(draft, now = Date.now()) {
  if (!draft || draft.status === 'COMPLETE') return null;
  if (draft.status === 'PAUSED') return draft.pausedSeconds ?? draft.pickTimerSeconds;
  if (draft.status !== 'LIVE') return draft.pickTimerSeconds;
  if (!draft.pickDeadlineAt) return null;
  return Math.max(0, Math.ceil((Date.parse(draft.pickDeadlineAt) - now) / 1000));
}
