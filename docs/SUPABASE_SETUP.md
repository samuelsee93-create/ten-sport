# Supabase setup for Ten Sport v0.4

The repository is prepared for a hosted Supabase backend.

## Apply migrations
Apply in order:
1. `db/migrations/001_initial.sql`
2. `db/migrations/002_transactions.sql`
3. `db/migrations/003_account_and_manager_actions.sql`

## Frontend environment
Copy `.env.example` to `.env.local` and provide:
- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`

Never commit a service-role key to the frontend repository.

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

## Next implementation step
Provision the Supabase project, apply migrations, configure auth, then replace the local demo snapshot loader with queries that hydrate the same UI/domain view model from Postgres.
