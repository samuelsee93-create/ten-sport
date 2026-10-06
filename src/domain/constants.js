export const SPORTS = [
  'NHL',
  'NFL',
  'F1',
  'Golf',
  'NBA',
  'MLB',
  'UCL',
  'NCAA',
  'Super Rugby Pacific',
  'Tennis',
];

export const ROSTER_SIZE = 20;
export const ACTIVE_SLOTS = 15;
export const BENCH_SLOTS = 5;
export const KEEPER_SLOTS = 3;
export const ASSET_SEASON_CEILING = 1000;

export const LINEUP_STATUS = Object.freeze({
  ACTIVE: 'ACTIVE',
  BENCH: 'BENCH',
});

export const TRADE_STATUS = Object.freeze({
  PENDING: 'PENDING',
  ACCEPTED: 'ACCEPTED',
  DECLINED: 'DECLINED',
  COUNTERED: 'COUNTERED',
  REVERSED: 'REVERSED',
});

export const DRAFT_STATUS = Object.freeze({
  SCHEDULED: 'SCHEDULED',
  LOBBY: 'LOBBY',
  LIVE: 'LIVE',
  PAUSED: 'PAUSED',
  COMPLETE: 'COMPLETE',
});
