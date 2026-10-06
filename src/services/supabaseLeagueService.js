import { supabase, supabaseConfigured } from './supabaseClient.js';

function client() {
  if (!supabaseConfigured || !supabase) throw new Error('Supabase is not configured.');
  return supabase;
}

function unwrap(result, label) {
  if (result.error) throw new Error(`${label}: ${result.error.message}`);
  return result.data;
}

async function selectIn(table, columns, column, values) {
  if (!values?.length) return [];
  return unwrap(
    await client().from(table).select(columns).in(column, values),
    `Load ${table}`
  );
}

function sumBy(rows, key, value) {
  return rows.reduce((acc, row) => {
    const k = row[key];
    acc[k] = (acc[k] ?? 0) + Number(row[value] ?? 0);
    return acc;
  }, {});
}

export class SupabaseLeagueService {
  constructor() {
    this.listeners = new Set();
    this.state = null;
    this.unsubscribeRealtime = null;
    this.refreshQueued = false;
  }

  getState() {
    return this.state == null ? null : structuredClone(this.state);
  }

  subscribe(fn) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  emit() {
    const snapshot = this.getState();
    this.listeners.forEach((fn) => fn(snapshot));
  }

  requireState() {
    if (!this.state) throw new Error('Hosted league state has not been loaded yet.');
    return this.state;
  }

  async initialize() {
    const state = await this.refresh();
    this.startRealtime();
    return state;
  }

  async refresh() {
    const next = await this.loadLeagueState();
    this.state = next;
    this.emit();
    return this.getState();
  }

  queueRefresh() {
    if (this.refreshQueued) return;
    this.refreshQueued = true;
    setTimeout(async () => {
      try {
        await this.refresh();
      } finally {
        this.refreshQueued = false;
      }
    }, 75);
  }

  startRealtime() {
    if (!this.state) return;
    this.unsubscribeRealtime?.();
    this.unsubscribeRealtime = this.subscribeToLeagueState(
      {
        leagueId: this.state.league.id,
        seasonId: this.state.league.seasonId,
        draftId: this.state.draft?.id ?? null,
      },
      () => this.queueRefresh()
    );
  }

  dispose() {
    this.unsubscribeRealtime?.();
    this.unsubscribeRealtime = null;
    this.listeners.clear();
  }

  async getCurrentContext() {
    const c = client();
    const {
      data: { user },
      error: userError,
    } = await c.auth.getUser();
    if (userError) {
      const noSession =
        userError.name === 'AuthSessionMissingError'
        || /auth session missing/i.test(userError.message ?? '');
      if (noSession) throw new Error('Authentication required.');
      throw userError;
    }
    if (!user) throw new Error('Authentication required.');

    const membershipRows = unwrap(
      await c
        .from('league_memberships')
        .select('league_id,role,status')
        .eq('user_id', user.id)
        .eq('status', 'ACTIVE')
        .limit(1),
      'Load league membership'
    );

    let membership = membershipRows?.[0] ?? null;
    let leagueId = membership?.league_id ?? null;

    if (!leagueId) {
      const commissionerRows = unwrap(
        await c
          .from('leagues')
          .select('id')
          .eq('commissioner_user_id', user.id)
          .limit(1),
        'Load commissioner league'
      );
      leagueId = commissionerRows?.[0]?.id ?? null;
      if (leagueId) membership = { league_id: leagueId, role: 'COMMISSIONER', status: 'ACTIVE' };
    }

    if (!leagueId) {
      const { error: bootstrapError } = await c.rpc('bootstrap_first_league');
      if (!bootstrapError) {
        const refreshedMemberships = unwrap(
          await c
            .from('league_memberships')
            .select('league_id,role,status')
            .eq('user_id', user.id)
            .eq('status', 'ACTIVE')
            .limit(1),
          'Reload league membership'
        );
        membership = refreshedMemberships?.[0] ?? null;
        leagueId = membership?.league_id ?? null;
      } else if (!bootstrapError.message?.includes('League already exists')) {
        throw bootstrapError;
      }
    }

    if (!leagueId) {
      throw new Error('Your account is not assigned to an active Ten Sport league yet.');
    }

    const [profileResult, leagueResult, teamResult] = await Promise.all([
      c.from('profiles').select('id,display_name,avatar_url').eq('id', user.id).maybeSingle(),
      c.from('leagues').select('*').eq('id', leagueId).single(),
      c.from('teams').select('*').eq('league_id', leagueId).eq('owner_user_id', user.id).maybeSingle(),
    ]);

    const league = unwrap(leagueResult, 'Load league');
    const profile = unwrap(profileResult, 'Load profile');
    const team = unwrap(teamResult, 'Load team');

    let season = unwrap(
      await c
        .from('seasons')
        .select('*')
        .eq('league_id', leagueId)
        .in('status', ['ACTIVE', 'SETUP'])
        .order('keeper_deadline', { ascending: false, nullsFirst: false })
        .limit(1)
        .maybeSingle(),
      'Load current season'
    );

    if (!season) {
      season = unwrap(
        await c
          .from('seasons')
          .select('*')
          .eq('league_id', leagueId)
          .order('label', { ascending: false })
          .limit(1)
          .maybeSingle(),
        'Load latest season'
      );
    }

    if (!season) throw new Error('This league does not have a season yet.');

    return { user, profile, membership, league, season, team };
  }

  async loadLeagueState() {
    const c = client();
    const context = await this.getCurrentContext();
    const { user, profile, membership, league, season, team } = context;

    const [
      membershipsResult,
      teamsResult,
      assetsResult,
      rosterResult,
      keepersResult,
      picksResult,
      tradesResult,
      draftResult,
      eventsResult,
      auditResult,
    ] = await Promise.all([
      c.from('league_memberships').select('league_id,user_id,role,status').eq('league_id', league.id).eq('status', 'ACTIVE'),
      c.from('teams').select('*').eq('league_id', league.id),
      c.from('assets').select('*').eq('active', true),
      c.from('roster_memberships').select('*').eq('season_id', season.id),
      c.from('keeper_selections').select('*').eq('season_id', season.id),
      c.from('draft_picks').select('*').eq('league_id', league.id),
      c.from('trades').select('*').eq('season_id', season.id).order('created_at', { ascending: false }),
      c.from('drafts').select('*').eq('season_id', season.id).maybeSingle(),
      c.from('scoring_events').select('*').eq('season_id', season.id),
      c.from('audit_log').select('*').eq('league_id', league.id).order('created_at', { ascending: false }).limit(100),
    ]);

    const memberships = unwrap(membershipsResult, 'Load memberships') ?? [];
    const teams = unwrap(teamsResult, 'Load teams') ?? [];
    const assets = unwrap(assetsResult, 'Load assets') ?? [];
    const roster = unwrap(rosterResult, 'Load rosters') ?? [];
    const keepers = unwrap(keepersResult, 'Load keepers') ?? [];
    const picks = unwrap(picksResult, 'Load draft picks') ?? [];
    const trades = unwrap(tradesResult, 'Load trades') ?? [];
    const draft = unwrap(draftResult, 'Load draft') ?? null;
    const events = unwrap(eventsResult, 'Load scoring events') ?? [];
    const audit = unwrap(auditResult, 'Load audit log') ?? [];

    const profileIds = [...new Set(teams.map((t) => t.owner_user_id))];
    const profiles = await selectIn('profiles', 'id,display_name,avatar_url', 'id', profileIds);
    const tradeItems = await selectIn('trade_items', '*', 'trade_id', trades.map((t) => t.id));
    const selections = draft
      ? unwrap(
          await c
            .from('draft_selections')
            .select('*')
            .eq('draft_id', draft.id)
            .order('overall_pick', { ascending: true }),
          'Load draft selections'
        ) ?? []
      : [];

    const eventIds = events.map((e) => e.id);
    const eventAssets = await selectIn('scoring_event_assets', '*', 'scoring_event_id', eventIds);
    const pointTransactions = await selectIn('point_transactions', '*', 'scoring_event_id', eventIds);
    const managerPoints = await selectIn(
      'manager_point_transactions',
      '*',
      'point_transaction_id',
      pointTransactions.map((p) => p.id)
    );

    const profileById = Object.fromEntries(profiles.map((p) => [p.id, p]));
    const membershipByUserId = Object.fromEntries(memberships.map((m) => [m.user_id, m]));
    const pointById = Object.fromEntries(pointTransactions.map((p) => [p.id, p]));
    const seasonPointsByAsset = sumBy(pointTransactions, 'asset_id', 'points');
    const teamPointsById = sumBy(managerPoints, 'team_id', 'counted_points');

    const teamAssetPointsById = {};
    for (const row of managerPoints) {
      const assetId = pointById[row.point_transaction_id]?.asset_id;
      if (!assetId) continue;
      teamAssetPointsById[row.team_id] ??= {};
      teamAssetPointsById[row.team_id][assetId] =
        (teamAssetPointsById[row.team_id][assetId] ?? 0) + Number(row.counted_points ?? 0);
    }

    const currentTeamId = team?.id ?? null;
    const currentTeamAssetPoints = currentTeamId ? teamAssetPointsById[currentTeamId] ?? {} : {};
    const now = Date.now();
    const activeEventIds = new Set(
      events
        .filter((e) => {
          const locksAt = new Date(e.locks_at).getTime();
          const occurredAt = e.occurred_at ? new Date(e.occurred_at).getTime() : null;
          return now >= locksAt && (occurredAt === null || now <= occurredAt);
        })
        .map((e) => e.id)
    );

    const lockedAssetIds = [
      ...new Set(
        eventAssets
          .filter((ea) => activeEventIds.has(ea.scoring_event_id))
          .map((ea) => ea.asset_id)
      ),
    ];

    const itemsByTradeId = tradeItems.reduce((acc, item) => {
      (acc[item.trade_id] ??= []).push(item);
      return acc;
    }, {});

    return {
      version: 4,
      currentUserId: user.id,
      currentTeamId,
      currentRole: membership?.role ?? 'MANAGER',
      currentUser: {
        id: user.id,
        displayName: profile?.display_name ?? user.email ?? 'Manager',
        avatarUrl: profile?.avatar_url ?? null,
      },
      league: {
        id: league.id,
        name: league.name,
        seasonId: season.id,
        season: season.label,
        scoringVersion: season.scoring_version,
        keeperDeadline: season.keeper_deadline,
        tradeDeadline: season.trade_deadline,
        rosterSize: league.roster_size,
        activeSlots: league.active_slots,
        benchSlots: league.bench_slots,
        keeperSlots: league.keeper_slots,
      },
      teams: teams.map((row) => ({
        id: row.id,
        name: row.name,
        logoUrl: row.logo_url,
        ownerUserId: row.owner_user_id,
        managerName: profileById[row.owner_user_id]?.display_name ?? 'Manager',
        managerAvatarUrl: profileById[row.owner_user_id]?.avatar_url ?? null,
        role: membershipByUserId[row.owner_user_id]?.role ?? 'MANAGER',
      })),
      assets: assets.map((row) => ({
        id: row.id,
        name: row.name,
        sport: row.sport,
        externalKey: row.external_key,
        seasonPoints: seasonPointsByAsset[row.id] ?? 0,
        pointsForTeam: currentTeamAssetPoints[row.id] ?? 0,
      })),
      rosterMemberships: roster.map((row) => ({
        id: row.id,
        teamId: row.team_id,
        assetId: row.asset_id,
        lineupStatus: row.lineup_status,
        acquiredAt: row.acquired_at,
      })),
      keeperSelections: keepers.map((row) => ({
        id: row.id,
        teamId: row.team_id,
        assetId: row.asset_id,
        lockedAt: row.locked_at,
      })),
      draftPicks: picks.map((row) => ({
        id: row.id,
        season: row.draft_year,
        round: row.round,
        slot: row.slot,
        originalTeamId: row.original_team_id,
        currentTeamId: row.current_team_id,
      })),
      trades: trades.map((row) => ({
        id: row.id,
        fromTeamId: row.proposer_team_id,
        toTeamId: row.recipient_team_id,
        status: row.status,
        createdAt: row.created_at,
        resolvedAt: row.resolved_at,
        items: (itemsByTradeId[row.id] ?? []).map((item) => ({
          id: item.id,
          side: item.side === 'PROPOSER' ? 'FROM' : 'TO',
          type: item.item_type,
          assetId: item.asset_id,
          draftPickId: item.draft_pick_id,
        })),
      })),
      draft: draft
        ? {
            id: draft.id,
            season: new Date(draft.scheduled_at ?? Date.now()).getFullYear(),
            scheduledAt: draft.scheduled_at,
            pickTimerSeconds: draft.pick_timer_seconds,
            status: draft.status,
            currentOverallPick: draft.current_overall_pick,
            rounds: draft.rounds,
            selections: selections.map((row) => ({
              id: row.id,
              overallPick: row.overall_pick,
              round: row.round,
              teamId: row.team_id,
              assetId: row.asset_id,
              draftPickId: row.draft_pick_id,
              createdAt: row.selected_at,
            })),
          }
        : null,
      lockedAssetIds,
      transactionLog: audit.map((row) => ({
        id: row.id,
        type: row.action_type,
        detail: row.payload,
        createdAt: row.created_at,
      })),
      teamPointsById,
      teamAssetPointsById,
    };
  }

  async renameTeam(teamId, name) {
    const { error } = await client().rpc('rename_team', { p_team_id: teamId, p_name: name });
    if (error) throw error;
    return this.refresh();
  }

  async setTeamLogoUrl(teamId, logoUrl) {
    const { error } = await client().rpc('set_team_logo_url', {
      p_team_id: teamId,
      p_logo_url: logoUrl,
    });
    if (error) throw error;
    return this.refresh();
  }

  async setLineupStatus(teamId, assetId, status) {
    const state = this.requireState();
    const { error } = await client().rpc('set_lineup_status', {
      p_season_id: state.league.seasonId,
      p_team_id: teamId,
      p_asset_id: assetId,
      p_status: status,
    });
    if (error) throw error;
    return this.refresh();
  }

  async toggleKeeper(teamId, assetId) {
    const state = this.requireState();
    const { data, error } = await client().rpc('toggle_keeper', {
      p_season_id: state.league.seasonId,
      p_team_id: teamId,
      p_asset_id: assetId,
    });
    if (error) throw error;
    await this.refresh();
    return data;
  }

  async acceptTrade(tradeId) {
    const { error } = await client().rpc('accept_trade', { p_trade_id: tradeId });
    if (error) throw error;
    return this.refresh();
  }

  async declineTrade(tradeId) {
    const { error } = await client().rpc('decline_trade', { p_trade_id: tradeId });
    if (error) throw error;
    return this.refresh();
  }

  async setDraftStatus(status) {
    const state = this.requireState();
    if (!state.draft?.id) throw new Error('No draft is configured for this season.');
    const { error } = await client().rpc('set_draft_status', {
      p_draft_id: state.draft.id,
      p_status: status,
    });
    if (error) throw error;
    return this.refresh();
  }

  async makeDraftPick(assetId) {
    const state = this.requireState();
    if (!state.draft?.id) throw new Error('No draft is configured for this season.');
    const { data, error } = await client().rpc('make_draft_pick', {
      p_draft_id: state.draft.id,
      p_asset_id: assetId,
    });
    if (error) throw error;
    await this.refresh();
    return data;
  }

  subscribeToDraft(draftId, onChange) {
    const channel = client()
      .channel(`draft:${draftId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'drafts', filter: `id=eq.${draftId}` }, onChange)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'draft_selections', filter: `draft_id=eq.${draftId}` }, onChange)
      .subscribe();

    return () => client().removeChannel(channel);
  }

  subscribeToLeagueState({ leagueId, seasonId, draftId }, onChange) {
    let channel = client()
      .channel(`league:${leagueId}:${seasonId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'teams', filter: `league_id=eq.${leagueId}` }, onChange)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'roster_memberships', filter: `season_id=eq.${seasonId}` }, onChange)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'keeper_selections', filter: `season_id=eq.${seasonId}` }, onChange)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'trades', filter: `season_id=eq.${seasonId}` }, onChange);

    if (draftId) {
      channel = channel
        .on('postgres_changes', { event: '*', schema: 'public', table: 'drafts', filter: `id=eq.${draftId}` }, onChange)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'draft_selections', filter: `draft_id=eq.${draftId}` }, onChange);
    }

    channel = channel.subscribe();
    return () => client().removeChannel(channel);
  }
}
