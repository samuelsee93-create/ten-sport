# Ten Sport v0.3 Architecture

## Goal
v0.3 separates fantasy-league rules from the React UI so the current local demo can be replaced by a hosted multi-user backend without rewriting screens or domain logic.

## Layers

### UI
`src/App.jsx` renders Dashboard, My Team, Trades, Keepers, Draft and Commissioner views. Components never write directly to local storage.

### Domain
`src/domain/` contains league constants, seed/demo data and selectors. Core invariants include:
- 20 owned assets per team
- 15 active / 5 bench
- 3 free keepers
- 1,000-point theoretical ceiling per asset
- draft picks retain original-team identity after every trade

### Service interface
`src/services/service.js` exports the service used by the UI. v0.3 points to `LocalLeagueService`; a hosted implementation can expose the same operations.

Current operations include:
- rename team
- change lineup status
- choose/remove keeper
- accept/decline trade
- start/pause draft
- make draft selection

### Persistence
v0.3 persists demo state in browser local storage. This is intentionally temporary. `db/schema.sql` defines the hosted relational model.

## Event locking
Lineup status must be snapshotted at a scoring event's lock time. The eventual scoring pipeline should create:
1. one `scoring_event`
2. one or more `point_transactions` for asset production
3. a `manager_point_transaction` recording ownership and active status at lock

This preserves both:
- **Season Points** — everything the asset earned
- **Points For You** — only production that counted while owned and active

## Atomic operations
These must be server-side transactions in production:
- accepted trades
- draft selections
- lineup changes around event locks
- commissioner reversals/corrections

A trade acceptance should validate ownership, pick ownership and roster capacity again inside the same transaction that moves the assets/picks.

A draft selection should atomically validate the current pick owner, asset availability and current draft pointer before inserting the selection and advancing the draft.

## Realtime
The live draft will subscribe to changes in draft status, current pick and selections. Trade status and league activity can use the same realtime channel/subscription approach.

## Next backend milestone
- hosted authentication
- Postgres deployment
- row-level authorization/permissions
- realtime subscriptions
- transactional RPC/functions
- file storage for team logos
- league invitations
