-- 014_scoring_version_v1_2.sql
-- Promote finalized Scoring Engine v1.2 to the live/default league scoring version.

update public.seasons
set scoring_version='v1.2'
where scoring_version='v1.0';

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
  values(v_league_id,coalesce(nullif(btrim(p_season_label),''),'2026-27'),
         coalesce(nullif(btrim(p_scoring_version),''),'v1.2'),'SETUP')
  returning id into v_season_id;

  insert into public.drafts(season_id,status,pick_timer_seconds,rounds,current_overall_pick)
  values(v_season_id,'SCHEDULED',90,17,1)
  returning id into v_draft_id;

  insert into public.audit_log(league_id,actor_user_id,action_type,entity_type,entity_id,payload)
  values(v_league_id,v_user_id,'LEAGUE_CREATED','league',v_league_id,
    jsonb_build_object('team_id',v_team_id,'season_id',v_season_id,'draft_id',v_draft_id));

  return jsonb_build_object(
    'league_id',v_league_id,'team_id',v_team_id,'season_id',v_season_id,
    'draft_id',v_draft_id,'join_code',v_code
  );
end;
$$;

revoke all on function public.create_league(text,text,text,text) from public;
revoke all on function public.create_league(text,text,text,text) from anon;
grant execute on function public.create_league(text,text,text,text) to authenticated;
