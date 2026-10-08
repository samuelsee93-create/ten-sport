-- Runs against Supabase in one transaction. All fixture data is rolled back.
begin;
create temp table draft_test_context as
select gen_random_uuid() league_id,gen_random_uuid() season_id,gen_random_uuid() draft_id,
  gen_random_uuid() team_a,gen_random_uuid() team_b,
  (select id from public.profiles order by id limit 1) user_a,
  (select id from public.profiles order by id offset 1 limit 1) user_b;
create temp table draft_test_results(test text);
grant select on draft_test_context to authenticated;
grant insert,select on draft_test_results to authenticated;
insert into public.leagues(id,name,commissioner_user_id,join_code) select league_id,'Draft clock integration test',user_a,upper(substr(replace(league_id::text,'-',''),1,8)) from draft_test_context;
insert into public.seasons(id,league_id,label,scoring_version) select season_id,league_id,'TEST_DRAFT_CLOCK','v1.2' from draft_test_context;
insert into public.league_memberships(league_id,user_id,role) select league_id,user_a,'COMMISSIONER' from draft_test_context;
insert into public.league_memberships(league_id,user_id,role) select league_id,user_b,'MANAGER' from draft_test_context;
insert into public.teams(id,league_id,owner_user_id,name) select team_a,league_id,user_a,'A' from draft_test_context;
insert into public.teams(id,league_id,owner_user_id,name) select team_b,league_id,user_b,'B' from draft_test_context;
insert into public.drafts(id,season_id,scheduled_at,rounds,status) select draft_id,season_id,now(),20,'LOBBY' from draft_test_context;
insert into public.draft_order(draft_id,team_id,slot) select draft_id,team_a,1 from draft_test_context;
insert into public.draft_order(draft_id,team_id,slot) select draft_id,team_b,2 from draft_test_context;
insert into public.draft_picks(league_id,draft_year,round,slot,original_team_id,current_team_id)
select c.league_id,extract(year from now())::int,r,slot,team,team
from draft_test_context c cross join generate_series(1,20) r
cross join lateral (values(1,c.team_a),(2,c.team_b)) x(slot,team);

select set_config('request.jwt.claim.sub',user_a::text,true) from draft_test_context;
set local role authenticated;
do $$ declare c record; a uuid; old_deadline timestamptz; frozen int; begin
  select * into c from draft_test_context;
  perform public.set_draft_timer(c.draft_id,30);
  perform public.set_draft_status(c.draft_id,'LIVE');
  select pick_deadline_at into old_deadline from public.drafts where id=c.draft_id;
  assert old_deadline>clock_timestamp()+interval '25 seconds','Start must set deadline';
  assert not public.process_draft_timeout(c.draft_id,1),'Early timeout must do nothing';
  perform public.set_draft_status(c.draft_id,'PAUSED');
  select paused_seconds into frozen from public.drafts where id=c.draft_id;
  assert frozen>0 and frozen<=30,'Pause must freeze time';
  perform public.set_draft_status(c.draft_id,'LIVE');
  assert (select pick_deadline_at is not null and paused_seconds is null from public.drafts where id=c.draft_id),'Resume must restore deadline';
  perform public.set_draft_timer(c.draft_id,60);
  assert (select pick_deadline_at>clock_timestamp()+interval '55 seconds' from public.drafts where id=c.draft_id),'Timer edit must reset current pick';
  select id into a from public.assets where active and sport='NHL' order by name limit 1;
  perform public.make_draft_pick(c.draft_id,a);
  assert (select count(*)=1 from public.roster_memberships where season_id=c.season_id and team_id=c.team_a),'Manual queue/pool RPC adds to roster';
  assert not public.process_draft_timeout(c.draft_id,1),'Stale timeout must not advance next team';
  begin perform public.set_draft_timer(c.draft_id,0); raise exception 'Invalid timer accepted';
  exception when others then if sqlerrm='Invalid timer accepted' then raise; end if; end;
  insert into draft_test_results values('timer edit, pause/resume, manual pick, early/stale timeout');
end $$;
reset role;
select set_config('request.jwt.claim.sub',user_b::text,true) from draft_test_context;
set local role authenticated;
do $$ declare c record; begin
  select * into c from draft_test_context;
  begin perform public.set_draft_timer(c.draft_id,60); raise exception 'Manager changed timer';
  exception when others then if sqlerrm<>'Commissioner permission required' then raise; end if; end;
  begin perform private.auto_pick_expired(c.draft_id,2); raise exception 'Private auto pick accessible';
  exception when insufficient_privilege then null; end;
  insert into draft_test_results values('manager timer denial and private auto-pick permissions');
end $$;
reset role;

-- Queue-first timeout for B, then ranking fallback at snake pick #3 (also B).
do $$ declare c record; a uuid; expected uuid; begin
  select * into c from draft_test_context;
  select id into a from public.assets where active and sport='NFL' order by name desc limit 1;
  insert into public.draft_preferences(draft_id,user_id,asset_id,queue_position) values(c.draft_id,c.user_b,a,1);
  update public.drafts set pick_deadline_at=clock_timestamp()-interval '1 second' where id=c.draft_id;
  assert private.auto_pick_expired(c.draft_id,2),'Expired pick must be made';
  assert (select asset_id=a and auto_picked from public.draft_selections where draft_id=c.draft_id and overall_pick=2),'Queue must beat rank';
  assert not private.auto_pick_expired(c.draft_id,2),'Duplicate timeout must do nothing';
  select x.id into expected from public.assets x left join lateral (
    select st.points from public.asset_season_stats st where st.asset_id=x.id and st.scoring_version='v1.2'
    and st.season_label<>'TEST_DRAFT_CLOCK' order by season_label desc limit 1
  ) h on true where x.active and x.sport=any(private.required_sports())
    and not exists(select 1 from public.roster_memberships where season_id=c.season_id and asset_id=x.id)
  order by coalesce(h.points,0) desc,x.sport collate "C",x.name collate "C",x.id limit 1;
  update public.drafts set pick_deadline_at=clock_timestamp()-interval '1 second' where id=c.draft_id;
  assert private.auto_pick_expired(c.draft_id,3),'Fallback must draft';
  assert (select asset_id=expected and team_id=c.team_b from public.draft_selections where draft_id=c.draft_id and overall_pick=3),'Fallback must match rank and snake owner';
  insert into draft_test_results values('queue first, taken queue skipped, ranked fallback, duplicate timeout, snake order');
end $$;

-- A full roster has 15 active / 5 bench; swap remains atomic when the second asset is locked.
delete from public.roster_memberships where season_id=(select season_id from draft_test_context);
insert into public.roster_memberships(season_id,team_id,asset_id,lineup_status)
select c.season_id,c.team_a,a.id,case when row_number() over(order by a.id)<=15 then 'ACTIVE' else 'BENCH' end
from draft_test_context c cross join lateral (select id from public.assets where active order by id limit 20) a;
select set_config('request.jwt.claim.sub',user_a::text,true) from draft_test_context;
set local role authenticated;
do $$ declare c record; a uuid; b uuid; begin
  select * into c from draft_test_context;
  select asset_id into a from public.roster_memberships where season_id=c.season_id and lineup_status='ACTIVE' limit 1;
  select asset_id into b from public.roster_memberships where season_id=c.season_id and lineup_status='BENCH' limit 1;
  perform public.swap_lineup_assets(c.season_id,c.team_a,a,b);
  assert (select lineup_status='BENCH' from public.roster_memberships where season_id=c.season_id and asset_id=a),'Active goes to bench';
  assert (select count(*)=15 from public.roster_memberships where season_id=c.season_id and lineup_status='ACTIVE'),'Swap preserves active count';
  insert into draft_test_results values('full 15/5 roster swaps atomically');
end $$;
reset role;
insert into public.scoring_events(season_id,sport,event_type,label,locks_at)
select season_id,'NHL','TEST','Locked swap test',now()-interval '1 day' from draft_test_context;
insert into public.scoring_event_assets(scoring_event_id,asset_id)
select se.id,rm.asset_id from public.scoring_events se join public.roster_memberships rm on rm.season_id=se.season_id
where se.season_id=(select season_id from draft_test_context) and rm.lineup_status='BENCH' limit 1;
set local role authenticated;
do $$ declare c record; a uuid; b uuid; begin
  select * into c from draft_test_context;
  select asset_id into a from public.roster_memberships where season_id=c.season_id and lineup_status='ACTIVE' limit 1;
  select sea.asset_id into b from public.scoring_event_assets sea join public.scoring_events se on se.id=sea.scoring_event_id where se.season_id=c.season_id limit 1;
  begin perform public.swap_lineup_assets(c.season_id,c.team_a,a,b); raise exception 'Locked swap accepted';
  exception when others then if sqlerrm<>'Asset is locked for an active scoring event' then raise; end if; end;
  assert (select lineup_status='ACTIVE' from public.roster_memberships where season_id=c.season_id and asset_id=a),'First leg must roll back';
  insert into draft_test_results values('locked second asset rolls back both lineup changes');
end $$;
reset role;

-- Final spot must fill the missing sport, even when queue prefers NHL.
delete from public.roster_memberships where season_id=(select season_id from draft_test_context);
insert into public.roster_memberships(season_id,team_id,asset_id,lineup_status)
select c.season_id,c.team_a,a.id,'ACTIVE' from draft_test_context c cross join lateral (
  select distinct on(sport) id,sport from public.assets where active and sport=any(private.required_sports()) and sport<>'Tennis' order by sport,id
) a;
insert into public.roster_memberships(season_id,team_id,asset_id,lineup_status)
select c.season_id,c.team_a,a.id,case when row_number() over(order by a.id)<=6 then 'ACTIVE' else 'BENCH' end
from draft_test_context c cross join lateral (
  select id from public.assets a where active and sport='NHL' and not exists(select 1 from public.roster_memberships rm where rm.season_id=c.season_id and rm.asset_id=a.id) order by id limit 10
) a;
do $$ declare c record; a uuid; begin
  select * into c from draft_test_context;
  select id into a from public.assets a where active and sport='NHL' and not exists(select 1 from public.roster_memberships where season_id=c.season_id and asset_id=a.id) limit 1;
  insert into public.draft_preferences(draft_id,user_id,asset_id,queue_position) values(c.draft_id,c.user_a,a,1);
  update public.drafts set current_overall_pick=40 where id=c.draft_id;
  update public.drafts set pick_deadline_at=clock_timestamp()-interval '1 second' where id=c.draft_id;
  assert private.auto_pick_expired(c.draft_id,40),'Last pick must resolve';
  assert (select a.sport='Tennis' from public.draft_selections ds join public.assets a on a.id=ds.asset_id where ds.draft_id=c.draft_id and overall_pick=40),'Missing sport overrides ineligible queue';
  assert (select status='COMPLETE' and pick_deadline_at is null from public.drafts where id=c.draft_id),'Last pick completes draft and clears clock';
  insert into draft_test_results values('sport coverage overrides illegal queue and final pick completes draft');
end $$;
select jsonb_agg(test) as passed from draft_test_results;
rollback;
