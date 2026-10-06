-- 001_initial.sql
-- Ten Sport v0.4 hosted schema for Supabase/Postgres.

create extension if not exists pgcrypto;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  avatar_url text,
  created_at timestamptz not null default now()
);

create table public.leagues (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  commissioner_user_id uuid not null references public.profiles(id),
  roster_size int not null default 20 check (roster_size = 20),
  active_slots int not null default 15 check (active_slots = 15),
  bench_slots int not null default 5 check (bench_slots = 5),
  keeper_slots int not null default 3 check (keeper_slots = 3),
  created_at timestamptz not null default now()
);

create table public.league_memberships (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null check (role in ('COMMISSIONER','MANAGER')),
  status text not null default 'ACTIVE' check (status in ('INVITED','ACTIVE','LEFT','REMOVED')),
  created_at timestamptz not null default now(),
  unique (league_id,user_id)
);

create table public.seasons (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  label text not null,
  scoring_version text not null,
  keeper_deadline timestamptz,
  trade_deadline timestamptz,
  status text not null default 'SETUP' check (status in ('SETUP','ACTIVE','COMPLETE')),
  unique (league_id,label)
);

create table public.teams (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  owner_user_id uuid not null references public.profiles(id),
  name text not null,
  logo_url text,
  created_at timestamptz not null default now(),
  unique (league_id,owner_user_id)
);

create table public.assets (
  id uuid primary key default gen_random_uuid(),
  sport text not null,
  external_key text,
  name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (sport,external_key)
);

create table public.roster_memberships (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.seasons(id) on delete cascade,
  team_id uuid not null references public.teams(id),
  asset_id uuid not null references public.assets(id),
  lineup_status text not null check (lineup_status in ('ACTIVE','BENCH')),
  acquired_at timestamptz not null default now(),
  released_at timestamptz,
  unique (season_id,asset_id)
);

create table public.lineup_events (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.seasons(id) on delete cascade,
  team_id uuid not null references public.teams(id),
  asset_id uuid not null references public.assets(id),
  from_status text check (from_status in ('ACTIVE','BENCH')),
  to_status text not null check (to_status in ('ACTIVE','BENCH')),
  created_at timestamptz not null default now()
);

create table public.scoring_events (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.seasons(id) on delete cascade,
  sport text not null,
  event_type text not null,
  label text not null,
  locks_at timestamptz not null,
  occurred_at timestamptz,
  source_ref text,
  created_at timestamptz not null default now()
);

create table public.scoring_event_assets (
  scoring_event_id uuid not null references public.scoring_events(id) on delete cascade,
  asset_id uuid not null references public.assets(id) on delete cascade,
  primary key (scoring_event_id,asset_id)
);

create table public.point_transactions (
  id uuid primary key default gen_random_uuid(),
  scoring_event_id uuid not null references public.scoring_events(id) on delete cascade,
  asset_id uuid not null references public.assets(id),
  points numeric not null,
  rule_key text not null,
  description text not null,
  created_at timestamptz not null default now(),
  unique (scoring_event_id,asset_id,rule_key)
);

create table public.manager_point_transactions (
  id uuid primary key default gen_random_uuid(),
  point_transaction_id uuid not null references public.point_transactions(id) on delete cascade,
  team_id uuid not null references public.teams(id),
  counted_points numeric not null,
  owned_at_lock boolean not null,
  active_at_lock boolean not null,
  created_at timestamptz not null default now(),
  unique (point_transaction_id,team_id)
);

create table public.keeper_selections (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.seasons(id) on delete cascade,
  team_id uuid not null references public.teams(id),
  asset_id uuid not null references public.assets(id),
  locked_at timestamptz,
  created_at timestamptz not null default now(),
  unique (season_id,team_id,asset_id)
);

create table public.trades (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.seasons(id) on delete cascade,
  proposer_team_id uuid not null references public.teams(id),
  recipient_team_id uuid not null references public.teams(id),
  status text not null default 'PENDING' check (status in ('PENDING','ACCEPTED','DECLINED','COUNTERED','REVERSED')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create table public.draft_picks (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  draft_year int not null,
  round int not null,
  slot int,
  original_team_id uuid not null references public.teams(id),
  current_team_id uuid not null references public.teams(id),
  unique (league_id,draft_year,round,original_team_id)
);

create table public.trade_items (
  id uuid primary key default gen_random_uuid(),
  trade_id uuid not null references public.trades(id) on delete cascade,
  side text not null check (side in ('PROPOSER','RECIPIENT')),
  item_type text not null check (item_type in ('ASSET','DRAFT_PICK')),
  asset_id uuid references public.assets(id),
  draft_pick_id uuid references public.draft_picks(id),
  check (
    (item_type='ASSET' and asset_id is not null and draft_pick_id is null) or
    (item_type='DRAFT_PICK' and draft_pick_id is not null and asset_id is null)
  )
);

create table public.drafts (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null unique references public.seasons(id) on delete cascade,
  scheduled_at timestamptz,
  status text not null default 'SCHEDULED' check (status in ('SCHEDULED','LOBBY','LIVE','PAUSED','COMPLETE')),
  pick_timer_seconds int not null default 90,
  rounds int not null default 17,
  current_overall_pick int not null default 1
);

create table public.draft_selections (
  id uuid primary key default gen_random_uuid(),
  draft_id uuid not null references public.drafts(id) on delete cascade,
  overall_pick int not null,
  round int not null,
  team_id uuid not null references public.teams(id),
  asset_id uuid not null references public.assets(id),
  draft_pick_id uuid references public.draft_picks(id),
  selected_at timestamptz not null default now(),
  unique (draft_id,overall_pick),
  unique (draft_id,asset_id)
);

create table public.audit_log (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  actor_user_id uuid references public.profiles(id),
  action_type text not null,
  entity_type text not null,
  entity_id uuid,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index roster_team_season_idx on public.roster_memberships(team_id,season_id);
create index point_asset_idx on public.point_transactions(asset_id);
create index manager_points_team_idx on public.manager_point_transactions(team_id);
create index trades_teams_idx on public.trades(proposer_team_id,recipient_team_id);
create index draft_picks_owner_idx on public.draft_picks(current_team_id);
create index scoring_event_lock_idx on public.scoring_events(locks_at);

alter table public.profiles enable row level security;
alter table public.leagues enable row level security;
alter table public.league_memberships enable row level security;
alter table public.seasons enable row level security;
alter table public.teams enable row level security;
alter table public.assets enable row level security;
alter table public.roster_memberships enable row level security;
alter table public.lineup_events enable row level security;
alter table public.scoring_events enable row level security;
alter table public.scoring_event_assets enable row level security;
alter table public.point_transactions enable row level security;
alter table public.manager_point_transactions enable row level security;
alter table public.keeper_selections enable row level security;
alter table public.trades enable row level security;
alter table public.trade_items enable row level security;
alter table public.draft_picks enable row level security;
alter table public.drafts enable row level security;
alter table public.draft_selections enable row level security;
alter table public.audit_log enable row level security;

create or replace function public.is_league_member(target_league uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists (
    select 1 from public.league_memberships
    where league_id=target_league and user_id=auth.uid() and status='ACTIVE'
  );
$$;

create or replace function public.is_league_commissioner(target_league uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists (
    select 1 from public.leagues
    where id=target_league and commissioner_user_id=auth.uid()
  );
$$;

create policy profiles_self_read on public.profiles for select using (id=auth.uid());
create policy profiles_self_update on public.profiles for update using (id=auth.uid());

create policy leagues_member_read on public.leagues for select using (public.is_league_member(id) or commissioner_user_id=auth.uid());
create policy memberships_member_read on public.league_memberships for select using (public.is_league_member(league_id) or public.is_league_commissioner(league_id));
create policy seasons_member_read on public.seasons for select using (public.is_league_member(league_id) or public.is_league_commissioner(league_id));
create policy teams_member_read on public.teams for select using (public.is_league_member(league_id) or public.is_league_commissioner(league_id));
create policy assets_authenticated_read on public.assets for select to authenticated using (true);

create policy roster_member_read on public.roster_memberships for select using (
  exists (select 1 from public.teams t where t.id=team_id and (public.is_league_member(t.league_id) or public.is_league_commissioner(t.league_id)))
);
create policy lineup_member_read on public.lineup_events for select using (
  exists (select 1 from public.teams t where t.id=team_id and (public.is_league_member(t.league_id) or public.is_league_commissioner(t.league_id)))
);
create policy scoring_member_read on public.scoring_events for select using (
  exists (select 1 from public.seasons s where s.id=season_id and (public.is_league_member(s.league_id) or public.is_league_commissioner(s.league_id)))
);
create policy scoring_assets_member_read on public.scoring_event_assets for select using (
  exists (
    select 1 from public.scoring_events e join public.seasons s on s.id=e.season_id
    where e.id=scoring_event_id and (public.is_league_member(s.league_id) or public.is_league_commissioner(s.league_id))
  )
);
create policy point_member_read on public.point_transactions for select using (
  exists (
    select 1 from public.scoring_events e join public.seasons s on s.id=e.season_id
    where e.id=scoring_event_id and (public.is_league_member(s.league_id) or public.is_league_commissioner(s.league_id))
  )
);
create policy manager_point_member_read on public.manager_point_transactions for select using (
  exists (select 1 from public.teams t where t.id=team_id and (public.is_league_member(t.league_id) or public.is_league_commissioner(t.league_id)))
);
create policy keeper_member_read on public.keeper_selections for select using (
  exists (select 1 from public.teams t where t.id=team_id and (public.is_league_member(t.league_id) or public.is_league_commissioner(t.league_id)))
);
create policy trades_member_read on public.trades for select using (
  exists (
    select 1 from public.teams t
    where t.id in (proposer_team_id,recipient_team_id)
      and (public.is_league_member(t.league_id) or public.is_league_commissioner(t.league_id))
  )
);
create policy trade_items_member_read on public.trade_items for select using (
  exists (
    select 1 from public.trades tr
    join public.teams t on t.id=tr.proposer_team_id
    where tr.id=trade_id and (public.is_league_member(t.league_id) or public.is_league_commissioner(t.league_id))
  )
);
create policy picks_member_read on public.draft_picks for select using (public.is_league_member(league_id) or public.is_league_commissioner(league_id));
create policy drafts_member_read on public.drafts for select using (
  exists (select 1 from public.seasons s where s.id=season_id and (public.is_league_member(s.league_id) or public.is_league_commissioner(s.league_id)))
);
create policy selections_member_read on public.draft_selections for select using (
  exists (
    select 1 from public.drafts d join public.seasons s on s.id=d.season_id
    where d.id=draft_id and (public.is_league_member(s.league_id) or public.is_league_commissioner(s.league_id))
  )
);
create policy audit_member_read on public.audit_log for select using (public.is_league_member(league_id) or public.is_league_commissioner(league_id));

alter publication supabase_realtime add table public.drafts;
alter publication supabase_realtime add table public.draft_selections;
alter publication supabase_realtime add table public.trades;
alter publication supabase_realtime add table public.roster_memberships;
