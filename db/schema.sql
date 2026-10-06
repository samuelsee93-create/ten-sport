-- Ten Sport v0.3 logical Postgres schema.
-- Designed for a hosted Postgres/Auth/Realtime provider in the next milestone.

create extension if not exists pgcrypto;

create table profiles (
  id uuid primary key,
  display_name text not null,
  avatar_url text,
  created_at timestamptz not null default now()
);

create table leagues (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  commissioner_user_id uuid not null references profiles(id),
  roster_size int not null default 20 check (roster_size = 20),
  active_slots int not null default 15 check (active_slots = 15),
  bench_slots int not null default 5 check (bench_slots = 5),
  keeper_slots int not null default 3 check (keeper_slots = 3),
  created_at timestamptz not null default now()
);

create table seasons (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references leagues(id) on delete cascade,
  label text not null,
  scoring_version text not null,
  keeper_deadline timestamptz,
  trade_deadline timestamptz,
  status text not null check (status in ('SETUP','ACTIVE','COMPLETE')),
  unique (league_id,label)
);

create table teams (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references leagues(id) on delete cascade,
  owner_user_id uuid not null references profiles(id),
  name text not null,
  logo_url text,
  unique (league_id,owner_user_id)
);

create table assets (
  id uuid primary key default gen_random_uuid(),
  sport text not null,
  external_key text,
  name text not null,
  active boolean not null default true,
  unique (sport,external_key)
);

create table roster_memberships (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references seasons(id) on delete cascade,
  team_id uuid not null references teams(id),
  asset_id uuid not null references assets(id),
  lineup_status text not null check (lineup_status in ('ACTIVE','BENCH')),
  acquired_at timestamptz not null default now(),
  released_at timestamptz,
  unique (season_id,asset_id)
);

create table lineup_events (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references seasons(id) on delete cascade,
  team_id uuid not null references teams(id),
  asset_id uuid not null references assets(id),
  from_status text check (from_status in ('ACTIVE','BENCH')),
  to_status text not null check (to_status in ('ACTIVE','BENCH')),
  created_at timestamptz not null default now()
);

create table scoring_events (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references seasons(id) on delete cascade,
  sport text not null,
  event_type text not null,
  label text not null,
  locks_at timestamptz,
  occurred_at timestamptz not null,
  source_ref text
);

create table point_transactions (
  id uuid primary key default gen_random_uuid(),
  scoring_event_id uuid not null references scoring_events(id) on delete cascade,
  asset_id uuid not null references assets(id),
  points numeric not null,
  rule_key text not null,
  description text not null,
  unique (scoring_event_id,asset_id,rule_key)
);

create table manager_point_transactions (
  id uuid primary key default gen_random_uuid(),
  point_transaction_id uuid not null references point_transactions(id) on delete cascade,
  team_id uuid not null references teams(id),
  counted_points numeric not null,
  owned_at_lock boolean not null,
  active_at_lock boolean not null,
  unique (point_transaction_id,team_id)
);

create table keeper_selections (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references seasons(id) on delete cascade,
  team_id uuid not null references teams(id),
  asset_id uuid not null references assets(id),
  locked_at timestamptz,
  unique (season_id,team_id,asset_id)
);

create table trades (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references seasons(id) on delete cascade,
  proposer_team_id uuid not null references teams(id),
  recipient_team_id uuid not null references teams(id),
  status text not null check (status in ('PENDING','ACCEPTED','DECLINED','COUNTERED','REVERSED')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create table draft_picks (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references leagues(id) on delete cascade,
  draft_year int not null,
  round int not null,
  slot int,
  original_team_id uuid not null references teams(id),
  current_team_id uuid not null references teams(id),
  unique (league_id,draft_year,round,original_team_id)
);

create table trade_items (
  id uuid primary key default gen_random_uuid(),
  trade_id uuid not null references trades(id) on delete cascade,
  side text not null check (side in ('PROPOSER','RECIPIENT')),
  item_type text not null check (item_type in ('ASSET','DRAFT_PICK')),
  asset_id uuid references assets(id),
  draft_pick_id uuid references draft_picks(id),
  check ((item_type='ASSET' and asset_id is not null and draft_pick_id is null) or (item_type='DRAFT_PICK' and draft_pick_id is not null and asset_id is null))
);

create table drafts (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null unique references seasons(id) on delete cascade,
  scheduled_at timestamptz,
  status text not null check (status in ('SCHEDULED','LOBBY','LIVE','PAUSED','COMPLETE')),
  pick_timer_seconds int not null default 90,
  rounds int not null default 17,
  current_overall_pick int not null default 1
);

create table draft_selections (
  id uuid primary key default gen_random_uuid(),
  draft_id uuid not null references drafts(id) on delete cascade,
  overall_pick int not null,
  round int not null,
  team_id uuid not null references teams(id),
  asset_id uuid not null references assets(id),
  draft_pick_id uuid references draft_picks(id),
  selected_at timestamptz not null default now(),
  unique (draft_id,overall_pick),
  unique (draft_id,asset_id)
);

create table audit_log (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references leagues(id) on delete cascade,
  actor_user_id uuid references profiles(id),
  action_type text not null,
  entity_type text not null,
  entity_id uuid,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Production implementation note:
-- lineup changes, accepted trades and draft selections should be executed through
-- database transactions/RPC functions so concurrent clients cannot produce double
-- ownership, overfilled rosters, or duplicate draft selections.
