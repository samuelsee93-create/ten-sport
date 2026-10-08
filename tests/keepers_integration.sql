-- Temporary fixtures test actual authenticated RPCs; nothing is retained.
begin;
create temp table k_ctx as select gen_random_uuid() league_id,gen_random_uuid() source_id,gen_random_uuid() target_id,gen_random_uuid() source_draft,gen_random_uuid() target_draft,gen_random_uuid() team_a,gen_random_uuid() team_b,
(select id from public.profiles order by id limit 1) user_a,(select id from public.profiles order by id offset 1 limit 1) user_b;
create temp table k_assets as select id,row_number() over(order by id) n from public.assets where active and sport='NHL';
create temp table k_results(test text);
grant select on k_ctx,k_assets to authenticated;grant select,insert on k_results to authenticated;
insert into public.leagues(id,name,commissioner_user_id,join_code) select league_id,'Keeper test',user_a,upper(substr(replace(league_id::text,'-',''),1,8)) from k_ctx;
insert into public.seasons(id,league_id,label,scoring_version,status,keeper_deadline) select source_id,league_id,'2026-27','v1.2','ACTIVE',now()-interval '1 day' from k_ctx;
insert into public.league_memberships(league_id,user_id,role) select league_id,user_a,'COMMISSIONER' from k_ctx;
insert into public.league_memberships(league_id,user_id,role) select league_id,user_b,'MANAGER' from k_ctx;
insert into public.teams(id,league_id,owner_user_id,name) select team_a,league_id,user_a,'A' from k_ctx;
insert into public.teams(id,league_id,owner_user_id,name) select team_b,league_id,user_b,'B' from k_ctx;
insert into public.drafts(id,season_id,scheduled_at,status,rounds,current_overall_pick) select source_draft,source_id,now()-interval '1 day','COMPLETE',20,41 from k_ctx;
insert into public.draft_picks(league_id,draft_year,round,slot,original_team_id,current_team_id) select league_id,2026,n::int+3,1,team_a,team_a from k_ctx cross join k_assets where n<=5;
insert into public.draft_selections(draft_id,overall_pick,round,team_id,asset_id,draft_pick_id,selection_type,selected_at)
select source_draft,n::int,case when n=5 then 1 else n::int+3 end,team_a,a.id,p.id,'DRAFT',now()-interval '1 day' from k_ctx c cross join k_assets a join public.draft_picks p on p.round=a.n+3 where a.n<=5 and p.league_id=c.league_id;
insert into public.roster_memberships(season_id,team_id,asset_id,lineup_status) select source_id,team_a,id,'ACTIVE' from k_ctx cross join k_assets where n<=5;
select set_config('request.jwt.claim.sub',user_a::text,true) from k_ctx;set local role authenticated;
do $$ declare c record; a uuid; state jsonb; begin
select * into c from k_ctx;
for a in select id from k_assets where n<=3 loop assert public.toggle_keeper_designation(c.source_id,c.team_a,a),'Designate during first active season';end loop;
state:=public.get_keeper_state(c.source_id,c.team_a);
assert state->>'mode'='NEXT' and not (state->>'closed')::boolean,'Current draft deadline must not close next-draft designations';
assert jsonb_array_length(state->'designations')=3,'Three choices saved';
assert (select (x->>'costRound')::int=3 from jsonb_array_elements(state->'eligible') x where x->>'assetId'=(select id::text from k_assets where n=1)),'Next keeper cost uses original round minus one';
begin perform public.toggle_keeper_designation(c.source_id,c.team_a,(select id from k_assets where n=4));raise exception 'Fourth keeper allowed';exception when others then if sqlerrm<>'Keeper limit reached' then raise;end if;end;
assert not public.toggle_keeper_designation(c.source_id,c.team_a,(select id from k_assets where n=3)),'Remove designation';
begin perform public.toggle_keeper_designation(c.source_id,c.team_a,(select id from k_assets where n=5));raise exception 'Round one keeper allowed';exception when others then if sqlerrm<>'Keeper cost would be earlier than Round 1' then raise;end if;end;
perform public.toggle_keeper_designation(c.source_id,c.team_a,(select id from k_assets where n=4));
insert into k_results values('in-season first-year designation, editable without next draft date, three-keeper limit, round cost validation');
end $$;reset role;
select set_config('request.jwt.claim.sub',user_b::text,true) from k_ctx;set local role authenticated;
do $$ declare c record;begin select * into c from k_ctx;
assert (select count(*)=0 from public.keeper_designations),'Other managers cannot read private choices';
begin perform public.toggle_keeper_designation(c.source_id,c.team_a,(select id from k_assets where n=1));raise exception 'Other manager edited';exception when others then if sqlerrm<>'Not authorized for this team' then raise;end if;end;
begin insert into public.keeper_designations(source_season_id,team_id,asset_id) values(c.source_id,c.team_a,(select id from k_assets where n=5));raise exception 'Direct write allowed';exception when insufficient_privilege then null;end;
insert into k_results values('ownership, private reads, and direct-write permissions');end $$;reset role;
-- Trade away one nominated asset; dropping uses the same roster trigger.
update public.roster_memberships set team_id=(select team_b from k_ctx) where season_id=(select source_id from k_ctx) and asset_id=(select id from k_assets where n=4);
do $$ begin assert not exists(select 1 from public.keeper_designations where asset_id=(select id from k_assets where n=4) and source_season_id=(select source_id from k_ctx)),'Ownership change clears designation';end $$;
insert into public.seasons(id,league_id,label,scoring_version,status,keeper_deadline) select target_id,league_id,'2027-28','v1.2','SETUP',now()+interval '1 month' from k_ctx;
insert into public.drafts(id,season_id,scheduled_at,status,rounds) select target_draft,target_id,now()+interval '2 months','SCHEDULED',20 from k_ctx;
insert into public.draft_order(draft_id,team_id,slot) select target_draft,team_a,1 from k_ctx;
insert into public.draft_order(draft_id,team_id,slot) select target_draft,team_b,2 from k_ctx;
select set_config('request.jwt.claim.sub',user_a::text,true) from k_ctx;set local role authenticated;
do $$ declare c record;begin select * into c from k_ctx;perform public.finalize_season(c.source_id);perform public.set_draft_schedule(c.target_draft,now()+interval '1 year');
assert public.get_keeper_state(c.target_id,c.team_a)->>'mode'='UPCOMING','Next setup uses previous final roster';
assert jsonb_array_length(public.get_keeper_state(c.target_id,c.team_a)->'designations')=2,'Saved choices carry over';
end $$;reset role;
update public.seasons set keeper_deadline=now()-interval '1 minute' where id=(select target_id from k_ctx);
set local role authenticated;
do $$ declare c record;begin select * into c from k_ctx;
begin perform public.toggle_keeper_designation(c.source_id,c.team_a,(select id from k_assets where n=1));raise exception 'Late edit allowed';exception when others then if sqlerrm<>'Keeper deadline has passed or the next draft has started' then raise;end if;end;
-- Saved choices import at draft start even when their deadline already passed.
perform public.set_draft_status(c.target_draft,'LIVE');
assert (select count(*)=2 from public.keeper_selections where season_id=c.target_id and locked_at is not null),'Saved choices become locked formal keepers';
assert (select count(*)=2 from public.draft_selections where draft_id=c.target_draft and selection_type='KEEPER'),'Reserved picks turn into keeper selections';
assert (select count(*)=2 from public.roster_memberships where season_id=c.target_id and team_id=c.team_a),'Kept assets enter next roster';
begin perform public.toggle_keeper(c.target_id,c.team_a,(select id from k_assets where n=1));raise exception 'Live formal keeper changed';exception when others then if sqlerrm<>'Keepers cannot change after the draft starts' then raise;end if;end;
insert into k_results values('ownership cleanup, next-season carryover, deadline enforcement, automatic draft import and locked picks');
end $$;reset role;
select jsonb_agg(test) results from k_results;
rollback;
