-- 032_ucl_nonparticipant_zero_history.sql
-- Current UCL clubs that did not participate in 2025-26 explicitly receive 0 prior-season points.

insert into public.asset_season_stats(
  asset_id,season_label,scoring_version,points,rank,source_ref,breakdown
)
select
  a.id,
  '2025-26',
  'v1.2',
  0,
  null,
  'https://www.uefa.com/uefachampionsleague/',
  jsonb_build_object('did_not_participate',true)
from public.assets a
where a.sport='UCL'
  and a.active=true
  and not exists (
    select 1
    from public.asset_season_stats ass
    where ass.asset_id=a.id
      and ass.season_label='2025-26'
      and ass.scoring_version='v1.2'
  )
on conflict (asset_id,season_label,scoring_version) do nothing;

with ranked as (
  select
    ass.id as stat_id,
    rank() over(order by ass.points desc)::int as calculated_rank
  from public.asset_season_stats ass
  join public.assets a on a.id=ass.asset_id
  where a.sport='UCL'
    and a.active=true
    and ass.season_label='2025-26'
    and ass.scoring_version='v1.2'
)
update public.asset_season_stats ass
set rank=ranked.calculated_rank,
    updated_at=now()
from ranked
where ranked.stat_id=ass.id;
