# Ten Sport League Rules v0.8

## Sport universe

The ten sports are:

1. NHL
2. NFL
3. F1
4. Golf
5. NBA
6. MLB
7. UCL
8. NCAA men's basketball
9. Super League Rugby
10. Tennis

Six Nations is no longer part of Ten Sport.

## Roster

- 20 assets per team.
- 15 Active, 5 Bench.
- There are no dedicated sport slots and no flex slots.
- A completed 20-asset roster must always include at least one asset from each of the 10 sports.
- During the draft or while a roster is incomplete, a move is legal only if enough open roster spots remain to still reach all 10 sports.
- Once a roster is full, trades and first-come-first-serve waiver claims cannot leave a sport unrepresented.

## Waivers

- Waivers/free-agent pickups are first come, first served.
- There is no FAAB budget and no rolling priority.
- The first valid claim committed to the database wins the asset.
- A full roster requires a corresponding drop.
- Locked assets cannot be dropped during their active scoring-event lock.

## Keepers

- Minimum keepers: 0.
- Maximum keepers: 3.
- Maximum keeper life: 3 keeper years.
- The manager must own an available pick in the required keeper-cost round.
- Selecting a keeper reserves that exact pick, so it cannot be traded while reserved.

### Drafted assets

Keeper cost moves one round earlier for each keeper year.

Example — Toronto Maple Leafs drafted in Round 6:
- Year 1 keeper: Round 5
- Year 2 keeper: Round 4
- Year 3 keeper: Round 3
- Year 4: not eligible

There is no Round 0:
- Round 1 draft assets cannot be kept.
- Round 2 assets can be kept once.
- Round 3 assets can be kept twice.
- Round 4+ assets can potentially reach all three keeper years.

### Waiver-acquired assets

A waiver acquisition resets the keeper cost schedule:

- Year 1 keeper: **Round 8**
- Year 2 keeper: **Round 7**
- Year 3 keeper: **Round 6**
- Year 4: not eligible

The keeper clock follows the asset through trades. A trade does not reset keeper age.

A new draft selection or a new waiver acquisition resets the keeper source:
- Redrafted asset -> keeper cost restarts from the new draft round.
- Waiver-acquired asset -> keeper cost restarts at Round 8.

## Draft

- Full draft length: 20 rounds.
- Draft format: snake.
- Commissioner may manually set the first-round order or randomize it.
- Even-numbered rounds automatically reverse the first-round order.
- Draft order must be complete before the draft can go LIVE.
- Keepers occupy/forfeit their assigned draft-pick slots and the live draft automatically skips those slots.
- Traded draft picks retain permanent original-team provenance.

## Scoring

- Hard maximum: 1,000 points per asset.
- 20 rostered assets = 20,000 theoretical maximum per manager.
- The scoring source of truth remains `docs/SCORING_ENGINE_V1_2.md`.
