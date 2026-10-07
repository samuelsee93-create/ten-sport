-- 033_draft_preferences.sql
-- Private per-manager draft favorites and queue ordering.

create table if not exists public.draft_preferences (
  id uuid primary key default gen_random_uuid(),
  draft_id uuid not null references public.drafts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  asset_id uuid not null references public.assets(id) on delete cascade,
  starred boolean not null default false,
  queue_position integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint draft_preferences_unique unique (draft_id,user_id,asset_id),
  constraint draft_preferences_queue_position_check
    check (queue_position is null or queue_position > 0)
);

create index if not exists draft_preferences_user_draft_queue_idx
  on public.draft_preferences(user_id,draft_id,queue_position)
  where queue_position is not null;

create index if not exists draft_preferences_draft_asset_idx
  on public.draft_preferences(draft_id,asset_id);

alter table public.draft_preferences enable row level security;

drop policy if exists draft_preferences_own_read on public.draft_preferences;
create policy draft_preferences_own_read
on public.draft_preferences
for select
to authenticated
using (
  user_id=(select auth.uid())
  and exists (
    select 1
    from public.drafts d
    join public.seasons s on s.id=d.season_id
    where d.id=draft_preferences.draft_id
      and (
        public.is_league_member(s.league_id)
        or public.is_league_commissioner(s.league_id)
      )
  )
);

drop policy if exists draft_preferences_own_insert on public.draft_preferences;
create policy draft_preferences_own_insert
on public.draft_preferences
for insert
to authenticated
with check (
  user_id=(select auth.uid())
  and exists (
    select 1
    from public.drafts d
    join public.seasons s on s.id=d.season_id
    where d.id=draft_preferences.draft_id
      and (
        public.is_league_member(s.league_id)
        or public.is_league_commissioner(s.league_id)
      )
  )
);

drop policy if exists draft_preferences_own_update on public.draft_preferences;
create policy draft_preferences_own_update
on public.draft_preferences
for update
to authenticated
using (
  user_id=(select auth.uid())
  and exists (
    select 1
    from public.drafts d
    join public.seasons s on s.id=d.season_id
    where d.id=draft_preferences.draft_id
      and (
        public.is_league_member(s.league_id)
        or public.is_league_commissioner(s.league_id)
      )
  )
)
with check (
  user_id=(select auth.uid())
  and exists (
    select 1
    from public.drafts d
    join public.seasons s on s.id=d.season_id
    where d.id=draft_preferences.draft_id
      and (
        public.is_league_member(s.league_id)
        or public.is_league_commissioner(s.league_id)
      )
  )
);

drop policy if exists draft_preferences_own_delete on public.draft_preferences;
create policy draft_preferences_own_delete
on public.draft_preferences
for delete
to authenticated
using (
  user_id=(select auth.uid())
  and exists (
    select 1
    from public.drafts d
    join public.seasons s on s.id=d.season_id
    where d.id=draft_preferences.draft_id
      and (
        public.is_league_member(s.league_id)
        or public.is_league_commissioner(s.league_id)
      )
  )
);

revoke all on table public.draft_preferences from anon;
grant select,insert,update,delete on table public.draft_preferences to authenticated;
