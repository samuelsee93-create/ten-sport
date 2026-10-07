import { supabase, supabaseConfigured } from './supabaseClient.js';

const localKey = (leagueId, userId) => `ten-sport-watchlist:${userId ?? 'local'}:${leagueId ?? 'default'}`;

function loadLocal(leagueId, userId) {
  try {
    const raw = localStorage.getItem(localKey(leagueId, userId));
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

function saveLocal(leagueId, userId, assetIds) {
  localStorage.setItem(localKey(leagueId, userId), JSON.stringify(assetIds));
}

export async function loadAssetWatchlist({ leagueId, userId }) {
  if (!leagueId) return [];

  if (!supabaseConfigured || !supabase) {
    return loadLocal(leagueId, userId);
  }

  const { data, error } = await supabase
    .from('asset_watchlist')
    .select('asset_id')
    .eq('league_id', leagueId)
    .eq('user_id', userId);

  if (error) throw error;
  return (data ?? []).map((row) => row.asset_id);
}

export async function setAssetWatched({ leagueId, userId, assetId, watched }) {
  if (!leagueId || !assetId) throw new Error('League and asset are required.');

  if (!supabaseConfigured || !supabase) {
    const current = new Set(loadLocal(leagueId, userId));
    if (watched) current.add(assetId);
    else current.delete(assetId);
    const next = [...current];
    saveLocal(leagueId, userId, next);
    return next;
  }

  if (watched) {
    const { error } = await supabase
      .from('asset_watchlist')
      .upsert({
        league_id: leagueId,
        user_id: userId,
        asset_id: assetId,
      }, { onConflict: 'league_id,user_id,asset_id' });
    if (error) throw error;
  } else {
    const { error } = await supabase
      .from('asset_watchlist')
      .delete()
      .eq('league_id', leagueId)
      .eq('user_id', userId)
      .eq('asset_id', assetId);
    if (error) throw error;
  }

  return loadAssetWatchlist({ leagueId, userId });
}
