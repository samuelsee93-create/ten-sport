-- Authenticated RPC integration; fixtures and changes are always rolled back.
begin;
create temp table tx_context as select gen_random_uuid() league_id,gen_random_uuid() season_id,
  gen_random_uuid() team_a,gen_random_uuid() team_b,gen_random_uuid() team_c,
  (select id from public.profiles order by id limit 1) user_a,
  (select id from public.profiles order by id offset 1 limit 1) user_b,
  (select id from public.profiles order by id offset 2 limit 1) user_c;
create temp table tx_assets as select id,sport,row_number() over(partition by sport order by id) n from public.assets where active and sport=any(private.required_sports());
create temp table tx_values(key text primary key,id uuid);
create temp table tx_results(test text);
grant select on tx_context,tx_assets to authenticated;
grant select,insert,update on tx_values,tx_results to authenticated;
insert into public.leagues(id,name,commissioner_user_id,join_code) select league_id,'Trade test',user_a,upper(substr(replace(league_id::text,'-',''),1,8)) from tx_context;
insert into public.seasons(id,league_id,label,scoring_version,status) select season_id,league_id,'TEST_TRANSACTIONS','v1.2','ACTIVE' from tx_context;
insert into public.league_memberships(league_id,user_id,role) select league_id,u,r from tx_context cross join lateral(values(user_a,'COMMISSIONER'),(user_b,'MANAGER'),(user_c,'MANAGER')) x(u,r);
insert into public.teams(id,league_id,owner_user_id,name) select t,league_id,u,name from tx_context cross join lateral(values(team_a,user_a,'A'),(team_b,user_b,'B'),(team_c,user_c,'C')) x(t,u,name);
insert into public.drafts(season_id,scheduled_at,status,rounds) select season_id,'2026-08-01','COMPLETE',20 from tx_context;
insert into public.roster_memberships(season_id,team_id,asset_id,lineup_status)
select season_id,case when a.n<=2 then team_a else team_b end,a.id,
  case when row_number() over(partition by a.n<=2 order by sport,n)<=15 then 'ACTIVE' else 'BENCH' end
from tx_context cross join tx_assets a where n<=4;
select set_config('request.jwt.claim.sub',user_a::text,true) from tx_context;
set local role authenticated;
do $$ declare c record; a uuid; b uuid; p uuid; q uuid; t uuid; begin
  select * into c from tx_context;
  perform public.ensure_future_draft_picks(c.league_id);
  perform public.ensure_future_draft_picks(c.league_id);
  assert (select count(*)=40 from public.draft_picks where league_id=c.league_id and original_team_id=c.team_a),'Two future years of 20 picks should be provisioned once';
  select id into a from tx_assets where sport='F1' and n=1;
  select id into b from tx_assets where sport='F1' and n=3;
  select id into p from public.draft_picks where league_id=c.league_id and current_team_id=c.team_a and draft_year=2027 and round=1;
  select id into q from public.draft_picks where league_id=c.league_id and current_team_id=c.team_b and draft_year=2027 and round=2;
  t:=public.propose_trade(c.season_id,c.team_a,c.team_b,jsonb_build_array(
    jsonb_build_object('side','FROM','type','ASSET','assetId',a),jsonb_build_object('side','FROM','type','DRAFT_PICK','draftPickId',p),
    jsonb_build_object('side','TO','type','ASSET','assetId',b),jsonb_build_object('side','TO','type','DRAFT_PICK','draftPickId',q)));
  insert into tx_values values('proposal',t);
  assert (select count(*)=4 from public.trade_items where trade_id=t),'Proposal includes both assets and picks';
  begin perform public.accept_trade(t); raise exception 'Proposer accepted'; exception when others then if sqlerrm<>'Only the recipient can accept this trade' then raise; end if; end;
  begin perform public.propose_trade(c.season_id,c.team_b,c.team_a,'[]'::jsonb); raise exception 'Impersonated proposer'; exception when others then if sqlerrm<>'You do not own the proposing team' then raise; end if; end;
  begin perform private.validate_trade(t); raise exception 'Private validator accessible'; exception when insufficient_privilege then null; end;
  insert into tx_results values('future entitlements idempotent, two-sided proposal, ownership and recipient authorization');
end $$;
reset role;
select set_config('request.jwt.claim.sub',user_c::text,true) from tx_context;
set local role authenticated;
do $$ declare t uuid; begin
  select id into t from tx_values where key='proposal';
  begin perform public.decline_trade(t); raise exception 'Outsider denied'; exception when others then if sqlerrm<>'Only the recipient can decline this trade' then raise; end if; end;
  begin perform public.counter_trade(t,'[]'); raise exception 'Outsider countered'; exception when others then if sqlerrm<>'Only the recipient can counter this trade' then raise; end if; end;
end $$;
reset role;
select set_config('request.jwt.claim.sub',user_b::text,true) from tx_context;
set local role authenticated;
do $$ declare c record; t uuid; v uuid; a uuid; b uuid; p uuid; q uuid; begin
  select * into c from tx_context;select id into t from tx_values where key='proposal';
  select id into a from tx_assets where sport='F1' and n=2;
  select id into b from tx_assets where sport='F1' and n=4;
  select id into p from public.draft_picks where league_id=c.league_id and current_team_id=c.team_a and draft_year=2027 and round=1;
  select id into q from public.draft_picks where league_id=c.league_id and current_team_id=c.team_b and draft_year=2027 and round=2;
  -- Invalid counter must leave the original offer pending.
  begin perform public.counter_trade(t,'[]'); raise exception 'Empty counter accepted'; exception when others then if sqlerrm<>'Select at least one asset or pick on each side' then raise; end if; end;
  assert (select status='PENDING' from public.trades where id=t),'Invalid counter cannot consume original';
  v:=public.counter_trade(t,jsonb_build_array(jsonb_build_object('side','FROM','type','ASSET','assetId',b),jsonb_build_object('side','FROM','type','DRAFT_PICK','draftPickId',q),jsonb_build_object('side','TO','type','ASSET','assetId',a),jsonb_build_object('side','TO','type','DRAFT_PICK','draftPickId',p)));
  insert into tx_values values('counter',v);
  assert (select status='COUNTERED' from public.trades where id=t),'Original becomes countered';
  assert (select proposer_team_id=c.team_b and recipient_team_id=c.team_a and counter_of_trade_id=t from public.trades where id=v),'Counter reverses proposer and recipient';
  insert into tx_results values('outsider denied, invalid counter rollback, counter revises both rosters and swaps recipient');
end $$;
reset role;
select set_config('request.jwt.claim.sub',user_a::text,true) from tx_context;
set local role authenticated;
do $$ declare c record; t uuid; a uuid; b uuid; begin
  select * into c from tx_context;select id into t from tx_values where key='counter';
  select id into a from tx_assets where sport='F1' and n=2;select id into b from tx_assets where sport='F1' and n=4;
  perform public.accept_trade(t);
  assert (select status='ACCEPTED' from public.trades where id=t),'Counter accepted';
  assert (select team_id=c.team_b from public.roster_memberships where season_id=c.season_id and asset_id=a),'A asset goes to B';
  assert (select team_id=c.team_a from public.roster_memberships where season_id=c.season_id and asset_id=b),'B asset goes to A';
  assert (select current_team_id=c.team_b from public.draft_picks where league_id=c.league_id and original_team_id=c.team_a and draft_year=2027 and round=1),'A pick goes to B';
  assert (select current_team_id=c.team_a from public.draft_picks where league_id=c.league_id and original_team_id=c.team_b and draft_year=2027 and round=2),'B pick goes to A';
  assert (select count(*)=15 from public.roster_memberships where season_id=c.season_id and team_id=c.team_a and lineup_status='ACTIVE'),'Active capacity preserved';
  begin perform public.accept_trade(t);raise exception 'Double accepted'; exception when others then if sqlerrm<>'Trade is no longer available' then raise; end if; end;
  t:=public.propose_trade(c.season_id,c.team_a,c.team_b,jsonb_build_array(jsonb_build_object('side','FROM','type','ASSET','assetId',b),jsonb_build_object('side','TO','type','ASSET','assetId',a)));
  insert into tx_values values('denied',t);
  t:=public.propose_trade(c.season_id,c.team_a,c.team_b,jsonb_build_array(jsonb_build_object('side','FROM','type','ASSET','assetId',b),jsonb_build_object('side','TO','type','ASSET','assetId',a)));
  insert into tx_values values('stale',t);
  insert into tx_results values('accepted counter atomically exchanges assets and future picks; repeated acceptance denied');
end $$;
reset role;
select set_config('request.jwt.claim.sub',user_b::text,true) from tx_context;
set local role authenticated;
do $$ declare t uuid; begin
  select id into t from tx_values where key='denied';perform public.decline_trade(t);
  assert (select status='DECLINED' from public.trades where id=t),'Denied status persisted';
end $$;
reset role;
-- Ownership changes before acceptance must invalidate the entire exchange.
update public.roster_memberships set team_id=(select team_c from tx_context)
where season_id=(select season_id from tx_context) and asset_id=(select id from tx_assets where sport='F1' and n=2);
set local role authenticated;
do $$ declare c record; t uuid; begin
  select * into c from tx_context;select id into t from tx_values where key='stale';
  begin perform public.accept_trade(t);raise exception 'Stale accepted'; exception when others then if sqlerrm<>'Asset ownership has changed' then raise; end if; end;
  assert (select status='PENDING' from public.trades where id=t),'Failed acceptance leaves offer pending';
  assert (select team_id=c.team_a from public.roster_memberships where season_id=c.season_id and asset_id=(select id from tx_assets where sport='F1' and n=4)),'Failed acceptance cannot move the other asset';
  insert into tx_results values('decline preserves ownership; stale acceptance rolls back all items');
end $$;
reset role;
select set_config('request.jwt.claim.sub',user_a::text,true) from tx_context;
-- Lock a roster asset for an ongoing event.
insert into public.scoring_events(season_id,sport,event_type,label,locks_at) select season_id,'NBA','TEST','Trade and drop lock',now()-interval '1 minute' from tx_context;
insert into public.scoring_event_assets(scoring_event_id,asset_id) select se.id,a.id from public.scoring_events se cross join tx_assets a where se.season_id=(select season_id from tx_context) and a.sport='NBA' and a.n=1;
set local role authenticated;
do $$ declare c record; a uuid; b uuid; pool uuid; begin
  select * into c from tx_context;
  select id into a from tx_assets where sport='NBA' and n=1;select id into b from tx_assets where sport='NBA' and n=3;select id into pool from tx_assets where sport='NBA' and n=5;
  begin perform public.propose_trade(c.season_id,c.team_a,c.team_b,jsonb_build_array(jsonb_build_object('side','FROM','type','ASSET','assetId',a),jsonb_build_object('side','TO','type','ASSET','assetId',b)));raise exception 'Locked trade accepted';exception when others then if sqlerrm<>'An asset in this trade is currently locked' then raise; end if;end;
  begin perform public.claim_waiver_asset(c.team_a,pool);raise exception 'Full add accepted';exception when others then if sqlerrm<>'Roster is full; choose an asset to drop' then raise; end if;end;
  begin perform public.claim_waiver_asset(c.team_a,pool,a);raise exception 'Locked drop accepted';exception when others then if sqlerrm<>'The asset you are trying to drop is currently locked' then raise; end if;end;
  select id into a from tx_assets where sport='NBA' and n=2;
  perform public.claim_waiver_asset(c.team_a,pool,a);
  assert (select count(*)=20 from public.roster_memberships where season_id=c.season_id and team_id=c.team_a),'Add/drop keeps roster capacity';
  assert (select count(*)=15 from public.roster_memberships where season_id=c.season_id and team_id=c.team_a and lineup_status='ACTIVE'),'Replacement preserves active/bench slot';
  assert not exists(select 1 from public.roster_memberships where season_id=c.season_id and asset_id=a),'Dropped asset returns to pool';
  assert (select count(*)=1 from public.waiver_transactions where season_id=c.season_id and added_asset_id=pool and dropped_asset_id=a),'Add/drop logged';
  begin perform public.claim_waiver_asset(c.team_a,b,pool);raise exception 'Stolen add accepted';exception when others then if sqlerrm<>'Asset has already been claimed' then raise;end if;end;
  begin
    perform public.propose_trade(c.season_id,c.team_a,c.team_b,jsonb_build_array(
      jsonb_build_object('side','FROM','type','ASSET','assetId',(select id from tx_assets where sport='NHL' and n=1)),
      jsonb_build_object('side','FROM','type','ASSET','assetId',(select id from tx_assets where sport='NHL' and n=2)),
      jsonb_build_object('side','TO','type','ASSET','assetId',(select id from tx_assets where sport='NFL' and n=3)),
      jsonb_build_object('side','TO','type','ASSET','assetId',(select id from tx_assets where sport='NFL' and n=4))));
    raise exception 'Sport coverage violated';
  exception when others then if sqlerrm<>'Trade would prevent the roster from representing all 10 sports' then raise; end if; end;
  begin
    perform public.propose_trade(c.season_id,c.team_a,c.team_b,jsonb_build_array(
      jsonb_build_object('side','FROM','type','DRAFT_PICK','draftPickId',(select id from public.draft_picks where league_id=c.league_id and original_team_id=c.team_a and draft_year=2027 and round=3)),
      jsonb_build_object('side','FROM','type','DRAFT_PICK','draftPickId',(select id from public.draft_picks where league_id=c.league_id and original_team_id=c.team_a and draft_year=2027 and round=3)),
      jsonb_build_object('side','TO','type','DRAFT_PICK','draftPickId',(select id from public.draft_picks where league_id=c.league_id and original_team_id=c.team_b and draft_year=2027 and round=3))));
    raise exception 'Duplicate pick allowed';
  exception when others then if sqlerrm<>'Duplicate trade item' then raise; end if; end;
  insert into tx_results values('scoring locks protect trades and drops; full roster add/drop atomic, slot preserved, ownership protected, sport coverage and duplicate items validated');
end $$;
reset role;
select jsonb_agg(test) results from tx_results;
rollback;
