import { ACTIVE_SLOTS, LINEUP_STATUS } from './constants.js';

export function currentTeam(state) {
  return state.teams.find((team) => team.id === 'team-sam');
}

export function teamById(state, teamId) {
  return state.teams.find((team) => team.id === teamId);
}

export function assetById(state, assetId) {
  return state.assets.find((asset) => asset.id === assetId);
}

export function rosterForTeam(state, teamId) {
  return state.rosterMemberships
    .filter((membership) => membership.teamId === teamId)
    .map((membership) => ({
      ...membership,
      asset: assetById(state, membership.assetId),
    }));
}

export function activeRosterForTeam(state, teamId) {
  return rosterForTeam(state, teamId).filter(
    (membership) => membership.lineupStatus === LINEUP_STATUS.ACTIVE,
  );
}

export function benchRosterForTeam(state, teamId) {
  return rosterForTeam(state, teamId).filter(
    (membership) => membership.lineupStatus === LINEUP_STATUS.BENCH,
  );
}

export function pointsForTeam(state, teamId) {
  return rosterForTeam(state, teamId).reduce(
    (sum, membership) => sum + (membership.asset?.pointsForTeam ?? 0),
    0,
  );
}

export function ownedDraftPicks(state, teamId) {
  return state.draftPicks.filter((pick) => pick.currentTeamId === teamId);
}

export function keeperIdsForTeam(state, teamId) {
  return state.keeperSelections
    .filter((selection) => selection.teamId === teamId)
    .map((selection) => selection.assetId);
}

export function tradeItemsForSide(state, trade, side) {
  return trade.items
    .filter((item) => item.side === side)
    .map((item) => {
      if (item.type === 'ASSET') {
        const asset = assetById(state, item.assetId);
        return { ...item, label: asset?.name ?? 'Unknown asset' };
      }
      const pick = state.draftPicks.find((candidate) => candidate.id === item.draftPickId);
      const originalTeam = pick ? teamById(state, pick.originalTeamId) : null;
      return {
        ...item,
        label: pick
          ? `${pick.season} Round ${pick.round} · Originally ${originalTeam?.managerName ?? originalTeam?.name ?? 'Unknown'}`
          : 'Unknown draft pick',
      };
    });
}

export function draftOrderForRound(state, round) {
  const teams = state.teams;
  const snake = round % 2 === 0 ? [...teams].reverse() : teams;
  return snake.map((team, index) => {
    const pick = state.draftPicks.find(
      (candidate) => candidate.round === round && candidate.originalTeamId === team.id,
    );
    return {
      overall: (round - 1) * teams.length + index + 1,
      round,
      originalTeamId: team.id,
      currentTeamId: pick?.currentTeamId ?? team.id,
      draftPickId: pick?.id ?? null,
    };
  });
}

export function activeSlotCount(state, teamId) {
  return activeRosterForTeam(state, teamId).length;
}

export function canActivate(state, teamId) {
  return activeSlotCount(state, teamId) < ACTIVE_SLOTS;
}
