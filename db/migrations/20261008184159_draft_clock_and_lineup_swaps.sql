-- One authoritative clock per draft. A pause freezes the remaining time.
alter table public.drafts add column if not exists pick_deadline_at timestamptz;
alter table public.drafts add column if not exists paused_seconds integer;
alter table public.draft_selections add column if not exists auto_picked boolean not null default false;

create or replace function private.update_draft_clock()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.status='COMPLETE' then
    new.pick_deadline_at := null;
    new.paused_seconds := null;
  elsif new.status='PAUSED' then
    if old.status='LIVE' then
      new.paused_seconds := greatest(0,ceil(extract(epoch from old.pick_deadline_at-clock_timestamp())))::int;
    end if;
    if new.pick_timer_seconds is distinct from old.pick_timer_seconds then
      new.paused_seconds := new.pick_timer_seconds;
    end if;
    new.pick_deadline_at := null;
  elsif new.status='LIVE' then
    if new.current_overall_pick is distinct from old.current_overall_pick
       or new.pick_timer_seconds is distinct from old.pick_timer_seconds then
      new.pick_deadline_at := clock_timestamp()+make_interval(secs=>new.pick_timer_seconds);
    elsif old.status='PAUSED' then
      new.pick_deadline_at := clock_timestamp()+make_interval(secs=>coalesce(old.paused_seconds,new.pick_timer_seconds));
    elsif old.status<>'LIVE' or old.pick_deadline_at is null then
      new.pick_deadline_at := clock_timestamp()+make_interval(secs=>new.pick_timer_seconds);
    end if;
    new.paused_seconds := null;
  else
    new.pick_deadline_at := null;
    new.paused_seconds := null;
  end if;
  return new;
end;
$$;
revoke all on function private.update_draft_clock() from public,anon,authenticated;
create trigger draft_clock_before_update before update on public.drafts
for each row execute function private.update_draft_clock();

create or replace function public.set_draft_timer(p_draft_id uuid,p_seconds integer)
returns void language plpgsql security definer set search_path = '' as $$
declare v_league uuid; v_status text;
begin
  select s.league_id,d.status into v_league,v_status
  from public.drafts d join public.seasons s on s.id=d.season_id where d.id=p_draft_id for update of d;
  if auth.uid() is null or not coalesce(public.is_league_commissioner(v_league),false) then
    raise exception 'Commissioner permission required';
  end if;
  if v_status='COMPLETE' then raise exception 'Draft is complete'; end if;
  if p_seconds is null or p_seconds<10 or p_seconds>600 then raise exception 'Pick timer must be between 10 and 600 seconds'; end if;
  update public.drafts set pick_timer_seconds=p_seconds where id=p_draft_id;
  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(v_league,auth.uid(),'DRAFT_TIMER_CHANGED','draft',p_draft_id,jsonb_build_object('seconds',p_seconds));
end;
$$;
revoke all on function public.set_draft_timer(uuid,integer) from public,anon;
grant execute on function public.set_draft_timer(uuid,integer) to authenticated;

-- RLS applies; this snapshot also supplies database time for clients with skewed clocks.
create or replace function public.get_draft_clock(p_draft_id uuid)
returns jsonb language sql security invoker set search_path = '' as $$
  select jsonb_build_object('deadline',d.pick_deadline_at,'paused_seconds',d.paused_seconds,
    'server_now',clock_timestamp(),'status',d.status,'current_pick',d.current_overall_pick)
  from public.drafts d where d.id=p_draft_id;
$$;
revoke all on function public.get_draft_clock(uuid) from public,anon;
grant execute on function public.get_draft_clock(uuid) to authenticated;

CREATE OR REPLACE FUNCTION private.commit_draft_pick(p_draft_id uuid, p_asset_id uuid, p_auto boolean default false)
 RETURNS draft_selections
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_draft public.drafts%rowtype;
  v_season public.seasons%rowtype;
  v_team_count int;
  v_round int;
  v_position int;
  v_original_slot int;
  v_pick public.draft_picks%rowtype;
  v_selection public.draft_selections%rowtype;
  v_roster_limit int;
  v_active_limit int;
  v_roster_count int;
  v_active_count int;
  v_lineup_status text;
  v_asset_sport text;
  v_missing_after int;
  v_remaining_after int;
begin
  select * into v_draft
  from public.drafts
  where id=p_draft_id
  for update;

  if v_draft.id is null or v_draft.status<>'LIVE' then
    raise exception 'Draft is not live';
  end if;

  select * into v_season
  from public.seasons
  where id=v_draft.season_id;

  select count(*) into v_team_count
  from public.teams
  where league_id=v_season.league_id;

  if v_draft.current_overall_pick>20*v_team_count then
    raise exception 'Draft is complete';
  end if;

  v_round := floor((v_draft.current_overall_pick-1)::numeric/v_team_count)::int+1;
  v_position := ((v_draft.current_overall_pick-1)%v_team_count)+1;
  v_original_slot := case
    when mod(v_round,2)=1 then v_position
    else v_team_count-v_position+1
  end;

  select * into v_pick
  from public.draft_picks
  where league_id=v_season.league_id
    and draft_year=extract(year from v_draft.scheduled_at)::int
    and round=v_round
    and slot=v_original_slot
  for update;

  if v_pick.id is null then raise exception 'Draft slot is missing'; end if;

  if exists (
    select 1
    from public.keeper_selections
    where forfeited_draft_pick_id=v_pick.id
  ) then
    raise exception 'This draft pick is reserved for a keeper';
  end if;

  if not p_auto and not exists (
    select 1
    from public.teams
    where id=v_pick.current_team_id
      and owner_user_id=(select auth.uid())
  ) and not public.is_league_commissioner(v_season.league_id) then
    raise exception 'You are not on the clock';
  end if;

  if not p_auto and (auth.uid() is null or (v_draft.pick_deadline_at is not null and clock_timestamp() >= v_draft.pick_deadline_at)) then
    raise exception 'Pick timer has expired';
  end if;

  select sport into v_asset_sport
  from public.assets
  where id=p_asset_id and active=true;

  if v_asset_sport is null then raise exception 'Asset is not draftable'; end if;

  if not (v_asset_sport=any(private.required_sports())) then
    raise exception 'Asset sport is not part of this league';
  end if;

  if exists (
    select 1
    from public.draft_selections
    where draft_id=p_draft_id
      and asset_id=p_asset_id
  ) or exists (
    select 1
    from public.roster_memberships
    where season_id=v_draft.season_id
      and asset_id=p_asset_id
  ) then raise exception 'Asset is already rostered'; end if;

  select l.roster_size,l.active_slots
  into v_roster_limit,v_active_limit
  from public.leagues l
  where l.id=v_season.league_id;

  select count(*),count(*) filter(where lineup_status='ACTIVE')
  into v_roster_count,v_active_count
  from public.roster_memberships
  where season_id=v_draft.season_id
    and team_id=v_pick.current_team_id;

  if v_roster_count>=v_roster_limit then
    raise exception 'Roster is full';
  end if;

  select count(*) into v_missing_after
  from unnest(private.required_sports()) req(sport)
  where req.sport<>v_asset_sport
    and not exists (
      select 1
      from public.roster_memberships rm
      join public.assets a on a.id=rm.asset_id
      where rm.season_id=v_draft.season_id
        and rm.team_id=v_pick.current_team_id
        and a.sport=req.sport
    );

  v_remaining_after := v_roster_limit-(v_roster_count+1);

  if v_remaining_after<v_missing_after then
    raise exception 'This pick would make it impossible to finish with all 10 sports represented';
  end if;

  v_lineup_status := case
    when v_active_count<v_active_limit then 'ACTIVE'
    else 'BENCH'
  end;

  insert into public.draft_selections(
    draft_id,overall_pick,round,team_id,asset_id,draft_pick_id,selection_type
  ) values (
    p_draft_id,v_draft.current_overall_pick,v_round,
    v_pick.current_team_id,p_asset_id,v_pick.id,'DRAFT'
  )
  returning * into v_selection;

  insert into public.roster_memberships(
    season_id,team_id,asset_id,lineup_status,acquired_at
  ) values (
    v_draft.season_id,v_pick.current_team_id,p_asset_id,v_lineup_status,now()
  );

  update public.drafts
  set current_overall_pick=current_overall_pick+1
  where id=p_draft_id;

  perform private.advance_draft_cursor(p_draft_id);

  insert into public.audit_log(
    league_id,actor_user_id,action_type,entity_type,entity_id,payload
  ) values (
    v_season.league_id,(select auth.uid()),'DRAFT_PICK_MADE',
    'draft_selection',v_selection.id,
    jsonb_build_object(
      'overall_pick',v_selection.overall_pick,
      'team_id',v_selection.team_id,
      'asset_id',p_asset_id,
      'auto_pick',p_auto,
      'lineup_status',v_lineup_status,
      'sport',v_asset_sport
    )
  );

  update public.draft_selections set auto_picked=p_auto where id=v_selection.id returning * into v_selection;
  return v_selection;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_lineup_status(p_season_id uuid, p_team_id uuid, p_asset_id uuid, p_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_current text;
  v_active_count int;
  v_active_limit int;
  v_league_id uuid;
begin
  if p_status not in ('ACTIVE','BENCH') then
    raise exception 'Invalid lineup status';
  end if;

  select t.league_id into v_league_id
  from public.teams t
  where t.id=p_team_id and t.owner_user_id=auth.uid();

  if v_league_id is null and not exists (
    select 1 from public.teams t
    where t.id=p_team_id and public.is_league_commissioner(t.league_id)
  ) then
    raise exception 'Not authorized for this team';
  end if;

  perform 1 from public.teams where id=p_team_id for update;
  if not exists (select 1 from public.seasons s join public.teams t on t.league_id=s.league_id where s.id=p_season_id and t.id=p_team_id) then
    raise exception 'Season does not belong to this team';
  end if;

  select rm.lineup_status into v_current
  from public.roster_memberships rm
  where rm.season_id=p_season_id and rm.team_id=p_team_id and rm.asset_id=p_asset_id
  for update;

  if v_current is null then
    raise exception 'Asset is not on this roster';
  end if;

  if exists (
    select 1
    from public.scoring_event_assets sea
    join public.scoring_events se on se.id=sea.scoring_event_id
    where sea.asset_id=p_asset_id
      and se.season_id=p_season_id
      and now() >= se.locks_at
      and (se.occurred_at is null or now() <= se.occurred_at)
  ) then
    raise exception 'Asset is locked for an active scoring event';
  end if;

  if p_status='ACTIVE' and v_current<>'ACTIVE' then
    select l.active_slots into v_active_limit
    from public.seasons s join public.leagues l on l.id=s.league_id
    where s.id=p_season_id;

    select count(*) into v_active_count
    from public.roster_memberships
    where season_id=p_season_id and team_id=p_team_id and lineup_status='ACTIVE';

    if v_active_count >= v_active_limit then
      raise exception 'Active lineup is full';
    end if;
  end if;

  update public.roster_memberships
  set lineup_status=p_status
  where season_id=p_season_id and team_id=p_team_id and asset_id=p_asset_id;

  insert into public.lineup_events(season_id,team_id,asset_id,from_status,to_status)
  values(p_season_id,p_team_id,p_asset_id,v_current,p_status);

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  select s.league_id,auth.uid(),'LINEUP_CHANGED','asset',p_asset_id,
         jsonb_build_object('team_id',p_team_id,'from',v_current,'to',p_status)
  from public.seasons s where s.id=p_season_id;
end;
$function$;

-- Privileged mutation stays private; manual and timeout calls share all roster validation.
revoke all on function private.commit_draft_pick(uuid,uuid,boolean) from public,anon,authenticated;
create or replace function public.make_draft_pick(p_draft_id uuid,p_asset_id uuid)
returns public.draft_selections language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  return private.commit_draft_pick(p_draft_id,p_asset_id,false);
end;
$$;
revoke all on function public.make_draft_pick(uuid,uuid) from public,anon;
grant execute on function public.make_draft_pick(uuid,uuid) to authenticated;

create or replace function private.auto_pick_expired(p_draft_id uuid,p_expected_pick integer)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  d public.drafts%rowtype; s public.seasons%rowtype; v_count int; v_round int; v_slot int;
  v_team uuid; v_owner uuid; v_roster_count int; v_limit int; v_asset uuid;
begin
  select * into d from public.drafts where id=p_draft_id for update;
  if d.status<>'LIVE' or d.pick_deadline_at is null or clock_timestamp()<d.pick_deadline_at
     or d.current_overall_pick<>p_expected_pick then return false; end if;
  select * into s from public.seasons where id=d.season_id;
  select count(*) into v_count from public.teams where league_id=s.league_id;
  if v_count=0 then return false; end if;
  v_round := (d.current_overall_pick-1)/v_count+1;
  v_slot := (d.current_overall_pick-1)%v_count+1;
  if v_round%2=0 then v_slot:=v_count-v_slot+1; end if;
  select dp.current_team_id,t.owner_user_id into v_team,v_owner
  from public.draft_picks dp join public.teams t on t.id=dp.current_team_id
  where dp.league_id=s.league_id and dp.draft_year=extract(year from d.scheduled_at)::int
    and dp.round=v_round and dp.slot=v_slot;
  if v_team is null then raise exception 'Draft slot is missing'; end if;
  select count(*) into v_roster_count from public.roster_memberships where season_id=s.id and team_id=v_team;
  select roster_size into v_limit from public.leagues where id=s.league_id;
  select a.id into v_asset from public.assets a
  left join public.draft_preferences pref on pref.draft_id=d.id and pref.user_id=v_owner and pref.asset_id=a.id
  left join lateral (
    select st.points from public.asset_season_stats st
    where st.asset_id=a.id and st.scoring_version=s.scoring_version and st.season_label<>s.label
    order by st.season_label desc limit 1
  ) history on true
  where a.active and a.sport=any(private.required_sports()) and v_roster_count<v_limit
    and not exists(select 1 from public.roster_memberships where season_id=s.id and asset_id=a.id)
    and not exists(select 1 from public.draft_selections where draft_id=d.id and asset_id=a.id)
    and v_limit-v_roster_count-1 >= (
      select count(*) from unnest(private.required_sports()) req(sport) where req.sport<>a.sport
      and not exists(select 1 from public.roster_memberships rm join public.assets ra on ra.id=rm.asset_id
        where rm.season_id=s.id and rm.team_id=v_team and ra.sport=req.sport)
    )
  order by (pref.queue_position is not null) desc,pref.queue_position asc nulls last,
    coalesce(history.points,0) desc,a.sport collate "C",a.name collate "C",a.id
  limit 1;
  if v_asset is null then
    update public.drafts set status='PAUSED' where id=d.id;
    insert into public.audit_log(league_id,action_type,entity_type,entity_id,payload)
    values(s.league_id,'DRAFT_AUTO_PICK_BLOCKED','draft',d.id,jsonb_build_object('reason','No eligible assets'));
    return false;
  end if;
  perform private.commit_draft_pick(d.id,v_asset,true);
  return true;
end;
$$;
revoke all on function private.auto_pick_expired(uuid,integer) from public,anon,authenticated;

create or replace function private.process_expired_drafts()
returns void language plpgsql security definer set search_path = '' as $$
declare d record;
begin
  for d in select id,current_overall_pick from public.drafts
    where status='LIVE' and pick_deadline_at<=clock_timestamp() for update skip locked
  loop
    begin
      perform private.auto_pick_expired(d.id,d.current_overall_pick);
    exception when others then
      raise warning 'Draft timeout failed for %: %',d.id,sqlerrm;
      update public.drafts set status='PAUSED' where id=d.id;
    end;
  end loop;
end;
$$;
revoke all on function private.process_expired_drafts() from public,anon,authenticated;

-- Any league member can wake an expired pick; the server validates time and pick identity.
create or replace function public.process_draft_timeout(p_draft_id uuid,p_expected_pick integer)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_league uuid;
begin
  select s.league_id into v_league from public.drafts d join public.seasons s on s.id=d.season_id where d.id=p_draft_id;
  if auth.uid() is null or not (coalesce(public.is_league_member(v_league),false)
    or coalesce(public.is_league_commissioner(v_league),false)) then raise exception 'League membership required'; end if;
  return private.auto_pick_expired(p_draft_id,p_expected_pick);
end;
$$;
revoke all on function public.process_draft_timeout(uuid,integer) from public,anon;
grant execute on function public.process_draft_timeout(uuid,integer) to authenticated;

create or replace function public.swap_lineup_assets(p_season_id uuid,p_team_id uuid,p_active_asset_id uuid,p_bench_asset_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_league uuid;
begin
  select t.league_id into v_league from public.teams t join public.seasons s on s.league_id=t.league_id
    where t.id=p_team_id and s.id=p_season_id and (t.owner_user_id=auth.uid() or public.is_league_commissioner(t.league_id)) for update of t;
  if auth.uid() is null or v_league is null then raise exception 'Not authorized for this team'; end if;
  perform 1 from public.roster_memberships where season_id=p_season_id and team_id=p_team_id
    and asset_id in (p_active_asset_id,p_bench_asset_id) order by asset_id for update;
  if not exists(select 1 from public.roster_memberships where season_id=p_season_id and team_id=p_team_id and asset_id=p_active_asset_id and lineup_status='ACTIVE')
    or not exists(select 1 from public.roster_memberships where season_id=p_season_id and team_id=p_team_id and asset_id=p_bench_asset_id and lineup_status='BENCH') then
    raise exception 'Choose one active asset and one bench asset';
  end if;
  -- Both changes, lock checks and lineup events succeed together or roll back together.
  perform public.set_lineup_status(p_season_id,p_team_id,p_active_asset_id,'BENCH');
  perform public.set_lineup_status(p_season_id,p_team_id,p_bench_asset_id,'ACTIVE');
end;
$$;
revoke all on function public.swap_lineup_assets(uuid,uuid,uuid,uuid) from public,anon;
grant execute on function public.swap_lineup_assets(uuid,uuid,uuid,uuid) to authenticated;

-- Existing paused drafts receive a full clock when resumed; completed drafts stay untouched.
update public.drafts set paused_seconds=pick_timer_seconds where status='PAUSED' and paused_seconds is null;
update public.drafts set pick_deadline_at=clock_timestamp()+make_interval(secs=>pick_timer_seconds)
where status='LIVE' and pick_deadline_at is null;

-- Works even with every browser closed. Private function is callable only by the job owner.
create extension if not exists pg_cron;
select cron.schedule('ten-sport-draft-timeouts','1 second','select private.process_expired_drafts()');
