-- Save next-draft choices during the season; formal keeper reservations remain separate.
create table public.keeper_designations (
  id uuid primary key default gen_random_uuid(),
  source_season_id uuid not null references public.seasons(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete cascade,
  asset_id uuid not null references public.assets(id),
  created_at timestamptz not null default now(),
  unique(source_season_id,team_id,asset_id)
);
create index keeper_designations_team_idx on public.keeper_designations(team_id);
create index keeper_designations_asset_idx on public.keeper_designations(asset_id);
alter table public.keeper_designations enable row level security;
revoke all on public.keeper_designations from anon,authenticated;
grant select on public.keeper_designations to authenticated;
create policy keeper_designations_owner_read on public.keeper_designations for select to authenticated using (
  exists(select 1 from public.teams t where t.id=team_id and (t.owner_user_id=(select auth.uid()) or public.is_league_commissioner(t.league_id)))
);
