# Ten Sport League Rules v0.7

## Roster

- 20 assets per team.
- 15 Active, 5 Bench.
- There are **no dedicated sport slots and no flex slots**.
- A completed 20-asset roster must always include at least one asset from each of the 10 sports.
- During the draft or while a roster is incomplete, a move is legal only if enough open roster spots remain to still reach all 10 sports.
- Once a roster is full, trades and first-come-first-serve waiver claims cannot leave a sport unrepresented.

## Waivers

- Waivers/free-agent pickups are **first come, first served**.
- There is no FAAB budget and no rolling priority.
- The first valid claim committed to the database wins the asset.
- A full roster requires a corresponding drop.
- Locked assets cannot be dropped during their active scoring-event lock.

## Keepers

- Minimum keepers: **0**.
- Maximum keepers: **3**.
- Keeper cost escalates one round earlier for each keeper year.
- Maximum keeper life: **3 keeper years**.

Example:
- Draft Toronto Maple Leafs in Round 6.
- First keeper year costs a Round 5 pick.
- Second keeper year costs a Round 4 pick.
- Third keeper year costs a Round 3 pick.
- The asset cannot be kept a fourth time.

Additional implementation rules:
- The keeper clock follows the asset through trades.
- If the asset returns to the draft and is selected again, the keeper clock resets from that new draft round.
- The manager must actually own an available pick in the required cost round.
- The selected keeper reserves that exact draft pick; a reserved pick cannot be traded unless the keeper is first removed.
- There is no Round 0. Therefore a Round 1 asset cannot be kept; a Round 2 asset can be kept once; a Round 3 asset can be kept twice; Round 4+ assets can potentially reach the full three years.
- Waiver-acquisition keeper cost remains undefined and waiver-only assets are not keeper-eligible until that rule is explicitly set.

## Draft

- Full draft length: **20 rounds**.
- Draft format: **snake**.
- The commissioner can either:
  - manually set the first-round order; or
  - randomize the order.
- Even-numbered rounds automatically reverse the first-round order.
- Draft order must be complete before the draft can go LIVE.
- Keepers occupy/forfeit their assigned draft-pick slots and are automatically skipped when the live draft reaches those picks.
- Traded draft picks retain permanent original-team provenance.
