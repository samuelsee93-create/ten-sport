-- 019_replace_six_nations_with_super_league_rugby.sql
-- Replace Six Nations with men's Super League Rugby and back-test the completed 2026 season.

create or replace function private.required_sports()
returns text[]
language sql
immutable
set search_path=pg_catalog
as $$
  select array[
    'NHL','NFL','F1','Golf','NBA','MLB','UCL','NCAA','Super League Rugby','Tennis'
  ]::text[];
$$;

delete from public.competition_editions
where sport='6 Nations';

delete from public.assets
where sport='6 Nations';

insert into public.assets(sport,external_key,name,asset_type,active)
values
('Super League Rugby','bradford-bulls','Bradford Bulls','TEAM',true),
('Super League Rugby','castleford-tigers','Castleford Tigers','TEAM',true),
('Super League Rugby','catalans-dragons','Catalans Dragons','TEAM',true),
('Super League Rugby','huddersfield-giants','Huddersfield Giants','TEAM',true),
('Super League Rugby','hull-fc','Hull FC','TEAM',true),
('Super League Rugby','hull-kr','Hull KR','TEAM',true),
('Super League Rugby','leeds-rhinos','Leeds Rhinos','TEAM',true),
('Super League Rugby','leigh-leopards','Leigh Leopards','TEAM',true),
('Super League Rugby','st-helens','St Helens','TEAM',true),
('Super League Rugby','toulouse-olympique','Toulouse Olympique','TEAM',true),
('Super League Rugby','wakefield-trinity','Wakefield Trinity','TEAM',true),
('Super League Rugby','warrington-wolves','Warrington Wolves','TEAM',true),
('Super League Rugby','wigan-warriors','Wigan Warriors','TEAM',true),
('Super League Rugby','york-knights','York Knights','TEAM',true)
on conflict (sport,external_key) do update
set name=excluded.name,
    asset_type='TEAM',
    active=true;

insert into public.competition_editions(
  sport,label,status,source_ref,starts_on,ends_on
)
values(
  'Super League Rugby',
  '2026',
  'COMPLETE',
  'https://www.superleague.co.uk/about',
  '2026-02-12',
  '2026-10-03'
)
on conflict (sport,label) do update
set status='COMPLETE',
    source_ref=excluded.source_ref,
    starts_on=excluded.starts_on,
    ends_on=excluded.ends_on;

insert into public.competition_entries(
  edition_id,asset_id,draftable,entry_status,source_ref
)
select
  e.id,a.id,false,'HISTORICAL','https://www.superleague.co.uk/standings'
from public.competition_editions e
join public.assets a on a.sport='Super League Rugby'
where e.sport='Super League Rugby'
  and e.label='2026'
on conflict (edition_id,asset_id) do update
set draftable=false,
    entry_status='HISTORICAL',
    source_ref=excluded.source_ref;

insert into public.asset_season_stats(
  asset_id,season_label,scoring_version,points,rank,source_ref,breakdown
)
values
((select id from public.assets where sport='Super League Rugby' and external_key='wigan-warriors'),'2026','v1.2',460.00,null,'https://www.superleague.co.uk/standings',jsonb_build_object('regular_season_wins',22,'regular_season_win_points',250.00,'regular_season_finish',1,'placement_points',150.00,'playoff_wins',0,'playoff_win_points',0,'advancement_points',60,'championship_points',0,'league_leaders_shield',true,'champion',false,'playoff_source','https://www.superleague.co.uk/')),
((select id from public.assets where sport='Super League Rugby' and external_key='leeds-rhinos'),'2026','v1.2',413.94,null,'https://www.superleague.co.uk/standings',jsonb_build_object('regular_season_wins',20,'regular_season_win_points',227.27,'regular_season_finish',2,'placement_points',126.67,'playoff_wins',0,'playoff_win_points',0,'advancement_points',60,'championship_points',0,'champion',false,'playoff_source','https://www.superleague.co.uk/')),
((select id from public.assets where sport='Super League Rugby' and external_key='warrington-wolves'),'2026','v1.2',630.61,null,'https://www.superleague.co.uk/standings',jsonb_build_object('regular_season_wins',20,'regular_season_win_points',227.27,'regular_season_finish',3,'placement_points',103.33,'playoff_wins',2,'playoff_win_points',200,'advancement_points',100,'championship_points',0,'runner_up',true,'champion',false,'playoff_source','https://www.superleague.co.uk/article/6698/trinity-are-2026-betfred-super-league-champions')),
((select id from public.assets where sport='Super League Rugby' and external_key='wakefield-trinity'),'2026','v1.2',895.91,null,'https://www.superleague.co.uk/standings',jsonb_build_object('regular_season_wins',19,'regular_season_win_points',215.91,'regular_season_finish',4,'placement_points',80.00,'playoff_wins',3,'playoff_win_points',200,'advancement_points',150,'championship_points',250,'champion',true,'playoff_source','https://www.superleague.co.uk/article/6698/trinity-are-2026-betfred-super-league-champions')),
((select id from public.assets where sport='Super League Rugby' and external_key='leigh-leopards'),'2026','v1.2',274.85,null,'https://www.superleague.co.uk/standings',jsonb_build_object('regular_season_wins',17,'regular_season_win_points',193.18,'regular_season_finish',5,'placement_points',56.67,'playoff_wins',0,'playoff_win_points',0,'advancement_points',25,'championship_points',0,'champion',false)),
((select id from public.assets where sport='Super League Rugby' and external_key='hull-kr'),'2026','v1.2',240.15,null,'https://www.superleague.co.uk/standings',jsonb_build_object('regular_season_wins',16,'regular_season_win_points',181.82,'regular_season_finish',6,'placement_points',33.33,'playoff_wins',0,'playoff_win_points',0,'advancement_points',25,'championship_points',0,'champion',false)),
((select id from public.assets where sport='Super League Rugby' and external_key='st-helens'),'2026','v1.2',180.45,null,'https://www.superleague.co.uk/standings',jsonb_build_object('regular_season_wins',15,'regular_season_win_points',170.45,'regular_season_finish',7,'placement_points',10.00,'playoff_wins',0,'playoff_win_points',0,'advancement_points',0,'championship_points',0,'champion',false)),
((select id from public.assets where sport='Super League Rugby' and external_key='toulouse-olympique'),'2026','v1.2',113.64,null,'https://www.superleague.co.uk/standings',jsonb_build_object('regular_season_wins',10,'regular_season_win_points',113.64,'regular_season_finish',8,'placement_points',0,'playoff_wins',0,'playoff_win_points',0,'advancement_points',0,'championship_points',0,'champion',false)),
((select id from public.assets where sport='Super League Rugby' and external_key='catalans-dragons'),'2026','v1.2',113.64,null,'https://www.superleague.co.uk/standings',jsonb_build_object('regular_season_wins',10,'regular_season_win_points',113.64,'regular_season_finish',9,'placement_points',0,'playoff_wins',0,'playoff_win_points',0,'advancement_points',0,'championship_points',0,'champion',false)),
((select id from public.assets where sport='Super League Rugby' and external_key='york-knights'),'2026','v1.2',102.27,null,'https://www.superleague.co.uk/standings',jsonb_build_object('regular_season_wins',9,'regular_season_win_points',102.27,'regular_season_finish',10,'placement_points',0,'playoff_wins',0,'playoff_win_points',0,'advancement_points',0,'championship_points',0,'champion',false)),
((select id from public.assets where sport='Super League Rugby' and external_key='hull-fc'),'2026','v1.2',90.91,null,'https://www.superleague.co.uk/standings',jsonb_build_object('regular_season_wins',8,'regular_season_win_points',90.91,'regular_season_finish',11,'placement_points',0,'playoff_wins',0,'playoff_win_points',0,'advancement_points',0,'championship_points',0,'champion',false)),
((select id from public.assets where sport='Super League Rugby' and external_key='huddersfield-giants'),'2026','v1.2',90.91,null,'https://www.superleague.co.uk/standings',jsonb_build_object('regular_season_wins',8,'regular_season_win_points',90.91,'regular_season_finish',12,'placement_points',0,'playoff_wins',0,'playoff_win_points',0,'advancement_points',0,'championship_points',0,'champion',false)),
((select id from public.assets where sport='Super League Rugby' and external_key='castleford-tigers'),'2026','v1.2',90.91,null,'https://www.superleague.co.uk/standings',jsonb_build_object('regular_season_wins',8,'regular_season_win_points',90.91,'regular_season_finish',13,'placement_points',0,'playoff_wins',0,'playoff_win_points',0,'advancement_points',0,'championship_points',0,'champion',false)),
((select id from public.assets where sport='Super League Rugby' and external_key='bradford-bulls'),'2026','v1.2',79.55,null,'https://www.superleague.co.uk/standings',jsonb_build_object('regular_season_wins',7,'regular_season_win_points',79.55,'regular_season_finish',14,'placement_points',0,'playoff_wins',0,'playoff_win_points',0,'advancement_points',0,'championship_points',0,'champion',false))
on conflict (asset_id,season_label,scoring_version) do update
set points=excluded.points,
    source_ref=excluded.source_ref,
    breakdown=excluded.breakdown,
    updated_at=now();

with ranked as (
  select ass.id as stat_id, rank() over(order by ass.points desc)::int as calculated_rank
  from public.asset_season_stats ass
  join public.assets a on a.id=ass.asset_id
  where a.sport='Super League Rugby'
    and ass.season_label='2026'
    and ass.scoring_version='v1.2'
)
update public.asset_season_stats ass
set rank=ranked.calculated_rank, updated_at=now()
from ranked
where ranked.stat_id=ass.id;
