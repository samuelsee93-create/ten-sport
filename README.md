# Ten Sport

Ten Sport is a keeper fantasy league spanning ten sports in one shared season-long competition.

## v0.3
This build moves the project from a single-user prototype toward a multi-user-ready architecture.

### League rules represented
- 20 assets per team
- 15 Active + 5 Bench
- only active assets count for a manager at each scoring-event lock
- three free keepers
- asset and draft-pick trading
- draft picks permanently retain original-team provenance
- 17-round live draft after three keepers
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
v0.3 uses browser local storage through a service layer. The next milestone replaces that implementation with hosted auth, Postgres and realtime synchronization without changing the domain-facing UI calls.
