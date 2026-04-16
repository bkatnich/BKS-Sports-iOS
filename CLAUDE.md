# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

**BKS-Sports-iOS** is a code generator, not an iOS app. It takes sport specifications in YAML and produces 7 production-ready Swift files that integrate into a BKS sport app target.

## Running the Generator

**Prerequisite:**
```bash
pip3 install pyyaml
```

**Generate a sport:**
```bash
./scaffold.sh <sport-slug>                          # auto-derives sibling output dir
./scaffold.sh basketball /path/to/BKS-Basketball-Client-iOS  # explicit output dir
```

The output directory is auto-derived as `../BKS-<TitleCase>-Client-iOS` relative to this repo.

## Adding a New Sport

1. Create `sports/<sport-slug>.yaml` following the structure of `sports/basketball.yaml`
2. Optionally add `context/<sport-slug>.md` for domain knowledge
3. Run `./scaffold.sh <sport-slug>`

The YAML spec drives everything — no changes to `scaffold.sh` are needed for a new sport unless a new pattern is required.

## Architecture of scaffold.sh

`scaffold.sh` is a bash wrapper around a Python heredoc. Flow:

1. **Parses** `sports/<slug>.yaml` via `pyyaml`
2. **Validates** required fields: `name`, `slug`, `prefix`, `appName`, `bundleId`, `platform`, `swiftVersion`, `xcodeVersion`, `scoring`, `positions`, `tiers`, `gameLog`, `api`
3. **Generates 7 Swift files** into the output app directory:

| File | Destination | Purpose |
|------|-------------|---------|
| `ConfigurationKeys+<Sport>.swift` | `App/Sources/Utilities/` | API endpoint URLs and config key constants |
| `SportPositionMap+<Sport>.swift` | `App/Sources/Utilities/` | Position filter chip group definitions |
| `<Prefix><Platform>Calculator.swift` | `App/Sources/Utilities/` | DFS scoring formula implementation |
| `SportConfiguration+<Sport>.swift` | `App/Sources/Utilities/` | Master sport config (tiers, stat fields, API params) |
| `TierThresholds+<Sport>.swift` | `App/Sources/Views/` | UI tier display thresholds |
| `GameEntry.swift` | `App/Sources/Models/` | Game stat model + `PlayerGameLog` aggregate |
| `GameLogViews.swift` | `App/Sources/Features/Trending/` | SwiftUI game log table and placeholder views |

## YAML Spec Structure

Key sections in a sport YAML:

- **`scoring.formula`** — Array of `{stat, multiplier}` entries; `scaffold.sh` builds the Swift expression dynamically
- **`scoring.bonuses`** — Double-double/triple-double style bonuses with qualifying stat counts and thresholds
- **`positions`** — Maps display group names (e.g., "Guards") to sport-specific terms (e.g., `[PG, SG]`)
- **`tiers`** — Four tiers (Elite/Good/Solid/Bottom) each with `minMinutes` and `minPoints` thresholds
- **`gameLog.stats`** — Ordered list of stat field definitions with `key`, `label`, `type`, `width`
- **`api`** — Four endpoint definitions: `players`, `opportunities`, `projections`, `gameLog`

## Generated App Dependencies

Generated apps expect these SPM packages to be present in the target:
- **BKSCore** ≥ 1.0.1 — Core protocols (`SportConfiguration`, `ScoringCalculator`, `TierDisplayable`)
- **BKSUICore** ≥ 1.0.4 — Shared SwiftUI components
- **Swinject** ≥ 2.9.0 — Dependency injection
- **Firebase** ≥ 11.0.0 — Auth, Firestore, Analytics, AppCheck

## Template Sync

When modifying `scaffold.sh`, the Python template strings inside it are the source of truth for generated code. If you change a template inside `scaffold.sh`, the change applies to all future scaffolds of that file type. There are no separate template files — templates are embedded directly in the script.
