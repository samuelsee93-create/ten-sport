-- 010_v06_advisor_cleanup.sql
-- Clean up v0.6 advisor findings without changing league behavior.

create or replace function private.required_sports()
returns text[]
language sql
immutable
set search_path=pg_catalog
as $$
  select array['NHL','NFL','F1','Golf','NBA','MLB','UCL','NCAA','6 Nations','Tennis']::text[];
$$;

create index if not exists season_sport_results_team_idx
  on public.season_sport_results(team_id);
create index if not exists season_team_results_team_idx
  on public.season_team_results(team_id);
create index if not exists waiver_transactions_added_asset_idx
  on public.waiver_transactions(added_asset_id);
create index if not exists waiver_transactions_dropped_asset_idx
  on public.waiver_transactions(dropped_asset_id);

-- Superseded by create_league/join_league; no browser client needs this bootstrap RPC anymore.
revoke all on function public.bootstrap_first_league(text,text,text,text) from authenticated;
revoke all on function public.bootstrap_first_league(text,text,text,text) from anon;
revoke all on function public.bootstrap_first_league(text,text,text,text) from public;
