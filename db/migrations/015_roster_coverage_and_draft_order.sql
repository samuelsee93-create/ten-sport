-- 015_roster_coverage_and_draft_order.sql
-- Remove dedicated/flex slots. Require all 10 sports to remain representable.
-- Drafts are 20-round snake drafts with commissioner-set or randomized order.

drop index if exists public.roster_one_dedicated_sport_idx;
alter table public.roster_memberships drop constraint if exists roster_memberships_slot_shape;
alter table public.roster_memberships drop constraint if exists roster_memberships_slot_type;
drop function if exists private.normalize_roster_slots(uuid,uuid);
alter table public.roster_memberships drop column if exists roster_slot_type;
alter table public.roster_memberships drop column if exists roster_slot_sport;

create or replace function private.missing_sport_count(
  p_season_id uuid,
  p_team_id uuid
) returns int
language sql
stable
security definer
set search_path=public,private
as $$
  select count(*)::int
  from unnest(private.required_sports()) req(sport)
  where not exists (
    select 1
    from public.roster_memberships rm
    join public.assets a on a.id=rm.asset_id
    where rm.season_id=p_season_id
      and rm.team_id=p_team_id
      and a.sport=req.sport
  );
$$;

create table if not exists public.draft_order (
  draft_id uuid not null references public.drafts(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete cascade,
  slot int not null check (slot > 0),
  created_at timestamptz not null default now(),
  primary key (draft_id,team_id),
  unique (draft_id,slot)
);

alter table public.draft_order enable row level security;
revoke all on table public.draft_order from anon;
revoke all on table public.draft_order from authenticated;
grant select on table public.draft_order to authenticated;

drop policy if exists draft_order_member_read on public.draft_order;
create policy draft_order_member_read
on public.draft_order for select to authenticated
using (
  exists (
    select 1
    from public.drafts d
    join public.seasons s on s.id=d.season_id
    where d.id=draft_id
      and (public.is_league_member(s.league_id) or public.is_league_commissioner(s.league_id))
  )
);

alter table public.drafts
  add column if not exists order_method text
    check (order_method in ('MANUAL','RANDOMIZED'));

alter table public.drafts alter column rounds set default 20;

update public.drafts d
set rounds=20
where d.status in ('SCHEDULED','LOBBY')
  and not exists (select 1 from public.draft_selections ds where ds.draft_id=d.id);

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
  if not public.is_league_commissioner(v_league_id) then
    raise exception 'Commissioner permission required';
  end if;
  if v_status in ('LIVE','COMPLETE') then
    raise exception 'Draft order cannot be changed after the draft starts';
  end if;

  select count(*) into v_team_count
  from public.teams where league_id=v_league_id;

  v_input_count := coalesce(array_length(p_team_ids,1),0);
  select count(distinct x) into v_distinct_count
  from unnest(coalesce(p_team_ids,'{}'::uuid[])) x;

  if v_input_count<>v_team_count or v_distinct_count<>v_team_count then
    raise exception 'Draft order must contain every league team exactly once';
  end if;

  if exists (
    select 1 from unnest(p_team_ids) x
    where not exists (
      select 1 from public.teams t where t.id=x and t.league_id=v_league_id
    )
  ) then
    raise exception 'Draft order contains a team outside this league';
  end if;

  delete from public.draft_order where draft_id=p_draft_id;

  insert into public.draft_order(draft_id,team_id,slot)
  select p_draft_id,x.team_id,x.ordinality::int
  from unnest(p_team_ids) with ordinality as x(team_id,ordinality);

  update public.drafts
  set order_method='MANUAL'
  where id=p_draft_id;

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
  values(
    v_league_id,(select auth.uid()),'DRAFT_ORDER_SET','draft',p_draft_id,
    jsonb_build_object('team_ids',p_team_ids,'method','MANUAL')
  );
end;
$$;

revoke all on function public.set_draft_order(uuid,uuid[]) from public;
revoke all on function public.set_draft_order(uuid,uuid[]) from anon;
grant execute on function public.set_draft_order(uuid,uuid[]) to authenticated;

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
  if not public.is_league_commissioner(v_league_id) then
    raise exception 'Commissioner permission required';
  end if;
  if v_status in ('LIVE','COMPLETE') then
    raise exception 'Draft order cannot be changed after the draft starts';
  end if;

  select array_agg(id order by random()) into v_order
  from public.teams where league_id=v_league_id;

  delete from public.draft_order where draft_id=p_draft_id;

  insert into public.draft_order(draft_id,team_id,slot)
  select p_draft_id,x.team_id,x.ordinality::int
  from unnest(v_order) with ordinality as x(team_id,ordinality);

  update public.drafts
  set order_method='RANDOMIZED'
  where id=p_draft_id;

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
  values(
    v_league_id,(select auth.uid()),'DRAFT_ORDER_SET','draft',p_draft_id,
    jsonb_build_object('team_ids',v_order,'method','RANDOMIZED')
  );

  return v_order;
end;
$$;

revoke all on function public.randomize_draft_order(uuid) from public;
revoke all on function public.randomize_draft_order(uuid) from anon;
grant execute on function public.randomize_draft_order(uuid) to authenticated;

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
  v_year int;
  v_team record;
  v_round int;
begin
  select s.league_id into v_league_id
  from public.drafts d
  join public.seasons s on s.id=d.season_id
  where d.id=p_draft_id
  for update;

  if v_league_id is null then raise exception 'Draft not found'; end if;
  if not public.is_league_commissioner(v_league_id) then
    raise exception 'Commissioner permission required';
  end if;
  if p_scheduled_at is null then raise exception 'Draft date and time are required'; end if;

  update public.drafts
  set scheduled_at=p_scheduled_at,rounds=20
  where id=p_draft_id;

  v_year := extract(year from p_scheduled_at)::int;

  for v_team in
    select t.id,dord.slot
    from public.teams t
    left join public.draft_order dord
      on dord.draft_id=p_draft_id and dord.team_id=t.id
    where t.league_id=v_league_id
  loop
    for v_round in 1..20 loop
      insert into public.draft_picks(
        league_id,draft_year,round,slot,original_team_id,current_team_id
      ) values (
        v_league_id,v_year,v_round,v_team.slot,v_team.id,v_team.id
      ) on conflict (league_id,draft_year,round,original_team_id)
      do update set slot=excluded.slot;
    end loop;
  end loop;

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(
    v_league_id,(select auth.uid()),'DRAFT_SCHEDULE_CHANGED','draft',p_draft_id,
    jsonb_build_object('scheduled_at',p_scheduled_at,'rounds',20)
  );
end;
$$;

create or replace function public.set_draft_status(
  p_draft_id uuid,
  p_status text
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_league_id uuid;
  v_scheduled_at timestamptz;
  v_team_count int;
  v_order_count int;
begin
  if p_status not in ('SCHEDULED','LOBBY','LIVE','PAUSED','COMPLETE') then
    raise exception 'Invalid draft status';
  end if;

  select s.league_id,d.scheduled_at into v_league_id,v_scheduled_at
  from public.drafts d
  join public.seasons s on s.id=d.season_id
  where d.id=p_draft_id
  for update;

  if v_league_id is null then raise exception 'Draft not found'; end if;
  if not public.is_league_commissioner(v_league_id) then
    raise exception 'Commissioner permission required';
  end if;

  if p_status='LIVE' then
    if v_scheduled_at is null then
      raise exception 'Set the draft date and time before starting the draft';
    end if;

    select count(*) into v_team_count
    from public.teams where league_id=v_league_id;

    select count(*) into v_order_count
    from public.draft_order where draft_id=p_draft_id;

    if v_order_count<>v_team_count then
      raise exception 'Set or randomize the complete draft order before starting the draft';
    end if;
  end if;

  update public.drafts set status=p_status where id=p_draft_id;

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(
    v_league_id,(select auth.uid()),'DRAFT_STATUS_CHANGED','draft',p_draft_id,
    jsonb_build_object('status',p_status)
  );
end;
$$;

create or replace function public.make_draft_pick(
  p_draft_id uuid,
  p_asset_id uuid
) returns public.draft_selections
language plpgsql
security definer
set search_path=public,private
as $$
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

  if v_draft.scheduled_at is null then
    raise exception 'Draft date and time are not set';
  end if;

  select * into v_season
  from public.seasons
  where id=v_draft.season_id;

  select sport into v_asset_sport
  from public.assets
  where id=p_asset_id and active=true;

  if v_asset_sport is null then raise exception 'Asset is not draftable'; end if;
  if not (v_asset_sport=any(private.required_sports())) then
    raise exception 'Asset sport is not part of this league';
  end if;

  select count(*) into v_team_count
  from public.teams
  where league_id=v_season.league_id;

  if v_team_count=0 then raise exception 'League has no teams'; end if;

  v_round := floor((v_draft.current_overall_pick-1)::numeric / v_team_count)::int + 1;
  if v_round>20 then raise exception 'Draft is complete'; end if;

  v_position := ((v_draft.current_overall_pick-1) % v_team_count) + 1;
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

  if not exists (
    select 1
    from public.teams
    where id=v_pick.current_team_id
      and owner_user_id=(select auth.uid())
  ) and not public.is_league_commissioner(v_season.league_id) then
    raise exception 'You are not on the clock';
  end if;

  if exists (
    select 1 from public.draft_selections
    where draft_id=p_draft_id and asset_id=p_asset_id
  ) then raise exception 'Asset has already been drafted'; end if;

  if exists (
    select 1 from public.roster_memberships
    where season_id=v_draft.season_id and asset_id=p_asset_id
  ) then raise exception 'Asset is already rostered'; end if;

  select l.roster_size,l.active_slots
  into v_roster_limit,v_active_limit
  from public.leagues l
  where l.id=v_season.league_id;

  select count(*),count(*) filter (where lineup_status='ACTIVE')
  into v_roster_count,v_active_count
  from public.roster_memberships
  where season_id=v_draft.season_id
    and team_id=v_pick.current_team_id;

  if v_roster_count>=v_roster_limit then raise exception 'Roster is full'; end if;

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
    draft_id,overall_pick,round,team_id,asset_id,draft_pick_id
  ) values (
    p_draft_id,v_draft.current_overall_pick,v_round,
    v_pick.current_team_id,p_asset_id,v_pick.id
  )
  returning * into v_selection;

  insert into public.roster_memberships(
    season_id,team_id,asset_id,lineup_status,acquired_at
  ) values (
    v_draft.season_id,v_pick.current_team_id,p_asset_id,v_lineup_status,now()
  );

  update public.drafts
  set current_overall_pick=current_overall_pick+1,
      rounds=20,
      status=case
        when current_overall_pick>=20*v_team_count then 'COMPLETE'
        else status
      end
  where id=p_draft_id;

  insert into public.audit_log(
    league_id,actor_user_id,action_type,entity_type,entity_id,payload
  ) values (
    v_season.league_id,(select auth.uid()),'DRAFT_PICK_MADE',
    'draft_selection',v_selection.id,
    jsonb_build_object(
      'overall_pick',v_selection.overall_pick,
      'team_id',v_selection.team_id,
      'asset_id',p_asset_id,
      'lineup_status',v_lineup_status,
      'sport',v_asset_sport
    )
  );

  return v_selection;
end;
$$;

create or replace function public.claim_waiver_asset(
  p_team_id uuid,
  p_asset_id uuid,
  p_drop_asset_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path=public,private
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_league_id uuid;
  v_season_id uuid;
  v_roster_limit int;
  v_roster_count int;
  v_missing_after int;
  v_remaining_after int;
  v_transaction_id uuid;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;

  select t.league_id,l.roster_size
  into v_league_id,v_roster_limit
  from public.teams t
  join public.leagues l on l.id=t.league_id
  where t.id=p_team_id and t.owner_user_id=v_user_id;

  if v_league_id is null then raise exception 'You do not own this team'; end if;

  if not exists (
    select 1 from public.league_memberships
    where league_id=v_league_id and user_id=v_user_id and status='ACTIVE'
  ) then raise exception 'You are not an active member of this league'; end if;

  select id into v_season_id
  from public.seasons
  where league_id=v_league_id and status in ('SETUP','ACTIVE')
  order by label desc
  limit 1;

  if v_season_id is null then
    raise exception 'This league does not have an active season';
  end if;

  perform 1
  from public.assets
  where id=p_asset_id and active=true
  for update;

  if not found then raise exception 'Asset is not available'; end if;

  if exists (
    select 1 from public.roster_memberships
    where season_id=v_season_id and asset_id=p_asset_id
  ) then raise exception 'Asset has already been claimed'; end if;

  select count(*) into v_roster_count
  from public.roster_memberships
  where season_id=v_season_id and team_id=p_team_id;

  if v_roster_count>=v_roster_limit and p_drop_asset_id is null then
    raise exception 'Roster is full; choose an asset to drop';
  end if;

  if p_drop_asset_id is not null then
    if not exists (
      select 1 from public.roster_memberships
      where season_id=v_season_id
        and team_id=p_team_id
        and asset_id=p_drop_asset_id
    ) then raise exception 'Drop asset is not on your roster'; end if;

    if exists (
      select 1
      from public.scoring_event_assets sea
      join public.scoring_events se on se.id=sea.scoring_event_id
      where sea.asset_id=p_drop_asset_id
        and se.season_id=v_season_id
        and now()>=se.locks_at
        and (se.occurred_at is null or now()<=se.occurred_at)
    ) then raise exception 'The asset you are trying to drop is currently locked'; end if;

    delete from public.keeper_selections
    where season_id=v_season_id
      and team_id=p_team_id
      and asset_id=p_drop_asset_id;

    delete from public.roster_memberships
    where season_id=v_season_id
      and team_id=p_team_id
      and asset_id=p_drop_asset_id;

    v_roster_count := v_roster_count-1;
  end if;

  insert into public.roster_memberships(
    season_id,team_id,asset_id,lineup_status,acquired_at
  ) values (
    v_season_id,p_team_id,p_asset_id,'BENCH',now()
  );

  select private.missing_sport_count(v_season_id,p_team_id)
  into v_missing_after;

  select v_roster_limit-count(*)
  into v_remaining_after
  from public.roster_memberships
  where season_id=v_season_id and team_id=p_team_id;

  if v_remaining_after<v_missing_after then
    raise exception 'This move would leave the roster unable to contain all 10 sports';
  end if;

  insert into public.waiver_transactions(
    season_id,team_id,added_asset_id,dropped_asset_id,transaction_type
  ) values (
    v_season_id,p_team_id,p_asset_id,p_drop_asset_id,'WAIVER'
  )
  returning id into v_transaction_id;

  insert into public.audit_log(
    league_id,actor_user_id,action_type,entity_type,entity_id,payload
  ) values (
    v_league_id,v_user_id,'WAIVER_CLAIMED','waiver_transaction',v_transaction_id,
    jsonb_build_object(
      'team_id',p_team_id,
      'added_asset_id',p_asset_id,
      'dropped_asset_id',p_drop_asset_id,
      'priority','FIRST_COME_FIRST_SERVE'
    )
  );

  return jsonb_build_object(
    'transaction_id',v_transaction_id,
    'team_id',p_team_id,
    'added_asset_id',p_asset_id,
    'dropped_asset_id',p_drop_asset_id
  );
end;
$$;

create or replace function public.accept_trade(p_trade_id uuid)
returns void
language plpgsql
security definer
set search_path=public,private
as $$
declare
  v_trade public.trades%rowtype;
  v_league_id uuid;
  v_roster_limit int;
  v_active_limit int;
  v_proposer_count int;
  v_recipient_count int;
  v_proposer_out int;
  v_recipient_out int;
  v_missing int;
  v_free int;
  v_asset record;
  v_pick record;
begin
  select * into v_trade
  from public.trades
  where id=p_trade_id
  for update;

  if v_trade.id is null or v_trade.status<>'PENDING' then
    raise exception 'Trade is no longer available';
  end if;

  select t.league_id into v_league_id
  from public.teams t
  where t.id=v_trade.recipient_team_id;

  if not exists (
    select 1
    from public.teams
    where id=v_trade.recipient_team_id
      and owner_user_id=(select auth.uid())
  ) and not public.is_league_commissioner(v_league_id) then
    raise exception 'Only the recipient can accept this trade';
  end if;

  if exists (
    select 1
    from public.seasons s
    where s.id=v_trade.season_id
      and s.trade_deadline is not null
      and now()>s.trade_deadline
  ) then raise exception 'The trade deadline has passed'; end if;

  select l.roster_size,l.active_slots
  into v_roster_limit,v_active_limit
  from public.seasons s
  join public.leagues l on l.id=s.league_id
  where s.id=v_trade.season_id;

  select count(*) into v_proposer_count
  from public.roster_memberships
  where season_id=v_trade.season_id
    and team_id=v_trade.proposer_team_id;

  select count(*) into v_recipient_count
  from public.roster_memberships
  where season_id=v_trade.season_id
    and team_id=v_trade.recipient_team_id;

  select count(*) into v_proposer_out
  from public.trade_items
  where trade_id=p_trade_id
    and side='PROPOSER'
    and item_type='ASSET';

  select count(*) into v_recipient_out
  from public.trade_items
  where trade_id=p_trade_id
    and side='RECIPIENT'
    and item_type='ASSET';

  if v_proposer_count-v_proposer_out+v_recipient_out>v_roster_limit
     or v_recipient_count-v_recipient_out+v_proposer_out>v_roster_limit then
    raise exception 'Trade would create an illegal roster size';
  end if;

  for v_asset in
    select ti.side,ti.asset_id
    from public.trade_items ti
    where ti.trade_id=p_trade_id
      and ti.item_type='ASSET'
    for update
  loop
    if v_asset.side='PROPOSER' then
      if not exists (
        select 1
        from public.roster_memberships
        where season_id=v_trade.season_id
          and team_id=v_trade.proposer_team_id
          and asset_id=v_asset.asset_id
      ) then raise exception 'Proposer asset ownership changed'; end if;

      update public.roster_memberships
      set team_id=v_trade.recipient_team_id,
          lineup_status='BENCH',
          acquired_at=now()
      where season_id=v_trade.season_id
        and team_id=v_trade.proposer_team_id
        and asset_id=v_asset.asset_id;
    else
      if not exists (
        select 1
        from public.roster_memberships
        where season_id=v_trade.season_id
          and team_id=v_trade.recipient_team_id
          and asset_id=v_asset.asset_id
      ) then raise exception 'Recipient asset ownership changed'; end if;

      update public.roster_memberships
      set team_id=v_trade.proposer_team_id,
          lineup_status='BENCH',
          acquired_at=now()
      where season_id=v_trade.season_id
        and team_id=v_trade.recipient_team_id
        and asset_id=v_asset.asset_id;
    end if;

    delete from public.keeper_selections
    where season_id=v_trade.season_id
      and asset_id=v_asset.asset_id;
  end loop;

  select private.missing_sport_count(v_trade.season_id,v_trade.proposer_team_id)
  into v_missing;
  select v_roster_limit-count(*) into v_free
  from public.roster_memberships
  where season_id=v_trade.season_id
    and team_id=v_trade.proposer_team_id;

  if v_missing>v_free then
    raise exception 'Trade would leave the proposer unable to represent all 10 sports';
  end if;

  select private.missing_sport_count(v_trade.season_id,v_trade.recipient_team_id)
  into v_missing;
  select v_roster_limit-count(*) into v_free
  from public.roster_memberships
  where season_id=v_trade.season_id
    and team_id=v_trade.recipient_team_id;

  if v_missing>v_free then
    raise exception 'Trade would leave the recipient unable to represent all 10 sports';
  end if;

  with active_needed as (
    select greatest(
      0,
      v_active_limit-count(*) filter(where lineup_status='ACTIVE')
    )::int as n
    from public.roster_memberships
    where season_id=v_trade.season_id
      and team_id=v_trade.proposer_team_id
  ),
  candidates as (
    select rm.id
    from public.roster_memberships rm
    where rm.season_id=v_trade.season_id
      and rm.team_id=v_trade.proposer_team_id
      and rm.lineup_status='BENCH'
      and not exists (
        select 1
        from public.scoring_event_assets sea
        join public.scoring_events se on se.id=sea.scoring_event_id
        where sea.asset_id=rm.asset_id
          and se.season_id=v_trade.season_id
          and now()>=se.locks_at
          and (se.occurred_at is null or now()<=se.occurred_at)
      )
    order by rm.acquired_at desc,rm.id
    limit (select n from active_needed)
  )
  update public.roster_memberships rm
  set lineup_status='ACTIVE'
  where rm.id in (select id from candidates);

  with active_needed as (
    select greatest(
      0,
      v_active_limit-count(*) filter(where lineup_status='ACTIVE')
    )::int as n
    from public.roster_memberships
    where season_id=v_trade.season_id
      and team_id=v_trade.recipient_team_id
  ),
  candidates as (
    select rm.id
    from public.roster_memberships rm
    where rm.season_id=v_trade.season_id
      and rm.team_id=v_trade.recipient_team_id
      and rm.lineup_status='BENCH'
      and not exists (
        select 1
        from public.scoring_event_assets sea
        join public.scoring_events se on se.id=sea.scoring_event_id
        where sea.asset_id=rm.asset_id
          and se.season_id=v_trade.season_id
          and now()>=se.locks_at
          and (se.occurred_at is null or now()<=se.occurred_at)
      )
    order by rm.acquired_at desc,rm.id
    limit (select n from active_needed)
  )
  update public.roster_memberships rm
  set lineup_status='ACTIVE'
  where rm.id in (select id from candidates);

  for v_pick in
    select ti.side,ti.draft_pick_id
    from public.trade_items ti
    where ti.trade_id=p_trade_id
      and ti.item_type='DRAFT_PICK'
    for update
  loop
    if v_pick.side='PROPOSER' then
      if not exists (
        select 1 from public.draft_picks
        where id=v_pick.draft_pick_id
          and current_team_id=v_trade.proposer_team_id
      ) then raise exception 'Proposer draft-pick ownership changed'; end if;

      update public.draft_picks
      set current_team_id=v_trade.recipient_team_id
      where id=v_pick.draft_pick_id;
    else
      if not exists (
        select 1 from public.draft_picks
        where id=v_pick.draft_pick_id
          and current_team_id=v_trade.recipient_team_id
      ) then raise exception 'Recipient draft-pick ownership changed'; end if;

      update public.draft_picks
      set current_team_id=v_trade.proposer_team_id
      where id=v_pick.draft_pick_id;
    end if;
  end loop;

  update public.trades
  set status='ACCEPTED',
      resolved_at=now()
  where id=p_trade_id;

  insert into public.audit_log(
    league_id,actor_user_id,action_type,entity_type,entity_id,payload
  ) values (
    v_league_id,(select auth.uid()),'TRADE_ACCEPTED','trade',p_trade_id,'{}'::jsonb
  );
end;
$$;

create or replace function public.create_league(
  p_name text,
  p_team_name text,
  p_season_label text default '2026-27',
  p_scoring_version text default 'v1.2'
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
  values(
    v_league_id,
    coalesce(nullif(btrim(p_season_label),''),'2026-27'),
    coalesce(nullif(btrim(p_scoring_version),''),'v1.2'),
    'SETUP'
  )
  returning id into v_season_id;

  insert into public.drafts(
    season_id,status,pick_timer_seconds,rounds,current_overall_pick
  ) values (
    v_season_id,'SCHEDULED',90,20,1
  )
  returning id into v_draft_id;

  insert into public.audit_log(
    league_id,actor_user_id,action_type,entity_type,entity_id,payload
  ) values (
    v_league_id,v_user_id,'LEAGUE_CREATED','league',v_league_id,
    jsonb_build_object(
      'team_id',v_team_id,
      'season_id',v_season_id,
      'draft_id',v_draft_id
    )
  );

  return jsonb_build_object(
    'league_id',v_league_id,
    'team_id',v_team_id,
    'season_id',v_season_id,
    'draft_id',v_draft_id,
    'join_code',v_code
  );
end;
$$;

revoke all on function public.set_draft_schedule(uuid,timestamptz) from public;
revoke all on function public.set_draft_schedule(uuid,timestamptz) from anon;
grant execute on function public.set_draft_schedule(uuid,timestamptz) to authenticated;

revoke all on function public.set_draft_status(uuid,text) from public;
revoke all on function public.set_draft_status(uuid,text) from anon;
grant execute on function public.set_draft_status(uuid,text) to authenticated;

revoke all on function public.make_draft_pick(uuid,uuid) from public;
revoke all on function public.make_draft_pick(uuid,uuid) from anon;
grant execute on function public.make_draft_pick(uuid,uuid) to authenticated;

revoke all on function public.claim_waiver_asset(uuid,uuid,uuid) from public;
revoke all on function public.claim_waiver_asset(uuid,uuid,uuid) from anon;
grant execute on function public.claim_waiver_asset(uuid,uuid,uuid) to authenticated;

revoke all on function public.accept_trade(uuid) from public;
revoke all on function public.accept_trade(uuid) from anon;
grant execute on function public.accept_trade(uuid) to authenticated;

revoke all on function public.create_league(text,text,text,text) from public;
revoke all on function public.create_league(text,text,text,text) from anon;
grant execute on function public.create_league(text,text,text,text) to authenticated;
