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

SCRIPT_DIR="$SCRIPT_DIR" SPORT_SLUG="$SPORT_SLUG" OUTPUT_DIR="$OUTPUT_DIR" python3 << 'PYEOF'
import sys, os, re, textwrap
sys.path.insert(0, '')

try:
    import yaml
except ImportError:
    print("Error: pyyaml not installed. Run: pip3 install pyyaml")
    sys.exit(1)

SCRIPT_DIR  = os.environ["SCRIPT_DIR"]
SPORT_SLUG  = os.environ["SPORT_SLUG"]
OUTPUT_DIR  = os.environ.get("OUTPUT_DIR", "")  # empty string means auto-derive

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
import BKSCore

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

# Build score expression — use var + individual += lines to avoid Swift type-checker timeouts
# on long chained expressions (which occur with 10+ addends).
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
            score_lines.append(f"        total += {expr}")
        else:
            pos_expr = cast + f" * {abs(mul)}"
            score_lines.append(f"        total -= {pos_expr}")
score_expr = "\n".join(score_lines)

# Build bonus logic
bonus_lines = []
for i, b in enumerate(bonuses):
    qualifying = b.get("qualifyingStats", [])
    threshold  = b["threshold"]
    value      = b["value"]
    # Use bonus name (snake_case → camelCase) or fallback to index for unique var names
    raw_name   = b.get("name", f"bonus{i}")
    var_name   = re.sub(r"_([a-z])", lambda m: m.group(1).upper(), raw_name)
    if qualifying:
        quals = ", ".join([f"entry.{q}" for q in qualifying])
        d0 = chr(36) + "0"  # builds "$0" without triggering heredoc shell expansion
        bonus_lines.append(
            f"        let {var_name}Count = [{quals}].filter {{ {d0} >= {threshold} }}.count\n"
            f"        if {var_name}Count >= {threshold} {{ total += {value} }}"
        )
bonus_block = "\n".join(bonus_lines)

calc_file = header() + f"""\
import Foundation
import BKSCore

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
        teamAbbreviationByID: [:] {team_lookup_comment}
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
# 8a. ScoringCalculator.swift  (protocol — app-side, not in BKSCore)
# ─────────────────────────────────────────────────────────────────────────────

scoring_calculator_proto = header() + f"""\
import Foundation

/// Computes a DFS fantasy score for a single game entry.
///
/// Each sport/platform combination provides its own implementation.
protocol ScoringCalculator {{
    /// Returns the DFS fantasy score for the given game entry stats.
    func score(for entry: GameEntry) -> Double
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Sport", "ScoringCalculator.swift"), scoring_calculator_proto)

# ─────────────────────────────────────────────────────────────────────────────
# 8b. SportPositionMap.swift  (base struct — app-side, not in BKSCore)
# ─────────────────────────────────────────────────────────────────────────────

sport_position_map_base = header() + f"""\
import Foundation

/// Maps broad UI chip labels to the raw position strings returned by the API,
/// enabling sport-agnostic position filtering.
struct SportPositionMap {{
    let filterChips: [String]
    private let terms: [String: [String]]

    init(filterChips: [String], terms: [String: [String]]) {{
        self.filterChips = filterChips
        self.terms = terms
    }}

    func matchesChip(_ chip: String?, position: String?) -> Bool {{
        guard let chip else {{ return true }}
        guard let position, !position.isEmpty else {{ return false }}
        guard let chipTerms = terms[chip] else {{ return false }}
        let pos = position.lowercased()
        for term in chipTerms where pos == term.lowercased() {{ return true }}
        if pos.contains("-") {{
            let parts = pos.split(separator: "-").map {{ $0.lowercased() }}
            for part in parts {{
                for term in chipTerms where part == term.lowercased() {{ return true }}
            }}
        }}
        return false
    }}
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Sport", "SportPositionMap.swift"), sport_position_map_base)

# ─────────────────────────────────────────────────────────────────────────────
# 8c. SportConfiguration.swift  (base struct — app-side, not in BKSCore)
# ─────────────────────────────────────────────────────────────────────────────

sport_config_base = header() + f"""\
import BKSCore
import BKSUICore

// MARK: - SportConfiguration

/// Centralises all sport-specific values used by services, views, and reducers.
struct SportConfiguration {{
    let slug: String
    let cacheKeyPrefix: String
    let positionMap: SportPositionMap
    let scoringCalculator: any ScoringCalculator
    let tierThresholds: [TierLevel: [TierThreshold]]
    let trendingFields: [String]
    let opportunityFields: [String]
    let opportunityParams: OpportunityParams
    let projectionParams: ProjectionParams
    let teamAbbreviationByID: [Int: String]

    struct OpportunityParams {{
        let limit: Int
        let platform: String
        let mode: String
    }}

    struct ProjectionParams {{
        let lookahead: Int
        let platform: String
        let mode: String
    }}

    func teamAbbreviation(for teamID: Int) -> String {{
        teamAbbreviationByID[teamID] ?? ""
    }}

    func thresholds(for level: TierLevel) -> [TierThreshold] {{
        tierThresholds[level] ?? []
    }}
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Sport", "SportConfiguration.swift"), sport_config_base)

# ─────────────────────────────────────────────────────────────────────────────
# 8. SportConfiguration+Environment.swift
#    Defines the SwiftUI EnvironmentKey for SportConfiguration.
#    This is app-side code — not part of BKSCore or BKSUICore.
# ─────────────────────────────────────────────────────────────────────────────

sport_config_env = header() + f"""\
import SwiftUI

// MARK: - EnvironmentKey

private struct SportConfigurationKey: EnvironmentKey {{
    static let defaultValue: SportConfiguration = .{slug}
}}

// MARK: - EnvironmentValues

extension EnvironmentValues {{
    /// The active sport configuration injected into the SwiftUI environment.
    var sportConfiguration: SportConfiguration {{
        get {{ self[SportConfigurationKey.self] }}
        set {{ self[SportConfigurationKey.self] = newValue }}
    }}
}}

// MARK: - View Helper

extension View {{
    /// Injects a `SportConfiguration` into the SwiftUI environment.
    func sportConfiguration(_ config: SportConfiguration) -> some View {{
        environment(\\.sportConfiguration, config)
    }}
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Sport", f"SportConfiguration+Environment.swift"), sport_config_env)

# ─────────────────────────────────────────────────────────────────────────────
# 8d. Bootstrap files  (App/Sources/App/Bootstrap/)
#     Minimal entry point + DI container + Firebase wiring.
#     Feature views/services are ported manually as development continues.
# ─────────────────────────────────────────────────────────────────────────────

bootstrap_app = header() + f"""\
import BackgroundTasks
import BKSCore
import BKSUICore
import FirebaseAnalytics
import FirebaseAppCheck
import FirebaseCore
import OSLog
import SwiftUI
import Swinject
import UIKit

@main
struct {type_prefix}App: App {{
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "AppLifecycle"
    )

    @ObservedObject private var authStore: Store<AuthState, AuthIntent>
    @StateObject private var networkMonitor = NetworkMonitor()

    private let configuration: ConfigurationProtocol
    private let auth: AuthenticationProtocol
    private let analyticsAdapter = FirebaseAnalyticsAdapter()

    init() {{
        Self.logLaunchDiagnostics()
        let container = Container.defaultContainer()
        authStore = container.require(Store<AuthState, AuthIntent>.self)
        auth = container.require(AuthenticationProtocol.self)
        configuration = container.require(ConfigurationProtocol.self)
        TrendRefreshTask.register()
    }}

    private static func logLaunchDiagnostics() {{
        let bundle = Bundle.main
        let appName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Unknown"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let bundleID = bundle.bundleIdentifier ?? "Unknown"
        let device = UIDevice.current
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #if DEBUG
            let configuration = "DEBUG"
        #else
            let configuration = "RELEASE"
        #endif
        logger.info("App Launch — \\\\(appName) v\\\\(version) (\\\\(build)) [\\\\(configuration)]")
        logger.info("Device — \\\\(device.model) · \\\\(device.systemName) \\\\(osVersion)")
        logger.debug("Bundle ID — \\\\(bundleID)")
    }}

    @State private var splashDismissed = false

    private var authSessionResolved: Bool {{
        if case .undetermined = authStore.state.session {{ return false }}
        return true
    }}

    var body: some Scene {{
        WindowGroup {{
            rootView
                .environmentObject(networkMonitor)
                .appConfiguration(configuration)
                .sportConfiguration(.{slug})
                .analytics(analyticsAdapter)
                .task {{ authStore.send(.checkStoredCredential) }}
                .onReceive(
                    NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
                ) {{ _ in
                    analyticsAdapter.logEvent(AnalyticsEvent.appBackgrounded, parameters: nil)
                    TrendRefreshTask.scheduleIfNeeded()
                }}
                .onReceive(
                    NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
                ) {{ _ in
                    analyticsAdapter.logEvent(AnalyticsEvent.appForegrounded, parameters: nil)
                }}
                .preferredColorScheme(.dark)
        }}
    }}

    private var rootView: some View {{
        ZStack {{
            switch authStore.state.session {{
            case .undetermined:
                Color.clear
            case .unauthenticated:
                // TODO: Add SignInView once feature views are ported
                Color.clear
            case .authenticated:
                // TODO: Add AppShell once feature views are ported
                Color.clear
            }}
            if !splashDismissed {{
                SplashView(onDismiss: {{ splashDismissed = true }},
                           authSessionResolved: authSessionResolved)
            }}
        }}
        .animation(.easeInOut(duration: 0.4), value: {{
            if case .authenticated = authStore.state.session {{ return true }}
            return false
        }}())
    }}
}}

// MARK: - AppDelegate

final class AppDelegate: NSObject, UIApplicationDelegate {{
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "AppDelegate"
    )

    private static func loadDetailedAnalyticsPreference() {{
        guard let data = UserDefaults.standard.data(forKey: UserPreferences.storageKey),
              let prefs = try? JSONDecoder().decode(UserPreferences.self, from: data)
        else {{ return }}
        FirebaseAnalyticsAdapter.detailedEnabled = prefs.detailedAnalyticsEnabled
    }}

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {{
        #if DEBUG
            AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
            let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
            logger.debug("Bundle identifier: \\\\(bundleID)")
        #else
            AppCheck.setAppCheckProviderFactory(AppAttestProviderFactory())
        #endif
        FirebaseApp.configure()
        Analytics.setAnalyticsCollectionEnabled(true)
        Analytics.logEvent(AnalyticsEvent.appStartUp, parameters: nil)
        Self.loadDetailedAnalyticsPreference()
        return true
    }}
}}
"""

bootstrap_container = header() + f"""\
import Alamofire
import BKSCore
import BKSUICore
import FirebaseAuth
import Swinject

// MARK: - Resolver + require

extension Resolver {{
    func require<T>(_ type: T.Type, name: String? = nil) -> T {{
        if let name {{
            guard let resolved = resolve(type, name: name) else {{
                preconditionFailure("DI: missing registration for \\\\(type) (name: \\\\(name))")
            }}
            return resolved
        }}
        guard let resolved = resolve(type) else {{
            preconditionFailure("DI: missing registration for \\\\(type)")
        }}
        return resolved
    }}
}}

// MARK: - Container

extension Container {{
    @MainActor
    static func defaultContainer() -> Container {{
        let container = Container()
        container.registerSportConfiguration()
        container.registerCoreServices()
        container.registerFeatureStores()
        return container
    }}

    private func registerSportConfiguration() {{
        register(SportConfiguration.self) {{ _ in .{slug} }}.inObjectScope(.container)
    }}

    private func registerCoreServices() {{
        register(LoggerProtocol.self) {{ _ in AppLogger(category: "General") }}
        register(StorageProtocol.self) {{ _ in Storage() }}
        register(ConfigurationProtocol.self) {{ resolver in
            Configuration(storage: resolver.require(StorageProtocol.self))
        }}
        register(NetworkProtocol.self, name: "firebase") {{ _ in
            let authInterceptor = FirebaseAuthInterceptor {{ forcingRefresh in
                guard let user = Auth.auth().currentUser else {{
                    struct Unauthenticated: Error {{}}
                    throw Unauthenticated()
                }}
                return try await user.getIDToken(forcingRefresh: forcingRefresh)
            }}
            let retryPolicy = RetryPolicy(retryLimit: 2, exponentialBackoffBase: 2, exponentialBackoffScale: 0.5)
            let interceptor = Interceptor(adapters: [authInterceptor], retriers: [authInterceptor, retryPolicy])
            return Network(interceptor: interceptor)
        }}
        register(NetworkProtocol.self, name: "apiKey") {{ resolver in
            let config = resolver.require(ConfigurationProtocol.self)
            let apiKeyInterceptor = APIKeyInterceptor(apiKey: config.value(for: .gameLogAPIKey))
            let retryPolicy = RetryPolicy(retryLimit: 2, exponentialBackoffBase: 2, exponentialBackoffScale: 0.5)
            let interceptor = Interceptor(adapters: [apiKeyInterceptor], retriers: [retryPolicy])
            return Network(interceptor: interceptor)
        }}
        register(MetricsCollectorProtocol.self) {{ _ in MetricsCollector() }}.inObjectScope(.container)
        register(AuthenticationProtocol.self) {{ resolver in
            Authentication(configuration: resolver.require(ConfigurationProtocol.self))
        }}
    }}

    @MainActor
    private func registerFeatureStores() {{
        register(Store<AuthState, AuthIntent>.self) {{ resolver in
            let storage = resolver.require(StorageProtocol.self)
            let auth = resolver.require(AuthenticationProtocol.self)
            return MainActor.assumeIsolated {{
                Store(initial: AuthState(), reduce: AuthState.makeReduce(storage: storage, auth: auth))
            }}
        }}
    }}
}}
"""

bootstrap_auth = header() + f"""\
import FirebaseAuth
import BKSCore
import Foundation
import OSLog

final class Authentication: AuthenticationProtocol {{
    private let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "Authentication"
    )

    init(configuration: ConfigurationProtocol) {{}}

    func createUser(withEmail email: String, password: String) async throws -> AuthResult {{
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        return AuthResult(provider: .email, userID: result.user.uid,
                         email: result.user.email, displayName: result.user.displayName)
    }}

    func signIn(withEmail email: String, password: String) async throws -> AuthResult {{
        let result = try await Auth.auth().signIn(withEmail: email, password: password)
        return AuthResult(provider: .email, userID: result.user.uid,
                         email: result.user.email, displayName: result.user.displayName)
    }}

    func sendPasswordReset(toEmail email: String) async throws {{
        try await Auth.auth().sendPasswordReset(withEmail: email)
    }}

    func signOut() {{
        try? Auth.auth().signOut()
    }}

    func deleteAccount() async throws {{
        try await Auth.auth().currentUser?.delete()
    }}

    func validateCredential(_ credential: StoredCredential) async -> Bool {{
        guard let user = Auth.auth().currentUser else {{ return false }}
        return (try? await user.getIDToken(forcingRefresh: false)) != nil
    }}
}}
"""

bootstrap_analytics = header() + f"""\
import BKSCore
import FirebaseAnalytics

struct FirebaseAnalyticsAdapter: AnalyticsConfigurable {{
    static var detailedEnabled = false

    func setDetailedCollectionEnabled(_ enabled: Bool) {{
        Self.detailedEnabled = enabled
    }}

    func logEvent(_ name: String, parameters: [String: String]?) {{
        Analytics.logEvent(name, parameters: parameters)
    }}

    func logDetailedEvent(_ name: String, parameters: [String: String]?) {{
        guard Self.detailedEnabled else {{ return }}
        Analytics.logEvent(name, parameters: parameters)
    }}
}}
"""

bootstrap_trend = header() + f"""\
import BackgroundTasks
import OSLog

enum TrendRefreshTask {{
    static let identifier = "{bundle_id}.trendrefresh"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "TrendRefreshTask"
    )

    static func register() {{
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) {{ task in
            guard let processingTask = task as? BGProcessingTask else {{ return }}
            scheduleIfNeeded()
            // TODO: wire up services once they are ported
            processingTask.setTaskCompleted(success: true)
        }}
    }}

    static func scheduleIfNeeded() {{
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = nextScheduledDate()
        try? BGTaskScheduler.shared.submit(request)
    }}

    private static func nextScheduledDate() -> Date {{
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date.now)
        components.hour = 3; components.minute = 0; components.second = 0
        guard let todayAt3am = Calendar.current.date(from: components) else {{
            return Date.now.addingTimeInterval(86400)
        }}
        return todayAt3am > Date.now
            ? todayAt3am
            : Calendar.current.date(byAdding: .day, value: 1, to: todayAt3am) ?? todayAt3am
    }}
}}
"""

bootstrap_dir = os.path.join(out_dir, "App/Sources/App/Bootstrap")
write(os.path.join(bootstrap_dir, f"{type_prefix}App.swift"), bootstrap_app)
write(os.path.join(bootstrap_dir, "DependencyContainer.swift"), bootstrap_container)
write(os.path.join(bootstrap_dir, "Authentication.swift"), bootstrap_auth)
write(os.path.join(bootstrap_dir, "FirebaseAnalyticsAdapter.swift"), bootstrap_analytics)
write(os.path.join(bootstrap_dir, "TrendRefreshTask.swift"), bootstrap_trend)

# ─────────────────────────────────────────────────────────────────────────────
# 9. project.yml  (XcodeGen spec)
# ─────────────────────────────────────────────────────────────────────────────

pkg      = packages
bkscore_from  = pkg.get("bkscore",   {}).get("from", "1.0.1")
bksuicore_from = pkg.get("bksuicore", {}).get("from", "1.0.16")
swinject_from = pkg.get("swinject",  {}).get("from", "2.9.0")
firebase_from = pkg.get("firebaseSDK", {}).get("from", "11.0.0")
firebase_products = pkg.get("firebaseProducts", ["FirebaseAnalytics", "FirebaseAuth", "FirebaseAppCheck", "FirebaseFirestore"])

firebase_deps = "\n".join(
    [f"      - package: FirebaseSDK\n        product: {p}" for p in firebase_products]
)

app_target = f"{prefix}{swift_name}"  # e.g. BKSBaseball

project_yml = f"""\
name: {app_target}
options:
  bundleIdPrefix: {bundle_id}
  developmentLanguage: en
  deploymentTarget:
    iOS: "{deploy_tgt}"
  xcodeVersion: "{xcode_ver}"
  generateEmptyDirectories: true
  groupSortPosition: top

packages:
  BKSCore:
    url: git@github.com:bkatnich/BKSCore.git
    from: "{bkscore_from}"
  BKSUICore:
    url: git@github.com:bkatnich/BKSUICore.git
    from: "{bksuicore_from}"
  Swinject:
    url: https://github.com/Swinject/Swinject.git
    from: "{swinject_from}"
  FirebaseSDK:
    url: https://github.com/firebase/firebase-ios-sdk.git
    from: "{firebase_from}"

schemes:
  {app_target}:
    build:
      targets:
        {app_target}: all
        {app_target}Tests: [test]
    run:
      config: Debug
      commandLineArguments:
        "-FIRAnalyticsDebugEnabled": true
      environmentVariables:
        - variable: FIRAAppCheckDebugToken
          value: $(FIRA_APP_CHECK_DEBUG_TOKEN)
          isEnabled: true
    test:
      config: Debug
      targets:
        - {app_target}Tests

targets:
  {app_target}:
    type: application
    platform: iOS
    configFiles:
      Debug: Config/Debug.xcconfig
      Release: Config/Release.xcconfig
    preBuildScripts:
      - script: |
          if command -v swiftlint > /dev/null; then
            swiftlint --config "${{PROJECT_DIR}}/../.swiftlint.yml"
          elif [ -f /opt/homebrew/bin/swiftlint ]; then
            /opt/homebrew/bin/swiftlint --config "${{PROJECT_DIR}}/../.swiftlint.yml"
          else
            echo "warning: SwiftLint not installed"
          fi
        name: SwiftLint
        basedOnDependencyAnalysis: false
    sources:
      - path: Sources
        excludes:
          - "**/.gitkeep"
    settings:
      base:
        INFOPLIST_FILE: Sources/App/Resources/Info.plist
        GENERATE_INFOPLIST_FILE: false
        CODE_SIGN_ENTITLEMENTS: Sources/App/Resources/{app_target}.entitlements
        SWIFT_VERSION: "{swift_ver}"
        TARGETED_DEVICE_FAMILY: "1"
        PRODUCT_BUNDLE_IDENTIFIER: {bundle_id}
        ENABLE_USER_SCRIPT_SANDBOXING: NO
    dependencies:
      - package: BKSCore
        product: BKSCore
      - package: BKSUICore
        product: BKSUICore
      - package: Swinject
{firebase_deps}
    resources:
      - path: Sources/App/Resources/Assets.xcassets
      - path: Sources/App/Resources/Localizable.xcstrings
      - path: Sources/App/Resources/PrivacyInfo.xcprivacy
      - path: Sources/App/Resources/Configuration.plist
      - path: Sources/App/Resources/GoogleService-Info.plist

  {app_target}Tests:
    type: bundle.unit-test
    platform: iOS
    configFiles:
      Debug: Config/{app_target}Tests.xcconfig
      Release: Config/{app_target}Tests.xcconfig
    sources:
      - path: Tests
        excludes:
          - "**/.gitkeep"
    settings:
      base:
        SWIFT_VERSION: "{swift_ver}"
        GENERATE_INFOPLIST_FILE: true
    dependencies:
      - target: {app_target}
"""

write(os.path.join(out_dir, "App/project.yml"), project_yml)

# ─────────────────────────────────────────────────────────────────────────────
# 10. xcconfig files
# ─────────────────────────────────────────────────────────────────────────────

base_xcconfig = f"""\
// Base.xcconfig — shared across all configurations
// Do not put secrets in this file.

IPHONEOS_DEPLOYMENT_TARGET = {deploy_tgt}
SWIFT_VERSION = {swift_ver}
SDKROOT = iphoneos
PRODUCT_NAME = $(TARGET_NAME)

// Versioning
MARKETING_VERSION = 0.0.1
CURRENT_PROJECT_VERSION = 1

// App target
ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon
CODE_SIGN_ENTITLEMENTS = Sources/App/Resources/{app_target}.entitlements
CODE_SIGN_IDENTITY = iPhone Developer
DEVELOPMENT_TEAM = PSW5J993A3
ENABLE_USER_SCRIPT_SANDBOXING = NO
GENERATE_INFOPLIST_FILE = NO
INFOPLIST_FILE = Sources/App/Resources/Info.plist
LD_RUNPATH_SEARCH_PATHS = $(inherited) @executable_path/Frameworks
PRODUCT_BUNDLE_IDENTIFIER = {bundle_id}
TARGETED_DEVICE_FAMILY = 1

// Compiler
CLANG_ENABLE_MODULES = YES
CLANG_ENABLE_OBJC_ARC = YES
CLANG_ENABLE_OBJC_WEAK = YES
CLANG_CXX_LANGUAGE_STANDARD = gnu++14
CLANG_CXX_LIBRARY = libc++
GCC_C_LANGUAGE_STANDARD = gnu11
GCC_NO_COMMON_BLOCKS = YES
ENABLE_STRICT_OBJC_MSGSEND = YES
MTL_FAST_MATH = YES
ALWAYS_SEARCH_USER_PATHS = NO

// Warnings
CLANG_ANALYZER_NONNULL = YES
CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE
CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES
CLANG_WARN_BOOL_CONVERSION = YES
CLANG_WARN_COMMA = YES
CLANG_WARN_CONSTANT_CONVERSION = YES
CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES
CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR
CLANG_WARN_DOCUMENTATION_COMMENTS = YES
CLANG_WARN_EMPTY_BODY = YES
CLANG_WARN_ENUM_CONVERSION = YES
CLANG_WARN_INFINITE_RECURSION = YES
CLANG_WARN_INT_CONVERSION = YES
CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES
CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES
CLANG_WARN_OBJC_LITERAL_CONVERSION = YES
CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR
CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES
CLANG_WARN_RANGE_LOOP_ANALYSIS = YES
CLANG_WARN_STRICT_PROTOTYPES = YES
CLANG_WARN_SUSPICIOUS_MOVE = YES
CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE
CLANG_WARN_UNREACHABLE_CODE = YES
CLANG_WARN__DUPLICATE_METHOD_MATCH = YES
GCC_WARN_64_TO_32_BIT_CONVERSION = YES
GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR
GCC_WARN_UNDECLARED_SELECTOR = YES
GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE
GCC_WARN_UNUSED_FUNCTION = YES
GCC_WARN_UNUSED_VARIABLE = YES
"""

debug_template = f"""\
// Debug.xcconfig — development configuration
// Copy this file to Debug.xcconfig and fill in your secret values.
// Debug.xcconfig is gitignored — do NOT commit it.

#include "Base.xcconfig"

// Debug build settings
GCC_OPTIMIZATION_LEVEL = 0
SWIFT_OPTIMIZATION_LEVEL = -Onone
SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG
DEBUG_INFORMATION_FORMAT = dwarf
ENABLE_TESTABILITY = YES
ONLY_ACTIVE_ARCH = YES
GCC_DYNAMIC_NO_PIC = NO
GCC_PREPROCESSOR_DEFINITIONS = $(inherited) DEBUG=1
MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE
COPY_PHASE_STRIP = NO

// Secrets — injected into Info.plist at build time
GAME_LOG_API_KEY = <your-balldontlie-api-key>
FIRA_APP_CHECK_DEBUG_TOKEN = <your-firebase-app-check-debug-token>
APP_ENVIRONMENT = development
"""

release_template = f"""\
// Release.xcconfig — production configuration
// Copy this file to Release.xcconfig and fill in your secret values.
// Release.xcconfig is gitignored — do NOT commit it.

#include "Base.xcconfig"

// Release build settings
SWIFT_OPTIMIZATION_LEVEL = -O
SWIFT_COMPILATION_MODE = wholemodule
DEBUG_INFORMATION_FORMAT = dwarf-with-dsym
ENABLE_NS_ASSERTIONS = NO
MTL_ENABLE_DEBUG_INFO = NO
COPY_PHASE_STRIP = NO

// Secrets — injected into Info.plist at build time
GAME_LOG_API_KEY = <your-production-api-key>
FIRA_APP_CHECK_DEBUG_TOKEN =
APP_ENVIRONMENT = production
"""

tests_xcconfig = f"""\

// {app_target}Tests.xcconfig — test target settings

BUNDLE_LOADER = $(TEST_HOST)
GENERATE_INFOPLIST_FILE = YES
LD_RUNPATH_SEARCH_PATHS = $(inherited) @executable_path/Frameworks @loader_path/Frameworks
PRODUCT_BUNDLE_IDENTIFIER = {bundle_id}Tests
TARGETED_DEVICE_FAMILY = 1
TEST_HOST = $(BUILT_PRODUCTS_DIR)/{app_target}.app/{app_target}
"""

write(os.path.join(out_dir, "App/Config/Base.xcconfig"), base_xcconfig)
write(os.path.join(out_dir, "App/Config/Debug.xcconfig.template"), debug_template)
write(os.path.join(out_dir, "App/Config/Release.xcconfig.template"), release_template)
write(os.path.join(out_dir, f"App/Config/{app_target}Tests.xcconfig"), tests_xcconfig)

# Write actual Debug/Release xcconfig files (gitignored; contain placeholder secrets)
write(os.path.join(out_dir, "App/Config/Debug.xcconfig"), debug_template)
write(os.path.join(out_dir, "App/Config/Release.xcconfig"), release_template)

# Tests directory placeholder so XcodeGen finds the path
write(os.path.join(out_dir, "App/Tests/.gitkeep"), "")

# ─────────────────────────────────────────────────────────────────────────────
# 10. Info.plist
# ─────────────────────────────────────────────────────────────────────────────

info_plist = f"""\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>AppEnvironment</key>
\t<string>$(APP_ENVIRONMENT)</string>
\t<key>BGTaskSchedulerPermittedIdentifiers</key>
\t<array>
\t\t<string>{bundle_id}.trendrefresh</string>
\t</array>
\t<key>CFBundleDevelopmentRegion</key>
\t<string>en</string>
\t<key>CFBundleDisplayName</key>
\t<string>{app_name}</string>
\t<key>CFBundleExecutable</key>
\t<string>$(EXECUTABLE_NAME)</string>
\t<key>CFBundleIdentifier</key>
\t<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
\t<key>CFBundleInfoDictionaryVersion</key>
\t<string>6.0</string>
\t<key>CFBundleName</key>
\t<string>$(PRODUCT_NAME)</string>
\t<key>CFBundlePackageType</key>
\t<string>APPL</string>
\t<key>CFBundleShortVersionString</key>
\t<string>$(MARKETING_VERSION)</string>
\t<key>CFBundleVersion</key>
\t<string>$(CURRENT_PROJECT_VERSION)</string>
\t<key>FirebaseDataCollectionDefaultEnabled</key>
\t<true/>
\t<key>GameLogAPIKey</key>
\t<string>$(GAME_LOG_API_KEY)</string>
\t<key>LSRequiresIPhoneOS</key>
\t<true/>
\t<key>NSHumanReadableCopyright</key>
\t<string>Copyright 2026 Black Katt Technologies Inc.</string>
\t<key>UIApplicationSceneManifest</key>
\t<dict>
\t\t<key>UIApplicationSupportsMultipleScenes</key>
\t\t<false/>
\t</dict>
\t<key>UIBackgroundModes</key>
\t<array>
\t\t<string>fetch</string>
\t\t<string>processing</string>
\t</array>
\t<key>UILaunchScreen</key>
\t<dict>
\t\t<key>UIColorName</key>
\t\t<string>LaunchBackground</string>
\t\t<key>UIImageName</key>
\t\t<string>InAppIcon</string>
\t</dict>
\t<key>UIRequiredDeviceCapabilities</key>
\t<array>
\t\t<string>arm64</string>
\t</array>
\t<key>UISupportedInterfaceOrientations</key>
\t<array>
\t\t<string>UIInterfaceOrientationPortrait</string>
\t</array>
</dict>
</plist>
"""

write(os.path.join(out_dir, "App/Sources/App/Resources/Info.plist"), info_plist)

# ─────────────────────────────────────────────────────────────────────────────
# 11. Configuration.plist  (runtime config — URLs baked in)
# ─────────────────────────────────────────────────────────────────────────────

config_plist = f"""\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>featureFlagsEnabled</key>
\t<false/>
\t<key>networkTimeoutSeconds</key>
\t<real>30</real>
\t<key>gameLogBaseURL</key>
\t<string>{gamelog_base}</string>
\t<key>getPlayersURL</key>
\t<string>{players_url}</string>
\t<key>getOpportunitiesURL</key>
\t<string>{opps_url}</string>
\t<key>gradientTopColor</key>
\t<string>0.05,0.3,0.65</string>
\t<key>gradientBottomColor</key>
\t<string>0.01,0.04,0.1</string>
</dict>
</plist>
"""

write(os.path.join(out_dir, "App/Sources/App/Resources/Configuration.plist"), config_plist)

# ─────────────────────────────────────────────────────────────────────────────
# 12. Entitlements (empty shell)
# ─────────────────────────────────────────────────────────────────────────────

entitlements = """\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
"""

write(os.path.join(out_dir, f"App/Sources/App/Resources/{app_target}.entitlements"), entitlements)

# ─────────────────────────────────────────────────────────────────────────────
# 13. PrivacyInfo.xcprivacy
# ─────────────────────────────────────────────────────────────────────────────

privacy_info = """\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>NSPrivacyTracking</key>
\t<false/>
\t<key>NSPrivacyTrackingDomains</key>
\t<array/>
\t<key>NSPrivacyCollectedDataTypes</key>
\t<array>
\t\t<!-- Firebase Analytics: Device ID or similar identifiers -->
\t\t<dict>
\t\t\t<key>NSPrivacyCollectedDataType</key>
\t\t\t<string>NSPrivacyCollectedDataTypeDeviceID</string>
\t\t\t<key>NSPrivacyCollectedDataTypeLinked</key>
\t\t\t<false/>
\t\t\t<key>NSPrivacyCollectedDataTypeTracking</key>
\t\t\t<false/>
\t\t\t<key>NSPrivacyCollectedDataTypePurposes</key>
\t\t\t<array>
\t\t\t\t<string>NSPrivacyCollectedDataTypePurposeAnalytics</string>
\t\t\t</array>
\t\t</dict>
\t\t<!-- Firebase Analytics: Product Interaction -->
\t\t<dict>
\t\t\t<key>NSPrivacyCollectedDataType</key>
\t\t\t<string>NSPrivacyCollectedDataTypeProductInteraction</string>
\t\t\t<key>NSPrivacyCollectedDataTypeLinked</key>
\t\t\t<false/>
\t\t\t<key>NSPrivacyCollectedDataTypeTracking</key>
\t\t\t<false/>
\t\t\t<key>NSPrivacyCollectedDataTypePurposes</key>
\t\t\t<array>
\t\t\t\t<string>NSPrivacyCollectedDataTypePurposeAnalytics</string>
\t\t\t</array>
\t\t</dict>
\t</array>
\t<key>NSPrivacyAccessedAPITypes</key>
\t<array>
\t\t<dict>
\t\t\t<key>NSPrivacyAccessedAPIType</key>
\t\t\t<string>NSPrivacyAccessedAPICategoryUserDefaults</string>
\t\t\t<key>NSPrivacyAccessedAPITypeReasons</key>
\t\t\t<array>
\t\t\t\t<string>CA92.1</string>
\t\t\t</array>
\t\t</dict>
\t\t<dict>
\t\t\t<key>NSPrivacyAccessedAPIType</key>
\t\t\t<string>NSPrivacyAccessedAPICategorySystemBootTime</string>
\t\t\t<key>NSPrivacyAccessedAPITypeReasons</key>
\t\t\t<array>
\t\t\t\t<string>35F9.1</string>
\t\t\t</array>
\t\t</dict>
\t</array>
</dict>
</plist>
"""

write(os.path.join(out_dir, "App/Sources/App/Resources/PrivacyInfo.xcprivacy"), privacy_info)

# ─────────────────────────────────────────────────────────────────────────────
# 14. GoogleService-Info.plist  (placeholder — must be replaced with real Firebase config)
# ─────────────────────────────────────────────────────────────────────────────

google_service = f"""\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<!-- TODO: Replace with real GoogleService-Info.plist from Firebase console -->
\t<key>BUNDLE_ID</key>
\t<string>{bundle_id}</string>
\t<key>PROJECT_ID</key>
\t<string>trendspotter-dbb4d</string>
\t<key>STORAGE_BUCKET</key>
\t<string>trendspotter-dbb4d.firebasestorage.app</string>
\t<key>IS_ADS_ENABLED</key>
\t<false/>
\t<key>IS_ANALYTICS_ENABLED</key>
\t<false/>
\t<key>IS_GCM_ENABLED</key>
\t<true/>
\t<key>IS_SIGNIN_ENABLED</key>
\t<true/>
</dict>
</plist>
"""

write(os.path.join(out_dir, "App/Sources/App/Resources/GoogleService-Info.plist"), google_service)

# ─────────────────────────────────────────────────────────────────────────────
# 15. .swiftlint.yml
# ─────────────────────────────────────────────────────────────────────────────

swiftlint_yml = """\
# SwiftLint configuration

# Paths to exclude
excluded:
  - Pods
  - Build
  - .build
  - DerivedData
  - .swiftpm
  - App/.build
  - "**/SourcePackages"

# Opt-in rules beyond defaults
opt_in_rules:
  - closure_end_indentation
  - closure_spacing
  - collection_alignment
  - contains_over_filter_count
  - contains_over_first_not_nil
  - empty_collection_literal
  - empty_count
  - empty_string
  - enum_case_associated_values_count
  - explicit_init
  - fatal_error_message
  - first_where
  - force_unwrapping
  - implicit_return
  - last_where
  - literal_expression_end_indentation
  - modifier_order
  - multiline_arguments
  - multiline_parameters
  - operator_usage_whitespace
  - overridden_super_call
  - pattern_matching_keywords
  - prefer_self_in_static_references
  - prefer_self_type_over_type_of_self
  - private_action
  - private_outlet
  - prohibited_super_call
  - redundant_nil_coalescing
  - redundant_type_annotation
  - sorted_first_last
  - toggle_bool
  - trailing_closure
  - unneeded_parentheses_in_closure_argument
  - vertical_parameter_alignment_on_call
  - yoda_condition

# Disabled default rules
disabled_rules:
  - todo
  - opening_brace
  - trailing_comma

# Line length: warn and error at 120
line_length:
  warning: 120
  error: 200
  ignores_urls: true
  ignores_function_declarations: false
  ignores_comments: false
  ignores_interpolated_strings: true

# Type body length
type_body_length:
  warning: 300
  error: 500

# File length
file_length:
  warning: 400
  error: 600
  ignore_comment_only_lines: true

# Function body length
function_body_length:
  warning: 40
  error: 80

# Function parameter count
function_parameter_count:
  warning: 5
  error: 8

# Type name rules
type_name:
  min_length: 3
  max_length: 50

# Identifier name rules
identifier_name:
  min_length:
    warning: 2
    error: 1
  max_length:
    warning: 50
    error: 60
  excluded:
    - id
    - x
    - y
    - i

# Nesting
nesting:
  type_level: 2
  function_level: 3

# Cyclomatic complexity
cyclomatic_complexity:
  warning: 10
  error: 20

# Large tuple
large_tuple:
  warning: 3
  error: 4

# Multiline arguments
multiline_arguments:
  only_enforce_after_first_closure_on_first_line: true

# Reporter
reporter: xcode
"""

write(os.path.join(out_dir, ".swiftlint.yml"), swiftlint_yml)

# ─────────────────────────────────────────────────────────────────────────────
# 16. .swiftformat
# ─────────────────────────────────────────────────────────────────────────────

swiftformat = f"""\
# SwiftFormat configuration
# Minimum Swift version
--swiftversion {swift_ver}

# Indentation
--indent 4
--indentcase false
--ifdef indent
--xcodeindentation disabled

# Braces & spacing
--allman false
--wraparguments before-first
--wrapparameters before-first
--wrapcollections before-first
--wrapconditions after-first
--closingparen balanced

# Self
--self remove
--selfrequired

# Imports
--importgrouping testable-bottom

# Trailing commas
--commas always

# Semicolons
--semicolons never

# Blank lines
--trimwhitespace always
--type-blank-lines remove
--linebreaks lf

# Marks
--markextensions always

# Redundancy
--redundanttype inferred

# Strip unused arguments
--stripunusedargs closure-only

# Organise declarations
--organizetypes class,struct,enum,extension

# Header
--header "// Copyright {{year}} Black Katt Technologies Inc."

# Line length (match SwiftLint)
--maxwidth 120

# Excluded paths
--exclude Pods,Build,.build,DerivedData
"""

write(os.path.join(out_dir, ".swiftformat"), swiftformat)

# ─────────────────────────────────────────────────────────────────────────────
# 17. .gitignore
# ─────────────────────────────────────────────────────────────────────────────

gitignore = """\
#
# Xcode
#

#
# MacOS
#
DS_Store
.AppleDouble
.LSOverride

#
# User settings
#
xcuserdata/
*.xcuserstate
Pods/

#
# App packaging
#
*.ipa
*.dSYM.zip
*.dSYM

#
# Playgrounds
#
timeline.xctimeline
playground.xcworkspace

#
# Xcode automatically generates this directory with a .xcworkspacedata file and xcuserdata
# hence it is not needed unless you have added a package configuration file to your project
#
.swiftpm
.build/
DerivedData/

#
# Index and log files
#
*.xcindex/
*.xcscmblueprint
*.xccheckout

#
# Claude Code
#
.claude/settings.local.json
.claude/gen/

#
# Ignore user data inside the project
#
*.xcodeproj/xcuserdata/
*.xcworkspace/xcuserdata/

#
# Build configuration secrets (xcconfig with API keys)
#
App/Config/Debug.xcconfig
App/Config/Release.xcconfig

#
# Custom Files
#
SCAFFOLD.md
PROJECTGEN.md
"""

write(os.path.join(out_dir, ".gitignore"), gitignore)

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

print()
print(f"✅ Scaffolded {app_name} at:")
print(f"   {out_dir}")
print()
print("Swift source files:")
print(f"  App/Sources/Core/Utilities/ConfigurationKeys+{swift_name}.swift")
print(f"  App/Sources/Core/Sport/ScoringCalculator.swift")
print(f"  App/Sources/Core/Sport/SportPositionMap.swift")
print(f"  App/Sources/Core/Sport/SportConfiguration.swift")
print(f"  App/Sources/Core/Sport/SportPositionMap+{swift_name}.swift")
print(f"  App/Sources/Core/Sport/{calc_name}.swift")
print(f"  App/Sources/Core/Sport/SportConfiguration+{swift_name}.swift")
print(f"  App/Sources/Core/UI/TierThresholds+{swift_name}.swift")
print(f"  App/Sources/Core/Models/GameEntry.swift")
print(f"  App/Sources/Features/Trending/Views/GameLogViews.swift")
print(f"  App/Sources/Core/Sport/SportConfiguration+Environment.swift")
print(f"  App/Sources/App/Bootstrap/{type_prefix}App.swift")
print(f"  App/Sources/App/Bootstrap/DependencyContainer.swift")
print(f"  App/Sources/App/Bootstrap/Authentication.swift")
print(f"  App/Sources/App/Bootstrap/FirebaseAnalyticsAdapter.swift")
print(f"  App/Sources/App/Bootstrap/TrendRefreshTask.swift")
print()
print("Project infrastructure:")
print(f"  App/project.yml                                  ← XcodeGen spec (packages, targets, schemes)")
print(f"  App/<AppName>.xcodeproj/.../swiftpm/Package.resolved  ← pre-pinned SPM versions (no 'Missing package' errors)")
print(f"  App/Config/Base.xcconfig                         ← shared build settings")
print(f"  App/Config/Debug.xcconfig                        ← gitignored; pre-filled with placeholders, add real secrets")
print(f"  App/Config/Debug.xcconfig.template               ← committed template (no secrets)")
print(f"  App/Config/Release.xcconfig                      ← gitignored; pre-filled with placeholders, add real secrets")
print(f"  App/Config/Release.xcconfig.template             ← committed template (no secrets)")
print(f"  App/Tests/.gitkeep                               ← placeholder so XcodeGen sees the Tests/ source path")
print(f"  App/Config/{app_target}Tests.xcconfig")
print(f"  App/Sources/App/Resources/Info.plist")
print(f"  App/Sources/App/Resources/Configuration.plist    ← runtime API URLs")
print(f"  App/Sources/App/Resources/{app_target}.entitlements")
print(f"  App/Sources/App/Resources/PrivacyInfo.xcprivacy")
print(f"  App/Sources/App/Resources/GoogleService-Info.plist  ← placeholder, replace with real Firebase config")
print(f"  .swiftlint.yml")
print(f"  .swiftformat")
print(f"  .gitignore")
print()
print("Next steps:")
print(f"  1. Copy Bootstrap/ source files from BKS-Basketball-Client-iOS and adapt to {swift_name}:")
print(f"       {app_target}App.swift, AppShell.swift, DependencyContainer.swift,")
print(f"       TrendRefreshTask.swift, Authentication.swift, FirebaseAnalyticsAdapter.swift")
print(f"  2. In DependencyContainer.swift: SportConfiguration.basketball → .{slug}")
print(f"  3. In {app_target}App.swift: .sportConfiguration(.basketball) → .{slug}")
print(f"  4. Copy service files from BKS-Basketball-Client-iOS/App/Sources/Core/Services/ and adapt")
print(f"  5. Copy feature Views/ and Store/ from BKS-Basketball-Client-iOS and adapt")
print(f"  6. Replace App/Sources/App/Resources/GoogleService-Info.plist with real Firebase config")
print(f"  7. Fill in teamAbbreviationByID in SportConfiguration+{swift_name}.swift")
print(f"  8. Fill in real API keys in App/Config/Debug.xcconfig (gitignored)")
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

# ── copy shared localizable strings ──────────────────────────────────────────

STRINGS_SRC="$SCRIPT_DIR/assets/Localizable.xcstrings"
STRINGS_DST="$(dirname "$ASSETS_DST")/Localizable.xcstrings"

if [[ -f "$STRINGS_SRC" ]]; then
    cp "$STRINGS_SRC" "$STRINGS_DST"
    echo "  copied Localizable.xcstrings → App/Sources/App/Resources/"
    echo "         (en, fr-CA, es — 100% translated, 257 keys)"
else
    echo "  warning: $STRINGS_SRC not found — skipping strings copy"
fi

# ── run xcodegen ──────────────────────────────────────────────────────────────

APP_DIR="$(dirname "$ASSETS_DST")/../../.."       # App/ relative to Assets.xcassets
APP_DIR="$(cd "$APP_DIR" && pwd)"                # resolve to absolute path

XCODEGEN=""
if command -v xcodegen > /dev/null 2>&1; then
    XCODEGEN="xcodegen"
elif [[ -f /opt/homebrew/bin/xcodegen ]]; then
    XCODEGEN="/opt/homebrew/bin/xcodegen"
elif [[ -f /usr/local/bin/xcodegen ]]; then
    XCODEGEN="/usr/local/bin/xcodegen"
fi

if [[ -n "$XCODEGEN" ]]; then
    echo ""
    echo "Running xcodegen..."
    "$XCODEGEN" generate --spec "$APP_DIR/project.yml" --project "$APP_DIR"
    echo "  ✅ Xcode project generated"

    XCODEPROJ="$(find "$APP_DIR" -maxdepth 1 -name "*.xcodeproj" | head -1)"

    # Write Package.resolved so Xcode has pinned versions on first open and
    # doesn't show "Missing package product" errors.
    if [[ -n "$XCODEPROJ" ]]; then
        SWIFTPM_DIR="$XCODEPROJ/project.xcworkspace/xcshareddata/swiftpm"
        mkdir -p "$SWIFTPM_DIR"
        cat > "$SWIFTPM_DIR/Package.resolved" << 'RESOLVED_EOF'
{
  "originHash" : "7ed8aa1e303d9c60d4b08edd19d6e53f1343180f51491033bcc3509c3dd38a76",
  "pins" : [
    {
      "identity" : "abseil-cpp-binary",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/google/abseil-cpp-binary.git",
      "state" : {
        "revision" : "bbe8b69694d7873315fd3a4ad41efe043e1c07c5",
        "version" : "1.2024072200.0"
      }
    },
    {
      "identity" : "alamofire",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/Alamofire/Alamofire.git",
      "state" : {
        "revision" : "e938f8c66708e7352fc7e3512647fa54255b267a",
        "version" : "5.11.2"
      }
    },
    {
      "identity" : "app-check",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/google/app-check.git",
      "state" : {
        "revision" : "61b85103a1aeed8218f17c794687781505fbbef5",
        "version" : "11.2.0"
      }
    },
    {
      "identity" : "bkscore",
      "kind" : "remoteSourceControl",
      "location" : "git@github.com:bkatnich/BKSCore.git",
      "state" : {
        "revision" : "c83ff215356a99fcaad4ee2849936345cf59d34b",
        "version" : "1.0.1"
      }
    },
    {
      "identity" : "bksuicore",
      "kind" : "remoteSourceControl",
      "location" : "git@github.com:bkatnich/BKSUICore.git",
      "state" : {
        "revision" : "fc63ec0113d619fb8de21f6288a0d2eeb9e9fe58",
        "version" : "1.0.15"
      }
    },
    {
      "identity" : "firebase-ios-sdk",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/firebase/firebase-ios-sdk.git",
      "state" : {
        "revision" : "fdc352fabaf5916e7faa1f96ad02b1957e93e5a5",
        "version" : "11.15.0"
      }
    },
    {
      "identity" : "google-ads-on-device-conversion-ios-sdk",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/googleads/google-ads-on-device-conversion-ios-sdk",
      "state" : {
        "revision" : "a2d0f1f1666de591eb1a811f40b1706f5c63a2ed",
        "version" : "2.3.0"
      }
    },
    {
      "identity" : "googleappmeasurement",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/google/GoogleAppMeasurement.git",
      "state" : {
        "revision" : "45ce435e9406d3c674dd249a042b932bee006f60",
        "version" : "11.15.0"
      }
    },
    {
      "identity" : "googledatatransport",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/google/GoogleDataTransport.git",
      "state" : {
        "revision" : "617af071af9aa1d6a091d59a202910ac482128f9",
        "version" : "10.1.0"
      }
    },
    {
      "identity" : "googleutilities",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/google/GoogleUtilities.git",
      "state" : {
        "revision" : "60da361632d0de02786f709bdc0c4df340f7613e",
        "version" : "8.1.0"
      }
    },
    {
      "identity" : "grpc-binary",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/google/grpc-binary.git",
      "state" : {
        "revision" : "75b31c842f664a0f46a2e590a570e370249fd8f6",
        "version" : "1.69.1"
      }
    },
    {
      "identity" : "gtm-session-fetcher",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/google/gtm-session-fetcher.git",
      "state" : {
        "revision" : "c756a29784521063b6a1202907e2cc47f41b667c",
        "version" : "4.5.0"
      }
    },
    {
      "identity" : "interop-ios-for-google-sdks",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/google/interop-ios-for-google-sdks.git",
      "state" : {
        "revision" : "040d087ac2267d2ddd4cca36c757d1c6a05fdbfe",
        "version" : "101.0.0"
      }
    },
    {
      "identity" : "leveldb",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/firebase/leveldb.git",
      "state" : {
        "revision" : "a0bc79961d7be727d258d33d5a6b2f1023270ba1",
        "version" : "1.22.5"
      }
    },
    {
      "identity" : "nanopb",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/firebase/nanopb.git",
      "state" : {
        "revision" : "b7e1104502eca3a213b46303391ca4d3bc8ddec1",
        "version" : "2.30910.0"
      }
    },
    {
      "identity" : "promises",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/google/promises.git",
      "state" : {
        "revision" : "540318ecedd63d883069ae7f1ed811a2df00b6ac",
        "version" : "2.4.0"
      }
    },
    {
      "identity" : "swift-protobuf",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/apple/swift-protobuf.git",
      "state" : {
        "revision" : "a008af1a102ff3dd6cc3764bb69bf63226d0f5f6",
        "version" : "1.36.1"
      }
    },
    {
      "identity" : "swinject",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/Swinject/Swinject.git",
      "state" : {
        "revision" : "b685b549fe4d8ae265fc7a2f27d0789720425d69",
        "version" : "2.10.0"
      }
    }
  ],
  "version" : 3
}
RESOLVED_EOF
        echo "  wrote  Package.resolved (pinned package versions)"
        echo "  Opening project in Xcode (packages pre-pinned, no resolution required)..."
        open "$XCODEPROJ"
    fi
else
    echo ""
    echo "  warning: xcodegen not found — skipping project generation"
    echo "           Install via: brew install xcodegen"
    echo "           Then run:    cd $APP_DIR && xcodegen generate --spec project.yml"
fi
