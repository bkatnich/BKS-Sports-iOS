# BKS-Sports-iOS

A code generator for BKS sport apps. You write a YAML file describing a sport; the generator produces 7 production-ready Swift files that drop into a BKS iOS app target.

This repo is **not** an iOS app. It is the factory that creates sport-specific Swift code.

---

## How It Works

```
sports/basketball.yaml  ──►  scaffold.sh  ──►  7 Swift files + shared assets
```

The YAML file is the single source of truth for everything: scoring formulas, player positions, tier thresholds, stat fields, API endpoints, and UI labels. `scaffold.sh` reads the YAML and writes the corresponding Swift source into a sibling app directory.

---

## Prerequisites

**Python 3 with PyYAML:**

```bash
pip3 install pyyaml
```

That's the only dependency. Xcode is not required to run the generator.

---

## Quick Start: Add a New Sport

Follow these five steps in order.

### Step 1 — Create the sport YAML

Copy the basketball spec as your starting point:

```bash
cp sports/basketball.yaml sports/baseball.yaml
```

Open `sports/baseball.yaml` in any text editor. The file is organized into labeled sections. Edit **every** value to match your sport. The required sections are:

| Section | What it controls |
|---|---|
| `sport` | App name, bundle ID, Swift/Xcode versions |
| `positions` | Position filter chips shown in the UI |
| `tiers` | Elite/Good/Solid/Bottom tier thresholds |
| `scoring` | DFS scoring formula and bonus rules |
| `api` | Backend endpoint URLs and field lists |
| `gamelog` | Stat fields, computed averages, display layout |

See [YAML Field Reference](#yaml-field-reference) below for a description of every field.

### Step 2 — (Optional) Add domain context

Create `context/<sport-slug>.md` with notes about your sport: league format, position semantics, scoring edge cases, DNP detection rules. This file is not used by the generator directly — it is documentation for future contributors.

```bash
touch context/baseball.md
```

### Step 3 — Run the generator

```bash
./scaffold.sh baseball
```

The script auto-derives the output directory as `../BKS-Baseball-Client-iOS` relative to this repo. Pass an explicit path if your app lives elsewhere:

```bash
./scaffold.sh baseball /path/to/your/BKS-Baseball-Client-iOS
```

The generator prints a summary of every file it writes, then prints a **Next Steps** checklist.

### Step 4 — Follow the Next Steps output

After the script finishes, it prints a checklist specific to your sport. Read it. It covers:
- Which Xcode targets to create
- Which SPM packages to add
- Which Info.plist keys to set
- Which files to wire into your app's dependency injection container

### Step 5 — Verify the output compiles

Open the generated app in Xcode and build. Fix any type errors before writing additional code — the generated files assume exact field names from your YAML.

---

## What Gets Generated

Running `scaffold.sh` writes these files into your app directory:

| Generated File | Destination in App | Purpose |
|---|---|---|
| `ConfigurationKeys+<Sport>.swift` | `App/Sources/Core/Utilities/` | API endpoint URLs and Info.plist key constants |
| `SportPositionMap+<Sport>.swift` | `App/Sources/Core/Sport/` | Position filter chip definitions |
| `<Calculator>.swift` | `App/Sources/Core/Sport/` | DFS scoring formula (implements `ScoringCalculator`) |
| `SportConfiguration+<Sport>.swift` | `App/Sources/Core/Sport/` | Master sport config: tiers, stat fields, API params |
| `TierThresholds+<Sport>.swift` | `App/Sources/Core/UI/` | UI tier badge thresholds |
| `GameEntry.swift` | `App/Sources/Core/Models/` | Game stat model and `PlayerGameLog` aggregate |
| `GameLogViews.swift` | `App/Sources/Features/Trending/Views/` | SwiftUI game log table and empty/error states |

It also copies shared branding assets into `App/Sources/App/Resources/`:
- `Assets.xcassets` — App icon, in-app icon, launch background color
- `Localizable.xcstrings` — 257 localized strings in English, French (CA), and Spanish

---

## YAML Field Reference

This section describes every configurable field. Use `sports/basketball.yaml` as a concrete example alongside this reference.

### `sport` — App metadata

```yaml
sport:
  name: Basketball            # Human-readable sport name
  slug: basketball            # Lowercase identifier; used in file names and directory derivation
  prefix: BKS                 # Swift class prefix (e.g., BKS → BKSBasketballCalculator)
  appName: BKS Basketball     # Display name shown in the app
  bundleId: com.blackkatt.bksbasketball  # Reverse-DNS bundle identifier
  league: NBA                 # League abbreviation (informational)
  platform: iOS               # Target platform (iOS)
  deploymentTarget: "17.0"    # Minimum iOS version
  xcodeVersion: "26.4"        # Xcode version used to build
  swiftVersion: "5.10"        # Swift language version
```

### `positions` — Position filter chips

Each entry becomes one filter chip group in the UI. Order controls display order.

```yaml
positions:
  - label: Guards                                        # UI label for the chip
    terms: [Guard, G, PG, SG, Point Guard, Shooting Guard]  # API values that match this group
  - label: Forwards
    terms: [Forward, F, SF, PF, Small Forward, Power Forward]
  - label: Centers
    terms: [Center, C]
```

### `tiers` — Player tier thresholds

Four tiers, always named `elite`, `good`, `solid`, and `bottom`. Each tier has a display label and a list of threshold descriptors shown in the UI.

```yaml
tiers:
  elite:
    label: Elite
    thresholds:
      - label: "Avg ≥ 35 min/game"
        systemImage: clock         # SF Symbol name
      - label: "Avg ≥ 40 DK pts/game"
        systemImage: bolt.fill
  good:
    label: Good
    thresholds:
      - label: "Avg ≥ 28 min/game"
        systemImage: clock
      - label: "Avg ≥ 28 DK pts/game"
        systemImage: bolt.fill
  solid:
    label: Solid
    thresholds:
      - label: "Avg ≥ 20 min/game"
        systemImage: clock
      - label: "Avg ≥ 18 DK pts/game"
        systemImage: bolt.fill
  bottom:
    label: Bottom Feeder
    thresholds: []               # No thresholds for the catch-all tier
```

### `scoring` — DFS formula

```yaml
scoring:
  platform: draftkings          # DFS platform identifier
  formula: nba_classic          # Formula name (informational label)
  calculator: DraftKingsNBACalculator  # Swift class name for the generated calculator
  stats:
    - key: points               # Must match a key in gamelog.stats
      type: Int
      multiplier: 1.0           # Points awarded per unit of this stat
    - key: turnovers
      type: Int
      multiplier: -0.5          # Negative multipliers are supported
  bonuses:
    - name: double_double
      qualifyingStats: [points, rebounds, assists, steals, blocks]  # Stats that count toward threshold
      threshold: 2              # How many qualifying stats must reach 10+ to trigger the bonus
      value: 1.5                # Bonus points awarded
    - name: triple_double
      qualifyingStats: [points, rebounds, assists, steals, blocks]
      threshold: 3
      value: 3.0
```

### `api` — Backend endpoints

```yaml
api:
  players:
    url: https://your-function-url/get_players
    fields:
      - id
      - first_name
      # ... full list of fields your endpoint returns
    params: {}                  # Optional query parameters

  opportunities:
    url: https://your-function-url/get_opportunities
    fields: [...]
    params:
      limit: 25
      platform: dk
      mode: balanced

  projections:
    url: https://your-function-url/get_projections
    fields: []
    params:
      lookahead: 5
      platform: dk
      mode: gpp

  todayGames:
    url: https://your-function-url/get_today_games

  gameLog:
    baseURL: https://api.example.com/v1
    apiKeyRequired: true        # If true, the generated code reads a key from Info.plist
```

### `gamelog` — Stat fields and display layout

```yaml
gamelog:
  isDNPCondition: 'minutes == "0" || minutes.isEmpty || minutes == "00"'
  # Swift expression that evaluates to true when a player did not play

  stats:
    - key: minutes              # Swift property name on GameEntry
      type: String              # Swift type: String, Int, or Double
      label: MIN                # Short label shown in table headers
      isPlayingTime: true       # Marks this as the primary time-on-field stat
    - key: points
      type: Int
      label: PTS

  averages:
    - key: averagePoints        # Swift property name on PlayerGameLog
      sourceKey: points         # Stat key to average across games
      label: PPG                # Display label

  percentages:
    - key: fieldGoalPercentage
      madeKey: fieldGoalsMade
      attemptedKey: fieldGoalsAttempted
      label: FG%

  display:
    primary:                    # Stats shown in the primary (top) row of the game log card
      - key: dk                 # "dk" is synthetic — computed by the ScoringCalculator
        label: DK
        localizationKey: gamelog.header.dk
        color: dkGreen
      - key: points
        label: PTS
        localizationKey: gamelog.header.pts
    secondary:                  # Stats shown in the secondary (bottom) row
      - key: steals
        label: STL
        localizationKey: gamelog.header.stl
```

---

## Generated App Dependencies

Every app produced by this generator expects these Swift Package Manager packages:

| Package | Minimum Version | Purpose |
|---|---|---|
| `BKSCore` | 1.0.1 | Core protocols (`SportConfiguration`, `ScoringCalculator`, `TierDisplayable`) |
| `BKSUICore` | 1.0.4 | Shared SwiftUI components |
| `Swinject` | 2.9.0 | Dependency injection |
| `Firebase` | 11.0.0 | Auth, Firestore, Analytics, AppCheck |

Add these packages to your app target in Xcode before building. The generator's Next Steps output repeats this list with the exact repository URLs.

---

## Repository Structure

```
BKS-Sports-iOS/
├── scaffold.sh          # Generator script — do not edit unless adding a new file pattern
├── sports/
│   └── basketball.yaml  # Basketball sport spec (use as a template for new sports)
├── context/
│   └── basketball.md    # Basketball domain notes (optional companion file)
└── assets/
    ├── Assets.xcassets  # Shared app icon and branding assets
    └── Localizable.xcstrings  # Shared localized strings (257 keys, 3 languages)
```

---

## Common Mistakes

**The output directory does not exist.**
`scaffold.sh` writes into an existing sibling directory. Clone or create your app repo at `../BKS-<Sport>-Client-iOS` before running the generator.

**`pyyaml` is not installed.**
Run `pip3 install pyyaml` first. The script will fail immediately with a Python import error if PyYAML is missing.

**A YAML key is missing or misspelled.**
The generator validates required fields and exits with an error message naming the missing key. Fix the YAML and re-run.

**The generated code has type errors in Xcode.**
The most common cause is a mismatch between stat `key` names in `gamelog.stats` and `scoring.stats`. Every key referenced in `scoring.stats` must also appear in `gamelog.stats`.

**You edited `scaffold.sh` and existing generated files look stale.**
`scaffold.sh` only writes files when you run it. Re-run `./scaffold.sh <slug>` to regenerate after any change to the script or the YAML.
