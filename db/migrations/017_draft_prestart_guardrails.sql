-- 017_draft_prestart_guardrails.sql
-- Draft date/order are mutable only before selections begin. Draft order is realtime.

create or replace function public.set_draft_order(
  p_draft_id uuid,
  p_team_ids uuid[]
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_league_id uuid;
  v_status text;
  v_team_count int;
  v_input_count int;
  v_distinct_count int;
  v_draft_year int;
begin
  select s.league_id,d.status,
         case when d.scheduled_at is null then null else extract(year from d.scheduled_at)::int end
  into v_league_id,v_status,v_draft_year
  from public.drafts d
  join public.seasons s on s.id=d.season_id
  where d.id=p_draft_id
  for update;

  if v_league_id is null then raise exception 'Draft not found'; end if;
  if not public.is_league_commissioner(v_league_id) then raise exception 'Commissioner permission required'; end if;
  if v_status in ('LIVE','PAUSED','COMPLETE')
     or exists (select 1 from public.draft_selections where draft_id=p_draft_id) then
    raise exception 'Draft order cannot be changed after selections begin';
  end if;

  select count(*) into v_team_count from public.teams where league_id=v_league_id;
  v_input_count := coalesce(array_length(p_team_ids,1),0);
  select count(distinct x) into v_distinct_count from unnest(coalesce(p_team_ids,'{}'::uuid[])) x;

  if v_input_count<>v_team_count or v_distinct_count<>v_team_count then
    raise exception 'Draft order must contain every league team exactly once';
  end if;

  if exists (
    select 1 from unnest(p_team_ids) x
    where not exists (
      select 1 from public.teams t where t.id=x and t.league_id=v_league_id
    )
  ) then raise exception 'Draft order contains a team outside this league'; end if;

  delete from public.draft_order where draft_id=p_draft_id;

  insert into public.draft_order(draft_id,team_id,slot)
  select p_draft_id,x.team_id,x.ordinality::int
  from unnest(p_team_ids) with ordinality as x(team_id,ordinality);

  update public.drafts set order_method='MANUAL' where id=p_draft_id;

  if v_draft_year is not null then
    update public.draft_picks dp
    set slot=dord.slot
    from public.draft_order dord
    where dord.draft_id=p_draft_id
      and dord.team_id=dp.original_team_id
      and dp.league_id=v_league_id
      and dp.draft_year=v_draft_year;
  end if;

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(v_league_id,(select auth.uid()),'DRAFT_ORDER_SET','draft',p_draft_id,
         jsonb_build_object('team_ids',p_team_ids,'method','MANUAL'));
end;
$$;

create or replace function public.randomize_draft_order(
  p_draft_id uuid
) returns uuid[]
language plpgsql
security definer
set search_path=public
as $$
declare
  v_league_id uuid;
  v_status text;
  v_order uuid[];
  v_year int;
begin
  select s.league_id,d.status,
         case when d.scheduled_at is null then null else extract(year from d.scheduled_at)::int end
  into v_league_id,v_status,v_year
  from public.drafts d
  join public.seasons s on s.id=d.season_id
  where d.id=p_draft_id
  for update;

  if v_league_id is null then raise exception 'Draft not found'; end if;
  if not public.is_league_commissioner(v_league_id) then raise exception 'Commissioner permission required'; end if;
  if v_status in ('LIVE','PAUSED','COMPLETE')
     or exists (select 1 from public.draft_selections where draft_id=p_draft_id) then
    raise exception 'Draft order cannot be changed after selections begin';
  end if;

  select array_agg(id order by random()) into v_order
  from public.teams where league_id=v_league_id;

  delete from public.draft_order where draft_id=p_draft_id;

  insert into public.draft_order(draft_id,team_id,slot)
  select p_draft_id,x.team_id,x.ordinality::int
  from unnest(v_order) with ordinality as x(team_id,ordinality);

  update public.drafts set order_method='RANDOMIZED' where id=p_draft_id;

  if v_year is not null then
    update public.draft_picks dp
    set slot=dord.slot
    from public.draft_order dord
    where dord.draft_id=p_draft_id
      and dord.team_id=dp.original_team_id
      and dp.league_id=v_league_id
      and dp.draft_year=v_year;
  end if;

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(v_league_id,(select auth.uid()),'DRAFT_ORDER_SET','draft',p_draft_id,
         jsonb_build_object('team_ids',v_order,'method','RANDOMIZED'));

  return v_order;
end;
$$;

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
  v_status text;
  v_old_scheduled_at timestamptz;
  v_year int;
  v_team record;
  v_round int;
begin
  select s.league_id,d.status,d.scheduled_at
  into v_league_id,v_status,v_old_scheduled_at
  from public.drafts d
  join public.seasons s on s.id=d.season_id
  where d.id=p_draft_id
  for update;

  if v_league_id is null then raise exception 'Draft not found'; end if;
  if not public.is_league_commissioner(v_league_id) then raise exception 'Commissioner permission required'; end if;
  if p_scheduled_at is null then raise exception 'Draft date and time are required'; end if;
  if v_status in ('LIVE','PAUSED','COMPLETE')
     or exists (select 1 from public.draft_selections where draft_id=p_draft_id) then
    raise exception 'Draft date cannot be changed after selections begin';
  end if;

  if v_old_scheduled_at is not null
     and extract(year from v_old_scheduled_at)::int<>extract(year from p_scheduled_at)::int
     and exists (
       select 1
       from public.keeper_selections ks
       join public.drafts d on d.season_id=ks.season_id
       where d.id=p_draft_id
     ) then
    raise exception 'Remove keeper selections before moving the draft into a different calendar year';
  end if;

  update public.drafts set scheduled_at=p_scheduled_at,rounds=20 where id=p_draft_id;
  v_year := extract(year from p_scheduled_at)::int;

  for v_team in
    select t.id,dord.slot
    from public.teams t
    left join public.draft_order dord on dord.draft_id=p_draft_id and dord.team_id=t.id
    where t.league_id=v_league_id
  loop
    for v_round in 1..20 loop
      insert into public.draft_picks(league_id,draft_year,round,slot,original_team_id,current_team_id)
      values(v_league_id,v_year,v_round,v_team.slot,v_team.id,v_team.id)
      on conflict (league_id,draft_year,round,original_team_id)
      do update set slot=excluded.slot;
    end loop;
  end loop;

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(v_league_id,(select auth.uid()),'DRAFT_SCHEDULE_CHANGED','draft',p_draft_id,
         jsonb_build_object('scheduled_at',p_scheduled_at,'rounds',20));
end;
$$;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='draft_order'
  ) then
    alter publication supabase_realtime add table public.draft_order;
  end if;
end
$$;

revoke all on function public.set_draft_order(uuid,uuid[]) from public;
revoke all on function public.set_draft_order(uuid,uuid[]) from anon;
grant execute on function public.set_draft_order(uuid,uuid[]) to authenticated;
revoke all on function public.randomize_draft_order(uuid) from public;
revoke all on function public.randomize_draft_order(uuid) from anon;
grant execute on function public.randomize_draft_order(uuid) to authenticated;
revoke all on function public.set_draft_schedule(uuid,timestamptz) from public;
revoke all on function public.set_draft_schedule(uuid,timestamptz) from anon;
grant execute on function public.set_draft_schedule(uuid,timestamptz) to authenticated;
