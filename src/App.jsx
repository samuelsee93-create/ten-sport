import React, { useEffect, useState } from 'react';
import {
  Activity,
  ArrowRightLeft,
  CalendarDays,
  Crown,
  Database,
  DraftingCompass,
  Gauge,
  List,
  LogOut,
  Palette,
  RotateCcw,
  Search,
  ShieldCheck,
  Trophy,
  Users,
} from 'lucide-react';
import { hostedBackendEnabled, leagueService } from './services/service.js';
import { signIn, signOut, signUp } from './services/authService.js';
import { LINEUP_STATUS, DRAFT_STATUS } from './domain/constants.js';
import {
  activeRosterForTeam,
  benchRosterForTeam,
  draftOrder,
  keeperIdsForTeam,
  ownedDraftPicks,
  pointsForTeam,
  rosterForTeam,
  teamById,
  tradeItemsForSide,
} from './domain/selectors.js';

const NAV = [
  ['Dashboard', Gauge],
  ['My Team', Users],
  ['Assets', List],
  ['Trades', ArrowRightLeft],
  ['Keepers', Crown],
  ['Draft', DraftingCompass],
  ['Commissioner', ShieldCheck],
];

function useLeague() {
  const [state, setState] = useState(() => leagueService.getState?.() ?? null);
  const [loading, setLoading] = useState(hostedBackendEnabled);
  const [bootError, setBootError] = useState(null);

  const reload = async () => {
    if (!hostedBackendEnabled) {
      setState(leagueService.getState());
      setBootError(null);
      return leagueService.getState();
    }

    setLoading(true);
    try {
      const next = await leagueService.initialize();
      setState(next);
      setBootError(null);
      return next;
    } catch (error) {
      setState(null);
      setBootError(error);
      return null;
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    const unsubscribe = leagueService.subscribe?.(setState);
    if (hostedBackendEnabled) reload();
    return () => {
      unsubscribe?.();
      leagueService.dispose?.();
    };
  }, []);

  return { state, loading, bootError, reload };
}

function Button({ children, onClick, kind = 'primary', disabled = false }) {
  return (
    <button className={`btn ${kind}`} onClick={onClick} disabled={disabled}>
      {children}
    </button>
  );
}

function Card({ title, icon: Icon, children, action }) {
  return (
    <section className="card">
      <div className="card-head">
        <div>
          <div className="eyebrow">TEN SPORT</div>
          <h2>{Icon && <Icon size={18} />} {title}</h2>
        </div>
        {action}
      </div>
      {children}
    </section>
  );
}

function Badge({ children, tone = 'neutral' }) {
  return <span className={`badge ${tone}`}>{children}</span>;
}

function formatDate(value) {
  if (!value) return 'Not set';
  return new Intl.DateTimeFormat('en-CA', {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(new Date(value));
}

async function run(action, setError) {
  try {
    setError('');
    await action();
  } catch (error) {
    setError(error.message || 'Something went wrong.');
  }
}

function AuthScreen({ onAuthenticated }) {
  const [mode, setMode] = useState('signin');
  const [displayName, setDisplayName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [message, setMessage] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const submit = async (event) => {
    event.preventDefault();
    setBusy(true);
    setError('');
    setMessage('');

    try {
      if (mode === 'signup') {
        const data = await signUp({ email, password, displayName });
        if (!data.session) {
          setMessage('Account created. Check your email to confirm your address, then sign in.');
          setMode('signin');
          return;
        }
      } else {
        await signIn({ email, password });
      }
      await onAuthenticated();
    } catch (e) {
      setError(e.message || 'Authentication failed.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="auth-shell">
      <div className="auth-card">
        <div className="brand auth-brand">
          <div>10</div>
          <span><b>TEN SPORT</b><small>Fantasy League</small></span>
        </div>
        <div className="eyebrow">LIVE MULTI-USER BACKEND</div>
        <h1>{mode === 'signin' ? 'Sign in' : 'Create manager account'}</h1>
        <p className="muted">
          {mode === 'signin'
            ? 'Sign in to load your league, roster, trades, keepers and live draft state.'
            : 'Create an account. Your league membership and team determine what you can access.'}
        </p>
        <form className="stack tight" onSubmit={submit}>
          {mode === 'signup' && (
            <input
              value={displayName}
              onChange={(e) => setDisplayName(e.target.value)}
              placeholder="Display name"
              required
            />
          )}
          <input
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="Email"
            required
          />
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            placeholder="Password"
            minLength={8}
            required
          />
          {error && <div className="error">{error}</div>}
          {message && <div className="callout">{message}</div>}
          <Button disabled={busy}>{busy ? 'Working…' : mode === 'signin' ? 'Sign in' : 'Create account'}</Button>
        </form>
        <button
          className="auth-switch"
          onClick={() => {
            setMode(mode === 'signin' ? 'signup' : 'signin');
            setError('');
            setMessage('');
          }}
        >
          {mode === 'signin' ? 'Need an account? Create one' : 'Already have an account? Sign in'}
        </button>
      </div>
    </div>
  );
}

function Dashboard({ state, teamId }) {
  const leaderboard = state.teams
    .map((team) => ({ ...team, points: pointsForTeam(state, team.id) }))
    .sort((a, b) => b.points - a.points);
  const team = teamById(state, teamId);

  return (
    <div className="grid two">
      <Card title="League Standings" icon={Trophy}>
        <div className="standings">
          {leaderboard.map((row, index) => (
            <div className="standing" key={row.id}>
              <strong>{index + 1}</strong>
              <div><b>{row.name}</b><small>{row.managerName}</small></div>
              <span>{row.points.toLocaleString()} pts</span>
            </div>
          ))}
        </div>
      </Card>
      <Card title="Season Snapshot" icon={Activity}>
        <div className="stats">
          <div><span>Season</span><b>{state.league.season}</b></div>
          <div><span>Scoring</span><b>{state.league.scoringVersion}</b></div>
          <div><span>Your roster</span><b>{team ? rosterForTeam(state, team.id).length : 0}/20</b></div>
          <div><span>Active</span><b>{team ? activeRosterForTeam(state, team.id).length : 0}/15</b></div>
        </div>
        <div className="callout">
          Every asset tracks <b>Season Points</b> and <b>Points For You</b> separately.
          Benched production stays visible but does not count toward your standings total.
        </div>
      </Card>
      <Card title="Recent League Activity" icon={CalendarDays}>
        <div className="timeline">
          {state.transactionLog.length
            ? state.transactionLog.slice(0, 8).map((item) => (
                <div key={item.id}>
                  <span>{item.type.replaceAll('_', ' ')}</span>
                  <small>{formatDate(item.createdAt)}</small>
                </div>
              ))
            : <p className="muted">No transactions yet.</p>}
        </div>
      </Card>
      <Card title="League Architecture" icon={Database}>
        <ul className="checklist">
          <li>20 owned assets · 15 Active · 5 Bench</li>
          <li>3 free keepers</li>
          <li>Asset + pick package trades</li>
          <li>Permanent draft-pick provenance</li>
          <li>Event-based lineup locks</li>
          <li>Atomic draft/trade transactions in hosted backend</li>
        </ul>
      </Card>
    </div>
  );
}

function MyTeam({ state, teamId, setError }) {
  const team = teamById(state, teamId);
  const active = team ? activeRosterForTeam(state, teamId) : [];
  const bench = team ? benchRosterForTeam(state, teamId) : [];
  const [name, setName] = useState(team?.name ?? '');
  const [logoUrl, setLogoUrl] = useState(team?.logoUrl ?? '');

  useEffect(() => {
    setName(team?.name ?? '');
    setLogoUrl(team?.logoUrl ?? '');
  }, [team?.id, team?.name, team?.logoUrl]);

  if (!team) {
    return <Card title="My Team" icon={Users}><p className="muted">No team is assigned to this account yet.</p></Card>;
  }

  const row = (membership, status) => (
    <div className="asset-row" key={membership.assetId}>
      <div>
        <div className="asset-name">{membership.asset.name} <Badge>{membership.asset.sport}</Badge></div>
        <small>Season {membership.asset.seasonPoints} · For You {membership.asset.pointsForTeam}</small>
      </div>
      <Button
        kind={status === LINEUP_STATUS.ACTIVE ? 'ghost' : 'primary'}
        onClick={() => run(
          () => leagueService.setLineupStatus(
            teamId,
            membership.assetId,
            status === LINEUP_STATUS.ACTIVE ? LINEUP_STATUS.BENCH : LINEUP_STATUS.ACTIVE
          ),
          setError
        )}
      >
        {status === LINEUP_STATUS.ACTIVE ? 'Bench' : 'Activate'}
      </Button>
    </div>
  );

  return (
    <div className="stack">
      <Card title="Team Identity" icon={Users}>
        <div className="team-identity">
          <div className="team-logo">
            {team.logoUrl ? <img src={team.logoUrl} alt="" /> : <span>{team.name.slice(0, 2).toUpperCase()}</span>}
          </div>
          <div className="stack tight team-fields">
            <div className="inline">
              <input value={name} onChange={(e) => setName(e.target.value)} placeholder="Team name" />
              <Button onClick={() => run(() => leagueService.renameTeam(teamId, name), setError)}>Save Team Name</Button>
            </div>
            <div className="inline">
              <input value={logoUrl} onChange={(e) => setLogoUrl(e.target.value)} placeholder="Team photo HTTPS URL" />
              <Button kind="ghost" onClick={() => run(() => leagueService.setTeamLogoUrl(teamId, logoUrl), setError)}>
                Save Team Photo
              </Button>
            </div>
          </div>
        </div>
      </Card>
      <div className="grid two">
        <Card title={`Active · ${active.length}/15`} icon={Activity}>
          {active.map((membership) => row(membership, LINEUP_STATUS.ACTIVE))}
        </Card>
        <Card title={`Bench · ${bench.length}/5`} icon={Users}>
          {bench.map((membership) => row(membership, LINEUP_STATUS.BENCH))}
        </Card>
      </div>
    </div>
  );
}


function Assets({ state }) {
  const [query, setQuery] = useState('');
  const [sport, setSport] = useState('ALL');
  const [availability, setAvailability] = useState('ALL');
  const [sort, setSort] = useState('POINTS');

  const sports = [...new Set(state.assets.map((asset) => asset.sport))].sort();
  const ownershipByAsset = Object.fromEntries(
    state.rosterMemberships.map((membership) => [membership.assetId, membership.teamId])
  );

  const rows = state.assets
    .map((asset) => {
      const previous = (asset.history ?? []).find((item) => item.seasonLabel !== state.league.season) ?? null;
      const ownerTeamId = ownershipByAsset[asset.id] ?? null;
      const owner = ownerTeamId ? teamById(state, ownerTeamId) : null;
      return { asset, previous, owner };
    })
    .filter(({ asset, owner }) => {
      const matchesQuery = !query.trim()
        || asset.name.toLowerCase().includes(query.trim().toLowerCase());
      const matchesSport = sport === 'ALL' || asset.sport === sport;
      const matchesAvailability = availability === 'ALL'
        || (availability === 'AVAILABLE' && !owner)
        || (availability === 'ROSTERED' && !!owner);
      return matchesQuery && matchesSport && matchesAvailability;
    })
    .sort((a, b) => {
      if (sort === 'NAME') return a.asset.name.localeCompare(b.asset.name);
      if (sort === 'SPORT') return a.asset.sport.localeCompare(b.asset.sport) || a.asset.name.localeCompare(b.asset.name);
      if (sort === 'RANK') return (a.previous?.rank ?? Number.MAX_SAFE_INTEGER) - (b.previous?.rank ?? Number.MAX_SAFE_INTEGER);
      return (b.previous?.points ?? -1) - (a.previous?.points ?? -1) || a.asset.name.localeCompare(b.asset.name);
    });

  return (
    <Card
      title="Draftable Assets"
      icon={List}
      action={<Badge>{state.assets.length} assets</Badge>}
    >
      <p className="muted">
        The master draft pool. Historical points show what each asset would have scored under the Ten Sport scoring model.
      </p>
      <div className="asset-toolbar">
        <label className="search-box">
          <Search size={16} />
          <input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Search assets…"
          />
        </label>
        <select value={sport} onChange={(event) => setSport(event.target.value)}>
          <option value="ALL">All sports</option>
          {sports.map((item) => <option key={item} value={item}>{item}</option>)}
        </select>
        <select value={availability} onChange={(event) => setAvailability(event.target.value)}>
          <option value="ALL">All assets</option>
          <option value="AVAILABLE">Available only</option>
          <option value="ROSTERED">Rostered only</option>
        </select>
        <select value={sort} onChange={(event) => setSort(event.target.value)}>
          <option value="POINTS">Sort: previous points</option>
          <option value="RANK">Sort: previous rank</option>
          <option value="NAME">Sort: name</option>
          <option value="SPORT">Sort: sport</option>
        </select>
      </div>

      {state.assets.length === 0 ? (
        <div className="empty-state">
          <b>The asset database is ready.</b>
          <span>No real-world assets have been imported yet. That is the next data-ingestion step.</span>
        </div>
      ) : rows.length === 0 ? (
        <div className="empty-state">
          <b>No assets match those filters.</b>
          <span>Try clearing the search or changing a filter.</span>
        </div>
      ) : (
        <div className="asset-table-wrap">
          <table className="asset-table">
            <thead>
              <tr>
                <th>Asset</th>
                <th>Sport</th>
                <th>Previous season</th>
                <th>Points</th>
                <th>Rank</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {rows.map(({ asset, previous, owner }) => (
                <tr key={asset.id}>
                  <td><b>{asset.name}</b></td>
                  <td><Badge>{asset.sport}</Badge></td>
                  <td>{previous?.seasonLabel ?? '—'}</td>
                  <td className="numeric">{previous ? previous.points.toLocaleString() : '—'}</td>
                  <td className="numeric">{previous?.rank ? `#${previous.rank}` : '—'}</td>
                  <td>
                    {owner
                      ? <Badge>{owner.name}</Badge>
                      : <Badge tone="good">Available</Badge>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  );
}

function Trades({ state, teamId, setError }) {
  const relevant = state.trades.filter((trade) => trade.toTeamId === teamId || trade.fromTeamId === teamId);
  return (
    <Card title="Trade Centre" icon={ArrowRightLeft}>
      {relevant.length === 0 && <p className="muted">No trades yet.</p>}
      {relevant.map((trade) => {
        const from = teamById(state, trade.fromTeamId);
        const to = teamById(state, trade.toTeamId);
        return (
          <div className="trade" key={trade.id}>
            <div className="trade-head">
              <div><b>{from?.name ?? 'Unknown team'}</b> → <b>{to?.name ?? 'Unknown team'}</b></div>
              <Badge tone={trade.status === 'PENDING' ? 'warn' : trade.status === 'ACCEPTED' ? 'good' : 'neutral'}>
                {trade.status}
              </Badge>
            </div>
            <div className="trade-sides">
              <div>
                <span>{from?.name ?? 'Team'} sends</span>
                {tradeItemsForSide(state, trade, 'FROM').map((item) => <p key={item.id ?? item.assetId ?? item.draftPickId}>{item.label}</p>)}
              </div>
              <div>
                <span>{to?.name ?? 'Team'} sends</span>
                {tradeItemsForSide(state, trade, 'TO').map((item) => <p key={item.id ?? item.assetId ?? item.draftPickId}>{item.label}</p>)}
              </div>
            </div>
            {trade.status === 'PENDING' && trade.toTeamId === teamId && (
              <div className="inline">
                <Button onClick={() => run(() => leagueService.acceptTrade(trade.id), setError)}>Accept Trade</Button>
                <Button kind="ghost" onClick={() => run(() => leagueService.declineTrade(trade.id), setError)}>Decline</Button>
              </div>
            )}
          </div>
        );
      })}
    </Card>
  );
}

function Keepers({ state, teamId, setError }) {
  const roster = rosterForTeam(state, teamId);
  const keepers = keeperIdsForTeam(state, teamId);
  return (
    <Card
      title={`Keeper Centre · ${keepers.length}/3`}
      icon={Crown}
      action={<Badge tone="warn">Deadline {formatDate(state.league.keeperDeadline)}</Badge>}
    >
      <p className="muted">Keep exactly three assets. Keepers cost no draft picks.</p>
      <div className="keeper-grid">
        {roster.map((membership) => {
          const selected = keepers.includes(membership.assetId);
          return (
            <button
              key={membership.assetId}
              className={`keeper ${selected ? 'selected' : ''}`}
              onClick={() => run(() => leagueService.toggleKeeper(teamId, membership.assetId), setError)}
            >
              <div>
                <b>{membership.asset.name}</b>
                <small>{membership.asset.sport} · {membership.asset.seasonPoints} season pts</small>
              </div>
              {selected ? <Crown size={18} /> : <span>Choose</span>}
            </button>
          );
        })}
      </div>
    </Card>
  );
}

function Draft({ state, teamId, setError }) {
  if (!state.draft) {
    return <Card title="Live Draft Room" icon={DraftingCompass}><p className="muted">No draft is configured for this season yet.</p></Card>;
  }

  const order = draftOrder(state);
  const current = order[state.draft.currentOverallPick - 1];
  const currentTeam = current ? teamById(state, current.currentTeamId) : null;
  const unowned = state.assets.filter(
    (asset) => !state.rosterMemberships.some((m) => m.assetId === asset.id)
      && !state.draft.selections.some((selection) => selection.assetId === asset.id)
  );

  return (
    <div className="stack">
      <Card
        title="Live Draft Room"
        icon={DraftingCompass}
        action={<Badge tone={state.draft.status === DRAFT_STATUS.LIVE ? 'good' : 'warn'}>{state.draft.status}</Badge>}
      >
        <div className="draft-banner">
          <div>
            <span>ROUND {current?.round ?? '—'} · PICK {state.draft.currentOverallPick}</span>
            <h3>{currentTeam?.name ?? 'Draft complete'}</h3>
            <small>{currentTeam ? `${currentTeam.managerName} is on the clock` : 'All selections completed'}</small>
          </div>
          <div className="timer">{state.draft.pickTimerSeconds}s</div>
        </div>
        {state.draft.status === DRAFT_STATUS.LIVE && currentTeam?.id === teamId && (
          <div className="draft-pool">
            {unowned.slice(0, 10).map((asset) => (
              <button key={asset.id} onClick={() => run(() => leagueService.makeDraftPick(asset.id), setError)}>
                <b>{asset.name}</b>
                <span>{asset.sport} · {asset.seasonPoints} pts</span>
              </button>
            ))}
          </div>
        )}
        {state.draft.status !== DRAFT_STATUS.LIVE && (
          <p className="muted">Commissioner can start the draft from Commissioner controls.</p>
        )}
      </Card>
      <Card title="Recent Picks" icon={Trophy}>
        {state.draft.selections.length
          ? state.draft.selections.slice(-8).reverse().map((selection) => (
              <div className="selection" key={selection.id}>
                <b>#{selection.overallPick}</b>
                <span>{state.assets.find((asset) => asset.id === selection.assetId)?.name}</span>
                <small>{teamById(state, selection.teamId)?.name}</small>
              </div>
            ))
          : <p className="muted">No picks have been made yet.</p>}
      </Card>
    </div>
  );
}

function Commissioner({ state, teamId, setError }) {
  const [appearance, setAppearance] = useState({
    name: state.league.name ?? 'Ten Sport Fantasy League',
    logoUrl: state.league.logoUrl ?? '',
    primaryColor: state.league.primaryColor ?? '#6ee7b7',
    accentColor: state.league.accentColor ?? '#22d3ee',
    themeMode: state.league.themeMode ?? 'dark',
  });

  useEffect(() => {
    setAppearance({
      name: state.league.name ?? 'Ten Sport Fantasy League',
      logoUrl: state.league.logoUrl ?? '',
      primaryColor: state.league.primaryColor ?? '#6ee7b7',
      accentColor: state.league.accentColor ?? '#22d3ee',
      themeMode: state.league.themeMode ?? 'dark',
    });
  }, [
    state.league.name,
    state.league.logoUrl,
    state.league.primaryColor,
    state.league.accentColor,
    state.league.themeMode,
  ]);

  const setAppearanceField = (field, value) => {
    setAppearance((current) => ({ ...current, [field]: value }));
  };

  return (
    <div className="grid two">
      {hostedBackendEnabled && (
        <Card title="League Appearance" icon={Palette}>
          <div className="appearance-preview">
            <div
              className="appearance-logo"
              style={{ background: `linear-gradient(145deg, ${appearance.primaryColor}, ${appearance.accentColor})` }}
            >
              {appearance.logoUrl ? <img src={appearance.logoUrl} alt="" /> : '10'}
            </div>
            <div>
              <b>{appearance.name || 'Ten Sport Fantasy League'}</b>
              <small>{appearance.themeMode} theme</small>
            </div>
          </div>
          <div className="appearance-fields">
            <label>
              <span>League name</span>
              <input
                value={appearance.name}
                maxLength={80}
                onChange={(event) => setAppearanceField('name', event.target.value)}
              />
            </label>
            <label>
              <span>League logo HTTPS URL</span>
              <input
                value={appearance.logoUrl}
                onChange={(event) => setAppearanceField('logoUrl', event.target.value)}
                placeholder="https://…"
              />
            </label>
            <div className="color-fields">
              <label>
                <span>Primary colour</span>
                <div className="color-input">
                  <input
                    type="color"
                    value={appearance.primaryColor}
                    onChange={(event) => setAppearanceField('primaryColor', event.target.value)}
                  />
                  <code>{appearance.primaryColor}</code>
                </div>
              </label>
              <label>
                <span>Accent colour</span>
                <div className="color-input">
                  <input
                    type="color"
                    value={appearance.accentColor}
                    onChange={(event) => setAppearanceField('accentColor', event.target.value)}
                  />
                  <code>{appearance.accentColor}</code>
                </div>
              </label>
            </div>
            <label>
              <span>Theme</span>
              <select
                value={appearance.themeMode}
                onChange={(event) => setAppearanceField('themeMode', event.target.value)}
              >
                <option value="dark">Dark</option>
                <option value="light">Light</option>
                <option value="system">Follow device</option>
              </select>
            </label>
            <Button onClick={() => run(() => leagueService.updateLeagueAppearance(appearance), setError)}>
              Save League Appearance
            </Button>
          </div>
        </Card>
      )}
      <Card title="Draft Controls" icon={ShieldCheck}>
        {state.draft ? (
          <div className="stack tight">
            <div className="detail"><span>Scheduled</span><b>{formatDate(state.draft.scheduledAt)}</b></div>
            <div className="detail"><span>Pick timer</span><b>{state.draft.pickTimerSeconds}s</b></div>
            <div className="inline">
              <Button onClick={() => run(() => leagueService.setDraftStatus(DRAFT_STATUS.LIVE), setError)}>Start / Resume</Button>
              <Button kind="ghost" onClick={() => run(() => leagueService.setDraftStatus(DRAFT_STATUS.PAUSED), setError)}>Pause</Button>
            </div>
          </div>
        ) : <p className="muted">No draft is configured yet.</p>}
      </Card>
      <Card title="Future Draft Capital" icon={CalendarDays}>
        {ownedDraftPicks(state, teamId).slice(0, 8).map((pick) => (
          <div className="detail" key={pick.id}>
            <span>{pick.season} Round {pick.round}</span>
            <b>Originally {teamById(state, pick.originalTeamId)?.managerName}</b>
          </div>
        ))}
      </Card>
      {hostedBackendEnabled ? (
        <Card title="Hosted Backend" icon={Database}>
          <ul className="checklist">
            <li>Authenticated manager identity</li>
            <li>Postgres persistence + RLS</li>
            <li>Realtime league and draft refresh</li>
            <li>Transactional trade/draft RPCs</li>
            <li>Team name + photo persistence</li>
          </ul>
        </Card>
      ) : (
        <Card title="Development Tools" icon={Database}>
          <p className="muted">Reset restores the local demo league and clears local changes.</p>
          <Button kind="danger" onClick={() => run(() => leagueService.reset(), setError)}>
            <RotateCcw size={16} /> Reset Demo Data
          </Button>
        </Card>
      )}
    </div>
  );
}

export default function App() {
  const { state, loading, bootError, reload } = useLeague();
  const [page, setPage] = useState('Dashboard');
  const [error, setError] = useState('');
  const isCommissioner = state?.currentRole === 'COMMISSIONER';

  useEffect(() => {
    if (state && !isCommissioner && page === 'Commissioner') setPage('Dashboard');
  }, [state, isCommissioner, page]);

  if (hostedBackendEnabled && loading && !state) {
    return <div className="auth-shell"><div className="auth-card"><div className="eyebrow">TEN SPORT</div><h1>Loading league…</h1></div></div>;
  }

  if (hostedBackendEnabled && !state) {
    if (bootError?.message === 'Authentication required.') {
      return <AuthScreen onAuthenticated={reload} />;
    }

    return (
      <div className="auth-shell">
        <div className="auth-card">
          <div className="eyebrow">TEN SPORT</div>
          <h1>League setup needed</h1>
          <p className="muted">{bootError?.message ?? 'No hosted league state is available.'}</p>
          <Button kind="ghost" onClick={() => run(async () => {
            await signOut();
            window.location.reload();
          }, setError)}>
            <LogOut size={16} /> Sign out
          </Button>
          {error && <div className="error">{error}</div>}
        </div>
      </div>
    );
  }

  if (!state) return null;

  const teamId = state.currentTeamId;
  const nav = isCommissioner ? NAV : NAV.filter(([label]) => label !== 'Commissioner');

  const content = {
    Dashboard: <Dashboard state={state} teamId={teamId} />,
    'My Team': <MyTeam state={state} teamId={teamId} setError={setError} />,
    Assets: <Assets state={state} />,
    Trades: <Trades state={state} teamId={teamId} setError={setError} />,
    Keepers: <Keepers state={state} teamId={teamId} setError={setError} />,
    Draft: <Draft state={state} teamId={teamId} setError={setError} />,
    Commissioner: <Commissioner state={state} teamId={teamId} setError={setError} />,
  };

  return (
    <div
      className={`app theme-${state.league.themeMode ?? 'dark'}`}
      style={{
        '--primary': state.league.primaryColor ?? '#6ee7b7',
        '--accent': state.league.accentColor ?? '#22d3ee',
      }}
    >
      <aside>
        <div className="brand">
          <div>{state.league.logoUrl ? <img src={state.league.logoUrl} alt="" /> : '10'}</div>
          <span><b>{state.league.name ?? 'TEN SPORT'}</b><small>Ten Sport Fantasy</small></span>
        </div>
        <nav>
          {nav.map(([label, Icon]) => (
            <button
              key={label}
              className={page === label ? 'active' : ''}
              onClick={() => {
                setPage(label);
                setError('');
              }}
            >
              <Icon size={18} />{label}
            </button>
          ))}
        </nav>
        <div className="aside-foot">
          <Badge tone="good">{hostedBackendEnabled ? 'v0.5 LIVE' : 'v0.3 LOCAL'}</Badge>
          <small>{hostedBackendEnabled ? 'Supabase multi-user mode' : 'Local demo mode'}</small>
        </div>
      </aside>
      <main>
        <header>
          <div>
            <div className="eyebrow">{state.league.season}</div>
            <h1>{page}</h1>
          </div>
          <div className="profile">
            <span>{state.currentUser?.displayName ?? 'Manager'}</span>
            <Badge tone="good">{state.currentRole}</Badge>
            {hostedBackendEnabled && (
              <Button kind="ghost" onClick={() => run(async () => {
                await signOut();
                window.location.reload();
              }, setError)}>
                <LogOut size={16} />
              </Button>
            )}
          </div>
        </header>
        {error && <div className="error">{error}<button onClick={() => setError('')}>×</button></div>}
        {content[page]}
      </main>
    </div>
  );
}
