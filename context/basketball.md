# Sport Context: NBA Basketball

This file provides domain knowledge for LLM-assisted scaffolding of a
BKS Basketball app. Feed it alongside `sports/basketball.yaml` when
generating sport-specific business logic stubs.

---

## League & Format

- **League**: NBA (National Basketball Association)
- **Season**: October – June
  - Regular season: ~82 games per team
  - Playoffs: best-of-7 series, 16 teams
  - Offseason: July – September (no DFS activity)
- **Game format**: 4 quarters × 12 minutes, overtime as needed

---

## DFS Context

- **Primary platform**: DraftKings Classic
- **Scoring unit**: DK fantasy points
- **Formula**: PTS×1 + 3PM×0.5 + REB×1.25 + AST×1.5 + STL×2 + BLK×2 − TO×0.5
  - Bonus: +1.5 for double-double, +3.0 for triple-double
  - Qualifying stats for bonus: PTS, REB, AST, STL, BLK (each ≥ 10)

---

## Positions

| API values | Group | Notes |
|---|---|---|
| PG, G, Point Guard | Guards | Primary ball handlers |
| SG, Shooting Guard | Guards | Perimeter scorers |
| SF, Small Forward | Forwards | Two-way wings |
| PF, Power Forward | Forwards | Stretch/post bigs |
| C, Center | Centers | Rim presence |
| F-C, G-F | Hyphenated combos | Match both sides |

---

## Box Score Stats (GameEntry fields)

| Field | Type | Description |
|---|---|---|
| points | Int | Total points scored |
| rebounds | Int | Total rebounds (offensive + defensive) |
| assists | Int | Assists |
| steals | Int | Steals |
| blocks | Int | Blocks |
| turnovers | Int | Turnovers |
| fieldGoalsMade | Int | FG made |
| fieldGoalsAttempted | Int | FG attempted |
| threePointersMade | Int | 3PM |
| threePointersAttempted | Int | 3PA |
| freeThrowsMade | Int | FT made |
| freeThrowsAttempted | Int | FT attempted |
| minutes | String | Minutes played ("0" / "" = DNP) |
| plusMinus | String | +/- for the game |

---

## Tier Semantics

| Tier | Minutes | DK pts | Profile |
|---|---|---|---|
| Elite | ≥ 35 | ≥ 40 | Stars, max-salary anchors |
| Good | ≥ 28 | ≥ 28 | Consistent starters |
| Solid | ≥ 20 | ≥ 18 | Rotation contributors |
| Bottom Feeder | < 20 | < 18 | Bench/spot minutes |

---

## Trending Signals

- **Hot streak**: positive `hotStreak` value (server-sent Int)
- **Surging**: `isSurging == true` — multi-category statistical spike
- **Trend direction**: `up` / `down` / `neutral` (TrendDirection enum)
- **Confidence score**: 0–100, reflects consistency of trend signal
- **Usage efficiency**: `expanding`, `expandingEfficiently`,
  `volumeInflation`, `efficientUsage`, `neutral`
- **Injury windows**: `isReturnGameWindow`, `daysSinceReturn` flag
  players returning from injury who may have inflated minutes

---

## Prospecting (Today's DFS Opportunities)

- Uses today's scheduled games as the universe
- Filters out players marked `out` or `doubtful`
- **Gems tab**: elite and good OpportunityTier
- **Fool's Gold tab**: solid and low OpportunityTier
- Playoff mode adds: `rotationTier`, `playoffRotationMultiplier`,
  `playoffTrendTrust`, `playoffGamesPlayed`
- Season modes: `regular_season`, `playoffs`, `offseason`
  - Offseason shows a banner; no slate to display

---

## Projecting (5-Game Ceiling Plays)

- Forward-looking window: next 5 scheduled games per player
- `projectionScore`: best DK score across the window
- `projectionTier`: best tier across the window
- `upcomingGames`: list of ProjectedGame (date, opponent, home/away,
  opponentStrength, projectedScore)
- Used for tournament (GPP) lineup construction
- Boom tab: elite and good ProjectionTier
- Bust tab: solid and low ProjectionTier

---

## Key Implementation Notes

- **DNP detection**: `minutes == "0" || minutes.isEmpty || minutes == "00"`
- **Hyphenated positions** ("F-C", "G-F"): split on "-" and match each part
- **Unavailable filter**: InjuryStatus `.out` or `.doubtful` → excluded
  from all active lists before tier/filter logic runs
- **Cache freshness**: default 24-hour threshold (`CacheFreshness.defaultThreshold`)
- **Background refresh**: `TrendRefreshTask` fires once per day at ~3am,
  refreshes Trending, Prospecting, and Projecting caches
