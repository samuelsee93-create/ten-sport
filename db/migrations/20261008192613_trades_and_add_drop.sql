-- Atomic two-team proposals, counters, future picks, and roster-safe add/drop.
alter table public.trades add column if not exists counter_of_trade_id uuid references public.trades(id);

create or replace function public.ensure_future_draft_picks(p_league_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_year int;
begin
  if auth.uid() is null or not public.is_league_member(p_league_id) then raise exception 'Active league membership required'; end if;
  select coalesce(extract(year from d.scheduled_at)::int,extract(year from now())::int) into v_year
  from public.seasons s left join public.drafts d on d.season_id=s.id
  where s.league_id=p_league_id and s.status in ('SETUP','ACTIVE') order by s.label desc limit 1;
  if v_year is null then raise exception 'No active season'; end if;
  -- Future entitlements have no slot until the commissioner sets that year's order.
  insert into public.draft_picks(league_id,draft_year,round,original_team_id,current_team_id)
  select p_league_id,y,r,t.id,t.id from public.teams t
  cross join generate_series(v_year+1,v_year+2) y cross join generate_series(1,20) r
  where t.league_id=p_league_id
  on conflict (league_id,draft_year,round,original_team_id) do nothing;
end;
$$;

create or replace function private.validate_trade(p_trade_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare t public.trades%rowtype; s public.seasons%rowtype; i record; n int; lim int; missing int;
begin
  select * into t from public.trades where id=p_trade_id;
  select * into s from public.seasons where id=t.season_id;
  if s.status not in ('SETUP','ACTIVE') then raise exception 'Season is closed'; end if;
  if s.trade_deadline is not null and now()>s.trade_deadline then raise exception 'The trade deadline has passed'; end if;
  if t.proposer_team_id=t.recipient_team_id or (select count(*) from public.teams where id in(t.proposer_team_id,t.recipient_team_id) and league_id=s.league_id)<>2 then raise exception 'Choose another team in this league'; end if;
  if (select count(*) from public.teams tm join public.league_memberships lm on lm.league_id=tm.league_id and lm.user_id=tm.owner_user_id and lm.status='ACTIVE' where tm.id in(t.proposer_team_id,t.recipient_team_id))<>2 then raise exception 'Both managers must be active league members'; end if;
  -- All roster mutations take draft then team locks before assets or picks.
  perform 1 from public.drafts where season_id=s.id for update;
  perform 1 from public.teams where id in(t.proposer_team_id,t.recipient_team_id) order by id for update;
  if not exists(select 1 from public.trade_items where trade_id=t.id and side='PROPOSER') or not exists(select 1 from public.trade_items where trade_id=t.id and side='RECIPIENT') then raise exception 'Select at least one asset or pick on each side'; end if;
  if exists(select 1 from public.trade_items where trade_id=t.id group by item_type,asset_id,draft_pick_id having count(*)>1) then raise exception 'Duplicate trade item'; end if;
  if exists(select 1 from public.trade_items where trade_id=t.id and item_type='ASSET') and exists(select 1 from public.drafts where season_id=s.id and status in('LIVE','PAUSED')) then raise exception 'Asset trades are available after the draft finishes'; end if;
  perform 1 from public.assets where id in(select asset_id from public.trade_items where trade_id=t.id) order by id for update;
  perform 1 from public.draft_picks where id in(select draft_pick_id from public.trade_items where trade_id=t.id) order by id for update;
  for i in select ti.*,case when side='PROPOSER' then t.proposer_team_id else t.recipient_team_id end owner from public.trade_items ti where trade_id=t.id loop
    if i.item_type='ASSET' then
      if not exists(select 1 from public.roster_memberships where season_id=s.id and team_id=i.owner and asset_id=i.asset_id) then raise exception 'Asset ownership has changed'; end if;
      if exists(select 1 from public.scoring_event_assets sea join public.scoring_events se on se.id=sea.scoring_event_id where sea.asset_id=i.asset_id and se.season_id=s.id and now()>=se.locks_at and (se.occurred_at is null or now()<=se.occurred_at)) then raise exception 'An asset in this trade is currently locked'; end if;
    else
      if not exists(select 1 from public.draft_picks dp where dp.id=i.draft_pick_id and dp.current_team_id=i.owner and dp.league_id=s.league_id
        and dp.draft_year>=coalesce((select extract(year from scheduled_at)::int from public.drafts where season_id=s.id),extract(year from now())::int)
        and not exists(select 1 from public.draft_selections where draft_pick_id=dp.id)
        and not exists(select 1 from public.keeper_selections where forfeited_draft_pick_id=dp.id)
        and not exists(select 1 from public.drafts d join public.seasons ds on ds.id=d.season_id where ds.league_id=s.league_id and extract(year from d.scheduled_at)::int=dp.draft_year and d.status='COMPLETE')) then raise exception 'Draft pick is unavailable or ownership has changed'; end if;
    end if;
  end loop;
  select roster_size into lim from public.leagues where id=s.league_id;
  for i in select t.proposer_team_id team,'PROPOSER' side union all select t.recipient_team_id,'RECIPIENT' loop
    with after_move as (
      select rm.asset_id from public.roster_memberships rm where season_id=s.id and team_id=i.team and not exists(select 1 from public.trade_items ti where ti.trade_id=t.id and ti.side=i.side and ti.asset_id=rm.asset_id)
      union all select asset_id from public.trade_items where trade_id=t.id and side<>i.side and item_type='ASSET'
    ) select count(*),(select count(*) from unnest(private.required_sports()) req(sport) where not exists(select 1 from after_move am join public.assets a on a.id=am.asset_id where a.sport=req.sport)) into n,missing from after_move;
    if n>lim then raise exception 'Trade would create an illegal roster size'; end if;
    if missing>lim-n then raise exception 'Trade would prevent the roster from representing all 10 sports'; end if;
  end loop;
end;
$$;

create or replace function private.create_trade(p_season_id uuid,p_from_team_id uuid,p_to_team_id uuid,p_items jsonb,p_counter_of uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid; league uuid;
begin
  select league_id into league from public.seasons where id=p_season_id;
  if auth.uid() is null or not exists(select 1 from public.teams where id=p_from_team_id and league_id=league and owner_user_id=auth.uid()) or not public.is_league_member(league) then raise exception 'You do not own the proposing team'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)>160 then raise exception 'Invalid trade items'; end if;
  insert into public.trades(season_id,proposer_team_id,recipient_team_id,counter_of_trade_id) values(p_season_id,p_from_team_id,p_to_team_id,p_counter_of) returning id into v_id;
  insert into public.trade_items(trade_id,side,item_type,asset_id,draft_pick_id)
  select v_id,case item->>'side' when 'FROM' then 'PROPOSER' when 'TO' then 'RECIPIENT' else '' end,item->>'type',(item->>'assetId')::uuid,(item->>'draftPickId')::uuid from jsonb_array_elements(p_items) item;
  perform private.validate_trade(v_id);
  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload) values(league,auth.uid(),case when p_counter_of is null then 'TRADE_PROPOSED' else 'TRADE_COUNTERED' end,'trade',v_id,jsonb_build_object('counter_of',p_counter_of));
  return v_id;
end;
$$;
create or replace function public.propose_trade(p_season_id uuid,p_from_team_id uuid,p_to_team_id uuid,p_items jsonb)
returns uuid language sql security definer set search_path='' as $$ select private.create_trade(p_season_id,p_from_team_id,p_to_team_id,p_items); $$;
create or replace function public.counter_trade(p_trade_id uuid,p_items jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare t public.trades%rowtype; v_id uuid;
begin
  select * into t from public.trades where id=p_trade_id for update;
  if t.id is null or t.status<>'PENDING' then raise exception 'Trade is no longer available'; end if;
  if auth.uid() is null or not exists(select 1 from public.teams where id=t.recipient_team_id and owner_user_id=auth.uid()) then raise exception 'Only the recipient can counter this trade'; end if;
  v_id:=private.create_trade(t.season_id,t.recipient_team_id,t.proposer_team_id,p_items,t.id);
  update public.trades set status='COUNTERED',resolved_at=now() where id=t.id;
  return v_id;
end;
$$;

CREATE OR REPLACE FUNCTION public.accept_trade(p_trade_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
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
  ) then
    raise exception 'Only the recipient can accept this trade';
  end if;

  if exists (
    select 1
    from public.seasons s
    where s.id=v_trade.season_id
      and s.trade_deadline is not null
      and now()>s.trade_deadline
  ) then raise exception 'The trade deadline has passed'; end if;

  perform private.validate_trade(p_trade_id);

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
$function$;

CREATE OR REPLACE FUNCTION public.decline_trade(p_trade_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_trade public.trades%rowtype;
  v_league_id uuid;
begin
  select * into v_trade
  from public.trades
  where id=p_trade_id
  for update;

  if v_trade.id is null or v_trade.status<>'PENDING' then
    raise exception 'Trade is no longer available';
  end if;

  select league_id into v_league_id
  from public.teams
  where id=v_trade.recipient_team_id;

  if not exists (
    select 1
    from public.teams
    where id=v_trade.recipient_team_id
      and owner_user_id=(select auth.uid())
  ) then
    raise exception 'Only the recipient can decline this trade';
  end if;

  update public.trades
  set status='DECLINED',
      resolved_at=now()
  where id=p_trade_id;

  insert into public.audit_log(
    league_id,actor_user_id,action_type,entity_type,entity_id,payload
  )
  values(
    v_league_id,(select auth.uid()),'TRADE_DECLINED','trade',p_trade_id,'{}'::jsonb
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.claim_waiver_asset(p_team_id uuid, p_asset_id uuid, p_drop_asset_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_user_id uuid := (select auth.uid());
  v_league_id uuid;
  v_season_id uuid;
  v_roster_limit int;
  v_roster_count int;
  v_missing_after int;
  v_remaining_after int;
  v_transaction_id uuid;
  v_lineup text;
  v_active_limit int;
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

  perform 1 from public.drafts where season_id=v_season_id for update;
  if exists(select 1 from public.drafts where season_id=v_season_id and status in('LIVE','PAUSED')) then raise exception 'Pool additions are available after the draft finishes'; end if;
  perform 1 from public.teams where id=p_team_id for update;
  if not exists(select 1 from public.assets where id=p_asset_id and sport=any(private.required_sports())) then raise exception 'Asset sport is not part of this league'; end if;
  if exists(select 1 from public.scoring_event_assets sea join public.scoring_events se on se.id=sea.scoring_event_id where sea.asset_id=p_asset_id and se.season_id=v_season_id and now()>=se.locks_at and (se.occurred_at is null or now()<=se.occurred_at)) then raise exception 'This asset is currently locked'; end if;
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

    select lineup_status into v_lineup from public.roster_memberships where season_id=v_season_id and team_id=p_team_id and asset_id=p_drop_asset_id;
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

  select active_slots into v_active_limit from public.leagues where id=v_league_id;
  v_lineup:=coalesce(v_lineup,case when (select count(*) from public.roster_memberships where season_id=v_season_id and team_id=p_team_id and lineup_status='ACTIVE')<v_active_limit then 'ACTIVE' else 'BENCH' end);
  insert into public.roster_memberships(
    season_id,team_id,asset_id,lineup_status,acquired_at
  ) values (
    v_season_id,p_team_id,p_asset_id,v_lineup,now()
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
$function$;

revoke all on function private.validate_trade(uuid),private.create_trade(uuid,uuid,uuid,jsonb,uuid) from public,anon,authenticated;
revoke all on function public.propose_trade(uuid,uuid,uuid,jsonb),public.counter_trade(uuid,jsonb),public.ensure_future_draft_picks(uuid) from public,anon;
grant execute on function public.propose_trade(uuid,uuid,uuid,jsonb),public.counter_trade(uuid,jsonb),public.ensure_future_draft_picks(uuid) to authenticated;
