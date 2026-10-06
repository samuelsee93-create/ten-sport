-- 005_live_advisor_cleanup.sql
-- Address live Supabase advisor findings without changing Ten Sport league rules.

-- SECURITY: anon users should never be able to call SECURITY DEFINER functions.
revoke execute on function public.accept_trade(uuid) from anon;
revoke execute on function public.decline_trade(uuid) from anon;
revoke execute on function public.handle_new_user() from anon;
revoke execute on function public.is_league_commissioner(uuid) from anon;
revoke execute on function public.is_league_member(uuid) from anon;
revoke execute on function public.make_draft_pick(uuid,uuid) from anon;
revoke execute on function public.rename_team(uuid,text) from anon;
revoke execute on function public.set_draft_status(uuid,text) from anon;
revoke execute on function public.set_lineup_status(uuid,uuid,uuid,text) from anon;
revoke execute on function public.set_team_logo_url(uuid,text) from anon;
revoke execute on function public.shares_active_league(uuid) from anon;
revoke execute on function public.toggle_keeper(uuid,uuid,uuid) from anon;

-- Trigger-only bootstrap function should not be callable from the Data API.
revoke execute on function public.handle_new_user() from authenticated;

-- RLS performance: evaluate auth.uid() once per statement where directly referenced.
alter policy profiles_self_read on public.profiles
  using ((select auth.uid()) = id);

alter policy leagues_member_read on public.leagues
  using (
    public.is_league_member(id)
    or commissioner_user_id = (select auth.uid())
  );

-- Consolidate profile SELECT policies to avoid multiple permissive-policy evaluation.
drop policy if exists profiles_league_member_read on public.profiles;
drop policy if exists profiles_self_read on public.profiles;
create policy profiles_member_read
on public.profiles
for select
to authenticated
using (
  id = (select auth.uid())
  or public.shares_active_league(id)
);

-- Cover foreign keys used in joins, deletes and RLS checks.
create index if not exists audit_log_actor_user_idx on public.audit_log(actor_user_id);
create index if not exists audit_log_league_idx on public.audit_log(league_id);
create index if not exists draft_picks_original_team_idx on public.draft_picks(original_team_id);
create index if not exists draft_selections_asset_idx on public.draft_selections(asset_id);
create index if not exists draft_selections_draft_pick_idx on public.draft_selections(draft_pick_id);
create index if not exists draft_selections_team_idx on public.draft_selections(team_id);
create index if not exists keeper_selections_asset_idx on public.keeper_selections(asset_id);
create index if not exists keeper_selections_team_idx on public.keeper_selections(team_id);
create index if not exists league_memberships_user_idx on public.league_memberships(user_id);
create index if not exists leagues_commissioner_idx on public.leagues(commissioner_user_id);
create index if not exists lineup_events_asset_idx on public.lineup_events(asset_id);
create index if not exists lineup_events_season_idx on public.lineup_events(season_id);
create index if not exists lineup_events_team_idx on public.lineup_events(team_id);
create index if not exists roster_memberships_asset_idx on public.roster_memberships(asset_id);
create index if not exists scoring_event_assets_asset_idx on public.scoring_event_assets(asset_id);
create index if not exists scoring_events_season_idx on public.scoring_events(season_id);
create index if not exists teams_owner_user_idx on public.teams(owner_user_id);
create index if not exists trade_items_asset_idx on public.trade_items(asset_id);
create index if not exists trade_items_draft_pick_idx on public.trade_items(draft_pick_id);
create index if not exists trade_items_trade_idx on public.trade_items(trade_id);
create index if not exists trades_recipient_team_idx on public.trades(recipient_team_id);
create index if not exists trades_season_idx on public.trades(season_id);
