-- 020_waiver_keeper_costs.sql
-- Waiver-acquired assets reset keeper cost to R8 -> R7 -> R6 over max three keeper years.

alter table public.keeper_selections
  add column if not exists keeper_source_type text,
  add column if not exists source_waiver_transaction_id uuid references public.waiver_transactions(id),
  add column if not exists source_acquired_at timestamptz;

alter table public.keeper_selections
  drop constraint if exists keeper_selections_source_type_check;

alter table public.keeper_selections
  add constraint keeper_selections_source_type_check
  check (keeper_source_type is null or keeper_source_type in ('DRAFT','WAIVER'));

alter table public.keeper_selections
  drop constraint if exists keeper_selections_round_checks;

alter table public.keeper_selections
  add constraint keeper_selections_round_checks
  check (
    cost_round is null
    or (
      cost_round between 1 and 20
      and (
        (keeper_source_type='DRAFT' and original_draft_round between 1 and 20)
        or
        (keeper_source_type='WAIVER' and original_draft_round is null)
        or
        keeper_source_type is null
      )
    )
  );

create index if not exists keeper_source_waiver_idx
  on public.keeper_selections(source_waiver_transaction_id);

create or replace function public.toggle_keeper(
  p_season_id uuid,
  p_team_id uuid,
  p_asset_id uuid
) returns boolean
language plpgsql
security definer
set search_path=public,private
as $$
declare
  v_deadline timestamptz;
  v_limit int;
  v_count int;
  v_exists boolean;
  v_league_id uuid;
  v_previous_season_id uuid;
  v_source_type text;
  v_source_id uuid;
  v_source_at timestamptz;
  v_original_round int;
  v_source_draft_selection_id uuid;
  v_source_waiver_transaction_id uuid;
  v_prior_keeper_years int;
  v_keeper_year int;
  v_cost_round int;
  v_draft_id uuid;
  v_scheduled_at timestamptz;
  v_draft_year int;
  v_pick_id uuid;
begin
  select s.keeper_deadline,l.keeper_slots,s.league_id
  into v_deadline,v_limit,v_league_id
  from public.seasons s
  join public.leagues l on l.id=s.league_id
  where s.id=p_season_id;

  if v_league_id is null then raise exception 'Season not found'; end if;

  if not exists (
    select 1 from public.teams
    where id=p_team_id
      and league_id=v_league_id
      and owner_user_id=(select auth.uid())
  ) and not public.is_league_commissioner(v_league_id) then
    raise exception 'Not authorized for this team';
  end if;

  if v_deadline is not null and now()>v_deadline then
    raise exception 'Keeper deadline has passed';
  end if;

  select exists(
    select 1 from public.keeper_selections
    where season_id=p_season_id
      and team_id=p_team_id
      and asset_id=p_asset_id
  ) into v_exists;

  if v_exists then
    delete from public.keeper_selections
    where season_id=p_season_id
      and team_id=p_team_id
      and asset_id=p_asset_id
      and locked_at is null;

    if found then
      insert into public.audit_log(
        league_id,actor_user_id,action_type,entity_type,entity_id,payload
      ) values (
        v_league_id,(select auth.uid()),'KEEPER_REMOVED','asset',p_asset_id,
        jsonb_build_object('team_id',p_team_id)
      );
      return false;
    end if;

    raise exception 'Keeper is already locked for the draft';
  end if;

  select count(*) into v_count
  from public.keeper_selections
  where season_id=p_season_id
    and team_id=p_team_id;

  if v_count>=v_limit then raise exception 'Keeper limit reached'; end if;

  select id into v_previous_season_id
  from public.seasons
  where league_id=v_league_id
    and id<>p_season_id
    and status='COMPLETE'
  order by label desc
  limit 1;

  if v_previous_season_id is null then
    raise exception 'This is the inaugural season; there are no keeper-eligible assets yet';
  end if;

  if not exists (
    select 1
    from public.roster_memberships
    where season_id=v_previous_season_id
      and team_id=p_team_id
      and asset_id=p_asset_id
  ) then
    raise exception 'Keeper must be on your final roster from the previous season';
  end if;

  select source_type,source_id,source_at,draft_round
  into v_source_type,v_source_id,v_source_at,v_original_round
  from (
    select
      'DRAFT'::text as source_type,
      ds.id as source_id,
      ds.selected_at as source_at,
      ds.round as draft_round
    from public.draft_selections ds
    join public.drafts d on d.id=ds.draft_id
    join public.seasons s on s.id=d.season_id
    where s.league_id=v_league_id
      and s.status='COMPLETE'
      and ds.asset_id=p_asset_id
      and ds.selection_type='DRAFT'

    union all

    select
      'WAIVER'::text as source_type,
      wt.id as source_id,
      wt.created_at as source_at,
      null::int as draft_round
    from public.waiver_transactions wt
    join public.seasons s on s.id=wt.season_id
    where s.league_id=v_league_id
      and s.status='COMPLETE'
      and wt.added_asset_id=p_asset_id
  ) sources
  order by source_at desc
  limit 1;

  if v_source_id is null then
    raise exception 'This asset has no eligible draft or waiver acquisition source';
  end if;

  if v_source_type='DRAFT' then
    v_source_draft_selection_id := v_source_id;
    v_source_waiver_transaction_id := null;
  else
    v_source_draft_selection_id := null;
    v_source_waiver_transaction_id := v_source_id;
  end if;

  select count(*) into v_prior_keeper_years
  from public.keeper_selections ks
  join public.seasons s on s.id=ks.season_id
  where s.league_id=v_league_id
    and s.status='COMPLETE'
    and ks.asset_id=p_asset_id
    and ks.created_at>v_source_at;

  v_keeper_year := v_prior_keeper_years+1;

  if v_keeper_year>3 then
    raise exception 'This asset has reached the three-year keeper maximum';
  end if;

  if v_source_type='WAIVER' then
    v_cost_round := 9-v_keeper_year;
    v_original_round := null;
  else
    v_cost_round := v_original_round-v_keeper_year;
  end if;

  if v_cost_round<1 then
    raise exception 'This asset cannot be kept because its required cost would be earlier than Round 1';
  end if;

  select id,scheduled_at
  into v_draft_id,v_scheduled_at
  from public.drafts
  where season_id=p_season_id;

  if v_draft_id is null then raise exception 'No draft is configured for this season'; end if;

  if v_scheduled_at is null then
    raise exception 'Set the draft date before selecting keepers';
  end if;

  v_draft_year := extract(year from v_scheduled_at)::int;

  select dp.id into v_pick_id
  from public.draft_picks dp
  where dp.league_id=v_league_id
    and dp.draft_year=v_draft_year
    and dp.round=v_cost_round
    and dp.current_team_id=p_team_id
    and not exists (
      select 1
      from public.keeper_selections ks
      where ks.forfeited_draft_pick_id=dp.id
    )
  order by
    case when dp.original_team_id=p_team_id then 0 else 1 end,
    dp.slot nulls last,
    dp.id
  limit 1
  for update;

  if v_pick_id is null then
    raise exception 'You need an available Round % draft pick to keep this asset',v_cost_round;
  end if;

  insert into public.keeper_selections(
    season_id,team_id,asset_id,keeper_year,original_draft_round,cost_round,
    forfeited_draft_pick_id,source_draft_selection_id,
    keeper_source_type,source_waiver_transaction_id,source_acquired_at
  ) values (
    p_season_id,p_team_id,p_asset_id,v_keeper_year,v_original_round,v_cost_round,
    v_pick_id,v_source_draft_selection_id,
    v_source_type,v_source_waiver_transaction_id,v_source_at
  );

  insert into public.audit_log(
    league_id,actor_user_id,action_type,entity_type,entity_id,payload
  ) values (
    v_league_id,(select auth.uid()),'KEEPER_SELECTED','asset',p_asset_id,
    jsonb_build_object(
      'team_id',p_team_id,
      'keeper_year',v_keeper_year,
      'keeper_source_type',v_source_type,
      'original_draft_round',v_original_round,
      'cost_round',v_cost_round,
      'forfeited_draft_pick_id',v_pick_id,
      'source_acquired_at',v_source_at
    )
  );

  return true;
end;
$$;

revoke all on function public.toggle_keeper(uuid,uuid,uuid) from public;
revoke all on function public.toggle_keeper(uuid,uuid,uuid) from anon;
grant execute on function public.toggle_keeper(uuid,uuid,uuid) to authenticated;
