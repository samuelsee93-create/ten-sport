-- 003_account_and_manager_actions.sql
-- Auth/profile bootstrap and authenticated manager/commissioner mutations.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  insert into public.profiles(id,display_name,avatar_url)
  values(
    new.id,
    coalesce(new.raw_user_meta_data->>'display_name',split_part(new.email,'@',1),'Manager'),
    new.raw_user_meta_data->>'avatar_url'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.rename_team(p_team_id uuid,p_name text)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_league_id uuid;
  v_clean text := btrim(p_name);
begin
  if v_clean='' or char_length(v_clean)>60 then
    raise exception 'Team name must be between 1 and 60 characters';
  end if;

  select league_id into v_league_id
  from public.teams
  where id=p_team_id and owner_user_id=auth.uid()
  for update;

  if v_league_id is null then
    raise exception 'Not authorized for this team';
  end if;

  update public.teams set name=v_clean where id=p_team_id;

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(v_league_id,auth.uid(),'TEAM_RENAMED','team',p_team_id,jsonb_build_object('name',v_clean));
end;
$$;

create or replace function public.toggle_keeper(
  p_season_id uuid,
  p_team_id uuid,
  p_asset_id uuid
) returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_deadline timestamptz;
  v_limit int;
  v_count int;
  v_exists boolean;
  v_league_id uuid;
begin
  select s.keeper_deadline,l.keeper_slots,s.league_id
  into v_deadline,v_limit,v_league_id
  from public.seasons s
  join public.leagues l on l.id=s.league_id
  where s.id=p_season_id;

  if v_league_id is null then raise exception 'Season not found'; end if;

  if not exists (
    select 1 from public.teams
    where id=p_team_id and league_id=v_league_id and owner_user_id=auth.uid()
  ) and not public.is_league_commissioner(v_league_id) then
    raise exception 'Not authorized for this team';
  end if;

  if v_deadline is not null and now()>v_deadline then
    raise exception 'Keeper deadline has passed';
  end if;

  if not exists (
    select 1 from public.roster_memberships
    where season_id=p_season_id and team_id=p_team_id and asset_id=p_asset_id
  ) then raise exception 'Keeper must be on the current roster'; end if;

  select exists(
    select 1 from public.keeper_selections
    where season_id=p_season_id and team_id=p_team_id and asset_id=p_asset_id
  ) into v_exists;

  if v_exists then
    delete from public.keeper_selections
    where season_id=p_season_id and team_id=p_team_id and asset_id=p_asset_id;
    return false;
  end if;

  select count(*) into v_count
  from public.keeper_selections
  where season_id=p_season_id and team_id=p_team_id;

  if v_count>=v_limit then
    raise exception 'Keeper limit reached';
  end if;

  insert into public.keeper_selections(season_id,team_id,asset_id)
  values(p_season_id,p_team_id,p_asset_id);

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(v_league_id,auth.uid(),'KEEPER_SELECTED','asset',p_asset_id,jsonb_build_object('team_id',p_team_id));

  return true;
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
begin
  if p_status not in ('SCHEDULED','LOBBY','LIVE','PAUSED','COMPLETE') then
    raise exception 'Invalid draft status';
  end if;

  select s.league_id into v_league_id
  from public.drafts d join public.seasons s on s.id=d.season_id
  where d.id=p_draft_id
  for update;

  if v_league_id is null then raise exception 'Draft not found'; end if;
  if not public.is_league_commissioner(v_league_id) then
    raise exception 'Commissioner permission required';
  end if;

  update public.drafts set status=p_status where id=p_draft_id;

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(v_league_id,auth.uid(),'DRAFT_STATUS_CHANGED','draft',p_draft_id,jsonb_build_object('status',p_status));
end;
$$;

revoke all on function public.rename_team(uuid,text) from public;
revoke all on function public.toggle_keeper(uuid,uuid,uuid) from public;
revoke all on function public.set_draft_status(uuid,text) from public;

grant execute on function public.rename_team(uuid,text) to authenticated;
grant execute on function public.toggle_keeper(uuid,uuid,uuid) to authenticated;
grant execute on function public.set_draft_status(uuid,text) to authenticated;
