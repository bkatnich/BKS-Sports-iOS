#!/usr/bin/env bash
# scaffold.sh — Generate a new BKS sport app from a sport YAML spec.
#
# Usage:
#   ./scaffold.sh <sport-slug> [output-dir]
#
# Examples:
#   ./scaffold.sh baseball
#       → writes into ../BKS-Baseball-Client-iOS/ (auto-derived)
#
#   ./scaffold.sh baseball /path/to/BKS-Baseball-Client-iOS
#       → writes into the specified directory
#
# The script reads sports/<sport-slug>.yaml and generates all sport-specific
# Swift files into the target app directory. It scaffolds:
#   ConfigurationKeys+<Sport>.swift
#   SportPositionMap+<Sport>.swift
#   <Calculator>.swift  (ScoringCalculator implementation)
#   SportConfiguration+<Sport>.swift
#   TierThresholds+<Sport>.swift
#   GameEntry.swift
#   GameLogViews.swift
#
# Requirements: python3, pyyaml (pip3 install pyyaml)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── argument check ───────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <sport-slug> [output-dir]"
    echo "  e.g. $0 baseball"
    echo "  e.g. $0 baseball /path/to/BKS-Baseball-Client-iOS"
    exit 1
fi

SPORT_SLUG="$1"
YAML_FILE="$SCRIPT_DIR/sports/${SPORT_SLUG}.yaml"

if [[ ! -f "$YAML_FILE" ]]; then
    echo "Error: sport spec not found at $YAML_FILE"
    echo "Create it first — see sports/basketball.yaml as a reference."
    exit 1
fi

# Optional explicit output directory; defaults to auto-derived sibling repo
OUTPUT_DIR="${2:-}"

# ── python helper: parse yaml and emit scaffold ───────────────────────────────

python3 << PYEOF
import sys, os, re, textwrap
sys.path.insert(0, '')

try:
    import yaml
except ImportError:
    print("Error: pyyaml not installed. Run: pip3 install pyyaml")
    sys.exit(1)

SCRIPT_DIR  = "${SCRIPT_DIR}"
SPORT_SLUG  = "${SPORT_SLUG}"
OUTPUT_DIR  = "${OUTPUT_DIR}"  # empty string means auto-derive

# ── load spec ─────────────────────────────────────────────────────────────────

with open(os.path.join(SCRIPT_DIR, "sports", f"{SPORT_SLUG}.yaml")) as f:
    spec = yaml.safe_load(f)

sport       = spec["sport"]
name        = sport["name"]          # e.g. "Baseball"
slug        = sport["slug"]          # e.g. "baseball"
prefix      = sport["prefix"]        # e.g. "BKS"
app_name    = sport["appName"]       # e.g. "BKS Baseball"
bundle_id   = sport["bundleId"]      # e.g. "com.blackkatt.bksbaseball"
league      = sport.get("league", name.upper())
deploy_tgt  = sport["deploymentTarget"]
xcode_ver   = sport["xcodeVersion"]
swift_ver   = sport["swiftVersion"]

positions   = spec.get("positions", [])
tiers       = spec.get("tiers", {})
scoring     = spec.get("scoring", {})
packages    = spec.get("packages", {})
api         = spec.get("api", {})
gamelog     = spec.get("gamelog", {})
tabs        = spec.get("tabs", {})
season      = spec.get("season", {})

swift_name  = name.replace(" ", "")         # "BaseBall" -> "Baseball"
type_prefix = f"{prefix}{swift_name}"       # "BKSBaseball"
calc_name   = scoring.get("calculator", f"DraftKings{swift_name}Calculator")

# Output directory: explicit arg or auto-derived sibling of this repo
if OUTPUT_DIR:
    out_dir = os.path.abspath(OUTPUT_DIR)
else:
    repo_parent = os.path.dirname(SCRIPT_DIR)
    out_dir     = os.path.join(repo_parent, f"{prefix}-{name.replace(' ', '')}-Client-iOS")

def mkdir(path):
    os.makedirs(path, exist_ok=True)

def write(path, content):
    mkdir(os.path.dirname(path))
    with open(path, "w") as f:
        f.write(content)
    print(f"  wrote  {os.path.relpath(path, out_dir)}")

# ── copyright header ──────────────────────────────────────────────────────────

def header(year=2026):
    return f"// Copyright {year} Black Katt Technologies Inc.\n\n"

# ─────────────────────────────────────────────────────────────────────────────
# 1. ConfigurationKeys+<Sport>.swift
# ─────────────────────────────────────────────────────────────────────────────

players_api     = api.get("players", {})
opps_api        = api.get("opportunities", {})
proj_api        = api.get("projections", {})
today_api       = api.get("todayGames", {})
gamelog_api     = api.get("gameLog", {})

players_url     = players_api.get("url", "")
opps_url        = opps_api.get("url", "")
proj_url        = proj_api.get("url", "")
today_url       = today_api.get("url", "")
gamelog_base    = gamelog_api.get("baseURL", "")
api_key_needed  = gamelog_api.get("apiKeyRequired", False)

config_keys = header() + f"""\
import Foundation
import BKSCore

// MARK: - {name}-specific configuration keys

extension ConfigurationKey where Value == String {{
"""
if api_key_needed:
    config_keys += f"""\
    static let gameLogAPIKey = ConfigurationKey(
        name: "gameLogAPIKey",
        defaultValue: "",
        infoPlistKey: "GameLogAPIKey"
    )
"""
config_keys += f"""\
    static let gameLogBaseURL = ConfigurationKey(
        name: "gameLogBaseURL",
        defaultValue: "{gamelog_base}"
    )
    static let getPlayersURL = ConfigurationKey(
        name: "getPlayersURL",
        defaultValue: "{players_url}"
    )
    static let getOpportunitiesURL = ConfigurationKey(
        name: "getOpportunitiesURL",
        defaultValue: "{opps_url}"
    )
    static let getTodayGamesURL = ConfigurationKey(
        name: "getTodayGamesURL",
        defaultValue: "{today_url}"
    )
    static let getProjectionsURL = ConfigurationKey(
        name: "getProjectionsURL",
        defaultValue: "{proj_url}"
    )
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Utilities", f"ConfigurationKeys+{swift_name}.swift"), config_keys)

# ─────────────────────────────────────────────────────────────────────────────
# 2. SportPositionMap extension
# ─────────────────────────────────────────────────────────────────────────────

chips = [p["label"] for p in positions]
chips_str = '", "'.join(chips)

terms_lines = []
for p in positions:
    label = p["label"]
    terms = p["terms"]
    terms_str = '", "'.join(str(t) for t in terms)
    terms_lines.append(f'            "{label}": ["{terms_str}"]')
terms_block = ",\n".join(terms_lines)

pos_map = header() + f"""\
import Foundation

// MARK: - {league} {name}

extension SportPositionMap {{
    /// Position map for {league} {name}.
    static let {slug} = SportPositionMap(
        filterChips: ["{chips_str}"],
        terms: [
{terms_block}
        ]
    )
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Sport", f"SportPositionMap+{swift_name}.swift"), pos_map)

# ─────────────────────────────────────────────────────────────────────────────
# 3. ScoringCalculator implementation
# ─────────────────────────────────────────────────────────────────────────────

formula      = scoring.get("formula", "classic")
stats        = scoring.get("stats", [])
bonuses      = scoring.get("bonuses", [])

# Build score expression
score_lines = []
for i, s in enumerate(stats):
    key = s["key"]
    mul = s["multiplier"]
    typ = s.get("type", "Int")
    if typ == "Int":
        cast = f"Double(entry.{key})"
    else:
        cast = f"entry.{key}"
    if mul == 1.0:
        expr = cast
    elif mul == -0.5:
        expr = f"{cast} * -0.5"
    else:
        expr = f"{cast} * {mul}"
    if i == 0:
        score_lines.append(f"        var total = {expr}")
    else:
        if mul >= 0:
            score_lines.append(f"            + {expr}")
        else:
            # negative multiplier: emit as subtraction
            pos_expr = expr.replace(f" * {mul}", f" * {abs(mul)}")
            score_lines.append(f"            - {pos_expr}")
score_expr = "\n".join(score_lines)

# Build bonus logic
bonus_lines = []
for b in bonuses:
    qualifying = b.get("qualifyingStats", [])
    threshold  = b["threshold"]
    value      = b["value"]
    if qualifying:
        quals = ", ".join([f"entry.{q}" for q in qualifying])
        d0 = chr(36) + "0"  # builds "$0" without triggering heredoc shell expansion
        bonus_lines.append(
            f"        let doubles{threshold} = [{quals}].filter {{ {d0} >= 10 }}.count\n"
            f"        if doubles{threshold} >= {threshold} {{ total += {value} }}"
        )
bonus_block = "\n".join(bonus_lines)

calc_file = header() + f"""\
import Foundation

// MARK: - DraftKings {league} {name} ({formula})

/// DraftKings Classic scoring for {league} {name}.
struct {calc_name}: ScoringCalculator {{
    static let shared = Self()

    func score(for entry: GameEntry) -> Double {{
{score_expr}
{bonus_block}
        return total
    }}
}}

// MARK: - Convenience

extension ScoringCalculator where Self == {calc_name} {{
    static var {slug}DraftKings: {calc_name} {{ .shared }}
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Sport", f"{calc_name}.swift"), calc_file)

# ─────────────────────────────────────────────────────────────────────────────
# 4. GameEntry.swift
# ─────────────────────────────────────────────────────────────────────────────

stat_fields  = gamelog.get("stats", [])
averages     = gamelog.get("averages", [])
percentages  = gamelog.get("percentages", [])
dnp_cond     = gamelog.get("isDNPCondition", 'minutes == "0" || minutes.isEmpty')

# stat declarations
stat_decls = "\n".join([f"    let {s['key']}: {s['type']}" for s in stat_fields])

# init params
init_params = "\n".join([f"        {s['key']}: {s['type']}," for s in stat_fields])

# init assignments
init_assigns = "\n".join([f"        self.{s['key']} = {s['key']}" for s in stat_fields])

# averages
def avg_block(a):
    k = a["key"]
    src = a["sourceKey"]
    d0 = chr(36) + "0"
    d1 = chr(36) + "1"
    return f"""\
    var {k}: Double {{
        guard !entries.isEmpty else {{ return 0 }}
        return Double(entries.reduce(0) {{ {d0} + {d1}.{src} }}) / Double(entries.count)
    }}
"""

# percentages
def pct_block(p):
    k = p["key"]
    made = p["madeKey"]
    att  = p["attemptedKey"]
    d0 = chr(36) + "0"
    d1 = chr(36) + "1"
    return f"""\
    var {k}: Double {{
        let totalMade = entries.reduce(0) {{ {d0} + {d1}.{made} }}
        let totalAttempted = entries.reduce(0) {{ {d0} + {d1}.{att} }}
        guard totalAttempted > 0 else {{ return 0 }}
        return Double(totalMade) / Double(totalAttempted) * 100
    }}
"""

avg_blocks = "\n".join([avg_block(a) for a in averages])
pct_blocks = "\n".join([pct_block(p) for p in percentages])

game_entry = header() + f"""\
import Foundation

// MARK: - GameResult

enum GameResult: Codable, Equatable {{
    case win(teamScore: Int, opponentScore: Int)
    case loss(teamScore: Int, opponentScore: Int)

    var isWin: Bool {{
        if case .win = self {{ return true }}
        return false
    }}

    var displayScore: String {{
        switch self {{
        case let .win(team, opponent):
            "\\\\(team)-\\\\(opponent)"
        case let .loss(team, opponent):
            "\\\\(team)-\\\\(opponent)"
        }}
    }}
}}

// MARK: - GameEntry

struct GameEntry: Codable, Equatable, Identifiable {{
    var id: String {{ gameID }}

    let gameID: String
    let gameDate: Date
    let opponent: String
    let opponentAbbreviation: String
    let isHomeGame: Bool
    let result: GameResult

{stat_decls}
    let plusMinus: String

    init(
        gameID: String,
        gameDate: Date,
        opponent: String,
        opponentAbbreviation: String,
        isHomeGame: Bool,
        result: GameResult,
{init_params}
        plusMinus: String
    ) {{
        self.gameID = gameID
        self.gameDate = gameDate
        self.opponent = opponent
        self.opponentAbbreviation = opponentAbbreviation
        self.isHomeGame = isHomeGame
        self.result = result
{init_assigns}
        self.plusMinus = plusMinus
    }}
}}

// MARK: - GameEntry Helpers

extension GameEntry {{
    /// True when the player did not participate in the game.
    var isDNP: Bool {{
        {dnp_cond}
    }}
}}

// MARK: - PlayerGameLog

struct PlayerGameLog: Codable, Equatable {{
    let playerID: String
    let entries: [GameEntry]
    let fetchedAt: Date
}}

extension PlayerGameLog {{
{avg_blocks}
{pct_blocks}
}}

// MARK: - TeamScheduleCache

struct TeamScheduleCache: Codable {{
    let teamID: String
    let completedGameIDs: [String]
    let fetchedAt: Date
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Models/GameEntry.swift"), game_entry)

# ─────────────────────────────────────────────────────────────────────────────
# 5. TierThresholds+<Sport>.swift
# ─────────────────────────────────────────────────────────────────────────────

tier_map = {"elite": ".elite", "good": ".good", "solid": ".solid", "bottom": ".bottom"}

tier_cases = []
for tier_key, tier_val in tiers.items():
    level = tier_map.get(tier_key, f".{tier_key}")
    thresholds = tier_val.get("thresholds", [])
    if thresholds:
        items = ",\n            ".join(
            [f'TierThreshold(label: "{t["label"]}", systemImage: "{t["systemImage"]}")' for t in thresholds]
        )
        tier_cases.append(f"        {level}: [\n            {items}\n        ]")
    else:
        tier_cases.append(f"        {level}: []")

tier_dict = ",\n".join(tier_cases)

tier_thresh = header() + f"""\
import BKSCore
import BKSUICore

extension TierDisplayable {{
    /// {league}/{name}-specific tier thresholds.
    /// Delegated to SportConfiguration so the YAML spec is the single source of truth.
    var tierThresholds: [TierThreshold] {{
        SportConfiguration.{slug}.thresholds(for: tierLevel)
    }}
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/UI", f"TierThresholds+{swift_name}.swift"), tier_thresh)

# ─────────────────────────────────────────────────────────────────────────────
# 6. SportConfiguration factory extension
# ─────────────────────────────────────────────────────────────────────────────

# Build tier thresholds dict
tier_thresh_entries = []
for tier_key, tier_val in tiers.items():
    level = tier_map.get(tier_key, f".{tier_key}")
    thresholds = tier_val.get("thresholds", [])
    if thresholds:
        items = ",\n                ".join(
            [f'TierThreshold(label: "{t["label"]}", systemImage: "{t["systemImage"]}")' for t in thresholds]
        )
        tier_thresh_entries.append(f"            {level}: [\n                {items}\n            ]")
    else:
        tier_thresh_entries.append(f"            {level}: []")
tier_thresh_dict = ",\n".join(tier_thresh_entries)

# Build trending fields list
trending_fields = players_api.get("fields", [])
trending_fields_str = "\n".join([f'            "{f}",' for f in trending_fields])
if trending_fields_str.endswith(","):
    trending_fields_str = trending_fields_str[:-1]

# Build opportunity fields list
opp_fields = opps_api.get("fields", [])
opp_fields_str = "\n".join([f'            "{f}",' for f in opp_fields])
if opp_fields_str.endswith(","):
    opp_fields_str = opp_fields_str[:-1]

# Opportunity params
opp_params = opps_api.get("params", {})
opp_limit    = opp_params.get("limit", 25)
opp_platform = opp_params.get("platform", "dk")
opp_mode     = opp_params.get("mode", "balanced")

# Projection params
proj_params  = proj_api.get("params", {})
proj_look    = proj_params.get("lookahead", 5)
proj_plat    = proj_params.get("platform", "dk")
proj_mode    = proj_params.get("mode", "gpp")

# Team lookup — placeholder (sport-specific, fill manually)
team_lookup_comment = f"        // TODO: populate {league} team ID → abbreviation lookup"

sport_config = header() + f"""\
import BKSCore
import BKSUICore

// MARK: - {league} {name}

extension SportConfiguration {{
    /// Sport configuration for {league} {name} / DraftKings Classic.
    static let {slug} = SportConfiguration(
        slug: "{slug}",
        cacheKeyPrefix: "{slug}_",
        positionMap: .{slug},
        scoringCalculator: {calc_name}.shared,
        tierThresholds: [
{tier_thresh_dict}
        ],
        trendingFields: [
{trending_fields_str}
        ],
        opportunityFields: [
{opp_fields_str}
        ],
        opportunityParams: OpportunityParams(limit: {opp_limit}, platform: "{opp_platform}", mode: "{opp_mode}"),
        projectionParams: ProjectionParams(lookahead: {proj_look}, platform: "{proj_plat}", mode: "{proj_mode}"),
        teamAbbreviationByID: [
{team_lookup_comment}
        ]
    )
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Sport", f"SportConfiguration+{swift_name}.swift"), sport_config)

# ─────────────────────────────────────────────────────────────────────────────
# 7. GameLogViews.swift (sport-specific stat pills)
# ─────────────────────────────────────────────────────────────────────────────

display = gamelog.get("display", {})
primary_stats   = display.get("primary", [])
secondary_stats = display.get("secondary", [])
backslash = chr(92)  # used inside f-strings to emit a literal backslash

def stat_pill_line(s, entry_var="entry", config_var="sportConfig"):
    key = s["key"]
    label_key = s.get("localizationKey", f"gamelog.header.{key}")
    label_default = s.get("label", key.upper())
    color = s.get("color", None)

    if key == "dk":
        value = f'String(format: "%.1f", {config_var}.scoringCalculator.score(for: {entry_var}))'
        color_arg = f",\n                color: AppColors.dkGreen"
    elif key == "minutes":
        value = f'{entry_var}.minutes'
        color_arg = ""
    else:
        value = f'"\\\\({entry_var}.{key})"'
        color_arg = ""

    return f"""\
            statPill(
                label: String(localized: "{label_key}", defaultValue: "{label_default}"),
                value: {value}{color_arg}
            )"""

primary_pills   = "\n".join([stat_pill_line(s) for s in primary_stats])
secondary_pills = "\n".join([stat_pill_line(s) for s in secondary_stats])

gamelog_views = header() + f"""\
import SwiftUI
import BKSCore
import BKSUICore

// MARK: - GameLogPlaceholderView

struct GameLogPlaceholderView: View {{
    enum Style {{ case loading, empty }}
    let style: Style

    var body: some View {{
        VStack(spacing: 6) {{
            switch style {{
            case .loading:
                ProgressView()
                    .tint(.white)
                Text(String(localized: "Loading game log...", defaultValue: "Loading game log..."))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(AppOpacity.separator))
            case .empty:
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(AppOpacity.dim))
                Text(String(localized: "No games found", defaultValue: "No games found"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(AppOpacity.separator))
            }}
        }}
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .appCard()
    }}
}}

// MARK: - GameLogTableView

struct GameLogTableView: View {{
    let entries: [GameEntry]
    @Environment({backslash}.sportConfiguration) private var sportConfig

    var body: some View {{
        VStack(spacing: 6) {{
            ForEach(entries) {{ entry in
                if entry.isDNP {{
                    dnpCard(entry: entry)
                }} else {{
                    gameCard(entry: entry)
                }}
            }}
        }}
    }}

    // MARK: - Game Card

    private func gameCard(entry: GameEntry) -> some View {{
        VStack(alignment: .leading, spacing: 4) {{
            gameHeaderRow(entry: entry)
            primaryStatsRow(entry: entry)
            secondaryStatsRow(entry: entry)
        }}
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .appCard()
    }}

    private func gameHeaderRow(entry: GameEntry) -> some View {{
        HStack(spacing: 0) {{
            Text(Self.dateFormatter.string(from: entry.gameDate))
                .foregroundStyle(.white.opacity(AppOpacity.secondary))
            Text(" ")
            Text(entry.isHomeGame
                ? String(localized: "gamelog.vs", defaultValue: "vs")
                : String(localized: "gamelog.at", defaultValue: "at"))
                .foregroundStyle(.white.opacity(AppOpacity.muted))
            Text(" ")
            Text(entry.opponentAbbreviation)
                .foregroundStyle(.white.opacity(AppOpacity.primary))
            Spacer(minLength: 0)
            resultText(for: entry)
        }}
        .font(AppFonts.gameLogHeader)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }}

    private func primaryStatsRow(entry: GameEntry) -> some View {{
        HStack(spacing: 0) {{
{primary_pills}
        }}
        .accessibilityElement(children: .combine)
    }}

    private func secondaryStatsRow(entry: GameEntry) -> some View {{
        HStack(spacing: 0) {{
{secondary_pills}
        }}
        .foregroundStyle(.white.opacity(AppOpacity.secondary))
        .accessibilityElement(children: .combine)
    }}

    // MARK: - Stat Pill

    private func statPill(
        label: String,
        value: String,
        color: Color = .white
    ) -> some View {{
        HStack(spacing: 3) {{
            Text(label)
                .font(AppFonts.gameLogHeader)
                .foregroundStyle(.white.opacity(AppOpacity.muted))
            Text(value)
                .font(AppFonts.gameLogCell)
                .foregroundStyle(color)
        }}
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity)
    }}

    // MARK: - DNP Card

    private func dnpCard(entry: GameEntry) -> some View {{
        VStack(alignment: .leading, spacing: 4) {{
            HStack(spacing: 0) {{
                Text(Self.dateFormatter.string(from: entry.gameDate))
                    .foregroundStyle(AppColors.dnpText)
                Text(" ")
                Text(entry.isHomeGame
                    ? String(localized: "gamelog.vs", defaultValue: "vs")
                    : String(localized: "gamelog.at", defaultValue: "at"))
                    .foregroundStyle(AppColors.dnpText.opacity(0.6))
                Text(" ")
                Text(entry.opponentAbbreviation)
                    .foregroundStyle(AppColors.dnpText)
                Spacer(minLength: 0)
                resultText(for: entry)
            }}
            .font(AppFonts.gameLogHeader)
            .lineLimit(1)

            Text(String(localized: "gamelog.dnp", defaultValue: "DNP"))
                .font(AppFonts.gameLogCell)
                .foregroundStyle(AppColors.dnpText)
        }}
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppColors.dnpBackground)
        .appCard()
    }}

    // MARK: - Helpers

    private func resultText(for entry: GameEntry) -> some View {{
        let prefix = entry.result.isWin
            ? String(localized: "W", defaultValue: "W")
            : String(localized: "L", defaultValue: "L")
        let color: Color = entry.result.isWin ? .green : .red
        return Text("\\\\(prefix) \\\\(entry.result.displayScore)")
            .foregroundStyle(color.opacity(0.9))
    }}

    private static let dateFormatter: DateFormatter = {{
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }}()
}}

// MARK: - GameLogErrorView

struct GameLogErrorView: View {{
    let error: Error
    let onRetry: () -> Void

    var body: some View {{
        VStack(spacing: 10) {{
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.white.opacity(AppOpacity.separator))
            Text(String(localized: "Failed to load game log", defaultValue: "Failed to load game log"))
                .font(.caption)
                .foregroundStyle(.white.opacity(AppOpacity.secondary))
            Text(error.localizedDescription)
                .font(.caption2)
                .foregroundStyle(.white.opacity(AppOpacity.separator))
                .multilineTextAlignment(.center)
            Button(action: onRetry) {{
                Text(String(localized: "Retry", defaultValue: "Retry"))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.white.opacity(AppOpacity.faint))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
            }}
        }}
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .appCard()
    }}
}}
"""

write(os.path.join(out_dir, "App/Sources/Features/Trending/Views/GameLogViews.swift"), gamelog_views)

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

print()
print(f"✅ Scaffolded {app_name} at:")
print(f"   {out_dir}")
print()
print("Generated files:")
print(f"  App/Sources/Core/Utilities/ConfigurationKeys+{swift_name}.swift")
print(f"  App/Sources/Core/Sport/SportPositionMap+{swift_name}.swift")
print(f"  App/Sources/Core/Sport/{calc_name}.swift")
print(f"  App/Sources/Core/Sport/SportConfiguration+{swift_name}.swift")
print(f"  App/Sources/Core/UI/TierThresholds+{swift_name}.swift")
print(f"  App/Sources/Core/Models/GameEntry.swift")
print(f"  App/Sources/Features/Trending/Views/GameLogViews.swift")
print()
print("Project structure (matches BKS-Basketball-Client-iOS):")
print(f"  App/Sources/App/Bootstrap/   ← BKSBasketballApp, AppShell, DependencyContainer,")
print(f"                                  TrendRefreshTask, Authentication, FirebaseAnalyticsAdapter")
print(f"  App/Sources/App/Resources/   ← Info.plist, Assets.xcassets, Localizable.xcstrings,")
print(f"                                  GoogleService-Info.plist, Configuration.plist,")
print(f"                                  BKSBasketball.entitlements, PrivacyInfo.xcprivacy")
print(f"  App/Sources/Core/            ← Services/, Models/, Sport/, Utilities/, UI/")
print(f"  App/Sources/Features/        ← Trending/, Prospecting/, Projecting/ (each with Views/ + Store/)")
print()
print("Next steps:")
print(f"  1. Clone BKS-Basketball-Client-iOS into {out_dir}/")
print(f"     Strip basketball-specific content; the scaffold has already written sport files.")
print(f"  2. In App/Sources/App/Bootstrap/DependencyContainer.swift:")
print(f"       change SportConfiguration.basketball → .{slug}")
print(f"  3. In App/Sources/App/Bootstrap/BKSBasketballApp.swift:")
print(f"       change .sportConfiguration(.basketball) → .{slug}")
print(f"  4. Fill in teamAbbreviationByID in App/Sources/Core/Sport/SportConfiguration+{swift_name}.swift")
print(f"  5. Wire API endpoints in App/Sources/Core/Services/ (four service files)")
print(f"  6. Update App/Sources/App/Resources/:")
print(f"       Info.plist (bundle name), GoogleService-Info.plist (Firebase config)")
print(f"  7. Update project.yml: name, bundleId, scheme name")
print(f"  8. Run: cd App && xcodegen generate --spec project.yml")
PYEOF

# ── copy shared assets ────────────────────────────────────────────────────────

ASSETS_SRC="$SCRIPT_DIR/assets/Assets.xcassets"

if [[ -n "$OUTPUT_DIR" ]]; then
    ASSETS_DST="$OUTPUT_DIR/App/Sources/App/Resources/Assets.xcassets"
else
    REPO_PARENT="$(dirname "$SCRIPT_DIR")"
    SPORT_NAME_CAP="$(python3 -c "import yaml; s=yaml.safe_load(open('$SCRIPT_DIR/sports/$SPORT_SLUG.yaml')); print(s['sport']['name'].replace(' ',''))")"
    PREFIX="$(python3 -c "import yaml; s=yaml.safe_load(open('$SCRIPT_DIR/sports/$SPORT_SLUG.yaml')); print(s['sport']['prefix'])")"
    ASSETS_DST="$REPO_PARENT/$PREFIX-$SPORT_NAME_CAP-Client-iOS/App/Sources/App/Resources/Assets.xcassets"
fi

if [[ -d "$ASSETS_SRC" ]]; then
    mkdir -p "$(dirname "$ASSETS_DST")"
    cp -r "$ASSETS_SRC" "$ASSETS_DST"
    echo "  copied Assets.xcassets → App/Sources/App/Resources/"
    echo "         (AppIcon, InAppIcon, LaunchBackground — shared Black Katt branding)"
else
    echo "  warning: $ASSETS_SRC not found — skipping asset copy"
fi
