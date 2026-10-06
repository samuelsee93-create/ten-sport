# Ten Sport

Ten Sport is a keeper fantasy league spanning ten sports in one shared season-long competition.

## v0.8 backend
This branch adds the live multi-user Supabase architecture while preserving the existing league rules and UI-facing service contract.

### League rules represented
- 20 assets per team
- 15 Active + 5 Bench
- each full roster must represent all ten sports; no dedicated/flex positions
- Super League Rugby replaces Six Nations
- only active assets count for a manager at each scoring-event lock
- 0–3 escalating-cost keepers (draft source: one round earlier per year; waiver source: R8 → R7 → R6)
- asset and draft-pick trading
- draft picks permanently retain original-team provenance
- 20-round snake draft with commissioner-set or randomized order
- separate Season Points and Points For You
- auditable transaction/event model

### Run locally
```bash
npm install
npm run dev
```

### Build
```bash
npm run build
```

### Architecture
See `docs/ARCHITECTURE.md` and `db/schema.sql`.

## Current persistence
The app keeps the local browser service as a zero-config fallback. When `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` are configured, it switches to Supabase Auth, Postgres/RLS, transactional RPCs and Realtime-backed league state.
