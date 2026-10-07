-- 034_index_draft_preference_assets.sql
create index if not exists draft_preferences_asset_idx
  on public.draft_preferences(asset_id);
