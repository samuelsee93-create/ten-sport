# Supabase setup for Ten Sport v0.4

The repository is prepared for a hosted Supabase backend.

## Apply migrations
Apply in order:
1. `db/migrations/001_initial.sql`
2. `db/migrations/002_transactions.sql`
3. `db/migrations/003_account_and_manager_actions.sql`
4. `db/migrations/004_backend_hardening.sql`
5. `db/migrations/005_live_advisor_cleanup.sql`
6. `db/migrations/006_bootstrap_first_league.sql`

## Frontend environment
Copy `.env.example` to `.env.local` and provide:
- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`

Never commit a secret/service-role key to the frontend repository. The browser uses a publishable key and relies on Auth + RLS for user-level authorization.

When both variables are present, `src/services/service.js` automatically switches from the local demo service to the hosted Supabase service.

## Security model
- Browser reads are restricted by Row Level Security.
- Sensitive writes use security-definer RPCs.
- RPCs validate the authenticated manager/commissioner again inside the transaction.
- Draft selections and trade acceptance lock the relevant rows before mutation.
- Event-specific lineup locks are represented by `scoring_event_assets`.

## Realtime
Realtime publication is enabled for:
- drafts
- draft_selections
- trades
- roster_memberships

The live draft client can subscribe through `SupabaseLeagueService.subscribeToDraft()`.

## Hosted state loader
`SupabaseLeagueService.loadLeagueState()` hydrates the existing UI/domain view model from Postgres, including manager identity, rosters, keepers, trades, draft capital, draft selections, scoring totals, lock state and audit activity. Realtime changes trigger a state refresh for the active league/season.

## Next implementation step
Connect the frontend environment to the live Supabase project, create the first commissioner account through the app, then test multi-user manager invitations, trades, lineup changes and the live draft.
