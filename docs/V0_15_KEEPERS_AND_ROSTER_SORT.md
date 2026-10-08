# v0.15 Keepers and roster sorting

My Team has a next-draft keeper summary and designation controls on every roster row. Keeper Centre presents the same choices with estimated round costs. Managers can plan keepers during the inaugural season, without waiting for a completed prior season or a scheduled next draft.

`keeper_designations` stores next-draft intent separately from the formal `keeper_selections` that reserve picks for a particular draft. The next season's keeper deadline, capped at its scheduled draft time, closes editing; without either date, choices remain editable until the next draft starts. The current season's old keeper deadline does not close next-draft planning. Up to the league's keeper limit may be chosen, and invalid acquisition histories, Round 1 costs, and the three-year keeper maximum are rejected.

When the next draft starts, saved choices from the prior completed season are converted through the existing cost and draft-pick reservation rules, then locked and added to the roster. Missing required picks prevent draft preparation with an explicit error. Trading or dropping an asset clears its designation. Only the owning manager can change designations; direct table writes are denied and reads use RLS.

My Team now shares the asset pool's name, sport, watch filtering, and watch list. Position filtering supports active and bench assets. Click column headers to sort asset name, sport, current points, previous points, rank, status, watch status, or keeper status. Sorting first groups active and bench rows, then sorts within each group. Active assets always precede bench assets regardless of sort direction. Previous-season rank uses the same full-pool ordering as Assets.

Validation: eight automated tests cover the existing draft/trade flows plus roster sorting in both directions for every column, filters, watch list use, keeper limits, edits, and persistence. `tests/keepers_integration.sql` uses authenticated Supabase RPCs inside a rolled-back transaction to verify first-year designation, costs, private access, ownership cleanup, next-season carryover, deadline enforcement, pick reservation, and draft import. Production build passes.
