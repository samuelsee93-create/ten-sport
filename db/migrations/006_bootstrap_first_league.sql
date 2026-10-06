-- 006_bootstrap_first_league.sql
-- Secure first-user bootstrap for a brand-new Ten Sport Supabase project.

-- Trigger-only auth bootstrap must not be exposed through the Data API.
revoke all on function public.handle_new_user() from public;
revoke all on function public.handle_new_user() from anon;
revoke all on function public.handle_new_user() from authenticated;

create or replace function public.bootstrap_first_league(
  p_league_name text default 'Ten Sport Fantasy League',
  p_team_name text default 'The Decathletes',
  p_season_label text default '2026-27',
  p_scoring_version text default 'v1.0'
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_league_id uuid;
  v_team_id uuid;
  v_season_id uuid;
  v_draft_id uuid;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if not exists (select 1 from public.profiles where id=v_user_id) then
    raise exception 'Profile not ready yet';
  end if;

  -- This RPC is intentionally one-time only for a fresh project.
  if exists (select 1 from public.leagues) then
    raise exception 'League already exists';
  end if;

  insert into public.leagues(
    name,commissioner_user_id,roster_size,active_slots,bench_slots,keeper_slots
  )
  values(
    coalesce(nullif(btrim(p_league_name),''),'Ten Sport Fantasy League'),
    v_user_id,20,15,5,3
  )
  returning id into v_league_id;

  insert into public.league_memberships(league_id,user_id,role,status)
  values(v_league_id,v_user_id,'COMMISSIONER','ACTIVE');

  insert into public.teams(league_id,owner_user_id,name)
  values(
    v_league_id,
    v_user_id,
    coalesce(nullif(btrim(p_team_name),''),'The Decathletes')
  )
  returning id into v_team_id;

  insert into public.seasons(
    league_id,label,scoring_version,status
  )
  values(
    v_league_id,
    coalesce(nullif(btrim(p_season_label),''),'2026-27'),
    coalesce(nullif(btrim(p_scoring_version),''),'v1.0'),
    'SETUP'
  )
  returning id into v_season_id;

  insert into public.drafts(
    season_id,status,pick_timer_seconds,rounds,current_overall_pick
  )
  values(v_season_id,'SCHEDULED',90,17,1)
  returning id into v_draft_id;

  insert into public.audit_log(
    league_id,actor_user_id,action_type,entity_type,entity_id,payload
  )
  values(
    v_league_id,v_user_id,'LEAGUE_BOOTSTRAPPED','league',v_league_id,
    jsonb_build_object(
      'team_id',v_team_id,
      'season_id',v_season_id,
      'draft_id',v_draft_id
    )
  );

  return jsonb_build_object(
    'league_id',v_league_id,
    'team_id',v_team_id,
    'season_id',v_season_id,
    'draft_id',v_draft_id
  );
end;
$$;

revoke all on function public.bootstrap_first_league(text,text,text,text) from public;
revoke all on function public.bootstrap_first_league(text,text,text,text) from anon;
grant execute on function public.bootstrap_first_league(text,text,text,text) to authenticated;
