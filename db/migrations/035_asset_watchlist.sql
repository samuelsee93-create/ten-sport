-- 035_asset_watchlist.sql
-- Private per-manager/per-league asset watch list for waiver targets.

create table if not exists public.asset_watchlist (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  asset_id uuid not null references public.assets(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint asset_watchlist_unique unique (league_id,user_id,asset_id)
);

create index if not exists asset_watchlist_user_league_idx
  on public.asset_watchlist(user_id,league_id);
create index if not exists asset_watchlist_asset_idx
  on public.asset_watchlist(asset_id);

alter table public.asset_watchlist enable row level security;

revoke all on table public.asset_watchlist from anon;
revoke all on table public.asset_watchlist from authenticated;
grant select,insert,delete on table public.asset_watchlist to authenticated;

drop policy if exists asset_watchlist_own_read on public.asset_watchlist;
create policy asset_watchlist_own_read
on public.asset_watchlist
for select
to authenticated
using (
  user_id=(select auth.uid())
  and league_id in (
    select lm.league_id
    from public.league_memberships lm
    where lm.user_id=(select auth.uid()) and lm.status='ACTIVE'
  )
);

drop policy if exists asset_watchlist_own_insert on public.asset_watchlist;
create policy asset_watchlist_own_insert
on public.asset_watchlist
for insert
to authenticated
with check (
  user_id=(select auth.uid())
  and league_id in (
    select lm.league_id
    from public.league_memberships lm
    where lm.user_id=(select auth.uid()) and lm.status='ACTIVE'
  )
);

drop policy if exists asset_watchlist_own_delete on public.asset_watchlist;
create policy asset_watchlist_own_delete
on public.asset_watchlist
for delete
to authenticated
using (
  user_id=(select auth.uid())
  and league_id in (
    select lm.league_id
    from public.league_memberships lm
    where lm.user_id=(select auth.uid()) and lm.status='ACTIVE'
  )
);
