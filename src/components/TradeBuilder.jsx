import React, { useState } from 'react';
import { rosterForTeam, teamById } from '../domain/selectors.js';
import { tradeablePicks, tradeError } from '../domain/transactions.js';
import { leagueService } from '../services/service.js';

export default function TradeBuilder({ state, teamId, counterTrade, onClose, onSent }) {
  const [otherTeamId, setOtherTeamId] = useState(counterTrade?.fromTeamId ?? '');
  const [items, setItems] = useState(counterTrade ? counterTrade.items.map(item => ({
    side: item.side === 'FROM' ? 'TO' : 'FROM', type: item.type,
    ...(item.type === 'ASSET' ? { assetId: item.assetId } : { draftPickId: item.draftPickId }),
  })) : []);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const reason = tradeError(state, teamId, otherTeamId, items);
  const toggle = (item) => {
    const key = item.assetId ?? item.draftPickId;
    setItems(current => current.some(i => (i.assetId ?? i.draftPickId) === key)
      ? current.filter(i => (i.assetId ?? i.draftPickId) !== key) : [...current, item]);
  };
  const send = async () => {
    if (busy || reason) return;
    setBusy(true); setError('');
    try { const id = await leagueService.proposeTrade(otherTeamId, items, counterTrade?.id); onSent(id); }
    catch (e) { setError(e.message); setBusy(false); }
  };
  const side = (ownerId, direction) => {
    const roster = rosterForTeam(state, ownerId);
    const picks = tradeablePicks(state, ownerId);
    const selectedCount = items.filter(i => i.side === direction).length;
    return <div className="trade-builder-side">
      <h3>{teamById(state, ownerId)?.name} sends · {selectedCount} selected</h3>
      {!!selectedCount && <div className="trade-selected">
        {items.filter(i => i.side === direction).map(item => {
          const pick = state.draftPicks.find(p => p.id === item.draftPickId);
          const label = item.type === 'ASSET' ? state.assets.find(a => a.id === item.assetId)?.name ?? 'Unavailable asset'
            : pick ? `${pick.season} Round ${pick.round} · ${teamById(state, pick.originalTeamId)?.name}` : 'Unavailable pick';
          return <div key={item.assetId ?? item.draftPickId}><span>{label}</span><button className="btn ghost" disabled={busy} aria-label={`Remove ${label}`} onClick={() => toggle(item)}>Remove</button></div>;
        })}
      </div>}
      <h4>Assets</h4>
      <div className="trade-options">
        {!roster.length && <p className="muted">No rostered assets.</p>}
        {roster.map(row => {
          const locked = state.lockedAssetIds.includes(row.assetId);
          return <label key={row.assetId} className="trade-option">
            <input type="checkbox" disabled={busy || locked || ['LIVE', 'PAUSED'].includes(state.draft?.status)}
              checked={items.some(i => i.side === direction && i.assetId === row.assetId)}
              onChange={() => toggle({ side: direction, type: 'ASSET', assetId: row.assetId })} />
            <span><b>{row.asset.name}</b><small>{row.asset.sport}{locked ? ' · Locked' : ''}</small></span>
          </label>;
        })}
      </div>
      <h4>Draft Picks</h4>
      <div className="trade-options">
        {!picks.length && <p className="muted">No available draft picks.</p>}
        {picks.map(pick => <label key={pick.id} className="trade-option">
          <input type="checkbox" disabled={busy} checked={items.some(i => i.side === direction && i.draftPickId === pick.id)}
            onChange={() => toggle({ side: direction, type: 'DRAFT_PICK', draftPickId: pick.id })} />
          <span><b>{pick.season} Round {pick.round}</b><small>Originally {teamById(state, pick.originalTeamId)?.name}</small></span>
        </label>)}
      </div>
    </div>;
  };
  return <section className="card trade-builder" aria-label={counterTrade ? 'Counteroffer builder' : 'Trade builder'}>
    <div className="card-head"><h2>{counterTrade ? 'Counter Trade' : 'Create Trade'}</h2><button className="btn ghost" disabled={busy} onClick={onClose}>Cancel</button></div>
    <label className="stack tight">Trade with
      <select aria-label="Trade with" disabled={busy || !!counterTrade} value={otherTeamId}
        onChange={e => { setOtherTeamId(e.target.value); setItems([]); setError(''); }}>
        <option value="">Choose a team</option>
        {state.teams.filter(t => t.id !== teamId).map(t => <option key={t.id} value={t.id}>{t.name}</option>)}
      </select>
    </label>
    <p className="muted">Choose assets and picks from both teams. Ownership changes only when the other manager accepts.</p>
    {otherTeamId && <div className="trade-sides">{side(teamId, 'FROM')}{side(otherTeamId, 'TO')}</div>}
    {error && <div className="error" role="alert">{error}</div>}
    {reason && <p className="muted" role="status">{reason}</p>}
    <button className="btn primary" disabled={busy || !!reason} onClick={send}>{busy ? 'Sending…' : counterTrade ? 'Send Counteroffer' : 'Send Trade Offer'}</button>
  </section>;
}
