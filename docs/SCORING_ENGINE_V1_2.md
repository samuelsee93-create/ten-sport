# Ten Sport Scoring Engine v1.2 — Source of Truth

The spreadsheet scoring model is **not authoritative**. Historical back-testing and the production scoring engine must use the finalized conversation rules below.

## Core rules

- Hard maximum: **1,000 points per asset**
- 20 rostered assets: **20,000 theoretical maximum per manager**
- Points accumulate through the season and are not clawed back.
- Championships matter heavily, but the majority of points must come from performance across the competition.
- Cross-sport draft value is a design constraint; historical distributions must be back-tested before the scoring engine is considered tuned.

## NHL / NFL / NBA / MLB

Maximum: **1,000**

- Regular-season wins: **250**
- Regular-season placement: **150**
- Playoff wins: **200**
- Playoff advancement: **150**
- Championship: **250**

Regular-season win bucket uses realistic elite benchmarks, capped at 250:
- NFL: ~15 wins
- NHL: ~60 wins
- NBA: ~70 wins
- MLB: ~110 wins

Formula: 250 × wins / elite benchmark, capped at 250.

The finalized discussion explicitly gives NHL/NBA advancement as:
- Round 1: +25
- Round 2: +35
- Conference Final: +40
- Final: +50
- Total advancement maximum: 150

Playoff wins use a separate 200-point pool normalized against the sport-specific maximum playoff wins.

## Golf

Four majors, maximum **250 per major / 1,000 total**:

- Win: 250
- 2nd: 200
- 3rd: 175
- 4–5: 150
- 6–10: 125
- 11–20: 90
- 21–30: 60
- 31–50: 35
- Made cut 51+: 15
- Missed cut: 0
- Did not qualify/play: 0

Cut classification for historical imports:
- If the player records a Round 3 or Round 4 score (more than two rounds played), treat them as having **made the cut**.
- If the player only records Rounds 1–2, treat them as **missed cut**.
- An explicit WD/DQ may override the round-count rule only when the source clearly shows the player had already advanced through the cut before withdrawing/disqualification.

## Tennis

Four Grand Slams, maximum **250 per Slam / 1,000 total**:

- Champion: 250
- Final: 200
- SF: 150
- QF: 110
- R16: 75
- R32: 45
- R64: 25
- R128: 10

## F1

Maximum: **1,000**

- Race/Sprint performance: **800**
- Final WDC placement: **150**
- World Champion bonus: **50**

Race/Sprint performance is normalized against the maximum points theoretically available to a driver.

## UCL

Maximum: **1,000**

- League-phase match results: **200**
- League-phase placement: **100**
- Knockout match wins: **250**
- Knockout advancement: **200**
- Championship: **250**

League phase:
- Win: 25
- Draw: 10
- 8 matches; bucket capped at 200

League-phase placement:
- 1st: 100
- 2nd: 95
- 3rd: 90
- 4th: 85
- 5–8: 75
- 9–12: 60
- 13–16: 45
- 17–20: 30
- 21–24: 15
- 25–36: 0

Knockout advancement:
- Win R16 tie: +50
- Win QF: +65
- Win SF: +85
- Total: 200

Knockout match wins are capped at 250 so extra playoff-round games do not create an inherent advantage.

## March Madness / NCAA

Maximum: **1,000**

Tournament wins:
- R64: 50
- R32: 75
- Sweet 16: 100
- Elite Eight: 125
- Final Four: 150
- Championship Game: 200
- Six-win total: 700

National Champion bonus: **+300**

## Super Rugby Pacific

Maximum: **1,000**

- Regular-season wins: **250**
- Regular-season placement: **150**
- Playoff wins: **200**
- Playoff advancement: **150**
- Championship: **250**

For the 2026 historical season:
- 14 regular-season matches per club.
- Elite win benchmark: **12 wins**.
- Formula: `250 × wins / 12`, capped at 250.

Regular-season placement:
- Top six score placement points because the top six qualify for the finals.
- 1st: 150
- 2nd: 122
- 3rd: 94
- 4th: 66
- 5th: 38
- 6th: 10
- 7th and lower: 0

Playoff wins:
- **100 points per playoff win**, capped at 200.
- This prevents a lower seed from receiving extra value solely because it has an additional knockout match available.

Playoff advancement:
- Qualify for the top-six finals: **+25**
- Reach the semifinals: **+35**
- Reach the Grand Final: **+40**
- Win the Grand Final: **+50**
- Maximum advancement: **150**

The championship bonus is a separate **+250**.

The advancement model accommodates the competition's finals structure, including semifinal byes or other officially defined advancement paths without double-counting playoff wins.

## Historical import rule

Do **not** derive historical points from the current workbook's normalized-placement scoring. Use this v1.2 specification and the underlying real-world results. If a sub-formula is not numerically specified in the finalized conversation, stop and resolve that sub-formula before writing historical scores into production.


## Finalized v1.2 sub-formulas

These formulas were green-lit after the initial v1.2 specification and are authoritative for historical back-testing.

### NHL / NFL / NBA / MLB regular-season placement — 150 max

Only the top half scores placement points.

Use a linear scale:
- 1st place = 150
- final scoring position in the top half = 10
- bottom half = 0

For a league with N scoring positions in the top half:

`placement_points = 150 - (finish - 1) × (140 / (N - 1))`

Cap at 150 and floor non-scoring positions at 0.

### Playoff-win buckets — 200 max

- NHL: 12.5 per playoff game win, 16 wins = 200.
- NBA: 12.5 per playoff game win, 16 wins = 200.
- NFL: 50 per playoff game win, capped at 200.
- MLB: 200 / 13 points per playoff game win, capped at 200.

### Playoff advancement — 150 max

NHL / NBA:
- First round won: 25
- Second round won: 35
- Conference final won: 40
- Final won: 50

NFL:
- Wild Card round advancement or a first-round bye: 25
- Divisional advancement: 35
- Conference championship advancement: 40
- Super Bowl win: 50

MLB:
- Wild Card advancement or first-round bye: 25
- Division Series advancement: 35
- League Championship Series advancement: 40
- World Series win: 50

### UCL knockout match wins — 250 max

Each knockout match win is worth `250 / 7` points (35.7142857...), capped at 250.

### F1 WDC placement — 150 max

- P1: 150
- P2: 127.5
- P3: 108.75
- P4: 90
- P5: 75
- P6: 60
- P7: 45
- P8: 33.75
- P9: 22.5
- P10: 15
- P11+: 0

World Champion bonus remains +50.

### F1 Race/Sprint performance — 800 max

`race_performance = 800 × actual FIA championship points / theoretical maximum points available to one driver in that season`

Cap at 800.
