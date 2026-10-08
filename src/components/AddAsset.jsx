import React, { useEffect, useRef, useState } from 'react';
import { rosterForTeam } from '../domain/selectors.js';
import { rosterMoveError } from '../domain/transactions.js';
import { leagueService } from '../services/service.js';

export default function AddAsset({ state, teamId, asset, onClose }) {
  const [dropId, setDropId] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const dialogRef = useRef(null);
  const latest = useRef({ busy, onClose });
  latest.current = { busy, onClose };
  useEffect(() => {
    const previousFocus = document.activeElement;
    const dialog = dialogRef.current;
    dialog.querySelector('button')?.focus();
    const onKey = event => {
      if (event.key === 'Escape' && !latest.current.busy) latest.current.onClose();
      if (event.key !== 'Tab') return;
      const controls = [...dialog.querySelectorAll('button:not(:disabled),select:not(:disabled)')];
      const first = controls[0], last = controls.at(-1);
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
      if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
    };
    dialog.addEventListener('keydown', onKey);
    return () => { dialog.removeEventListener('keydown', onKey); previousFocus?.focus(); };
  }, []);
  const roster = rosterForTeam(state, teamId);
  const limit = state.league.rosterSize ?? 20;
  const reason = rosterMoveError(state, teamId, dropId ? [dropId] : [], [asset.id]);
  const available = !state.rosterMemberships.some(row => row.assetId === asset.id);
  const locked = state.lockedAssetIds.includes(asset.id) || state.lockedAssetIds.includes(dropId);
  const drafting = ['LIVE', 'PAUSED'].includes(state.draft?.status);
  const confirm = async () => {
    if (busy || reason || !available || locked || drafting) return;
    setBusy(true); setError('');
    try { await leagueService.claimWaiverAsset(asset.id, dropId || null); onClose(); }
    catch (e) { setError(e.message); setBusy(false); }
  };
  return <div className="modal-backdrop"><section ref={dialogRef} className="card add-asset-dialog" role="dialog" aria-modal="true" aria-label={`Add ${asset.name}`}>
    <div className="card-head"><h2>Add {asset.name}</h2><button className="btn ghost" disabled={busy} onClick={onClose}>Cancel</button></div>
    <p>{asset.sport} · Your roster: {roster.length}/{limit}</p>
    <label className="stack tight">{roster.length >= limit ? 'Choose an asset to drop to make room' : 'Drop an asset (optional)'}
      <select aria-label="Asset to drop" value={dropId} disabled={busy} onChange={e => setDropId(e.target.value)}>
        <option value="">{roster.length >= limit ? 'Choose an asset' : 'Keep all my assets'}</option>
        {roster.map(row => <option key={row.assetId} value={row.assetId} disabled={state.lockedAssetIds.includes(row.assetId)}>
          {row.asset.name} · {row.asset.sport}{state.lockedAssetIds.includes(row.assetId) ? ' · Locked' : ''}
        </option>)}
      </select>
    </label>
    {dropId && <p>Drop <b>{roster.find(row => row.assetId === dropId)?.asset.name}</b> and add <b>{asset.name}</b>.</p>}
    {(error || reason || !available || locked || drafting) && <p className="error" role="alert">{error || (!available ? 'This asset has already been added by another team.' : locked ? 'This asset is currently locked.' : drafting ? 'Pool additions are available after the draft finishes.' : reason)}</p>}
    <button className="btn primary" disabled={busy || !!reason || !available || locked || drafting} onClick={confirm}>
      {busy ? 'Adding…' : dropId ? 'Confirm Add / Drop' : 'Confirm Add'}
    </button>
  </section></div>;
}
