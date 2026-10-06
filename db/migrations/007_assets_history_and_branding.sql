-- 007_assets_history_and_branding.sql
-- Historical draftable-asset scoring, commissioner-controlled league branding,
-- and Realtime coverage for league/team/keeper changes.

alter table public.leagues
  add column if not exists logo_url text,
  add column if not exists primary_color text not null default '#6ee7b7',
  add column if not exists accent_color text not null default '#22d3ee',
  add column if not exists theme_mode text not null default 'dark'
    check (theme_mode in ('dark','light','system'));

create table if not exists public.asset_season_stats (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.assets(id) on delete cascade,
  season_label text not null,
  scoring_version text not null,
  points numeric not null default 0,
  rank int check (rank is null or rank > 0),
  source_ref text,
  breakdown jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (asset_id, season_label, scoring_version)
);

create index if not exists asset_season_stats_lookup_idx
  on public.asset_season_stats(season_label, scoring_version, points desc);
create index if not exists asset_season_stats_asset_idx
  on public.asset_season_stats(asset_id);

alter table public.asset_season_stats enable row level security;

revoke all on table public.asset_season_stats from anon;
revoke all on table public.asset_season_stats from authenticated;
grant select on table public.asset_season_stats to authenticated;

drop policy if exists asset_season_stats_authenticated_read on public.asset_season_stats;
create policy asset_season_stats_authenticated_read
on public.asset_season_stats
for select
to authenticated
using (true);

create or replace function public.update_league_appearance(
  p_league_id uuid,
  p_name text,
  p_logo_url text,
  p_primary_color text,
  p_accent_color text,
  p_theme_mode text
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_name text := nullif(btrim(p_name),'');
  v_logo text := nullif(btrim(p_logo_url),'');
  v_primary text := lower(btrim(p_primary_color));
  v_accent text := lower(btrim(p_accent_color));
begin
  if not public.is_league_commissioner(p_league_id) then
    raise exception 'Commissioner permission required';
  end if;

  if v_name is null or char_length(v_name) > 80 then
    raise exception 'League name must be between 1 and 80 characters';
  end if;

  if v_logo is not null
     and (char_length(v_logo) > 2048 or v_logo !~* '^https://') then
    raise exception 'League logo must be an HTTPS URL';
  end if;

  if v_primary !~ '^#[0-9a-f]{6}$' or v_accent !~ '^#[0-9a-f]{6}$' then
    raise exception 'Colours must use six-digit hex format';
  end if;

  if p_theme_mode not in ('dark','light','system') then
    raise exception 'Invalid theme mode';
  end if;

  update public.leagues
  set name=v_name,
      logo_url=v_logo,
      primary_color=v_primary,
      accent_color=v_accent,
      theme_mode=p_theme_mode
  where id=p_league_id;

  insert into public.audit_log(
    league_id,actor_user_id,action_type,entity_type,entity_id,payload
  )
  values(
    p_league_id,(select auth.uid()),'LEAGUE_APPEARANCE_UPDATED','league',p_league_id,
    jsonb_build_object(
      'name',v_name,
      'logo_url',v_logo,
      'primary_color',v_primary,
      'accent_color',v_accent,
      'theme_mode',p_theme_mode
    )
  );
end;
$$;

revoke all on function public.update_league_appearance(uuid,text,text,text,text,text) from public;
revoke all on function public.update_league_appearance(uuid,text,text,text,text,text) from anon;
grant execute on function public.update_league_appearance(uuid,text,text,text,text,text) to authenticated;

alter default privileges for role postgres in schema public
  revoke select, insert, update, delete on tables from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke execute on functions from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke execute on functions from public;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='teams'
  ) then
    alter publication supabase_realtime add table public.teams;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='keeper_selections'
  ) then
    alter publication supabase_realtime add table public.keeper_selections;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='leagues'
  ) then
    alter publication supabase_realtime add table public.leagues;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='asset_season_stats'
  ) then
    alter publication supabase_realtime add table public.asset_season_stats;
  end if;
end
$$;
