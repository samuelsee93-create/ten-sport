-- 011_first_come_first_serve_waivers.sql
-- Immediate waiver/free-agent claims: first committed claim wins. No rolling priority or FAAB.

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
  order by label desc limit 1;

  if v_season_id is null then raise exception 'This league does not have an active season'; end if;

  perform 1 from public.assets where id=p_asset_id and active=true for update;
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
      where season_id=v_season_id and team_id=p_team_id and asset_id=p_drop_asset_id
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
    where season_id=v_season_id and team_id=p_team_id and asset_id=p_drop_asset_id;

    delete from public.roster_memberships
    where season_id=v_season_id and team_id=p_team_id and asset_id=p_drop_asset_id;

    v_roster_count := v_roster_count - 1;
  end if;

  if v_roster_count>=v_roster_limit then raise exception 'Roster is full'; end if;

  insert into public.roster_memberships(
    season_id,team_id,asset_id,lineup_status,acquired_at,roster_slot_type,roster_slot_sport
  ) values (
    v_season_id,p_team_id,p_asset_id,'BENCH',now(),'FLEX',null
  );

  perform private.normalize_roster_slots(v_season_id,p_team_id);

  select count(*) into v_missing_after
  from unnest(private.required_sports()) req(sport)
  where not exists (
    select 1
    from public.roster_memberships rm
    join public.assets a on a.id=rm.asset_id
    where rm.season_id=v_season_id and rm.team_id=p_team_id and a.sport=req.sport
  );

  select v_roster_limit-count(*) into v_remaining_after
  from public.roster_memberships
  where season_id=v_season_id and team_id=p_team_id;

  if v_remaining_after<v_missing_after then
    raise exception 'This move would make it impossible to fill all 10 dedicated sport roster spots';
  end if;

  insert into public.waiver_transactions(
    season_id,team_id,added_asset_id,dropped_asset_id,transaction_type
  ) values (
    v_season_id,p_team_id,p_asset_id,p_drop_asset_id,'WAIVER'
  ) returning id into v_transaction_id;

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

revoke all on function public.claim_waiver_asset(uuid,uuid,uuid) from public;
revoke all on function public.claim_waiver_asset(uuid,uuid,uuid) from anon;
grant execute on function public.claim_waiver_asset(uuid,uuid,uuid) to authenticated;
