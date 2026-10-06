-- 016_keeper_escalation_and_pick_costs.sql
-- 0-3 keepers. Cost moves one round earlier per keeper year, maximum three years.
-- Keeper clock follows an asset through trades and resets only when the asset is redrafted.

alter table public.draft_selections
  add column if not exists selection_type text not null default 'DRAFT';

alter table public.draft_selections
  drop constraint if exists draft_selections_selection_type_check;

alter table public.draft_selections
  add constraint draft_selections_selection_type_check
  check (selection_type in ('DRAFT','KEEPER'));

alter table public.keeper_selections
  add column if not exists keeper_year int,
  add column if not exists original_draft_round int,
  add column if not exists cost_round int,
  add column if not exists forfeited_draft_pick_id uuid references public.draft_picks(id),
  add column if not exists source_draft_selection_id uuid references public.draft_selections(id);

alter table public.keeper_selections
  drop constraint if exists keeper_selections_keeper_year_check;

alter table public.keeper_selections
  add constraint keeper_selections_keeper_year_check
  check (keeper_year is null or keeper_year between 1 and 3);

alter table public.keeper_selections
  drop constraint if exists keeper_selections_round_checks;

alter table public.keeper_selections
  add constraint keeper_selections_round_checks
  check (
    (original_draft_round is null and cost_round is null)
    or
    (original_draft_round between 1 and 20 and cost_round between 1 and 20)
  );

create unique index if not exists keeper_forfeited_pick_unique_idx
  on public.keeper_selections(forfeited_draft_pick_id)
  where forfeited_draft_pick_id is not null;

create or replace function private.advance_draft_cursor(
  p_draft_id uuid
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_current int;
  v_total int;
  v_team_count int;
  v_rounds int;
begin
  select d.current_overall_pick,d.rounds,count(t.id)
  into v_current,v_rounds,v_team_count
  from public.drafts d
  join public.seasons s on s.id=d.season_id
  left join public.teams t on t.league_id=s.league_id
  where d.id=p_draft_id
  group by d.current_overall_pick,d.rounds;

  if v_current is null then return; end if;

  v_total := v_rounds*v_team_count;

  while v_current<=v_total and exists (
    select 1
    from public.draft_selections
    where draft_id=p_draft_id
      and overall_pick=v_current
  ) loop
    v_current := v_current+1;
  end loop;

  update public.drafts
  set current_overall_pick=v_current,
      status=case when v_current>v_total then 'COMPLETE' else status end
  where id=p_draft_id;
end;
$$;

create or replace function private.prevent_reserved_keeper_pick_trade()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if new.current_team_id is distinct from old.current_team_id
     and exists (
       select 1
       from public.keeper_selections
       where forfeited_draft_pick_id=old.id
     ) then
    raise exception 'This draft pick is reserved to pay for a keeper';
  end if;
  return new;
end;
$$;

drop trigger if exists prevent_reserved_keeper_pick_trade on public.draft_picks;

create trigger prevent_reserved_keeper_pick_trade
before update of current_team_id on public.draft_picks
for each row execute function private.prevent_reserved_keeper_pick_trade();

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
  v_source_selection_id uuid;
  v_source_selected_at timestamptz;
  v_original_round int;
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
    select 1
    from public.teams
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
    select 1
    from public.keeper_selections
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

  if v_count>=v_limit then
    raise exception 'Keeper limit reached';
  end if;

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

  select ds.id,ds.round,ds.selected_at
  into v_source_selection_id,v_original_round,v_source_selected_at
  from public.draft_selections ds
  join public.drafts d on d.id=ds.draft_id
  join public.seasons s on s.id=d.season_id
  where s.league_id=v_league_id
    and ds.asset_id=p_asset_id
    and ds.selection_type='DRAFT'
    and s.id<>p_season_id
  order by ds.selected_at desc
  limit 1;

  if v_source_selection_id is null then
    raise exception 'This asset has no draft round. Waiver-acquisition keeper cost is not defined yet';
  end if;

  select count(*) into v_prior_keeper_years
  from public.keeper_selections ks
  join public.seasons s on s.id=ks.season_id
  where s.league_id=v_league_id
    and s.status='COMPLETE'
    and ks.asset_id=p_asset_id
    and ks.created_at>v_source_selected_at;

  v_keeper_year := v_prior_keeper_years+1;

  if v_keeper_year>3 then
    raise exception 'This asset has reached the three-year keeper maximum';
  end if;

  v_cost_round := v_original_round-v_keeper_year;

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
    forfeited_draft_pick_id,source_draft_selection_id
  ) values (
    p_season_id,p_team_id,p_asset_id,v_keeper_year,v_original_round,v_cost_round,
    v_pick_id,v_source_selection_id
  );

  insert into public.audit_log(
    league_id,actor_user_id,action_type,entity_type,entity_id,payload
  ) values (
    v_league_id,(select auth.uid()),'KEEPER_SELECTED','asset',p_asset_id,
    jsonb_build_object(
      'team_id',p_team_id,
      'keeper_year',v_keeper_year,
      'original_draft_round',v_original_round,
      'cost_round',v_cost_round,
      'forfeited_draft_pick_id',v_pick_id
    )
  );

  return true;
end;
$$;

create or replace function private.prepare_keepers_for_draft(
  p_draft_id uuid
) returns void
language plpgsql
security definer
set search_path=public,private
as $$
declare
  v_draft public.drafts%rowtype;
  v_league_id uuid;
  v_team_count int;
  v_active_limit int;
  v_keeper record;
  v_pick public.draft_picks%rowtype;
  v_position int;
  v_overall int;
  v_active_count int;
  v_status text;
  v_draft_year int;
begin
  select * into v_draft
  from public.drafts
  where id=p_draft_id
  for update;

  if v_draft.id is null then raise exception 'Draft not found'; end if;

  v_draft_year := extract(year from v_draft.scheduled_at)::int;

  select s.league_id,l.active_slots
  into v_league_id,v_active_limit
  from public.seasons s
  join public.leagues l on l.id=s.league_id
  where s.id=v_draft.season_id;

  select count(*) into v_team_count
  from public.teams
  where league_id=v_league_id;

  for v_keeper in
    select *
    from public.keeper_selections
    where season_id=v_draft.season_id
      and locked_at is null
    order by cost_round,team_id,asset_id
    for update
  loop
    select * into v_pick
    from public.draft_picks
    where id=v_keeper.forfeited_draft_pick_id
    for update;

    if v_pick.id is null
       or v_pick.current_team_id<>v_keeper.team_id
       or v_pick.round<>v_keeper.cost_round
       or v_pick.draft_year<>v_draft_year
       or v_pick.slot is null then
      raise exception 'Keeper draft-pick reservation is no longer valid';
    end if;

    v_position := case
      when mod(v_pick.round,2)=1 then v_pick.slot
      else v_team_count-v_pick.slot+1
    end;

    v_overall := (v_pick.round-1)*v_team_count+v_position;

    if exists (
      select 1
      from public.draft_selections
      where draft_id=p_draft_id
        and overall_pick=v_overall
    ) then
      raise exception 'Keeper pick collides with an existing draft selection';
    end if;

    insert into public.draft_selections(
      draft_id,overall_pick,round,team_id,asset_id,draft_pick_id,selection_type
    ) values (
      p_draft_id,v_overall,v_pick.round,v_keeper.team_id,v_keeper.asset_id,
      v_pick.id,'KEEPER'
    );

    select count(*) filter(where lineup_status='ACTIVE')
    into v_active_count
    from public.roster_memberships
    where season_id=v_draft.season_id
      and team_id=v_keeper.team_id;

    v_status := case
      when v_active_count<v_active_limit then 'ACTIVE'
      else 'BENCH'
    end;

    insert into public.roster_memberships(
      season_id,team_id,asset_id,lineup_status,acquired_at
    ) values (
      v_draft.season_id,v_keeper.team_id,v_keeper.asset_id,v_status,now()
    )
    on conflict (season_id,asset_id) do nothing;

    update public.keeper_selections
    set locked_at=now()
    where id=v_keeper.id;
  end loop;

  perform private.advance_draft_cursor(p_draft_id);
end;
$$;

create or replace function public.set_draft_status(
  p_draft_id uuid,
  p_status text
) returns void
language plpgsql
security definer
set search_path=public,private
as $$
declare
  v_league_id uuid;
  v_scheduled_at timestamptz;
  v_team_count int;
  v_order_count int;
  v_existing_status text;
begin
  if p_status not in ('SCHEDULED','LOBBY','LIVE','PAUSED','COMPLETE') then
    raise exception 'Invalid draft status';
  end if;

  select s.league_id,d.scheduled_at,d.status
  into v_league_id,v_scheduled_at,v_existing_status
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
    from public.teams
    where league_id=v_league_id;

    select count(*) into v_order_count
    from public.draft_order
    where draft_id=p_draft_id;

    if v_order_count<>v_team_count then
      raise exception 'Set or randomize the complete draft order before starting the draft';
    end if;

    if v_existing_status in ('SCHEDULED','LOBBY') then
      perform private.prepare_keepers_for_draft(p_draft_id);
    end if;
  end if;

  update public.drafts
  set status=p_status
  where id=p_draft_id;

  insert into public.audit_log(
    league_id,actor_user_id,action_type,entity_type,entity_id,payload
  ) values (
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

  if not exists (
    select 1
    from public.teams
    where id=v_pick.current_team_id
      and owner_user_id=(select auth.uid())
  ) and not public.is_league_commissioner(v_season.league_id) then
    raise exception 'You are not on the clock';
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
      'lineup_status',v_lineup_status,
      'sport',v_asset_sport
    )
  );

  return v_selection;
end;
$$;

revoke all on function public.toggle_keeper(uuid,uuid,uuid) from public;
revoke all on function public.toggle_keeper(uuid,uuid,uuid) from anon;
grant execute on function public.toggle_keeper(uuid,uuid,uuid) to authenticated;

revoke all on function public.set_draft_status(uuid,text) from public;
revoke all on function public.set_draft_status(uuid,text) from anon;
grant execute on function public.set_draft_status(uuid,text) to authenticated;

revoke all on function public.make_draft_pick(uuid,uuid) from public;
revoke all on function public.make_draft_pick(uuid,uuid) from anon;
grant execute on function public.make_draft_pick(uuid,uuid) to authenticated;
