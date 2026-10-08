import { useEffect, useState } from 'react';
import { loadAssetWatchlist, setAssetWatched } from '../services/watchlistService.js';

export function useAssetWatchlist(state) {
  const [ids, setIds] = useState([]);
  const [error, setError] = useState('');
  useEffect(() => {
    let cancelled = false;
    setIds([]); setError('');
    loadAssetWatchlist({ leagueId: state.league.id, userId: state.currentUserId }).then(next => { if(!cancelled) setIds(next); })
      .catch(e => { if(!cancelled) setError(e.message || 'Unable to load watch list.'); });
    return () => { cancelled=true; };
  }, [state.league.id,state.currentUserId]);
  const toggle = async assetId => {
    const wasWatched = ids.includes(assetId), previous=ids;
    setIds(wasWatched ? ids.filter(id=>id!==assetId) : [...ids,assetId]); setError('');
    try { setIds(await setAssetWatched({ leagueId: state.league.id,userId: state.currentUserId,assetId,watched: !wasWatched })); }
    catch(e) { setIds(previous); setError(e.message || 'Unable to update watch list.'); }
  };
  return { ids,error,toggle };
}
