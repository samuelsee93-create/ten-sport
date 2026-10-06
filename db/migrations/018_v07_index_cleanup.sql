-- 018_v07_index_cleanup.sql
create index if not exists draft_order_team_idx
  on public.draft_order(team_id);

create index if not exists keeper_source_draft_selection_idx
  on public.keeper_selections(source_draft_selection_id);
