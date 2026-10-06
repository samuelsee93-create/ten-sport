-- 023_replace_super_league_with_super_rugby_pacific.sql
-- Correct rugby competition: Super Rugby Pacific replaces Super League Rugby.
-- 2026 is historical; 2027 current draft pool contains the 10 confirmed teams.

create or replace function private.required_sports()
returns text[]
language sql
immutable
set search_path=pg_catalog
as $$
  select array[
    'NHL','NFL','F1','Golf','NBA','MLB','UCL','NCAA','Super Rugby Pacific','Tennis'
  ]::text[];
$$;

delete from public.competition_editions where sport='Super League Rugby';
delete from public.assets where sport='Super League Rugby';

insert into public.assets(sport,external_key,name,asset_type,active)
values
('Super Rugby Pacific','blues','Blues','TEAM',true),
('Super Rugby Pacific','act-brumbies','ACT Brumbies','TEAM',true),
('Super Rugby Pacific','chiefs','Chiefs','TEAM',true),
('Super Rugby Pacific','crusaders','Crusaders','TEAM',true),
('Super Rugby Pacific','fijian-drua','Fijian Drua','TEAM',true),
('Super Rugby Pacific','highlanders','Highlanders','TEAM',true),
('Super Rugby Pacific','hurricanes','Hurricanes','TEAM',true),
('Super Rugby Pacific','nsw-waratahs','NSW Waratahs','TEAM',true),
('Super Rugby Pacific','queensland-reds','Queensland Reds','TEAM',true),
('Super Rugby Pacific','western-force','Western Force','TEAM',true),
('Super Rugby Pacific','moana-pasifika','Moana Pasifika','TEAM',false)
on conflict (sport,external_key) do update
set name=excluded.name,asset_type='TEAM',active=excluded.active;

insert into public.competition_editions(sport,label,status,source_ref,starts_on,ends_on)
values
('Super Rugby Pacific','2026','COMPLETE','https://super.rugby/superrugby/','2026-02-13','2026-06-20'),
('Super Rugby Pacific','2027','UPCOMING','https://super.rugby/superrugby/teams/','2027-02-12','2027-06-26')
on conflict (sport,label) do update
set status=excluded.status,source_ref=excluded.source_ref,starts_on=excluded.starts_on,ends_on=excluded.ends_on;

insert into public.competition_entries(edition_id,asset_id,draftable,entry_status,source_ref)
select e.id,a.id,false,'HISTORICAL','https://super.rugby/superrugby/fixtures/archives/2026-super-rugby-pacific/'
from public.competition_editions e
join public.assets a on a.sport='Super Rugby Pacific'
where e.sport='Super Rugby Pacific' and e.label='2026'
on conflict (edition_id,asset_id) do update
set draftable=false,entry_status='HISTORICAL',source_ref=excluded.source_ref;

insert into public.competition_entries(edition_id,asset_id,draftable,entry_status,source_ref)
select e.id,a.id,true,'CONFIRMED','https://super.rugby/superrugby/teams/'
from public.competition_editions e
join public.assets a on a.sport='Super Rugby Pacific' and a.active=true
where e.sport='Super Rugby Pacific' and e.label='2027'
on conflict (edition_id,asset_id) do update
set draftable=true,entry_status='CONFIRMED',source_ref=excluded.source_ref;

insert into public.asset_season_stats(asset_id,season_label,scoring_version,points,rank,source_ref,breakdown)
values
((select id from public.assets where sport='Super Rugby Pacific' and external_key='hurricanes'),'2026','v1.2',979.17,null,'https://super.rugby/superrugby/',jsonb_build_object('regular_season_wins',11,'regular_season_win_points',229.17,'regular_season_finish',1,'placement_points',150,'playoff_wins',3,'playoff_win_points',200,'advancement_points',150,'championship_points',250,'champion',true)),
((select id from public.assets where sport='Super Rugby Pacific' and external_key='chiefs'),'2026','v1.2',651.17,null,'https://super.rugby/superrugby/',jsonb_build_object('regular_season_wins',11,'regular_season_win_points',229.17,'regular_season_finish',2,'placement_points',122,'playoff_wins',2,'playoff_win_points',200,'advancement_points',100,'championship_points',0,'runner_up',true,'champion',false)),
((select id from public.assets where sport='Super Rugby Pacific' and external_key='crusaders'),'2026','v1.2',420.67,null,'https://super.rugby/superrugby/',jsonb_build_object('regular_season_wins',8,'regular_season_win_points',166.67,'regular_season_finish',3,'placement_points',94,'playoff_wins',1,'playoff_win_points',100,'advancement_points',60,'championship_points',0,'champion',false)),
((select id from public.assets where sport='Super Rugby Pacific' and external_key='blues'),'2026','v1.2',292.67,null,'https://super.rugby/superrugby/',jsonb_build_object('regular_season_wins',8,'regular_season_win_points',166.67,'regular_season_finish',4,'placement_points',66,'playoff_wins',0,'playoff_win_points',0,'advancement_points',60,'championship_points',0,'lucky_loser_semifinal',true,'champion',false)),
((select id from public.assets where sport='Super Rugby Pacific' and external_key='queensland-reds'),'2026','v1.2',229.67,null,'https://super.rugby/superrugby/',jsonb_build_object('regular_season_wins',8,'regular_season_win_points',166.67,'regular_season_finish',5,'placement_points',38,'playoff_wins',0,'playoff_win_points',0,'advancement_points',25,'championship_points',0,'champion',false)),
((select id from public.assets where sport='Super Rugby Pacific' and external_key='act-brumbies'),'2026','v1.2',180.83,null,'https://super.rugby/superrugby/',jsonb_build_object('regular_season_wins',7,'regular_season_win_points',145.83,'regular_season_finish',6,'placement_points',10,'playoff_wins',0,'playoff_win_points',0,'advancement_points',25,'championship_points',0,'champion',false)),
((select id from public.assets where sport='Super Rugby Pacific' and external_key='western-force'),'2026','v1.2',145.83,null,'https://super.rugby/superrugby/',jsonb_build_object('regular_season_wins',7,'regular_season_win_points',145.83,'regular_season_finish',7,'placement_points',0,'playoff_wins',0,'playoff_win_points',0,'advancement_points',0,'championship_points',0,'champion',false)),
((select id from public.assets where sport='Super Rugby Pacific' and external_key='nsw-waratahs'),'2026','v1.2',104.17,null,'https://super.rugby/superrugby/',jsonb_build_object('regular_season_wins',5,'regular_season_win_points',104.17,'regular_season_finish',8,'placement_points',0,'playoff_wins',0,'playoff_win_points',0,'advancement_points',0,'championship_points',0,'champion',false)),
((select id from public.assets where sport='Super Rugby Pacific' and external_key='highlanders'),'2026','v1.2',104.17,null,'https://super.rugby/superrugby/',jsonb_build_object('regular_season_wins',5,'regular_season_win_points',104.17,'regular_season_finish',9,'placement_points',0,'playoff_wins',0,'playoff_win_points',0,'advancement_points',0,'championship_points',0,'champion',false)),
((select id from public.assets where sport='Super Rugby Pacific' and external_key='fijian-drua'),'2026','v1.2',104.17,null,'https://super.rugby/superrugby/',jsonb_build_object('regular_season_wins',5,'regular_season_win_points',104.17,'regular_season_finish',10,'placement_points',0,'playoff_wins',0,'playoff_win_points',0,'advancement_points',0,'championship_points',0,'champion',false)),
((select id from public.assets where sport='Super Rugby Pacific' and external_key='moana-pasifika'),'2026','v1.2',41.67,null,'https://super.rugby/superrugby/',jsonb_build_object('regular_season_wins',2,'regular_season_win_points',41.67,'regular_season_finish',11,'placement_points',0,'playoff_wins',0,'playoff_win_points',0,'advancement_points',0,'championship_points',0,'champion',false))
on conflict (asset_id,season_label,scoring_version) do update
set points=excluded.points,source_ref=excluded.source_ref,breakdown=excluded.breakdown,updated_at=now();

with ranked as (
  select ass.id as stat_id, rank() over(order by ass.points desc)::int as calculated_rank
  from public.asset_season_stats ass
  join public.assets a on a.id=ass.asset_id
  where a.sport='Super Rugby Pacific' and ass.season_label='2026' and ass.scoring_version='v1.2'
)
update public.asset_season_stats ass
set rank=ranked.calculated_rank,updated_at=now()
from ranked where ranked.stat_id=ass.id;
