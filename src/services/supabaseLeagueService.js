import { supabase, supabaseConfigured } from './supabaseClient.js';

const ACTIVE_LEAGUE_KEY = 'ten-sport-active-league';

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

function saveActiveLeague(id) {
  if (typeof localStorage === 'undefined') return;
  if (id) localStorage.setItem(ACTIVE_LEAGUE_KEY, id);
  else localStorage.removeItem(ACTIVE_LEAGUE_KEY);
}

function storedActiveLeague() {
  if (typeof localStorage === 'undefined') return null;
  return localStorage.getItem(ACTIVE_LEAGUE_KEY);
}

export class SupabaseLeagueService {
  constructor() {
    this.listeners = new Set();
    this.state = null;
    this.unsubscribeRealtime = null;
    this.refreshQueued = false;
    this.activeLeagueId = storedActiveLeague();
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
    if (!this.state || this.state.needsLeague) {
      throw new Error('Hosted league state has not been loaded yet.');
    }
    return this.state;
  }

  async getAuthenticatedUser() {
    const c = client();
    const { data: { user }, error } = await c.auth.getUser();
    if (error) {
      const noSession =
        error.name === 'AuthSessionMissingError'
        || /auth session missing/i.test(error.message ?? '');
      if (noSession) throw new Error('Authentication required.');
      throw error;
    }
    if (!user) throw new Error('Authentication required.');
    return user;
  }

  async loadAvailableLeagues(userId) {
    const memberships = unwrap(
      await client()
        .from('league_memberships')
        .select('league_id,role,status')
        .eq('user_id', userId)
        .eq('status', 'ACTIVE'),
      'Load league memberships'
    ) ?? [];

    const leagues = await selectIn(
      'leagues',
      'id,name,logo_url,join_code,primary_color,accent_color,theme_mode,created_at',
      'id',
      memberships.map((row) => row.league_id)
    );
    const leagueById = Object.fromEntries(leagues.map((row) => [row.id, row]));

    return memberships
      .map((membership) => {
        const league = leagueById[membership.league_id];
        if (!league) return null;
        return {
          id: league.id,
          name: league.name,
          logoUrl: league.logo_url ?? null,
          joinCode: league.join_code,
          role: membership.role,
          primaryColor: league.primary_color ?? '#6ee7b7',
          accentColor: league.accent_color ?? '#22d3ee',
          themeMode: league.theme_mode ?? 'dark',
          createdAt: league.created_at,
        };
      })
      .filter(Boolean)
      .sort((a, b) => a.name.localeCompare(b.name));
  }

  async loadAccountState() {
    const user = await this.getAuthenticatedUser();
    const profile = unwrap(
      await client()
        .from('profiles')
        .select('id,display_name,avatar_url')
        .eq('id', user.id)
        .maybeSingle(),
      'Load profile'
    );
    const availableLeagues = await this.loadAvailableLeagues(user.id);

    return {
      version: 11,
      needsLeague: availableLeagues.length === 0,
      currentUserId: user.id,
      currentUser: {
        id: user.id,
        displayName: profile?.display_name ?? user.email ?? 'Manager',
        avatarUrl: profile?.avatar_url ?? null,
      },
      availableLeagues,
    };
  }

  async initialize() {
    const account = await this.loadAccountState();

    if (account.needsLeague) {
      this.activeLeagueId = null;
      saveActiveLeague(null);
      this.state = account;
      this.emit();
      return this.getState();
    }

    const preferred = account.availableLeagues.some((league) => league.id === this.activeLeagueId)
      ? this.activeLeagueId
      : account.availableLeagues[0].id;

    this.activeLeagueId = preferred;
    saveActiveLeague(preferred);
    const state = await this.refresh(preferred);
    this.startRealtime();
    return state;
  }

  async refresh(leagueId = this.activeLeagueId) {
    if (!leagueId) {
      const account = await this.loadAccountState();
      this.state = account;
      this.emit();
      return this.getState();
    }

    const next = await this.loadLeagueState(leagueId);
    this.activeLeagueId = leagueId;
    saveActiveLeague(leagueId);
    this.state = next;
    this.emit();
    return this.getState();
  }

  async switchLeague(leagueId) {
    this.unsubscribeRealtime?.();
    this.unsubscribeRealtime = null;
    const next = await this.refresh(leagueId);
    this.startRealtime();
    return next;
  }

  queueRefresh() {
    if (this.refreshQueued || !this.activeLeagueId) return;
    this.refreshQueued = true;
    setTimeout(async () => {
      try {
        await this.refresh(this.activeLeagueId);
      } finally {
        this.refreshQueued = false;
      }
    }, 75);
  }

  startRealtime() {
    if (!this.state || this.state.needsLeague || !this.state.league) return;
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

  async getCurrentContext(leagueId) {
    const c = client();
    const user = await this.getAuthenticatedUser();

    const membership = unwrap(
      await c
        .from('league_memberships')
        .select('league_id,role,status')
        .eq('league_id', leagueId)
        .eq('user_id', user.id)
        .eq('status', 'ACTIVE')
        .maybeSingle(),
      'Load league membership'
    );

    if (!membership) throw new Error('You are not an active member of this league.');

    const [profileResult, leagueResult, teamResult, availableLeagues] = await Promise.all([
      c.from('profiles').select('id,display_name,avatar_url').eq('id', user.id).maybeSingle(),
      c.from('leagues').select('*').eq('id', leagueId).single(),
      c.from('teams').select('*').eq('league_id', leagueId).eq('owner_user_id', user.id).maybeSingle(),
      this.loadAvailableLeagues(user.id),
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
        .order('label', { ascending: false })
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

    return { user, profile, membership, league, season, team, availableLeagues };
  }

  async loadLeagueState(leagueId) {
    const c = client();
    const context = await this.getCurrentContext(leagueId);
    const { user, profile, membership, league, season, team, availableLeagues } = context;

    const [
      membershipsResult,
      teamsResult,
      assetsResult,
      rosterResult,
      keepersResult,
      picksResult,
      tradesResult,
      waiversResult,
      draftResult,
      eventsResult,
      historyResult,
      auditResult,
      seasonsResult,
    ] = await Promise.all([
      c.from('league_memberships').select('league_id,user_id,role,status').eq('league_id', league.id).eq('status', 'ACTIVE'),
      c.from('teams').select('*').eq('league_id', league.id).order('created_at', { ascending: true }),
      c.from('assets').select('*').eq('active', true),
      c.from('roster_memberships').select('*').eq('season_id', season.id),
      c.from('keeper_selections').select('*').eq('season_id', season.id),
      c.from('draft_picks').select('*').eq('league_id', league.id),
      c.from('trades').select('*').eq('season_id', season.id).order('created_at', { ascending: false }),
      c.from('waiver_transactions').select('*').eq('season_id', season.id).order('created_at', { ascending: false }),
      c.from('drafts').select('*').eq('season_id', season.id).maybeSingle(),
      c.from('scoring_events').select('*').eq('season_id', season.id),
      c.from('asset_season_stats').select('*').eq('scoring_version', season.scoring_version),
      c.from('audit_log').select('*').eq('league_id', league.id).order('created_at', { ascending: false }).limit(150),
      c.from('seasons').select('id,label,status').eq('league_id', league.id).order('label', { ascending: false }),
    ]);

    const memberships = unwrap(membershipsResult, 'Load memberships') ?? [];
    const teams = unwrap(teamsResult, 'Load teams') ?? [];
    const assets = unwrap(assetsResult, 'Load assets') ?? [];
    const roster = unwrap(rosterResult, 'Load rosters') ?? [];
    const keepers = unwrap(keepersResult, 'Load keepers') ?? [];
    const picks = unwrap(picksResult, 'Load draft picks') ?? [];
    const trades = unwrap(tradesResult, 'Load trades') ?? [];
    const waivers = unwrap(waiversResult, 'Load waiver transactions') ?? [];
    const draft = unwrap(draftResult, 'Load draft') ?? null;
    const clock = draft ? unwrap(await c.rpc('get_draft_clock', { p_draft_id: draft.id }), 'Load draft clock') : null;
    const clockOffsetMs = clock?.server_now ? Date.parse(clock.server_now) - Date.now() : 0;
    const events = unwrap(eventsResult, 'Load scoring events') ?? [];
    const history = unwrap(historyResult, 'Load asset history') ?? [];
    const audit = unwrap(auditResult, 'Load audit log') ?? [];
    const seasons = unwrap(seasonsResult, 'Load seasons') ?? [];

    const previousCompletedSeason = seasons.find(
      (row) => row.id !== season.id && row.status === 'COMPLETE'
    ) ?? null;

    const [teamHistory, sportHistory, draftOrderRows, previousRoster, draftPreferences] = await Promise.all([
      selectIn('season_team_results', '*', 'season_id', seasons.map((row) => row.id)),
      selectIn('season_sport_results', '*', 'season_id', seasons.map((row) => row.id)),
      draft
        ? unwrap(
            await c.from('draft_order').select('*').eq('draft_id', draft.id).order('slot', { ascending: true }),
            'Load draft order'
          ) ?? []
        : [],
      previousCompletedSeason && team?.id
        ? unwrap(
            await c
              .from('roster_memberships')
              .select('*')
              .eq('season_id', previousCompletedSeason.id)
              .eq('team_id', team.id),
            'Load keeper-eligible roster'
          ) ?? []
        : [],
      draft
        ? unwrap(
            await c
              .from('draft_preferences')
              .select('*')
              .eq('draft_id', draft.id)
              .eq('user_id', user.id)
              .order('queue_position', { ascending: true, nullsFirst: false }),
            'Load draft preferences'
          ) ?? []
        : [],
    ]);

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

    const historyByAssetId = history.reduce((acc, row) => {
      (acc[row.asset_id] ??= []).push({
        id: row.id,
        seasonLabel: row.season_label,
        scoringVersion: row.scoring_version,
        points: Number(row.points ?? 0),
        rank: row.rank,
        sourceRef: row.source_ref,
        breakdown: row.breakdown ?? {},
      });
      return acc;
    }, {});
    Object.values(historyByAssetId).forEach((rows) => {
      rows.sort((a, b) => b.seasonLabel.localeCompare(a.seasonLabel));
    });

    const seasonById = Object.fromEntries(seasons.map((row) => [row.id, row]));
    const leagueHistory = {
      seasons: seasons.map((row) => ({
        id: row.id,
        label: row.label,
        status: row.status,
        results: teamHistory
          .filter((result) => result.season_id === row.id)
          .map((result) => ({
            id: result.id,
            teamId: result.team_id,
            teamName: result.team_name,
            managerName: result.manager_name,
            finalRank: result.final_rank,
            totalPoints: Number(result.total_points ?? 0),
            finalizedAt: result.finalized_at,
          }))
          .sort((a, b) => a.finalRank - b.finalRank),
      })),
      sportResults: sportHistory.map((result) => ({
        id: result.id,
        seasonId: result.season_id,
        seasonLabel: seasonById[result.season_id]?.label ?? 'Unknown',
        teamId: result.team_id,
        sport: result.sport,
        points: Number(result.points ?? 0),
      })),
    };

    return {
      version: 10,
      needsLeague: false,
      availableLeagues,
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
        joinCode: league.join_code,
        seasonId: season.id,
        season: season.label,
        seasonStatus: season.status,
        scoringVersion: season.scoring_version,
        keeperDeadline: season.keeper_deadline,
        tradeDeadline: season.trade_deadline,
        rosterSize: league.roster_size,
        activeSlots: league.active_slots,
        benchSlots: league.bench_slots,
        keeperSlots: league.keeper_slots,
        logoUrl: league.logo_url ?? null,
        primaryColor: league.primary_color ?? '#6ee7b7',
        accentColor: league.accent_color ?? '#22d3ee',
        themeMode: league.theme_mode ?? 'dark',
      },
      teams: teams.map((row) => ({
        id: row.id,
        name: row.name,
        logoUrl: row.logo_url,
        ownerUserId: row.owner_user_id,
        managerName: profileById[row.owner_user_id]?.display_name ?? 'Manager',
        managerAvatarUrl: profileById[row.owner_user_id]?.avatar_url ?? null,
        role: membershipByUserId[row.owner_user_id]?.role ?? 'MANAGER',
        createdAt: row.created_at,
      })),
      assets: assets.map((row) => ({
        id: row.id,
        name: row.name,
        sport: row.sport,
        externalKey: row.external_key,
        seasonPoints: seasonPointsByAsset[row.id] ?? 0,
        pointsForTeam: currentTeamAssetPoints[row.id] ?? 0,
        history: historyByAssetId[row.id] ?? [],
      })),
      rosterMemberships: roster.map((row) => ({
        id: row.id,
        teamId: row.team_id,
        assetId: row.asset_id,
        lineupStatus: row.lineup_status,
        acquiredAt: row.acquired_at,
      })),
      keeperEligibleRoster: previousRoster
        .filter((row) => assets.some((asset) => asset.id === row.asset_id))
        .map((row) => ({
          id: row.id,
          teamId: row.team_id,
          assetId: row.asset_id,
          lineupStatus: row.lineup_status,
          acquiredAt: row.acquired_at,
        })),
      keeperSourceSeason: previousCompletedSeason
        ? { id: previousCompletedSeason.id, label: previousCompletedSeason.label }
        : null,
      keeperSelections: keepers.map((row) => ({
        id: row.id,
        teamId: row.team_id,
        assetId: row.asset_id,
        lockedAt: row.locked_at,
        keeperYear: row.keeper_year,
        originalDraftRound: row.original_draft_round,
        costRound: row.cost_round,
        forfeitedDraftPickId: row.forfeited_draft_pick_id,
        sourceDraftSelectionId: row.source_draft_selection_id,
        sourceType: row.keeper_source_type,
        sourceWaiverTransactionId: row.source_waiver_transaction_id,
        sourceAcquiredAt: row.source_acquired_at,
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
        counterOfTradeId: row.counter_of_trade_id,
        items: (itemsByTradeId[row.id] ?? []).map((item) => ({
          id: item.id,
          side: item.side === 'PROPOSER' ? 'FROM' : 'TO',
          type: item.item_type,
          assetId: item.asset_id,
          draftPickId: item.draft_pick_id,
        })),
      })),
      waiverTransactions: waivers.map((row) => ({
        id: row.id,
        teamId: row.team_id,
        addedAssetId: row.added_asset_id,
        droppedAssetId: row.dropped_asset_id,
        transactionType: row.transaction_type,
        createdAt: row.created_at,
      })),
      draft: draft
        ? {
            id: draft.id,
            season: draft.scheduled_at ? new Date(draft.scheduled_at).getFullYear() : null,
            scheduledAt: draft.scheduled_at,
            pickTimerSeconds: draft.pick_timer_seconds,
            pickDeadlineAt: clock?.deadline ?? draft.pick_deadline_at,
            pausedSeconds: clock?.paused_seconds ?? draft.paused_seconds,
            clockOffsetMs,
            status: draft.status,
            currentOverallPick: draft.current_overall_pick,
            rounds: draft.rounds,
            orderMethod: draft.order_method,
            order: draftOrderRows.map((row) => ({
              teamId: row.team_id,
              slot: row.slot,
            })),
            selections: selections.map((row) => ({
              id: row.id,
              overallPick: row.overall_pick,
              round: row.round,
              teamId: row.team_id,
              assetId: row.asset_id,
              draftPickId: row.draft_pick_id,
              autoPicked: row.auto_picked,
              selectionType: row.selection_type ?? 'DRAFT',
              createdAt: row.selected_at,
            })),
            preferences: draftPreferences.map((row) => ({
              id: row.id,
              assetId: row.asset_id,
              starred: row.starred,
              queuePosition: row.queue_position,
              updatedAt: row.updated_at,
            })),
          }
        : null,
      leagueHistory,
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

  async createLeague({ name, teamName, seasonLabel = '2026-27', scoringVersion = 'v1.2' }) {
    const { data, error } = await client().rpc('create_league', {
      p_name: name,
      p_team_name: teamName,
      p_season_label: seasonLabel,
      p_scoring_version: scoringVersion,
    });
    if (error) throw error;
    this.activeLeagueId = data.league_id;
    saveActiveLeague(data.league_id);
    const state = await this.refresh(data.league_id);
    this.startRealtime();
    return state;
  }

  async joinLeague({ code, teamName }) {
    const { data, error } = await client().rpc('join_league', {
      p_code: code,
      p_team_name: teamName,
    });
    if (error) throw error;
    this.activeLeagueId = data.league_id;
    saveActiveLeague(data.league_id);
    const state = await this.refresh(data.league_id);
    this.startRealtime();
    return state;
  }

  async updateLeagueAppearance({ name, logoUrl, primaryColor, accentColor, themeMode }) {
    const state = this.requireState();
    const { error } = await client().rpc('update_league_appearance', {
      p_league_id: state.league.id,
      p_name: name,
      p_logo_url: logoUrl,
      p_primary_color: primaryColor,
      p_accent_color: accentColor,
      p_theme_mode: themeMode,
    });
    if (error) throw error;
    return this.refresh();
  }

  async renameLeague(name) {
    const state = this.requireState();
    const clean = name.trim();
    if (!clean) throw new Error('League name cannot be empty.');
    const { error } = await client().rpc('update_league_appearance', {
      p_league_id: state.league.id,
      p_name: clean,
      p_logo_url: state.league.logoUrl,
      p_primary_color: state.league.primaryColor,
      p_accent_color: state.league.accentColor,
      p_theme_mode: state.league.themeMode,
    });
    if (error) throw error;
    return this.refresh();
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

  async claimWaiverAsset(assetId, dropAssetId = null) {
    const state = this.requireState();
    if (!state.currentTeamId) throw new Error('No team is assigned to this account in the current league.');
    const { data, error } = await client().rpc('claim_waiver_asset', {
      p_team_id: state.currentTeamId,
      p_asset_id: assetId,
      p_drop_asset_id: dropAssetId,
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

  async prepareTradeBuilder() {
    const state = this.requireState();
    const { error } = await client().rpc('ensure_future_draft_picks', { p_league_id: state.league.id });
    if (error) throw error;
    return this.refresh();
  }

  async proposeTrade(toTeamId, items, counterOfTradeId = null) {
    const state = this.requireState();
    const { data, error } = await client().rpc(counterOfTradeId ? 'counter_trade' : 'propose_trade', counterOfTradeId
      ? { p_trade_id: counterOfTradeId, p_items: items }
      : { p_season_id: state.league.seasonId, p_from_team_id: state.currentTeamId, p_to_team_id: toTeamId, p_items: items });
    if (error) throw error;
    await this.refresh();
    return data;
  }

  async declineTrade(tradeId) {
    const { error } = await client().rpc('decline_trade', { p_trade_id: tradeId });
    if (error) throw error;
    return this.refresh();
  }

  async setDraftSchedule(scheduledAt) {
    const state = this.requireState();
    if (!state.draft?.id) throw new Error('No draft is configured for this season.');
    const { error } = await client().rpc('set_draft_schedule', {
      p_draft_id: state.draft.id,
      p_scheduled_at: scheduledAt,
    });
    if (error) throw error;
    return this.refresh();
  }

  async setDraftTimer(seconds) {
    const { error } = await client().rpc('set_draft_timer', { p_draft_id: this.state.draft.id, p_seconds: seconds });
    if (error) throw error;
    return this.refresh();
  }

  async syncDraftClock() {
    const draft = this.state?.draft;
    if (!draft) return;
    const { data, error } = await client().rpc('get_draft_clock', { p_draft_id: draft.id });
    if (error) throw error;
    if (!data || this.state?.draft?.id !== draft.id) return;
    if (this.state.draft.currentOverallPick !== draft.currentOverallPick || this.state.draft.status !== draft.status) return;
    if (data.current_pick !== draft.currentOverallPick || data.status !== draft.status) return this.refresh();
    this.state.draft = { ...draft, pickDeadlineAt: data.deadline, pausedSeconds: data.paused_seconds,
      clockOffsetMs: Date.parse(data.server_now) - Date.now() };
    this.emit();
    if (data.status === 'LIVE' && data.deadline && Date.parse(data.server_now) >= Date.parse(data.deadline)) {
      const result = await client().rpc('process_draft_timeout', { p_draft_id: draft.id, p_expected_pick: data.current_pick });
      if (result.error) throw result.error;
      return this.refresh();
    }
  }

  async swapLineupAssets(teamId, activeAssetId, benchAssetId) {
    const { error } = await client().rpc('swap_lineup_assets', {
      p_season_id: this.state.league.seasonId, p_team_id: teamId,
      p_active_asset_id: activeAssetId, p_bench_asset_id: benchAssetId,
    });
    if (error) throw error;
    return this.refresh();
  }

  async setDraftOrder(teamIds) {
    const state = this.requireState();
    if (!state.draft?.id) throw new Error('No draft is configured for this season.');
    const { error } = await client().rpc('set_draft_order', {
      p_draft_id: state.draft.id,
      p_team_ids: teamIds,
    });
    if (error) throw error;
    return this.refresh();
  }

  async randomizeDraftOrder() {
    const state = this.requireState();
    if (!state.draft?.id) throw new Error('No draft is configured for this season.');
    const { data, error } = await client().rpc('randomize_draft_order', {
      p_draft_id: state.draft.id,
    });
    if (error) throw error;
    await this.refresh();
    return data;
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

  async finalizeSeason() {
    const state = this.requireState();
    const { error } = await client().rpc('finalize_season', {
      p_season_id: state.league.seasonId,
    });
    if (error) throw error;
    return this.refresh();
  }

  async setDraftFavorite(assetId, starred) {
    const state = this.requireState();
    if (!state.draft?.id) throw new Error('No draft is configured for this season.');
    const existing = state.draft.preferences?.find((row) => row.assetId === assetId);
    const { error } = await client().from('draft_preferences').upsert({
      draft_id: state.draft.id,
      user_id: state.currentUserId,
      asset_id: assetId,
      starred,
      queue_position: existing?.queuePosition ?? null,
      updated_at: new Date().toISOString(),
    }, { onConflict: 'draft_id,user_id,asset_id' });
    if (error) throw error;
    return this.refresh();
  }

  async toggleDraftQueue(assetId) {
    const state = this.requireState();
    if (!state.draft?.id) throw new Error('No draft is configured for this season.');
    const existing = state.draft.preferences?.find((row) => row.assetId === assetId);
    const queued = (state.draft.preferences ?? []).filter((row) => row.queuePosition != null);
    const nextPosition = existing?.queuePosition != null
      ? null
      : Math.max(0, ...queued.map((row) => row.queuePosition ?? 0)) + 1;

    const { error } = await client().from('draft_preferences').upsert({
      draft_id: state.draft.id,
      user_id: state.currentUserId,
      asset_id: assetId,
      starred: existing?.starred ?? false,
      queue_position: nextPosition,
      updated_at: new Date().toISOString(),
    }, { onConflict: 'draft_id,user_id,asset_id' });
    if (error) throw error;
    return this.refresh();
  }

  async moveDraftQueue(assetId, direction) {
    const state = this.requireState();
    if (!state.draft?.id) throw new Error('No draft is configured for this season.');
    const queued = (state.draft.preferences ?? [])
      .filter((row) => row.queuePosition != null)
      .slice()
      .sort((a, b) => a.queuePosition - b.queuePosition);
    const index = queued.findIndex((row) => row.assetId === assetId);
    const targetIndex = index + direction;
    if (index < 0 || targetIndex < 0 || targetIndex >= queued.length) return state;

    const current = queued[index];
    const target = queued[targetIndex];
    const nowIso = new Date().toISOString();

    const [first, second] = await Promise.all([
      client().from('draft_preferences')
        .update({ queue_position: target.queuePosition, updated_at: nowIso })
        .eq('draft_id', state.draft.id)
        .eq('user_id', state.currentUserId)
        .eq('asset_id', current.assetId),
      client().from('draft_preferences')
        .update({ queue_position: current.queuePosition, updated_at: nowIso })
        .eq('draft_id', state.draft.id)
        .eq('user_id', state.currentUserId)
        .eq('asset_id', target.assetId),
    ]);
    if (first.error) throw first.error;
    if (second.error) throw second.error;
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
      .on('postgres_changes', { event: '*', schema: 'public', table: 'leagues', filter: `id=eq.${leagueId}` }, onChange)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'teams', filter: `league_id=eq.${leagueId}` }, onChange)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'roster_memberships', filter: `season_id=eq.${seasonId}` }, onChange)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'keeper_selections', filter: `season_id=eq.${seasonId}` }, onChange)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'trades', filter: `season_id=eq.${seasonId}` }, onChange)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'waiver_transactions', filter: `season_id=eq.${seasonId}` }, onChange);

    if (draftId) {
      channel = channel
        .on('postgres_changes', { event: '*', schema: 'public', table: 'drafts', filter: `id=eq.${draftId}` }, onChange)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'draft_order', filter: `draft_id=eq.${draftId}` }, onChange)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'draft_selections', filter: `draft_id=eq.${draftId}` }, onChange);
    }

    channel = channel.subscribe();
    return () => client().removeChannel(channel);
  }
}
