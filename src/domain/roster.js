import { previousScore } from './draft.js';
import { rosterForTeam } from './selectors.js';

export function assetRanks(state) {
  const rows = state.assets.map(asset => ({ asset, points: previousScore(state, asset)?.points ?? 0 }))
    .sort((a,b) => b.points-a.points || a.asset.sport.localeCompare(b.asset.sport) || a.asset.name.localeCompare(b.asset.name));
  const counts = {};
  return Object.fromEntries(rows.map(({asset}, index) => {
    counts[asset.sport] = (counts[asset.sport] ?? 0) + 1;
    return [asset.id, { overall: index+1, sport: counts[asset.sport] }];
  }));
}

export function sortedRoster(state, teamId, sort, filters = {}, watchedIds = [], keeperIds = []) {
  const ranks = assetRanks(state);
  const watched = new Set(watchedIds), keepers = new Set(keeperIds);
  const direction = sort.direction === 'ASC' ? 1 : -1;
  return rosterForTeam(state, teamId).map(row => ({ ...row, previous: previousScore(state,row.asset),
    points: state.teamAssetPointsById?.[teamId]?.[row.assetId] ?? row.asset.pointsForTeam ?? 0,
    rank: ranks[row.assetId], watched: watched.has(row.assetId), keeper: keepers.has(row.assetId),
  })).filter(row => (!filters.query || row.asset.name.toLowerCase().includes(filters.query.trim().toLowerCase()))
    && (!filters.sport || filters.sport === 'ALL' || row.asset.sport === filters.sport)
    && (!filters.lineup || filters.lineup === 'ALL' || row.lineupStatus === filters.lineup)
    && (!filters.watch || filters.watch === 'ALL' || row.watched))
    .sort((a,b) => {
      if (a.lineupStatus !== b.lineupStatus) return a.lineupStatus === 'ACTIVE' ? -1 : 1;
      let comparison = 0;
      if (sort.key === 'NAME') comparison = a.asset.name.localeCompare(b.asset.name);
      if (sort.key === 'SPORT') comparison = a.asset.sport.localeCompare(b.asset.sport);
      if (sort.key === 'POINTS') comparison = a.points-b.points;
      if (sort.key === 'PREVIOUS') comparison = (a.previous?.points ?? 0)-(b.previous?.points ?? 0);
      if (sort.key === 'RANK') comparison = a.rank.overall-b.rank.overall;
      if (sort.key === 'WATCH') comparison = Number(a.watched)-Number(b.watched);
      if (sort.key === 'KEEPER') comparison = Number(a.keeper)-Number(b.keeper);
      if (sort.key === 'STATUS') comparison = Number(state.lockedAssetIds.includes(a.assetId))-Number(state.lockedAssetIds.includes(b.assetId));
      return comparison*direction || a.asset.name.localeCompare(b.asset.name);
    });
}

export function keeperChoices(state, teamId) {
  const plan = state.keeperPlan;
  const designated = plan?.designations ?? state.keeperDesignations ?? [];
  const formal = plan?.mode === 'UPCOMING' ? state.keeperSelections : [];
  return [...new Set([...designated,...formal].filter(row => row.teamId === teamId).map(row => row.assetId))];
}
