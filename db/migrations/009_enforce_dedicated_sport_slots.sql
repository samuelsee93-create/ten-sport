-- 009_enforce_dedicated_sport_slots.sql
-- Enforce one dedicated roster place for each Ten Sport category across drafts/trades.

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
begin
  if p_status not in ('SCHEDULED','LOBBY','LIVE','PAUSED','COMPLETE') then
    raise exception 'Invalid draft status';
  end if;

  select s.league_id,d.scheduled_at into v_league_id,v_scheduled_at
  from public.drafts d join public.seasons s on s.id=d.season_id
  where d.id=p_draft_id
  for update;

  if v_league_id is null then raise exception 'Draft not found'; end if;
  if not public.is_league_commissioner(v_league_id) then
    raise exception 'Commissioner permission required';
  end if;
  if p_status='LIVE' and v_scheduled_at is null then
    raise exception 'Set the draft date and time before starting the draft';
  end if;

  update public.drafts set status=p_status where id=p_draft_id;

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(v_league_id,(select auth.uid()),'DRAFT_STATUS_CHANGED','draft',p_draft_id,
         jsonb_build_object('status',p_status));
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
  select * into v_draft from public.drafts where id=p_draft_id for update;
  if v_draft.id is null or v_draft.status<>'LIVE' then raise exception 'Draft is not live'; end if;
  if v_draft.scheduled_at is null then raise exception 'Draft date and time are not set'; end if;

  select * into v_season from public.seasons where id=v_draft.season_id;
  select sport into v_asset_sport from public.assets where id=p_asset_id and active=true;
  if v_asset_sport is null then raise exception 'Asset is not draftable'; end if;
  if not (v_asset_sport=any(private.required_sports())) then raise exception 'Asset sport is not part of this league'; end if;

  select count(*) into v_team_count from public.teams where league_id=v_season.league_id;
  if v_team_count=0 then raise exception 'League has no teams'; end if;

  v_round := floor((v_draft.current_overall_pick-1)::numeric / v_team_count)::int + 1;
  if v_round>v_draft.rounds then raise exception 'Draft is complete'; end if;

  v_position := ((v_draft.current_overall_pick-1) % v_team_count) + 1;
  v_original_slot := case when mod(v_round,2)=1 then v_position else v_team_count-v_position+1 end;

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
    where id=v_pick.current_team_id and owner_user_id=(select auth.uid())
  ) and not public.is_league_commissioner(v_season.league_id) then
    raise exception 'You are not on the clock';
  end if;

  if exists (select 1 from public.draft_selections where draft_id=p_draft_id and asset_id=p_asset_id) then
    raise exception 'Asset has already been drafted';
  end if;
  if exists (select 1 from public.roster_memberships where season_id=v_draft.season_id and asset_id=p_asset_id) then
    raise exception 'Asset is already rostered';
  end if;

  select l.roster_size,l.active_slots into v_roster_limit,v_active_limit
  from public.leagues l where l.id=v_season.league_id;

  select count(*),count(*) filter (where lineup_status='ACTIVE')
  into v_roster_count,v_active_count
  from public.roster_memberships
  where season_id=v_draft.season_id and team_id=v_pick.current_team_id;

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
    raise exception 'This pick would make it impossible to fill all 10 dedicated sport roster spots';
  end if;

  v_lineup_status := case when v_active_count<v_active_limit then 'ACTIVE' else 'BENCH' end;

  insert into public.draft_selections(draft_id,overall_pick,round,team_id,asset_id,draft_pick_id)
  values(p_draft_id,v_draft.current_overall_pick,v_round,v_pick.current_team_id,p_asset_id,v_pick.id)
  returning * into v_selection;

  insert into public.roster_memberships(
    season_id,team_id,asset_id,lineup_status,acquired_at,roster_slot_type,roster_slot_sport
  ) values (
    v_draft.season_id,v_pick.current_team_id,p_asset_id,v_lineup_status,now(),'FLEX',null
  );

  perform private.normalize_roster_slots(v_draft.season_id,v_pick.current_team_id);

  update public.drafts
  set current_overall_pick=current_overall_pick+1,
      status=case when current_overall_pick>=rounds*v_team_count then 'COMPLETE' else status end
  where id=p_draft_id;

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(
    v_season.league_id,(select auth.uid()),'DRAFT_PICK_MADE','draft_selection',v_selection.id,
    jsonb_build_object('overall_pick',v_selection.overall_pick,'team_id',v_selection.team_id,
      'asset_id',p_asset_id,'lineup_status',v_lineup_status,'sport',v_asset_sport)
  );

  return v_selection;
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
  v_proposer_was_compliant boolean;
  v_recipient_was_compliant boolean;
  v_asset record;
  v_pick record;
begin
  select * into v_trade from public.trades where id=p_trade_id for update;
  if v_trade.id is null or v_trade.status<>'PENDING' then raise exception 'Trade is no longer available'; end if;

  select t.league_id into v_league_id from public.teams t where t.id=v_trade.recipient_team_id;

  if not exists (
    select 1 from public.teams
    where id=v_trade.recipient_team_id and owner_user_id=(select auth.uid())
  ) and not public.is_league_commissioner(v_league_id) then
    raise exception 'Only the recipient can accept this trade';
  end if;

  if exists (
    select 1 from public.seasons s
    where s.id=v_trade.season_id and s.trade_deadline is not null and now()>s.trade_deadline
  ) then raise exception 'The trade deadline has passed'; end if;

  select l.roster_size,l.active_slots into v_roster_limit,v_active_limit
  from public.seasons s join public.leagues l on l.id=s.league_id
  where s.id=v_trade.season_id;

  select count(*) into v_proposer_count from public.roster_memberships
  where season_id=v_trade.season_id and team_id=v_trade.proposer_team_id;
  select count(*) into v_recipient_count from public.roster_memberships
  where season_id=v_trade.season_id and team_id=v_trade.recipient_team_id;
  select count(*) into v_proposer_out from public.trade_items
  where trade_id=p_trade_id and side='PROPOSER' and item_type='ASSET';
  select count(*) into v_recipient_out from public.trade_items
  where trade_id=p_trade_id and side='RECIPIENT' and item_type='ASSET';

  if v_proposer_count-v_proposer_out+v_recipient_out>v_roster_limit
     or v_recipient_count-v_recipient_out+v_proposer_out>v_roster_limit then
    raise exception 'Trade would create an illegal roster size';
  end if;

  select not exists (
    select 1 from unnest(private.required_sports()) req(sport)
    where not exists (
      select 1 from public.roster_memberships rm join public.assets a on a.id=rm.asset_id
      where rm.season_id=v_trade.season_id and rm.team_id=v_trade.proposer_team_id and a.sport=req.sport
    )
  ) into v_proposer_was_compliant;

  select not exists (
    select 1 from unnest(private.required_sports()) req(sport)
    where not exists (
      select 1 from public.roster_memberships rm join public.assets a on a.id=rm.asset_id
      where rm.season_id=v_trade.season_id and rm.team_id=v_trade.recipient_team_id and a.sport=req.sport
    )
  ) into v_recipient_was_compliant;

  for v_asset in
    select ti.side,ti.asset_id from public.trade_items ti
    where ti.trade_id=p_trade_id and ti.item_type='ASSET'
    for update
  loop
    if v_asset.side='PROPOSER' then
      if not exists (
        select 1 from public.roster_memberships
        where season_id=v_trade.season_id and team_id=v_trade.proposer_team_id and asset_id=v_asset.asset_id
      ) then raise exception 'Proposer asset ownership changed'; end if;

      update public.roster_memberships
      set team_id=v_trade.recipient_team_id,lineup_status='BENCH',acquired_at=now(),
          roster_slot_type='FLEX',roster_slot_sport=null
      where season_id=v_trade.season_id and team_id=v_trade.proposer_team_id and asset_id=v_asset.asset_id;
    else
      if not exists (
        select 1 from public.roster_memberships
        where season_id=v_trade.season_id and team_id=v_trade.recipient_team_id and asset_id=v_asset.asset_id
      ) then raise exception 'Recipient asset ownership changed'; end if;

      update public.roster_memberships
      set team_id=v_trade.proposer_team_id,lineup_status='BENCH',acquired_at=now(),
          roster_slot_type='FLEX',roster_slot_sport=null
      where season_id=v_trade.season_id and team_id=v_trade.recipient_team_id and asset_id=v_asset.asset_id;
    end if;

    delete from public.keeper_selections where season_id=v_trade.season_id and asset_id=v_asset.asset_id;
  end loop;

  if v_proposer_was_compliant and exists (
    select 1 from unnest(private.required_sports()) req(sport)
    where not exists (
      select 1 from public.roster_memberships rm join public.assets a on a.id=rm.asset_id
      where rm.season_id=v_trade.season_id and rm.team_id=v_trade.proposer_team_id and a.sport=req.sport
    )
  ) then raise exception 'Trade would leave the proposer without a required sport'; end if;

  if v_recipient_was_compliant and exists (
    select 1 from unnest(private.required_sports()) req(sport)
    where not exists (
      select 1 from public.roster_memberships rm join public.assets a on a.id=rm.asset_id
      where rm.season_id=v_trade.season_id and rm.team_id=v_trade.recipient_team_id and a.sport=req.sport
    )
  ) then raise exception 'Trade would leave the recipient without a required sport'; end if;

  perform private.normalize_roster_slots(v_trade.season_id,v_trade.proposer_team_id);
  perform private.normalize_roster_slots(v_trade.season_id,v_trade.recipient_team_id);

  with active_needed as (
    select greatest(0,v_active_limit-count(*) filter(where lineup_status='ACTIVE'))::int as n
    from public.roster_memberships
    where season_id=v_trade.season_id and team_id=v_trade.proposer_team_id
  ),
  candidates as (
    select rm.id
    from public.roster_memberships rm
    where rm.season_id=v_trade.season_id
      and rm.team_id=v_trade.proposer_team_id
      and rm.lineup_status='BENCH'
      and not exists (
        select 1 from public.scoring_event_assets sea
        join public.scoring_events se on se.id=sea.scoring_event_id
        where sea.asset_id=rm.asset_id and se.season_id=v_trade.season_id
          and now()>=se.locks_at and (se.occurred_at is null or now()<=se.occurred_at)
      )
    order by rm.acquired_at desc,rm.id
    limit (select n from active_needed)
  )
  update public.roster_memberships rm set lineup_status='ACTIVE'
  where rm.id in (select id from candidates);

  with active_needed as (
    select greatest(0,v_active_limit-count(*) filter(where lineup_status='ACTIVE'))::int as n
    from public.roster_memberships
    where season_id=v_trade.season_id and team_id=v_trade.recipient_team_id
  ),
  candidates as (
    select rm.id
    from public.roster_memberships rm
    where rm.season_id=v_trade.season_id
      and rm.team_id=v_trade.recipient_team_id
      and rm.lineup_status='BENCH'
      and not exists (
        select 1 from public.scoring_event_assets sea
        join public.scoring_events se on se.id=sea.scoring_event_id
        where sea.asset_id=rm.asset_id and se.season_id=v_trade.season_id
          and now()>=se.locks_at and (se.occurred_at is null or now()<=se.occurred_at)
      )
    order by rm.acquired_at desc,rm.id
    limit (select n from active_needed)
  )
  update public.roster_memberships rm set lineup_status='ACTIVE'
  where rm.id in (select id from candidates);

  for v_pick in
    select ti.side,ti.draft_pick_id from public.trade_items ti
    where ti.trade_id=p_trade_id and ti.item_type='DRAFT_PICK'
    for update
  loop
    if v_pick.side='PROPOSER' then
      if not exists (select 1 from public.draft_picks where id=v_pick.draft_pick_id and current_team_id=v_trade.proposer_team_id)
      then raise exception 'Proposer draft-pick ownership changed'; end if;
      update public.draft_picks set current_team_id=v_trade.recipient_team_id where id=v_pick.draft_pick_id;
    else
      if not exists (select 1 from public.draft_picks where id=v_pick.draft_pick_id and current_team_id=v_trade.recipient_team_id)
      then raise exception 'Recipient draft-pick ownership changed'; end if;
      update public.draft_picks set current_team_id=v_trade.proposer_team_id where id=v_pick.draft_pick_id;
    end if;
  end loop;

  update public.trades set status='ACCEPTED',resolved_at=now() where id=p_trade_id;

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(v_league_id,(select auth.uid()),'TRADE_ACCEPTED','trade',p_trade_id,'{}'::jsonb);
end;
$$;
