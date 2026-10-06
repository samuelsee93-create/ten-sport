import { supabase, supabaseConfigured } from './supabaseClient.js';

function client() {
  if (!supabaseConfigured || !supabase) throw new Error('Supabase is not configured.');
  return supabase;
}

export class SupabaseLeagueService {
  async renameTeam(teamId, name) {
    const { error } = await client().rpc('rename_team', { p_team_id: teamId, p_name: name });
    if (error) throw error;
  }

  async setLineupStatus(seasonId, teamId, assetId, status) {
    const { error } = await client().rpc('set_lineup_status', {
      p_season_id: seasonId,
      p_team_id: teamId,
      p_asset_id: assetId,
      p_status: status,
    });
    if (error) throw error;
  }

  async toggleKeeper(seasonId, teamId, assetId) {
    const { data, error } = await client().rpc('toggle_keeper', {
      p_season_id: seasonId,
      p_team_id: teamId,
      p_asset_id: assetId,
    });
    if (error) throw error;
    return data;
  }

  async acceptTrade(tradeId) {
    const { error } = await client().rpc('accept_trade', { p_trade_id: tradeId });
    if (error) throw error;
  }

  async setDraftStatus(draftId, status) {
    const { error } = await client().rpc('set_draft_status', {
      p_draft_id: draftId,
      p_status: status,
    });
    if (error) throw error;
  }

  async makeDraftPick(draftId, assetId) {
    const { data, error } = await client().rpc('make_draft_pick', {
      p_draft_id: draftId,
      p_asset_id: assetId,
    });
    if (error) throw error;
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
}
