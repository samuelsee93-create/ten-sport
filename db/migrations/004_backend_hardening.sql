-- 004_backend_hardening.sql
-- Ten Sport v0.4: browser Data API access, RLS hardening, manager action parity,
-- and roster consistency for trades/draft selections.

-- The browser only needs SELECT on league data. Sensitive writes remain RPC-only.
grant usage on schema public to authenticated;
grant select on table
  public.profiles,
  public.leagues,
  public.league_memberships,
  public.seasons,
  public.teams,
  public.assets,
  public.roster_memberships,
  public.lineup_events,
  public.scoring_events,
  public.scoring_event_assets,
  public.point_transactions,
  public.manager_point_transactions,
  public.keeper_selections,
  public.trades,
  public.trade_items,
  public.draft_picks,
  public.drafts,
  public.draft_selections,
  public.audit_log
to authenticated;

-- Restrict existing read/update policies to authenticated users explicitly.
alter policy profiles_self_read on public.profiles to authenticated;
alter policy profiles_self_update on public.profiles
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);
alter policy leagues_member_read on public.leagues to authenticated;
alter policy memberships_member_read on public.league_memberships to authenticated;
alter policy seasons_member_read on public.seasons to authenticated;
alter policy teams_member_read on public.teams to authenticated;
alter policy assets_authenticated_read on public.assets to authenticated;
alter policy roster_member_read on public.roster_memberships to authenticated;
alter policy lineup_member_read on public.lineup_events to authenticated;
alter policy scoring_member_read on public.scoring_events to authenticated;
alter policy scoring_assets_member_read on public.scoring_event_assets to authenticated;
alter policy point_member_read on public.point_transactions to authenticated;
alter policy manager_point_member_read on public.manager_point_transactions to authenticated;
alter policy keeper_member_read on public.keeper_selections to authenticated;
alter policy trades_member_read on public.trades to authenticated;
alter policy trade_items_member_read on public.trade_items to authenticated;
alter policy picks_member_read on public.draft_picks to authenticated;
alter policy drafts_member_read on public.drafts to authenticated;
alter policy selections_member_read on public.draft_selections to authenticated;
alter policy audit_member_read on public.audit_log to authenticated;

-- Helper functions are SECURITY DEFINER because they are used inside RLS. Do not
-- expose them to anon/PUBLIC; authenticated clients may execute them as needed
-- while the functions themselves still key authorization off auth.uid().
revoke all on function public.is_league_member(uuid) from public;
revoke all on function public.is_league_commissioner(uuid) from public;
grant execute on function public.is_league_member(uuid) to authenticated;
grant execute on function public.is_league_commissioner(uuid) to authenticated;

-- League members need to see one another's display names/avatars in the shared UI.
create or replace function public.shares_active_league(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select exists (
    select 1
    from public.league_memberships mine
    join public.league_memberships theirs
      on theirs.league_id=mine.league_id
    where mine.user_id=(select auth.uid())
      and mine.status='ACTIVE'
      and theirs.user_id=p_user_id
      and theirs.status='ACTIVE'
  )
  or exists (
    select 1
    from public.leagues l
    join public.league_memberships theirs
      on theirs.league_id=l.id
    where l.commissioner_user_id=(select auth.uid())
      and theirs.user_id=p_user_id
      and theirs.status='ACTIVE'
  );
$$;

revoke all on function public.shares_active_league(uuid) from public;
grant execute on function public.shares_active_league(uuid) to authenticated;

drop policy if exists profiles_league_member_read on public.profiles;
create policy profiles_league_member_read
on public.profiles
for select
to authenticated
using (public.shares_active_league(id));

-- Persist a team logo URL after the client uploads/chooses the image.
create or replace function public.set_team_logo_url(
  p_team_id uuid,
  p_logo_url text
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_league_id uuid;
  v_clean text := nullif(btrim(p_logo_url), '');
begin
  select league_id into v_league_id
  from public.teams
  where id=p_team_id
    and owner_user_id=(select auth.uid())
  for update;

  if v_league_id is null then
    raise exception 'Not authorized for this team';
  end if;

  if v_clean is not null
     and (char_length(v_clean)>2048 or v_clean !~* '^https://') then
    raise exception 'Team logo must be an HTTPS URL';
  end if;

  update public.teams
  set logo_url=v_clean
  where id=p_team_id;

  insert into public.audit_log(
    league_id,actor_user_id,action_type,entity_type,entity_id,payload
  )
  values(
    v_league_id,(select auth.uid()),'TEAM_LOGO_CHANGED','team',p_team_id,
    jsonb_build_object('logo_url',v_clean)
  );
end;
$$;

revoke all on function public.set_team_logo_url(uuid,text) from public;
grant execute on function public.set_team_logo_url(uuid,text) to authenticated;

-- Match the local/UI contract: the trade recipient can decline a pending trade.
create or replace function public.decline_trade(p_trade_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
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
  ) and not public.is_league_commissioner(v_league_id) then
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
$$;

revoke all on function public.decline_trade(uuid) from public;
grant execute on function public.decline_trade(uuid) to authenticated;

-- Recreate trade acceptance so both teams are normalized back toward the
-- league's 15 Active / 5 Bench shape after incoming assets initially land on Bench.
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
  v_active_limit int;
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
  ) then
    raise exception 'The trade deadline has passed';
  end if;

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

  if v_proposer_count-v_proposer_out+v_recipient_out > v_roster_limit
     or v_recipient_count-v_recipient_out+v_proposer_out > v_roster_limit then
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
      ) then
        raise exception 'Proposer asset ownership changed';
      end if;

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
      ) then
        raise exception 'Recipient asset ownership changed';
      end if;

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

  -- Fill open Active slots after the move. Newly acquired assets are preferred
  -- because their acquired_at timestamp was just refreshed.
  with active_needed as (
    select greatest(
      0,
      v_active_limit-count(*) filter (where lineup_status='ACTIVE')
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
    order by rm.acquired_at desc,rm.id
    limit (select n from active_needed)
  )
  update public.roster_memberships rm
  set lineup_status='ACTIVE'
  where rm.id in (select id from candidates);

  with active_needed as (
    select greatest(
      0,
      v_active_limit-count(*) filter (where lineup_status='ACTIVE')
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
        select 1
        from public.draft_picks
        where id=v_pick.draft_pick_id
          and current_team_id=v_trade.proposer_team_id
      ) then
        raise exception 'Proposer draft-pick ownership changed';
      end if;

      update public.draft_picks
      set current_team_id=v_trade.recipient_team_id
      where id=v_pick.draft_pick_id;
    else
      if not exists (
        select 1
        from public.draft_picks
        where id=v_pick.draft_pick_id
          and current_team_id=v_trade.recipient_team_id
      ) then
        raise exception 'Recipient draft-pick ownership changed';
      end if;

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
  )
  values(
    v_league_id,(select auth.uid()),'TRADE_ACCEPTED','trade',p_trade_id,'{}'::jsonb
  );
end;
$$;

-- A draft selection must also become an owned roster asset. Fill Active slots
-- first, then Bench, preserving the 20 total / 15 Active / 5 Bench league shape.
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
  v_roster_limit int;
  v_active_limit int;
  v_roster_count int;
  v_active_count int;
  v_lineup_status text;
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

  if v_team_count=0 then
    raise exception 'League has no teams';
  end if;

  v_round := floor((v_draft.current_overall_pick-1)::numeric / v_team_count)::int + 1;
  if v_round>v_draft.rounds then
    raise exception 'Draft is complete';
  end if;

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

  if v_pick.id is null then
    raise exception 'Draft slot is missing';
  end if;

  if not exists (
    select 1
    from public.teams
    where id=v_pick.current_team_id
      and owner_user_id=(select auth.uid())
  ) and not public.is_league_commissioner(v_season.league_id) then
    raise exception 'You are not on the clock';
  end if;

  if exists (
    select 1
    from public.draft_selections
    where draft_id=p_draft_id
      and asset_id=p_asset_id
  ) then
    raise exception 'Asset has already been drafted';
  end if;

  if exists (
    select 1
    from public.roster_memberships
    where season_id=v_draft.season_id
      and asset_id=p_asset_id
  ) then
    raise exception 'Asset is already rostered';
  end if;

  select l.roster_size,l.active_slots
  into v_roster_limit,v_active_limit
  from public.leagues l
  where l.id=v_season.league_id;

  select
    count(*),
    count(*) filter (where lineup_status='ACTIVE')
  into v_roster_count,v_active_count
  from public.roster_memberships
  where season_id=v_draft.season_id
    and team_id=v_pick.current_team_id;

  if v_roster_count>=v_roster_limit then
    raise exception 'Roster is full';
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
      status=case
        when current_overall_pick >= rounds*v_team_count then 'COMPLETE'
        else status
      end
  where id=p_draft_id;

  insert into public.audit_log(
    league_id,actor_user_id,action_type,entity_type,entity_id,payload
  )
  values(
    v_season.league_id,(select auth.uid()),'DRAFT_PICK_MADE',
    'draft_selection',v_selection.id,
    jsonb_build_object(
      'overall_pick',v_selection.overall_pick,
      'team_id',v_selection.team_id,
      'asset_id',p_asset_id,
      'lineup_status',v_lineup_status
    )
  );

  return v_selection;
end;
$$;

revoke all on function public.accept_trade(uuid) from public;
revoke all on function public.make_draft_pick(uuid,uuid) from public;
grant execute on function public.accept_trade(uuid) to authenticated;
grant execute on function public.make_draft_pick(uuid,uuid) to authenticated;
