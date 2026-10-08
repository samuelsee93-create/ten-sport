alter publication supabase_realtime add table public.keeper_designations;

create or replace function private.keeper_window(p_source_season_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('deadline',case when s.keeper_deadline is null then d.scheduled_at when d.scheduled_at is null then s.keeper_deadline else least(s.keeper_deadline,d.scheduled_at) end,
    'draftAt',d.scheduled_at,'started',coalesce(d.status in('LIVE','PAUSED','COMPLETE'),false),'targetSeasonId',s.id)
  from public.seasons source left join lateral (
    select next.* from public.seasons next where next.league_id=source.league_id and next.label>source.label order by next.label limit 1
  ) s on true left join public.drafts d on d.season_id=s.id where source.id=p_source_season_id;
$$;

create or replace function private.keeper_cost(p_source_season_id uuid,p_asset_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_league uuid; v_label text; v_source record; years int; cost int;
begin
  select league_id,label into v_league,v_label from public.seasons where id=p_source_season_id;
  select * into v_source from (
    select 'DRAFT'::text type,ds.selected_at acquired,ds.round from public.draft_selections ds join public.drafts d on d.id=ds.draft_id join public.seasons s on s.id=d.season_id where s.league_id=v_league and s.label<=v_label and ds.asset_id=p_asset_id and ds.selection_type='DRAFT'
    union all select 'WAIVER',wt.created_at,null::int from public.waiver_transactions wt join public.seasons s on s.id=wt.season_id where s.league_id=v_league and s.label<=v_label and wt.added_asset_id=p_asset_id
  ) src order by acquired desc limit 1;
  if v_source.type is null then return jsonb_build_object('reason','No eligible draft or waiver acquisition source'); end if;
  select count(*)+1 into years from public.keeper_selections ks join public.seasons s on s.id=ks.season_id where s.league_id=v_league and s.label<=v_label and ks.asset_id=p_asset_id and ks.locked_at is not null and ks.created_at>v_source.acquired;
  cost:=case when v_source.type='WAIVER' then 9-years else v_source.round-years end;
  return jsonb_build_object('keeperYear',years,'costRound',cost,'sourceType',v_source.type,
    'reason',case when years>3 then 'Three-year keeper maximum reached' when cost<1 then 'Keeper cost would be earlier than Round 1' else null end);
end;
$$;

create or replace function public.get_keeper_state(p_season_id uuid,p_team_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.seasons%rowtype; source public.seasons%rowtype; d public.drafts%rowtype; mode text; win jsonb; opts jsonb; selections jsonb;
begin
  select * into s from public.seasons where id=p_season_id;
  if auth.uid() is null or not public.is_league_member(s.league_id) or not exists(select 1 from public.teams where id=p_team_id and league_id=s.league_id and (owner_user_id=auth.uid() or public.is_league_commissioner(s.league_id))) then raise exception 'Not authorized for this team'; end if;
  select * into d from public.drafts where season_id=s.id;
  select * into source from public.seasons where league_id=s.league_id and label<s.label and status='COMPLETE' order by label desc limit 1;
  if source.id is not null and d.status in('SCHEDULED','LOBBY') then mode:='UPCOMING';
  else source:=s;mode:='NEXT'; end if;
  win:=private.keeper_window(source.id);
  select coalesce(jsonb_agg(jsonb_build_object('assetId',rm.asset_id,'teamId',rm.team_id)||private.keeper_cost(source.id,rm.asset_id)),'[]'::jsonb) into opts from public.roster_memberships rm join public.assets a on a.id=rm.asset_id and a.active where rm.season_id=source.id and rm.team_id=p_team_id;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'assetId',asset_id,'teamId',team_id)),'[]'::jsonb) into selections from public.keeper_designations where source_season_id=source.id and team_id=p_team_id;
  return jsonb_build_object('mode',mode,'sourceSeasonId',source.id,'sourceLabel',source.label,'deadline',win->'deadline','draftAt',win->'draftAt','closed',coalesce((win->>'started')::boolean,false) or ((win->>'deadline') is not null and now()>=(win->>'deadline')::timestamptz),'eligible',opts,'designations',selections);
end;
$$;

create or replace function public.toggle_keeper_designation(p_source_season_id uuid,p_team_id uuid,p_asset_id uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare league uuid; lim int; win jsonb; cost jsonb; target uuid; n int;
begin
  select s.league_id,l.keeper_slots into league,lim from public.seasons s join public.leagues l on l.id=s.league_id where s.id=p_source_season_id;
  if auth.uid() is null or not public.is_league_member(league) or not exists(select 1 from public.teams where id=p_team_id and league_id=league and owner_user_id=auth.uid()) then raise exception 'Not authorized for this team'; end if;
  win:=private.keeper_window(p_source_season_id);target:=(win->>'targetSeasonId')::uuid;
  perform 1 from public.drafts where season_id in(p_source_season_id,target) order by id for update;
  perform 1 from public.teams where id=p_team_id for update;
  win:=private.keeper_window(p_source_season_id);
  if (win->>'started')::boolean or (win->>'deadline' is not null and now()>=(win->>'deadline')::timestamptz) then raise exception 'Keeper deadline has passed or the next draft has started'; end if;
  delete from public.keeper_designations where source_season_id=p_source_season_id and team_id=p_team_id and asset_id=p_asset_id;
  if found then return false; end if;
  if not exists(select 1 from public.roster_memberships rm join public.assets a on a.id=rm.asset_id and a.active where rm.season_id=p_source_season_id and rm.team_id=p_team_id and rm.asset_id=p_asset_id) then raise exception 'Keeper must be on your roster'; end if;
  select count(*) into n from (
    select asset_id from public.keeper_designations where source_season_id=p_source_season_id and team_id=p_team_id
    union select asset_id from public.keeper_selections where season_id=target and team_id=p_team_id
  ) chosen;
  if n>=lim then raise exception 'Keeper limit reached'; end if;
  cost:=private.keeper_cost(p_source_season_id,p_asset_id);
  if cost->>'reason' is not null then raise exception '%',cost->>'reason'; end if;
  insert into public.keeper_designations(source_season_id,team_id,asset_id) values(p_source_season_id,p_team_id,p_asset_id);
  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload) values(league,auth.uid(),'KEEPER_DESIGNATED','asset',p_asset_id,jsonb_build_object('source_season_id',p_source_season_id,'team_id',p_team_id));
  return true;
end;
$$;

create or replace function private.clear_keeper_designation_on_roster_change()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_op='DELETE' or new.team_id is distinct from old.team_id or new.asset_id is distinct from old.asset_id or new.season_id is distinct from old.season_id then
    delete from public.keeper_designations where source_season_id=old.season_id and team_id=old.team_id and asset_id=old.asset_id;
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;
create trigger clear_keeper_designation_on_roster_change after update or delete on public.roster_memberships for each row execute function private.clear_keeper_designation_on_roster_change();


revoke all on function private.keeper_window(uuid),private.keeper_cost(uuid,uuid),private.clear_keeper_designation_on_roster_change() from public,anon,authenticated;
revoke all on function public.get_keeper_state(uuid,uuid),public.toggle_keeper_designation(uuid,uuid,uuid) from public,anon;
grant execute on function public.get_keeper_state(uuid,uuid),public.toggle_keeper_designation(uuid,uuid,uuid) to authenticated;
