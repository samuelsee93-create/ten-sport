-- 002_transactions.sql
-- Atomic server-side mutations for Ten Sport v0.4.

create or replace function public.set_lineup_status(
  p_season_id uuid,
  p_team_id uuid,
  p_asset_id uuid,
  p_status text
) returns void
language plpgsql
security definer
set search_path=public
as $$
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
$$;

create or replace function public.accept_trade(p_trade_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_trade public.trades%rowtype;
  v_league_id uuid;
  v_roster_limit int;
  v_proposer_count int;
  v_recipient_count int;
  v_proposer_out int;
  v_recipient_out int;
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
    select 1 from public.teams
    where id=v_trade.recipient_team_id and owner_user_id=auth.uid()
  ) and not public.is_league_commissioner(v_league_id) then
    raise exception 'Only the recipient can accept this trade';
  end if;

  if exists (
    select 1 from public.seasons s
    where s.id=v_trade.season_id
      and s.trade_deadline is not null
      and now()>s.trade_deadline
  ) then
    raise exception 'The trade deadline has passed';
  end if;

  select l.roster_size into v_roster_limit
  from public.seasons s join public.leagues l on l.id=s.league_id
  where s.id=v_trade.season_id;

  select count(*) into v_proposer_count
  from public.roster_memberships
  where season_id=v_trade.season_id and team_id=v_trade.proposer_team_id;

  select count(*) into v_recipient_count
  from public.roster_memberships
  where season_id=v_trade.season_id and team_id=v_trade.recipient_team_id;

  select count(*) into v_proposer_out
  from public.trade_items
  where trade_id=p_trade_id and side='PROPOSER' and item_type='ASSET';

  select count(*) into v_recipient_out
  from public.trade_items
  where trade_id=p_trade_id and side='RECIPIENT' and item_type='ASSET';

  if v_proposer_count-v_proposer_out+v_recipient_out > v_roster_limit
     or v_recipient_count-v_recipient_out+v_proposer_out > v_roster_limit then
    raise exception 'Trade would create an illegal roster size';
  end if;

  for v_asset in
    select ti.side,ti.asset_id
    from public.trade_items ti
    where ti.trade_id=p_trade_id and ti.item_type='ASSET'
    for update
  loop
    if v_asset.side='PROPOSER' then
      if not exists (
        select 1 from public.roster_memberships
        where season_id=v_trade.season_id
          and team_id=v_trade.proposer_team_id
          and asset_id=v_asset.asset_id
      ) then raise exception 'Proposer asset ownership changed'; end if;

      update public.roster_memberships
      set team_id=v_trade.recipient_team_id,lineup_status='BENCH',acquired_at=now()
      where season_id=v_trade.season_id
        and team_id=v_trade.proposer_team_id
        and asset_id=v_asset.asset_id;
    else
      if not exists (
        select 1 from public.roster_memberships
        where season_id=v_trade.season_id
          and team_id=v_trade.recipient_team_id
          and asset_id=v_asset.asset_id
      ) then raise exception 'Recipient asset ownership changed'; end if;

      update public.roster_memberships
      set team_id=v_trade.proposer_team_id,lineup_status='BENCH',acquired_at=now()
      where season_id=v_trade.season_id
        and team_id=v_trade.recipient_team_id
        and asset_id=v_asset.asset_id;
    end if;

    delete from public.keeper_selections
    where season_id=v_trade.season_id and asset_id=v_asset.asset_id;
  end loop;

  for v_pick in
    select ti.side,ti.draft_pick_id
    from public.trade_items ti
    where ti.trade_id=p_trade_id and ti.item_type='DRAFT_PICK'
    for update
  loop
    if v_pick.side='PROPOSER' then
      if not exists (
        select 1 from public.draft_picks
        where id=v_pick.draft_pick_id and current_team_id=v_trade.proposer_team_id
      ) then raise exception 'Proposer draft-pick ownership changed'; end if;

      update public.draft_picks
      set current_team_id=v_trade.recipient_team_id
      where id=v_pick.draft_pick_id;
    else
      if not exists (
        select 1 from public.draft_picks
        where id=v_pick.draft_pick_id and current_team_id=v_trade.recipient_team_id
      ) then raise exception 'Recipient draft-pick ownership changed'; end if;

      update public.draft_picks
      set current_team_id=v_trade.proposer_team_id
      where id=v_pick.draft_pick_id;
    end if;
  end loop;

  update public.trades
  set status='ACCEPTED',resolved_at=now()
  where id=p_trade_id;

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(v_league_id,auth.uid(),'TRADE_ACCEPTED','trade',p_trade_id,'{}'::jsonb);
end;
$$;

create or replace function public.make_draft_pick(
  p_draft_id uuid,
  p_asset_id uuid
) returns public.draft_selections
language plpgsql
security definer
set search_path=public
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
begin
  select * into v_draft
  from public.drafts
  where id=p_draft_id
  for update;

  if v_draft.id is null or v_draft.status<>'LIVE' then
    raise exception 'Draft is not live';
  end if;

  select * into v_season from public.seasons where id=v_draft.season_id;

  select count(*) into v_team_count
  from public.teams where league_id=v_season.league_id;

  if v_team_count=0 then raise exception 'League has no teams'; end if;

  v_round := floor((v_draft.current_overall_pick-1)::numeric / v_team_count)::int + 1;
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
    select 1 from public.teams
    where id=v_pick.current_team_id and owner_user_id=auth.uid()
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

  insert into public.draft_selections(
    draft_id,overall_pick,round,team_id,asset_id,draft_pick_id
  ) values (
    p_draft_id,v_draft.current_overall_pick,v_round,
    v_pick.current_team_id,p_asset_id,v_pick.id
  )
  returning * into v_selection;

  update public.drafts
  set current_overall_pick=current_overall_pick+1,
      status=case
        when current_overall_pick >= rounds*v_team_count then 'COMPLETE'
        else status
      end
  where id=p_draft_id;

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(
    v_season.league_id,auth.uid(),'DRAFT_PICK_MADE','draft_selection',v_selection.id,
    jsonb_build_object('overall_pick',v_selection.overall_pick,'team_id',v_selection.team_id,'asset_id',p_asset_id)
  );

  return v_selection;
end;
$$;

revoke all on function public.set_lineup_status(uuid,uuid,uuid,text) from public;
revoke all on function public.accept_trade(uuid) from public;
revoke all on function public.make_draft_pick(uuid,uuid) from public;

grant execute on function public.set_lineup_status(uuid,uuid,uuid,text) to authenticated;
grant execute on function public.accept_trade(uuid) to authenticated;
grant execute on function public.make_draft_pick(uuid,uuid) to authenticated;
