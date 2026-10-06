-- 008_league_history_multi_league_and_roster_slots.sql
-- Ten Sport v0.6: league codes/multi-league support, history/record-book snapshots,
-- waiver transaction journal, dedicated sport roster slots, and draft scheduling.

create schema if not exists private;
revoke all on schema private from public;
revoke all on schema private from anon;
revoke all on schema private from authenticated;

create or replace function private.required_sports()
returns text[]
language sql
immutable
as $$
  select array['NHL','NFL','F1','Golf','NBA','MLB','UCL','NCAA','6 Nations','Tennis']::text[];
$$;

create or replace function private.generate_league_code()
returns text
language plpgsql
security definer
set search_path=public,private
as $$
declare
  v_code text;
begin
  loop
    v_code := upper(substr(encode(gen_random_bytes(4),'hex'),1,8));
    exit when not exists (select 1 from public.leagues where join_code=v_code);
  end loop;
  return v_code;
end;
$$;

alter table public.leagues add column if not exists join_code text;
update public.leagues
set join_code = 'TS' || upper(substr(replace(id::text,'-',''),1,6))
where join_code is null;
alter table public.leagues alter column join_code set not null;
create unique index if not exists leagues_join_code_uidx on public.leagues(join_code);
alter table public.leagues drop constraint if exists leagues_join_code_format;
alter table public.leagues add constraint leagues_join_code_format
  check (join_code ~ '^[A-Z0-9]{8}$');

alter table public.roster_memberships
  add column if not exists roster_slot_type text not null default 'FLEX',
  add column if not exists roster_slot_sport text;
alter table public.roster_memberships drop constraint if exists roster_memberships_slot_shape;
alter table public.roster_memberships add constraint roster_memberships_slot_shape
  check (
    (roster_slot_type='FLEX' and roster_slot_sport is null)
    or
    (roster_slot_type='SPORT' and roster_slot_sport is not null)
  );
alter table public.roster_memberships drop constraint if exists roster_memberships_slot_type;
alter table public.roster_memberships add constraint roster_memberships_slot_type
  check (roster_slot_type in ('SPORT','FLEX'));

create or replace function private.normalize_roster_slots(
  p_season_id uuid,
  p_team_id uuid
) returns void
language plpgsql
security definer
set search_path=public,private
as $$
declare
  v_sport text;
  v_membership_id uuid;
begin
  update public.roster_memberships
  set roster_slot_type='FLEX', roster_slot_sport=null
  where season_id=p_season_id and team_id=p_team_id;

  foreach v_sport in array private.required_sports()
  loop
    select rm.id into v_membership_id
    from public.roster_memberships rm
    join public.assets a on a.id=rm.asset_id
    where rm.season_id=p_season_id
      and rm.team_id=p_team_id
      and a.sport=v_sport
    order by rm.acquired_at,rm.id
    limit 1;

    if v_membership_id is not null then
      update public.roster_memberships
      set roster_slot_type='SPORT', roster_slot_sport=v_sport
      where id=v_membership_id;
    end if;
    v_membership_id := null;
  end loop;
end;
$$;

do $$
declare r record;
begin
  for r in select distinct season_id,team_id from public.roster_memberships
  loop
    perform private.normalize_roster_slots(r.season_id,r.team_id);
  end loop;
end
$$;

create unique index if not exists roster_one_dedicated_sport_idx
  on public.roster_memberships(season_id,team_id,roster_slot_sport)
  where roster_slot_type='SPORT';

create table if not exists public.waiver_transactions (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.seasons(id) on delete cascade,
  team_id uuid not null references public.teams(id),
  added_asset_id uuid not null references public.assets(id),
  dropped_asset_id uuid references public.assets(id),
  transaction_type text not null default 'WAIVER'
    check (transaction_type in ('WAIVER','FREE_AGENT')),
  created_at timestamptz not null default now()
);

create index if not exists waiver_transactions_season_idx
  on public.waiver_transactions(season_id,created_at desc);
create index if not exists waiver_transactions_team_idx
  on public.waiver_transactions(team_id);

alter table public.waiver_transactions enable row level security;
revoke all on table public.waiver_transactions from anon;
revoke all on table public.waiver_transactions from authenticated;
grant select on table public.waiver_transactions to authenticated;
drop policy if exists waiver_member_read on public.waiver_transactions;
create policy waiver_member_read
on public.waiver_transactions for select to authenticated
using (
  exists (
    select 1 from public.seasons s
    where s.id=season_id
      and (public.is_league_member(s.league_id) or public.is_league_commissioner(s.league_id))
  )
);

create table if not exists public.season_team_results (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.seasons(id) on delete cascade,
  team_id uuid not null references public.teams(id),
  team_name text not null,
  manager_name text not null,
  final_rank int not null check (final_rank > 0),
  total_points numeric not null default 0,
  finalized_at timestamptz not null default now(),
  unique(season_id,team_id)
);

create table if not exists public.season_sport_results (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.seasons(id) on delete cascade,
  team_id uuid not null references public.teams(id),
  sport text not null,
  points numeric not null default 0,
  finalized_at timestamptz not null default now(),
  unique(season_id,team_id,sport)
);

create index if not exists season_team_results_season_idx
  on public.season_team_results(season_id,final_rank);
create index if not exists season_sport_results_season_idx
  on public.season_sport_results(season_id,sport,points);

alter table public.season_team_results enable row level security;
alter table public.season_sport_results enable row level security;
revoke all on table public.season_team_results from anon;
revoke all on table public.season_sport_results from anon;
revoke all on table public.season_team_results from authenticated;
revoke all on table public.season_sport_results from authenticated;
grant select on table public.season_team_results to authenticated;
grant select on table public.season_sport_results to authenticated;

drop policy if exists season_team_results_member_read on public.season_team_results;
create policy season_team_results_member_read
on public.season_team_results for select to authenticated
using (
  exists (
    select 1 from public.seasons s
    where s.id=season_id
      and (public.is_league_member(s.league_id) or public.is_league_commissioner(s.league_id))
  )
);

drop policy if exists season_sport_results_member_read on public.season_sport_results;
create policy season_sport_results_member_read
on public.season_sport_results for select to authenticated
using (
  exists (
    select 1 from public.seasons s
    where s.id=season_id
      and (public.is_league_member(s.league_id) or public.is_league_commissioner(s.league_id))
  )
);

create or replace function public.create_league(
  p_name text,
  p_team_name text,
  p_season_label text default '2026-27',
  p_scoring_version text default 'v1.0'
) returns jsonb
language plpgsql
security definer
set search_path=public,private
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_league_id uuid;
  v_team_id uuid;
  v_season_id uuid;
  v_draft_id uuid;
  v_code text;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if not exists (select 1 from public.profiles where id=v_user_id) then
    raise exception 'Profile not ready yet';
  end if;
  if nullif(btrim(p_name),'') is null then raise exception 'League name is required'; end if;
  if nullif(btrim(p_team_name),'') is null then raise exception 'Team name is required'; end if;

  v_code := private.generate_league_code();

  insert into public.leagues(
    name,commissioner_user_id,roster_size,active_slots,bench_slots,keeper_slots,join_code
  ) values (
    btrim(p_name),v_user_id,20,15,5,3,v_code
  ) returning id into v_league_id;

  insert into public.league_memberships(league_id,user_id,role,status)
  values(v_league_id,v_user_id,'COMMISSIONER','ACTIVE');

  insert into public.teams(league_id,owner_user_id,name)
  values(v_league_id,v_user_id,btrim(p_team_name))
  returning id into v_team_id;

  insert into public.seasons(league_id,label,scoring_version,status)
  values(v_league_id,coalesce(nullif(btrim(p_season_label),''),'2026-27'),
         coalesce(nullif(btrim(p_scoring_version),''),'v1.0'),'SETUP')
  returning id into v_season_id;

  insert into public.drafts(season_id,status,pick_timer_seconds,rounds,current_overall_pick)
  values(v_season_id,'SCHEDULED',90,17,1)
  returning id into v_draft_id;

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(v_league_id,v_user_id,'LEAGUE_CREATED','league',v_league_id,
    jsonb_build_object('team_id',v_team_id,'season_id',v_season_id,'draft_id',v_draft_id));

  return jsonb_build_object(
    'league_id',v_league_id,'team_id',v_team_id,'season_id',v_season_id,
    'draft_id',v_draft_id,'join_code',v_code
  );
end;
$$;

revoke all on function public.create_league(text,text,text,text) from public;
revoke all on function public.create_league(text,text,text,text) from anon;
grant execute on function public.create_league(text,text,text,text) to authenticated;

create or replace function public.join_league(
  p_code text,
  p_team_name text
) returns jsonb
language plpgsql
security definer
set search_path=public,private
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_league public.leagues%rowtype;
  v_team_id uuid;
  v_season_id uuid;
  v_draft public.drafts%rowtype;
  v_slot int;
  v_round int;
  v_year int;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if nullif(btrim(p_team_name),'') is null then raise exception 'Team name is required'; end if;

  select * into v_league
  from public.leagues
  where join_code=upper(btrim(p_code))
  for update;

  if v_league.id is null then raise exception 'League code not found'; end if;

  if exists (
    select 1 from public.league_memberships
    where league_id=v_league.id and user_id=v_user_id and status='ACTIVE'
  ) then
    raise exception 'You are already in this league';
  end if;

  if exists (
    select 1 from public.league_memberships
    where league_id=v_league.id and user_id=v_user_id
  ) then
    update public.league_memberships
    set status='ACTIVE',role='MANAGER'
    where league_id=v_league.id and user_id=v_user_id;
  else
    insert into public.league_memberships(league_id,user_id,role,status)
    values(v_league.id,v_user_id,'MANAGER','ACTIVE');
  end if;

  insert into public.teams(league_id,owner_user_id,name)
  values(v_league.id,v_user_id,btrim(p_team_name))
  on conflict (league_id,owner_user_id)
  do update set name=excluded.name
  returning id into v_team_id;

  select id into v_season_id
  from public.seasons
  where league_id=v_league.id and status in ('SETUP','ACTIVE')
  order by label desc
  limit 1;

  if v_season_id is not null then
    select * into v_draft from public.drafts where season_id=v_season_id;
    if v_draft.id is not null and v_draft.scheduled_at is not null then
      v_year := extract(year from v_draft.scheduled_at)::int;
      select count(*) into v_slot from public.teams where league_id=v_league.id;
      for v_round in 1..v_draft.rounds loop
        insert into public.draft_picks(
          league_id,draft_year,round,slot,original_team_id,current_team_id
        ) values (
          v_league.id,v_year,v_round,v_slot,v_team_id,v_team_id
        ) on conflict (league_id,draft_year,round,original_team_id) do nothing;
      end loop;
    end if;
  end if;

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(v_league.id,v_user_id,'LEAGUE_JOINED','team',v_team_id,'{}'::jsonb);

  return jsonb_build_object('league_id',v_league.id,'team_id',v_team_id);
end;
$$;

revoke all on function public.join_league(text,text) from public;
revoke all on function public.join_league(text,text) from anon;
grant execute on function public.join_league(text,text) to authenticated;

create or replace function public.set_draft_schedule(
  p_draft_id uuid,
  p_scheduled_at timestamptz
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_league_id uuid;
  v_rounds int;
  v_year int;
  v_team record;
  v_round int;
begin
  select s.league_id,d.rounds into v_league_id,v_rounds
  from public.drafts d
  join public.seasons s on s.id=d.season_id
  where d.id=p_draft_id
  for update;

  if v_league_id is null then raise exception 'Draft not found'; end if;
  if not public.is_league_commissioner(v_league_id) then
    raise exception 'Commissioner permission required';
  end if;
  if p_scheduled_at is null then raise exception 'Draft date and time are required'; end if;

  update public.drafts set scheduled_at=p_scheduled_at where id=p_draft_id;
  v_year := extract(year from p_scheduled_at)::int;

  for v_team in
    select id,row_number() over(order by created_at,id)::int as slot
    from public.teams
    where league_id=v_league_id
    order by created_at,id
  loop
    for v_round in 1..v_rounds loop
      insert into public.draft_picks(
        league_id,draft_year,round,slot,original_team_id,current_team_id
      ) values (
        v_league_id,v_year,v_round,v_team.slot,v_team.id,v_team.id
      ) on conflict (league_id,draft_year,round,original_team_id)
      do update set slot=excluded.slot;
    end loop;
  end loop;

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(v_league_id,(select auth.uid()),'DRAFT_SCHEDULE_CHANGED','draft',p_draft_id,
         jsonb_build_object('scheduled_at',p_scheduled_at));
end;
$$;

revoke all on function public.set_draft_schedule(uuid,timestamptz) from public;
revoke all on function public.set_draft_schedule(uuid,timestamptz) from anon;
grant execute on function public.set_draft_schedule(uuid,timestamptz) to authenticated;

create or replace function public.finalize_season(p_season_id uuid)
returns void
language plpgsql
security definer
set search_path=public,private
as $$
declare
  v_league_id uuid;
begin
  select league_id into v_league_id from public.seasons where id=p_season_id for update;
  if v_league_id is null then raise exception 'Season not found'; end if;
  if not public.is_league_commissioner(v_league_id) then
    raise exception 'Commissioner permission required';
  end if;

  delete from public.season_sport_results where season_id=p_season_id;
  delete from public.season_team_results where season_id=p_season_id;

  insert into public.season_team_results(
    season_id,team_id,team_name,manager_name,final_rank,total_points,finalized_at
  )
  with totals as (
    select
      t.id as team_id,
      t.name as team_name,
      coalesce(p.display_name,'Manager') as manager_name,
      coalesce(sum(case when se.id is not null then mpt.counted_points else 0 end),0)::numeric as total_points
    from public.teams t
    left join public.profiles p on p.id=t.owner_user_id
    left join public.manager_point_transactions mpt on mpt.team_id=t.id
    left join public.point_transactions pt on pt.id=mpt.point_transaction_id
    left join public.scoring_events se on se.id=pt.scoring_event_id and se.season_id=p_season_id
    where t.league_id=v_league_id
    group by t.id,t.name,p.display_name
  ),
  ranked as (
    select *,rank() over(order by total_points desc)::int as final_rank
    from totals
  )
  select p_season_id,team_id,team_name,manager_name,final_rank,total_points,now()
  from ranked;

  insert into public.season_sport_results(
    season_id,team_id,sport,points,finalized_at
  )
  select
    p_season_id,
    t.id,
    sport.sport,
    coalesce(sum(case when se.sport=sport.sport then mpt.counted_points else 0 end),0)::numeric,
    now()
  from public.teams t
  cross join unnest(private.required_sports()) as sport(sport)
  left join public.manager_point_transactions mpt on mpt.team_id=t.id
  left join public.point_transactions pt on pt.id=mpt.point_transaction_id
  left join public.scoring_events se on se.id=pt.scoring_event_id and se.season_id=p_season_id
  where t.league_id=v_league_id
  group by t.id,sport.sport;

  update public.seasons set status='COMPLETE' where id=p_season_id;

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(v_league_id,(select auth.uid()),'SEASON_FINALIZED','season',p_season_id,'{}'::jsonb);
end;
$$;

revoke all on function public.finalize_season(uuid) from public;
revoke all on function public.finalize_season(uuid) from anon;
grant execute on function public.finalize_season(uuid) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='waiver_transactions'
  ) then
    alter publication supabase_realtime add table public.waiver_transactions;
  end if;
end
$$;
