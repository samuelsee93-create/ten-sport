-- 024_merge_ncaa_iowa_state_alias.sql
-- Merge the historical Iowa State tournament record into the active Iowa St. asset.

with target as (
  select id from public.assets
  where sport='NCAA' and external_key='iowa-st'
),
source as (
  select id from public.assets
  where sport='NCAA' and external_key='iowa-state'
),
source_stat as (
  select ass.*
  from public.asset_season_stats ass
  join source s on s.id=ass.asset_id
  where ass.season_label='2026' and ass.scoring_version='v1.2'
)
insert into public.asset_season_stats(
  asset_id,season_label,scoring_version,points,rank,source_ref,breakdown
)
select
  t.id,ss.season_label,ss.scoring_version,ss.points,ss.rank,ss.source_ref,ss.breakdown
from target t cross join source_stat ss
on conflict (asset_id,season_label,scoring_version) do update
set points=excluded.points,
    rank=excluded.rank,
    source_ref=excluded.source_ref,
    breakdown=excluded.breakdown,
    updated_at=now();

delete from public.assets
where sport='NCAA' and external_key='iowa-state';

with ranked as (
  select ass.id as stat_id,rank() over(order by ass.points desc)::int as calculated_rank
  from public.asset_season_stats ass
  join public.assets a on a.id=ass.asset_id
  where a.sport='NCAA' and a.active=true
    and ass.season_label='2026' and ass.scoring_version='v1.2'
)
update public.asset_season_stats ass
set rank=ranked.calculated_rank,updated_at=now()
from ranked where ranked.stat_id=ass.id;
