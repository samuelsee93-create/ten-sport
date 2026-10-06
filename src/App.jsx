import React, { useEffect, useMemo, useState } from 'react';
import {
  Activity,
  ArrowLeftRight,
  CalendarDays,
  Crown,
  Database,
  DraftingCompass,
  Gauge,
  History as HistoryIcon,
  Layers3,
  List,
  LogOut,
  Palette,
  Search,
  ShieldCheck,
  Trophy,
  Users,
} from 'lucide-react';
import { hostedBackendEnabled, leagueService } from './services/service.js';
import { signIn, signOut, signUp } from './services/authService.js';
import { DRAFT_STATUS, LINEUP_STATUS, SPORTS } from './domain/constants.js';
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
  ['Transactions', ArrowLeftRight],
  ['History', HistoryIcon],
  ['Leagues', Layers3],
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
      const next = leagueService.getState();
      setState(next);
      setBootError(null);
      return next;
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

function Button({ children, onClick, kind = 'primary', disabled = false, type = 'button' }) {
  return (
    <button type={type} className={`btn ${kind}`} onClick={onClick} disabled={disabled}>
      {children}
    </button>
  );
}

function Card({ title, icon: Icon, children, action, className = '' }) {
  return (
    <section className={`card ${className}`}>
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

function toLocalDateTimeInput(value) {
  if (!value) return '';
  const date = new Date(value);
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
  return local.toISOString().slice(0, 16);
}

async function run(action, setError) {
  try {
    setError('');
    await action();
  } catch (error) {
    setError(error.message || 'Something went wrong.');
  }
}

function previousScore(state, asset) {
  return (asset?.history ?? []).find((row) => row.seasonLabel !== state.league?.season) ?? null;
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
            ? 'Sign in to your leagues, rosters, transactions, history and live drafts.'
            : 'Create one account, then create or join as many Ten Sport leagues as you want.'}
        </p>
        <form className="stack tight" onSubmit={submit}>
          {mode === 'signup' && (
            <input value={displayName} onChange={(e) => setDisplayName(e.target.value)} placeholder="Display name" required />
          )}
          <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="Email" required />
          <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} placeholder="Password" minLength={8} required />
          {error && <div className="error">{error}</div>}
          {message && <div className="callout">{message}</div>}
          <Button type="submit" disabled={busy}>{busy ? 'Working…' : mode === 'signin' ? 'Sign in' : 'Create account'}</Button>
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

function LeagueForms({ onComplete, currentSeason = '2026-27' }) {
  const [mode, setMode] = useState('join');
  const [leagueName, setLeagueName] = useState('');
  const [teamName, setTeamName] = useState('');
  const [code, setCode] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const submit = async (event) => {
    event.preventDefault();
    setBusy(true);
    setError('');
    try {
      if (mode === 'join') {
        await leagueService.joinLeague({ code, teamName });
      } else {
        await leagueService.createLeague({
          name: leagueName,
          teamName,
          seasonLabel: currentSeason,
          scoringVersion: 'v1.2',
        });
      }
      onComplete?.();
    } catch (e) {
      setError(e.message || 'Unable to continue.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="league-form">
      <div className="segmented">
        <button className={mode === 'join' ? 'active' : ''} onClick={() => setMode('join')}>Join league</button>
        <button className={mode === 'create' ? 'active' : ''} onClick={() => setMode('create')}>Create league</button>
      </div>
      <form className="stack tight" onSubmit={submit}>
        {mode === 'create' ? (
          <input value={leagueName} onChange={(e) => setLeagueName(e.target.value)} placeholder="League name" required />
        ) : (
          <input
            value={code}
            onChange={(e) => setCode(e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 8))}
            placeholder="8-character league code"
            required
            minLength={8}
            maxLength={8}
          />
        )}
        <input value={teamName} onChange={(e) => setTeamName(e.target.value)} placeholder="Your team name" required />
        {error && <div className="error">{error}</div>}
        <Button type="submit" disabled={busy}>
          {busy ? 'Working…' : mode === 'join' ? 'Join League' : 'Create League'}
        </Button>
      </form>
    </div>
  );
}

function LeagueHub({ state }) {
  return (
    <div className="auth-shell">
      <div className="auth-card league-hub-card">
        <div className="brand auth-brand">
          <div>10</div>
          <span><b>TEN SPORT</b><small>Fantasy League</small></span>
        </div>
        <div className="eyebrow">WELCOME {state.currentUser?.displayName?.toUpperCase()}</div>
        <h1>Choose your league</h1>
        <p className="muted">Join a friend's league with their code, or create a new one and become commissioner.</p>
        <LeagueForms />
        <Button kind="ghost" onClick={async () => {
          await signOut();
          window.location.reload();
        }}><LogOut size={16} /> Sign out</Button>
      </div>
    </div>
  );
}

function Dashboard({ state, teamId, onOpenTeam }) {
  const leaderboard = state.teams
    .map((team) => ({ ...team, points: pointsForTeam(state, team.id) }))
    .sort((a, b) => b.points - a.points);
  const team = teamById(state, teamId);

  return (
    <div className="grid two">
      <Card title="League Standings" icon={Trophy}>
        <div className="standings">
          {leaderboard.map((row, index) => (
            <button className="standing standing-button" key={row.id} onClick={() => onOpenTeam(row.id)}>
              <strong>{index + 1}</strong>
              <div><b>{row.name}</b><small>{row.managerName}</small></div>
              <span>{row.points.toLocaleString()} pts</span>
            </button>
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
          Every 20-asset roster must contain at least one asset from each of the 10 sports. There are no dedicated or flex roster positions. Active/Bench remains separate: 15 score and 5 sit each scoring lock.
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
          <li>20 assets · all 10 sports must be represented</li>
          <li>15 Active · 5 Bench</li>
          <li>3 free keepers</li>
          <li>Asset + draft-pick trades</li>
          <li>Permanent pick provenance</li>
          <li>Multi-league accounts + join codes</li>
        </ul>
      </Card>
    </div>
  );
}

function SportCoverage({ state, teamId }) {
  const roster = rosterForTeam(state, teamId);
  const counts = Object.fromEntries(
    SPORTS.map((sport) => [sport, roster.filter((row) => row.asset?.sport === sport).length])
  );
  const represented = SPORTS.filter((sport) => counts[sport] > 0).length;

  return (
    <div>
      <div className="coverage-summary">
        <b>{represented}/10 sports represented</b>
        <span className="muted">20 total roster spots · no dedicated or flex positions</span>
      </div>
      <div className="sport-coverage-grid">
        {SPORTS.map((sport) => (
          <div className={`sport-coverage ${counts[sport] > 0 ? 'covered' : 'missing'}`} key={sport}>
            <span>{sport}</span>
            <b>{counts[sport]}</b>
            <small>{counts[sport] > 0 ? 'Represented' : 'Required'}</small>
          </div>
        ))}
      </div>
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
        <small>{membership.asset.sport} · Season {membership.asset.seasonPoints} · For You {membership.asset.pointsForTeam}</small>
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
      <Card title="Sport Coverage" icon={List}>
        <SportCoverage state={state} teamId={teamId} />
      </Card>
      <div className="grid two">
        <Card title={`Active · ${active.length}/15`} icon={Activity}>
          {active.length ? active.map((membership) => row(membership, LINEUP_STATUS.ACTIVE)) : <p className="muted">No active assets yet.</p>}
        </Card>
        <Card title={`Bench · ${bench.length}/5`} icon={Users}>
          {bench.length ? bench.map((membership) => row(membership, LINEUP_STATUS.BENCH)) : <p className="muted">No benched assets yet.</p>}
        </Card>
      </div>
    </div>
  );
}

function TeamDetail({ state, teamId, onBack }) {
  const team = teamById(state, teamId);
  const [sort, setSort] = useState('CURRENT');
  if (!team) return <Card title="Team" icon={Users}><p className="muted">Team not found.</p></Card>;

  const rows = rosterForTeam(state, teamId)
    .map((membership) => ({
      ...membership,
      currentPoints: state.teamAssetPointsById?.[teamId]?.[membership.assetId] ?? 0,
      previous: previousScore(state, membership.asset),
    }))
    .sort((a, b) => {
      if (sort === 'PREVIOUS') return (b.previous?.points ?? -1) - (a.previous?.points ?? -1);
      return b.currentPoints - a.currentPoints;
    });

  const sportTotals = Object.fromEntries(SPORTS.map((sport) => [sport, 0]));
  rows.forEach((row) => {
    sportTotals[row.asset.sport] = (sportTotals[row.asset.sport] ?? 0) + row.currentPoints;
  });

  return (
    <div className="stack">
      <div className="team-detail-head">
        <Button kind="ghost" onClick={onBack}>← Back</Button>
        <div>
          <h2>{team.name}</h2>
          <span className="muted">{team.managerName}</span>
        </div>
        <div className="team-total"><span>Season total</span><b>{pointsForTeam(state, teamId).toLocaleString()} pts</b></div>
      </div>
      <Card title="Points by Sport" icon={Trophy}>
        <div className="sport-total-grid">
          {SPORTS.map((sport) => (
            <div key={sport}><span>{sport}</span><b>{sportTotals[sport].toLocaleString()}</b></div>
          ))}
        </div>
      </Card>
      <Card title="Sport Coverage" icon={List}>
        <SportCoverage state={state} teamId={teamId} />
      </Card>
      <Card
        title="Roster Performance"
        icon={Activity}
        action={
          <select value={sort} onChange={(e) => setSort(e.target.value)}>
            <option value="CURRENT">Sort: this season points</option>
            <option value="PREVIOUS">Sort: previous season points</option>
          </select>
        }
      >
        <div className="asset-table-wrap">
          <table className="asset-table">
            <thead>
              <tr>
                <th>Asset</th><th>Sport</th><th>This Season</th><th>Previous Season</th><th>Lineup</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.assetId}>
                  <td><b>{row.asset.name}</b></td>
                  <td><Badge>{row.asset.sport}</Badge></td>
                  <td className="numeric">{row.currentPoints.toLocaleString()}</td>
                  <td className="numeric">{row.previous ? row.previous.points.toLocaleString() : '—'}</td>
                  <td><Badge tone={row.lineupStatus === 'ACTIVE' ? 'good' : 'neutral'}>{row.lineupStatus}</Badge></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  );
}

function Assets({ state }) {
  const [query, setQuery] = useState('');
  const [sport, setSport] = useState('ALL');
  const [availability, setAvailability] = useState('ALL');
  const [sort, setSort] = useState('POINTS');

  const sports = [...new Set(state.assets.map((asset) => asset.sport))].sort();
  const ownershipByAsset = Object.fromEntries(state.rosterMemberships.map((membership) => [membership.assetId, membership.teamId]));

  const rows = state.assets
    .map((asset) => {
      const previous = previousScore(state, asset);
      const ownerTeamId = ownershipByAsset[asset.id] ?? null;
      const owner = ownerTeamId ? teamById(state, ownerTeamId) : null;
      return { asset, previous, owner };
    })
    .filter(({ asset, owner }) => {
      const matchesQuery = !query.trim() || asset.name.toLowerCase().includes(query.trim().toLowerCase());
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
    <Card title="Draftable Assets" icon={List} action={<Badge>{state.assets.length} assets</Badge>}>
      <p className="muted">Historical points show what each asset would have scored under the Ten Sport scoring model.</p>
      <div className="asset-toolbar">
        <label className="search-box">
          <Search size={16} />
          <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search assets…" />
        </label>
        <select value={sport} onChange={(e) => setSport(e.target.value)}>
          <option value="ALL">All sports</option>
          {sports.map((item) => <option key={item} value={item}>{item}</option>)}
        </select>
        <select value={availability} onChange={(e) => setAvailability(e.target.value)}>
          <option value="ALL">All assets</option><option value="AVAILABLE">Available only</option><option value="ROSTERED">Rostered only</option>
        </select>
        <select value={sort} onChange={(e) => setSort(e.target.value)}>
          <option value="POINTS">Sort: previous points</option><option value="RANK">Sort: previous rank</option><option value="NAME">Sort: name</option><option value="SPORT">Sort: sport</option>
        </select>
      </div>
      {state.assets.length === 0 ? (
        <div className="empty-state"><b>The asset database is ready.</b><span>No real-world assets have been imported yet.</span></div>
      ) : (
        <div className="asset-table-wrap">
          <table className="asset-table">
            <thead><tr><th>Asset</th><th>Sport</th><th>Previous Season</th><th>Points</th><th>Rank</th><th>Status</th></tr></thead>
            <tbody>
              {rows.map(({ asset, previous, owner }) => (
                <tr key={asset.id}>
                  <td><b>{asset.name}</b></td><td><Badge>{asset.sport}</Badge></td><td>{previous?.seasonLabel ?? '—'}</td>
                  <td className="numeric">{previous ? previous.points.toLocaleString() : '—'}</td>
                  <td className="numeric">{previous?.rank ? `#${previous.rank}` : '—'}</td>
                  <td>{owner ? <Badge>{owner.name}</Badge> : <Badge tone="good">Available</Badge>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  );
}

function TradeCard({ state, trade, teamId, setError, interactive = false }) {
  const from = teamById(state, trade.fromTeamId);
  const to = teamById(state, trade.toTeamId);
  return (
    <div className="trade">
      <div className="trade-head">
        <div><b>{from?.name ?? 'Unknown team'}</b> → <b>{to?.name ?? 'Unknown team'}</b></div>
        <Badge tone={trade.status === 'PENDING' ? 'warn' : trade.status === 'ACCEPTED' ? 'good' : 'neutral'}>{trade.status}</Badge>
      </div>
      <div className="trade-sides">
        <div><span>{from?.name ?? 'Team'} sends</span>{tradeItemsForSide(state, trade, 'FROM').map((item) => <p key={item.id ?? item.assetId ?? item.draftPickId}>{item.label}</p>)}</div>
        <div><span>{to?.name ?? 'Team'} sends</span>{tradeItemsForSide(state, trade, 'TO').map((item) => <p key={item.id ?? item.assetId ?? item.draftPickId}>{item.label}</p>)}</div>
      </div>
      {interactive && trade.status === 'PENDING' && trade.toTeamId === teamId && (
        <div className="inline">
          <Button onClick={() => run(() => leagueService.acceptTrade(trade.id), setError)}>Accept Trade</Button>
          <Button kind="ghost" onClick={() => run(() => leagueService.declineTrade(trade.id), setError)}>Decline</Button>
        </div>
      )}
      <small>{formatDate(trade.resolvedAt ?? trade.createdAt)}</small>
    </div>
  );
}

function Transactions({ state, teamId, setError }) {
  const pending = state.trades.filter((trade) => trade.status === 'PENDING' && (trade.toTeamId === teamId || trade.fromTeamId === teamId));
  const completedTrades = state.trades.filter((trade) => trade.status !== 'PENDING');

  const activity = [
    ...completedTrades.map((trade) => ({ kind: 'TRADE', date: trade.resolvedAt ?? trade.createdAt, trade })),
    ...(state.waiverTransactions ?? []).map((waiver) => ({ kind: 'WAIVER', date: waiver.createdAt, waiver })),
  ].sort((a, b) => new Date(b.date) - new Date(a.date));

  return (
    <div className="stack">
      <Card title="Pending Trades" icon={ArrowLeftRight}>
        {pending.length ? pending.map((trade) => <TradeCard key={trade.id} state={state} trade={trade} teamId={teamId} setError={setError} interactive />) : <p className="muted">No pending trades for your team.</p>}
      </Card>
      <Card title="Transaction Log" icon={HistoryIcon}>
        {activity.length === 0 && <p className="muted">No completed trades or waiver pickups yet.</p>}
        <div className="transaction-list">
          {activity.map((item) => {
            if (item.kind === 'TRADE') {
              const from = teamById(state, item.trade.fromTeamId);
              const to = teamById(state, item.trade.toTeamId);
              return (
                <div className="transaction-row" key={`trade-${item.trade.id}`}>
                  <Badge>TRADE</Badge>
                  <div><b>{from?.name} ↔ {to?.name}</b><small>{item.trade.status}</small></div>
                  <span>{formatDate(item.date)}</span>
                </div>
              );
            }
            const team = teamById(state, item.waiver.teamId);
            const added = state.assets.find((asset) => asset.id === item.waiver.addedAssetId);
            const dropped = state.assets.find((asset) => asset.id === item.waiver.droppedAssetId);
            return (
              <div className="transaction-row" key={`waiver-${item.waiver.id}`}>
                <Badge tone="good">{item.waiver.transactionType}</Badge>
                <div><b>{team?.name} added {added?.name ?? 'Unknown asset'}</b><small>{dropped ? `Dropped ${dropped.name}` : 'No drop'}</small></div>
                <span>{formatDate(item.date)}</span>
              </div>
            );
          })}
        </div>
      </Card>
    </div>
  );
}

function History({ state }) {
  const finalized = (state.leagueHistory?.seasons ?? []).filter((season) => season.results.length > 0);
  const allTeamResults = finalized.flatMap((season) => season.results.map((result) => ({ ...result, seasonLabel: season.label })));
  const allSportResults = state.leagueHistory?.sportResults ?? [];

  const highestSeason = [...allTeamResults].sort((a, b) => b.totalPoints - a.totalPoints)[0];
  const lowestSeason = [...allTeamResults].sort((a, b) => a.totalPoints - b.totalPoints)[0];

  return (
    <div className="stack">
      <Card title="League Champions" icon={Trophy}>
        {finalized.length === 0 ? (
          <div className="empty-state"><b>History starts here.</b><span>The first champion will appear after the inaugural season is finalized.</span></div>
        ) : (
          <div className="champion-grid">
            {finalized.map((season) => {
              const winners = season.results.filter((row) => row.finalRank === 1);
              return winners.map((winner) => (
                <div className="champion-card" key={`${season.id}-${winner.teamId}`}>
                  <span>{season.label}</span><b>{winner.teamName}</b><small>{winner.managerName} · {winner.totalPoints.toLocaleString()} pts</small>
                </div>
              ));
            })}
          </div>
        )}
      </Card>
      <Card title="Record Book · Season Totals" icon={HistoryIcon}>
        {highestSeason ? (
          <div className="record-grid">
            <div><span>Most points in a season</span><b>{highestSeason.totalPoints.toLocaleString()}</b><small>{highestSeason.teamName} · {highestSeason.seasonLabel}</small></div>
            <div><span>Lowest points in a season</span><b>{lowestSeason.totalPoints.toLocaleString()}</b><small>{lowestSeason.teamName} · {lowestSeason.seasonLabel}</small></div>
          </div>
        ) : <p className="muted">No finalized season totals yet.</p>}
      </Card>
      <Card title="Record Book · By Sport" icon={Trophy}>
        <div className="record-sport-list">
          {SPORTS.map((sport) => {
            const rows = allSportResults.filter((row) => row.sport === sport);
            const high = [...rows].sort((a, b) => b.points - a.points)[0];
            const low = [...rows].sort((a, b) => a.points - b.points)[0];
            const highTeam = high ? teamById(state, high.teamId) : null;
            const lowTeam = low ? teamById(state, low.teamId) : null;
            return (
              <div className="record-sport-row" key={sport}>
                <b>{sport}</b>
                <div><span>Most</span><strong>{high ? high.points.toLocaleString() : '—'}</strong><small>{high ? `${highTeam?.name ?? 'Historical team'} · ${high.seasonLabel}` : 'No record yet'}</small></div>
                <div><span>Lowest</span><strong>{low ? low.points.toLocaleString() : '—'}</strong><small>{low ? `${lowTeam?.name ?? 'Historical team'} · ${low.seasonLabel}` : 'No record yet'}</small></div>
              </div>
            );
          })}
        </div>
      </Card>
    </div>
  );
}

function Leagues({ state, setPage }) {
  return (
    <div className="grid two">
      <Card title="Your Leagues" icon={Layers3}>
        <div className="league-list">
          {(state.availableLeagues ?? []).map((league) => (
            <div className={`league-row ${league.id === state.league.id ? 'current' : ''}`} key={league.id}>
              <div>
                <b>{league.name}</b>
                <small>{league.role} {league.id === state.league.id ? '· Current league' : ''}</small>
              </div>
              {league.id === state.league.id
                ? <Badge tone="good">ACTIVE</Badge>
                : <Button kind="ghost" onClick={async () => {
                    await leagueService.switchLeague(league.id);
                    setPage('Dashboard');
                  }}>Switch</Button>}
            </div>
          ))}
        </div>
      </Card>
      <Card title="Join or Create Another League" icon={Layers3}>
        <LeagueForms currentSeason={state.league.season} onComplete={() => setPage('Dashboard')} />
      </Card>
      <Card title="Current League Code" icon={Database}>
        <div className="join-code">{state.league.joinCode}</div>
        <p className="muted">Share this code with anyone you want to invite. Their account can join this league without affecting any other leagues they belong to.</p>
      </Card>
    </div>
  );
}

function Keepers({ state, teamId, setError }) {
  const keepers = state.keeperSelections.filter((row) => row.teamId === teamId);
  const eligible = (state.keeperEligibleRoster ?? [])
    .filter((row) => row.teamId === teamId)
    .map((row) => ({ ...row, asset: state.assets.find((asset) => asset.id === row.assetId) }))
    .filter((row) => row.asset);

  return (
    <Card
      title={`Keeper Centre · ${keepers.length}/3`}
      icon={Crown}
      action={<Badge tone="warn">Deadline {formatDate(state.league.keeperDeadline)}</Badge>}
    >
      <p className="muted">
        Keep 0–3 assets. Each keeper costs one round earlier than its original draft round for every year kept, for a maximum of three keeper years.
      </p>
      {!state.keeperSourceSeason ? (
        <div className="empty-state">
          <b>Inaugural season</b>
          <span>There are no keeper-eligible assets until this league completes its first season.</span>
        </div>
      ) : eligible.length === 0 ? (
        <div className="empty-state">
          <b>No keeper-eligible assets</b>
          <span>Only assets from your final {state.keeperSourceSeason.label} roster that remain draftable can be kept.</span>
        </div>
      ) : (
        <div className="keeper-grid">
          {eligible.map((membership) => {
            const keeper = keepers.find((row) => row.assetId === membership.assetId);
            return (
              <button
                key={membership.assetId}
                className={`keeper ${keeper ? 'selected' : ''}`}
                onClick={() => run(() => leagueService.toggleKeeper(teamId, membership.assetId), setError)}
              >
                <div>
                  <b>{membership.asset.name}</b>
                  <small>
                    {membership.asset.sport}
                    {keeper
                      ? ` · Year ${keeper.keeperYear} · Costs Round ${keeper.costRound}`
                      : ' · Select to calculate keeper cost'}
                  </small>
                </div>
                {keeper ? <Crown size={18} /> : <span>Choose</span>}
              </button>
            );
          })}
        </div>
      )}
      <div className="callout">
        Keeper age follows the asset through trades. If an asset returns to the draft and is selected again, its keeper clock resets from the new draft round.
      </div>
    </Card>
  );
}

function Draft({ state, teamId, setError }) {
  if (!state.draft) return <Card title="Live Draft Room" icon={DraftingCompass}><p className="muted">No draft is configured for this season yet.</p></Card>;

  const order = draftOrder(state);
  const current = order[state.draft.currentOverallPick - 1];
  const currentTeam = current ? teamById(state, current.currentTeamId) : null;
  const unowned = state.assets.filter(
    (asset) => !state.rosterMemberships.some((m) => m.assetId === asset.id)
      && !state.draft.selections.some((selection) => selection.assetId === asset.id)
  );

  return (
    <div className="stack">
      <Card title="Live Draft Room" icon={DraftingCompass} action={<Badge tone={state.draft.status === DRAFT_STATUS.LIVE ? 'good' : 'warn'}>{state.draft.status}</Badge>}>
        <div className="draft-banner">
          <div>
            <span>ROUND {current?.round ?? '—'} · PICK {state.draft.currentOverallPick}</span>
            <h3>{currentTeam?.name ?? 'Draft complete'}</h3>
            <small>{currentTeam ? `${currentTeam.managerName} is on the clock` : 'All selections completed'}</small>
          </div>
          <div className="timer">{state.draft.pickTimerSeconds}s</div>
        </div>
        <p className="muted">Draft date: {formatDate(state.draft.scheduledAt)} · 20-round snake draft · finished rosters must represent all 10 sports.</p>
        {state.draft.status === DRAFT_STATUS.LIVE && currentTeam?.id === teamId && (
          <div className="draft-pool">
            {unowned.slice(0, 10).map((asset) => (
              <button key={asset.id} onClick={() => run(() => leagueService.makeDraftPick(asset.id), setError)}>
                <b>{asset.name}</b><span>{asset.sport} · {previousScore(state, asset)?.points ?? 0} prior pts</span>
              </button>
            ))}
          </div>
        )}
        {state.draft.status !== DRAFT_STATUS.LIVE && <p className="muted">Commissioner can start the draft from Commissioner controls.</p>}
      </Card>
      <Card title="Recent Picks" icon={Trophy}>
        {state.draft.selections.length
          ? state.draft.selections.slice(-8).reverse().map((selection) => (
              <div className="selection" key={selection.id}>
                <b>#{selection.overallPick}</b><span>{state.assets.find((asset) => asset.id === selection.assetId)?.name}</span><small>{teamById(state, selection.teamId)?.name}{selection.selectionType === 'KEEPER' ? ' · KEEPER' : ''}</small>
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
  const [draftDate, setDraftDate] = useState(toLocalDateTimeInput(state.draft?.scheduledAt));
  const [draftOrderIds, setDraftOrderIds] = useState(() => {
    const configured = (state.draft?.order ?? []).slice().sort((a, b) => a.slot - b.slot).map((row) => row.teamId);
    return configured.length === state.teams.length ? configured : state.teams.map((team) => team.id);
  });

  useEffect(() => {
    setAppearance({
      name: state.league.name ?? 'Ten Sport Fantasy League',
      logoUrl: state.league.logoUrl ?? '',
      primaryColor: state.league.primaryColor ?? '#6ee7b7',
      accentColor: state.league.accentColor ?? '#22d3ee',
      themeMode: state.league.themeMode ?? 'dark',
    });
  }, [state.league.id, state.league.name, state.league.logoUrl, state.league.primaryColor, state.league.accentColor, state.league.themeMode]);

  useEffect(() => {
    setDraftDate(toLocalDateTimeInput(state.draft?.scheduledAt));
  }, [state.draft?.id, state.draft?.scheduledAt]);

  useEffect(() => {
    const configured = (state.draft?.order ?? []).slice().sort((a, b) => a.slot - b.slot).map((row) => row.teamId);
    setDraftOrderIds(configured.length === state.teams.length ? configured : state.teams.map((team) => team.id));
  }, [state.draft?.id, state.draft?.orderMethod, state.teams.length]);

  const moveDraftTeam = (index, delta) => {
    setDraftOrderIds((current) => {
      const next = [...current];
      const target = index + delta;
      if (target < 0 || target >= next.length) return current;
      [next[index], next[target]] = [next[target], next[index]];
      return next;
    });
  };

  const setAppearanceField = (field, value) => setAppearance((current) => ({ ...current, [field]: value }));

  return (
    <div className="grid two">
      <Card title="League Appearance" icon={Palette}>
        <div className="appearance-preview">
          <div className="appearance-logo" style={{ background: `linear-gradient(145deg, ${appearance.primaryColor}, ${appearance.accentColor})` }}>
            {appearance.logoUrl ? <img src={appearance.logoUrl} alt="" /> : '10'}
          </div>
          <div><b>{appearance.name || 'Ten Sport Fantasy League'}</b><small>{appearance.themeMode} theme</small></div>
        </div>
        <div className="appearance-fields">
          <label><span>League name</span><input value={appearance.name} maxLength={80} onChange={(e) => setAppearanceField('name', e.target.value)} /></label>
          <label><span>League logo HTTPS URL</span><input value={appearance.logoUrl} onChange={(e) => setAppearanceField('logoUrl', e.target.value)} placeholder="https://…" /></label>
          <div className="color-fields">
            <label><span>Primary colour</span><div className="color-input"><input type="color" value={appearance.primaryColor} onChange={(e) => setAppearanceField('primaryColor', e.target.value)} /><code>{appearance.primaryColor}</code></div></label>
            <label><span>Accent colour</span><div className="color-input"><input type="color" value={appearance.accentColor} onChange={(e) => setAppearanceField('accentColor', e.target.value)} /><code>{appearance.accentColor}</code></div></label>
          </div>
          <label><span>Theme</span><select value={appearance.themeMode} onChange={(e) => setAppearanceField('themeMode', e.target.value)}><option value="dark">Dark</option><option value="light">Light</option><option value="system">Follow device</option></select></label>
          <Button onClick={() => run(() => leagueService.updateLeagueAppearance(appearance), setError)}>Save League Appearance</Button>
        </div>
      </Card>

      <Card title="Draft Controls" icon={ShieldCheck}>
        {state.draft ? (
          <div className="stack tight">
            <label className="field-label"><span>Draft date & time</span><input type="datetime-local" value={draftDate} onChange={(e) => setDraftDate(e.target.value)} /></label>
            <Button kind="ghost" disabled={!draftDate} onClick={() => run(() => leagueService.setDraftSchedule(new Date(draftDate).toISOString()), setError)}>Save Draft Date & Time</Button>
            <div className="detail"><span>Scheduled</span><b>{formatDate(state.draft.scheduledAt)}</b></div>
            <div className="detail"><span>Pick timer</span><b>{state.draft.pickTimerSeconds}s</b></div>
            <div className="inline">
              <Button onClick={() => run(() => leagueService.setDraftStatus(DRAFT_STATUS.LIVE), setError)}>Start / Resume</Button>
              <Button kind="ghost" onClick={() => run(() => leagueService.setDraftStatus(DRAFT_STATUS.PAUSED), setError)}>Pause</Button>
            </div>
          </div>
        ) : <p className="muted">No draft is configured yet.</p>}
      </Card>

      <Card title="Draft Order · Snake" icon={DraftingCompass}>
        {!state.draft ? (
          <p className="muted">No draft is configured yet.</p>
        ) : (
          <div className="stack tight">
            <p className="muted">
              Set the first-round order manually or randomize it. Even-numbered rounds automatically reverse this order.
            </p>
            <div className="draft-order-list">
              {draftOrderIds.map((id, index) => {
                const team = teamById(state, id);
                return (
                  <div className="draft-order-row" key={id}>
                    <strong>{index + 1}</strong>
                    <div><b>{team?.name ?? 'Unknown team'}</b><small>{team?.managerName}</small></div>
                    <div className="draft-order-actions">
                      <button disabled={index === 0 || state.draft.status === DRAFT_STATUS.LIVE} onClick={() => moveDraftTeam(index, -1)}>↑</button>
                      <button disabled={index === draftOrderIds.length - 1 || state.draft.status === DRAFT_STATUS.LIVE} onClick={() => moveDraftTeam(index, 1)}>↓</button>
                    </div>
                  </div>
                );
              })}
            </div>
            <div className="inline">
              <Button
                disabled={state.draft.status === DRAFT_STATUS.LIVE}
                onClick={() => run(() => leagueService.setDraftOrder(draftOrderIds), setError)}
              >
                Save Draft Order
              </Button>
              <Button
                kind="ghost"
                disabled={state.draft.status === DRAFT_STATUS.LIVE}
                onClick={() => run(() => leagueService.randomizeDraftOrder(), setError)}
              >
                Randomize Order
              </Button>
            </div>
            <div className="detail"><span>Order method</span><b>{state.draft.orderMethod ?? 'Not set'}</b></div>
          </div>
        )}
      </Card>

      <Card title="League Access" icon={Layers3}>
        <div className="join-code">{state.league.joinCode}</div>
        <p className="muted">Share this unique code with managers you want to invite.</p>
        <div className="detail"><span>Managers</span><b>{state.teams.length}</b></div>
      </Card>

      <Card title="Future Draft Capital" icon={CalendarDays}>
        {ownedDraftPicks(state, teamId).slice(0, 12).map((pick) => (
          <div className="detail" key={pick.id}><span>{pick.season} Round {pick.round}</span><b>Originally {teamById(state, pick.originalTeamId)?.managerName}</b></div>
        ))}
        {ownedDraftPicks(state, teamId).length === 0 && <p className="muted">Draft picks are generated when the draft date is set.</p>}
      </Card>

      <Card title="Season Archive" icon={HistoryIcon}>
        <p className="muted">Finalizing a season locks its standings into League History and updates the Record Book.</p>
        <Button
          kind="danger"
          disabled={state.league.seasonStatus === 'COMPLETE'}
          onClick={() => {
            if (window.confirm('Finalize this season? This snapshots the standings into League History.')) {
              run(() => leagueService.finalizeSeason(), setError);
            }
          }}
        >
          {state.league.seasonStatus === 'COMPLETE' ? 'Season Finalized' : 'Finalize Season'}
        </Button>
      </Card>

      <Card title="Hosted Backend" icon={Database}>
        <ul className="checklist">
          <li>Multi-league manager accounts</li><li>Unique league join codes</li><li>Postgres persistence + RLS</li>
          <li>Realtime roster/transaction refresh</li><li>Historical season snapshots</li><li>Dedicated sport-slot enforcement</li>
        </ul>
      </Card>
    </div>
  );
}

export default function App() {
  const { state, loading, bootError, reload } = useLeague();
  const [page, setPage] = useState('Dashboard');
  const [error, setError] = useState('');
  const [selectedTeamId, setSelectedTeamId] = useState(null);
  const isCommissioner = state?.currentRole === 'COMMISSIONER';

  useEffect(() => {
    if (state?.league && !isCommissioner && page === 'Commissioner') setPage('Dashboard');
  }, [state?.league?.id, isCommissioner, page]);

  useEffect(() => {
    setSelectedTeamId(null);
    if (state?.league?.id) setPage((current) => current === 'Team' ? 'Dashboard' : current);
  }, [state?.league?.id]);

  if (hostedBackendEnabled && loading && !state) {
    return <div className="auth-shell"><div className="auth-card"><div className="eyebrow">TEN SPORT</div><h1>Loading…</h1></div></div>;
  }

  if (hostedBackendEnabled && !state) {
    if (bootError?.message === 'Authentication required.') return <AuthScreen onAuthenticated={reload} />;
    return (
      <div className="auth-shell"><div className="auth-card"><div className="eyebrow">TEN SPORT</div><h1>Something needs attention</h1><p className="muted">{bootError?.message ?? 'No hosted state is available.'}</p></div></div>
    );
  }

  if (!state) return null;
  if (hostedBackendEnabled && state.needsLeague) return <LeagueHub state={state} />;

  const teamId = state.currentTeamId;
  const nav = isCommissioner ? NAV : NAV.filter(([label]) => label !== 'Commissioner');
  const openTeam = (id) => {
    setSelectedTeamId(id);
    setPage('Team');
    setError('');
  };

  const content = {
    Dashboard: <Dashboard state={state} teamId={teamId} onOpenTeam={openTeam} />,
    'My Team': <MyTeam state={state} teamId={teamId} setError={setError} />,
    Assets: <Assets state={state} />,
    Transactions: <Transactions state={state} teamId={teamId} setError={setError} />,
    History: <History state={state} />,
    Leagues: <Leagues state={state} setPage={setPage} />,
    Keepers: <Keepers state={state} teamId={teamId} setError={setError} />,
    Draft: <Draft state={state} teamId={teamId} setError={setError} />,
    Commissioner: <Commissioner state={state} teamId={teamId} setError={setError} />,
    Team: <TeamDetail state={state} teamId={selectedTeamId} onBack={() => setPage('Dashboard')} />,
  };

  return (
    <div
      className={`app theme-${state.league.themeMode ?? 'dark'}`}
      style={{ '--primary': state.league.primaryColor ?? '#6ee7b7', '--accent': state.league.accentColor ?? '#22d3ee' }}
    >
      <aside>
        <div className="brand">
          <div>{state.league.logoUrl ? <img src={state.league.logoUrl} alt="" /> : '10'}</div>
          <span><b>{state.league.name ?? 'TEN SPORT'}</b><small>Ten Sport Fantasy</small></span>
        </div>

        {(state.availableLeagues ?? []).length > 1 && (
          <select
            className="league-switcher"
            value={state.league.id}
            onChange={async (e) => {
              await leagueService.switchLeague(e.target.value);
              setPage('Dashboard');
            }}
          >
            {state.availableLeagues.map((league) => <option key={league.id} value={league.id}>{league.name}</option>)}
          </select>
        )}

        <nav>
          {nav.map(([label, Icon]) => (
            <button
              key={label}
              className={page === label ? 'active' : ''}
              onClick={() => {
                setPage(label);
                setSelectedTeamId(null);
                setError('');
              }}
            >
              <Icon size={18} />{label}
            </button>
          ))}
        </nav>
        <div className="aside-foot">
          <Badge tone="good">{hostedBackendEnabled ? 'v0.7 LIVE' : 'v0.3 LOCAL'}</Badge>
          <small>{hostedBackendEnabled ? 'Supabase multi-league mode' : 'Local demo mode'}</small>
        </div>
      </aside>
      <main>
        <header>
          <div><div className="eyebrow">{state.league.season}</div><h1>{page === 'Team' ? teamById(state, selectedTeamId)?.name ?? 'Team' : page}</h1></div>
          <div className="profile">
            <span>{state.currentUser?.displayName ?? 'Manager'}</span>
            <Badge tone="good">{state.currentRole}</Badge>
            {hostedBackendEnabled && <Button kind="ghost" onClick={() => run(async () => { await signOut(); window.location.reload(); }, setError)}><LogOut size={16} /></Button>}
          </div>
        </header>
        {error && <div className="error">{error}<button onClick={() => setError('')}>×</button></div>}
        {content[page]}
      </main>
    </div>
  );
}
