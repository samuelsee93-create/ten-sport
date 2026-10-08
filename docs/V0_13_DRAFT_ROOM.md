# Draft room and lineup feedback

The commissioner can save a 10–600 second pick timer from the draft room or Commissioner page. A timer change resets the current live pick to a full clock; pause freezes the remaining time and resume restores it.

The countdown uses a saved database deadline and synchronizes against database time. A private one-second database worker auto-picks expired turns even when browsers are closed. The worker sleeps when no draft is live. Clients also poll a small clock snapshot and can request timeout processing; expired-time validation, an expected pick number, and a row lock prevent early or duplicate picks.

Timeout selection follows the team's owner's private queue, then the draft room's overall rank (previous-season points descending; ties use sport, name, asset ID). It skips taken assets and choices that would prevent a 20-asset roster from representing all ten sports. Traded pick ownership, snake order, and keeper cursor skipping continue to apply. If no eligible asset exists, the draft pauses.

The draft room shows a queue with Draft buttons, an in-room team roster selector with counts for each sport, and a strip showing the last selection, current team and next five unreserved picks. Roster controls are in the left position column: click ACT or BN, then choose the opposite-status asset to swap. Both assets' lock checks and lineup events happen in one transaction, preserving a full 15-active/5-bench roster. Empty positions can still be filled individually.

Validation: `npm test` exercises actual React DOM interactions and local deadline, queue, rank, coverage and swap behavior. `npm run build` builds the production app. `tests/draft_integration.sql` runs real RPC checks with authenticated roles against temporary league fixtures inside a rolled-back transaction. New database functions restrict execution to the appropriate roles; public mutation functions validate league membership, commissioner status, or team ownership. Supabase's signed-in SECURITY DEFINER advisor notices for those intentional RPC endpoints were reviewed.

Database migrations: `20261008184159_draft_clock_and_lineup_swaps.sql` and `20261008185711_draft_worker_lifecycle.sql`. Both are applied to the beta database.
