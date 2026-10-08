import { SPORTS } from './constants.js';
import { rosterForTeam, ownedDraftPicks } from './selectors.js';

export function tradeablePicks(state, teamId) {
  const used = new Set((state.draft?.selections ?? []).map(row => row.draftPickId));
  const reserved = new Set(state.keeperSelections.map(row => row.forfeitedDraftPickId));
  const year = state.draft?.season ?? new Date().getFullYear();
  return ownedDraftPicks(state, teamId).filter(pick => pick.season >= year
    && !(pick.season === year && state.draft?.status === 'COMPLETE')
    && !used.has(pick.id) && !reserved.has(pick.id))
    .sort((a, b) => a.season - b.season || a.round - b.round || a.originalTeamId.localeCompare(b.originalTeamId));
}

export function rosterMoveError(state, teamId, outgoingIds, incomingIds) {
  const assets = [...rosterForTeam(state, teamId).filter(row => !outgoingIds.includes(row.assetId)).map(row => row.asset),
    ...incomingIds.map(id => state.assets.find(asset => asset.id === id))];
  const limit = state.league.rosterSize ?? 20;
  if (assets.length > limit) return 'Roster is full; include an asset to send or drop.';
  const sports = new Set(assets.map(asset => asset?.sport));
  if (SPORTS.filter(sport => !sports.has(sport)).length > limit - assets.length) return 'This move would prevent the roster from representing all 10 sports.';
  return '';
}

export function tradeError(state, fromTeamId, toTeamId, items) {
  if (!fromTeamId || !toTeamId || fromTeamId === toTeamId || !state.teams.some(t => t.id === toTeamId)) return 'Choose another team.';
  if (state.league.tradeDeadline && Date.now() > new Date(state.league.tradeDeadline).getTime()) return 'The trade deadline has passed.';
  if (!items.some(i => i.side === 'FROM') || !items.some(i => i.side === 'TO')) return 'Select at least one asset or pick on each side.';
  const seen = new Set();
  for (const item of items) {
    const key = `${item.type}:${item.assetId ?? item.draftPickId}`;
    if (seen.has(key)) return 'An asset or pick can only appear once in a trade.';
    seen.add(key);
    const owner = item.side === 'FROM' ? fromTeamId : toTeamId;
    if (!['FROM', 'TO'].includes(item.side)) return 'Invalid trade side.';
    if (item.type === 'ASSET') {
      if (['LIVE', 'PAUSED'].includes(state.draft?.status)) return 'Asset trades are available after the draft finishes.';
      if (!state.rosterMemberships.some(m => m.teamId === owner && m.assetId === item.assetId)) return 'Asset ownership has changed.';
      if (state.lockedAssetIds.includes(item.assetId)) return 'An asset in this trade is currently locked.';
    } else if (item.type !== 'DRAFT_PICK' || !tradeablePicks(state, owner).some(p => p.id === item.draftPickId)) return 'Draft pick is unavailable or ownership has changed.';
  }
  const from = items.filter(i => i.side === 'FROM' && i.type === 'ASSET').map(i => i.assetId);
  const to = items.filter(i => i.side === 'TO' && i.type === 'ASSET').map(i => i.assetId);
  return rosterMoveError(state, fromTeamId, from, to) || rosterMoveError(state, toTeamId, to, from);
}
