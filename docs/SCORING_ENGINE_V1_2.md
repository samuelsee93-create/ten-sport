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

## Six Nations

Maximum: **1,000**

- Match wins: **500** (100 per win)
- Final table: **up to 300**
- Tournament champion: **+100**
- Grand Slam: **+100**

A 5–0 champion with a Grand Slam reaches 1,000. A 4–1 champion cannot.

## Historical import rule

Do **not** derive historical points from the current workbook's normalized-placement scoring. Use this v1.2 specification and the underlying real-world results. If a sub-formula is not numerically specified in the finalized conversation, stop and resolve that sub-formula before writing historical scores into production.
