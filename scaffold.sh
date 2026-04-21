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

players_api      = api.get("players", {})
opps_api         = api.get("opportunities", {})
proj_api         = api.get("projections", {})
today_api        = api.get("todayGames", {})
gamelog_api      = api.get("gameLog", {})
league_state_api = api.get("leagueState", {})
bracket_api      = api.get("playoffBracket", {})
promo_api        = api.get("redeemPromoCode", {})

players_url      = players_api.get("url", "")
opps_url         = opps_api.get("url", "")
proj_url         = proj_api.get("url", "")
today_url        = today_api.get("url", "")
gamelog_base     = gamelog_api.get("baseURL", "")
api_key_needed   = gamelog_api.get("apiKeyRequired", False)
league_state_url = league_state_api.get("url", "")
bracket_url      = bracket_api.get("url", "")
promo_url        = promo_api.get("url", "")

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
    static let getLeagueStateURL = ConfigurationKey(
        name: "getLeagueStateURL",
        defaultValue: "{league_state_url}"
    )
    static let getPlayoffBracketURL = ConfigurationKey(
        name: "getPlayoffBracketURL",
        defaultValue: "{bracket_url}"
    )
    static let redeemPromoCodeURL = ConfigurationKey(
        name: "redeemPromoCodeURL",
        defaultValue: "{promo_url}"
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

    private var scores: (team: Int, opponent: Int) {{
        switch self {{
        case let .win(team, opponent): (team, opponent)
        case let .loss(team, opponent): (team, opponent)
        }}
    }}

    var displayScore: String {{
        "\\\\(scores.team)-\\\\(scores.opponent)"
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
        let color: Color = entry.result.isWin ? .green : .red
        let winLoss: String = entry.result.isWin
            ? String(localized: "W", defaultValue: "W")
            : String(localized: "L", defaultValue: "L")
        return Text(winLoss + " " + entry.result.displayScore)
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
#     Fully-wired entry point + DI container + Firebase wiring.
# ─────────────────────────────────────────────────────────────────────────────

bootstrap_app = header() + f"""\
// swiftlint:disable file_length

import BackgroundTasks
import BKSCore
import BKSUICore
import FirebaseAnalytics
import FirebaseAppCheck
import FirebaseCore
import FirebaseInAppMessaging
import FirebaseMessaging
import OSLog
import SwiftUI
import Swinject
import UIKit
import UserNotifications

@main
struct {type_prefix}App: App {{
    /// Register app delegate for Firebase setup
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "AppLifecycle"
    )

    @ObservedObject private var boardStore: Store<BoardState, BoardIntent>
    @ObservedObject private var authStore: Store<AuthState, AuthIntent>
    @ObservedObject private var profileStore: Store<ProfileState, ProfileIntent>
    @ObservedObject private var signInStore: Store<SignInState, SignInIntent>

    @StateObject private var networkMonitor = NetworkMonitor()

    private let trendingsService: TrendingsServiceProtocol
    private let opportunitiesService: OpportunitiesServiceProtocol
    private let projectionsService: ProjectionsServiceProtocol
    private let gamesService: GamesServiceProtocol
    private let promoCodeService: PromoCodeServiceProtocol
    private let configuration: ConfigurationProtocol
    private let auth: AuthenticationProtocol
    private let analyticsAdapter = FirebaseAnalyticsAdapter()
    private let metricsCollector: MetricsCollectorProtocol

    init() {{
        Self.logLaunchDiagnostics()

        let container = Container.defaultContainer()

        let resolvedAuth = container.require(Store<AuthState, AuthIntent>.self)
        authStore = resolvedAuth

        let resolvedBoard = container.require(Store<BoardState, BoardIntent>.self)
        boardStore = resolvedBoard

        let resolvedAuth2 = container.require(AuthenticationProtocol.self)
        auth = resolvedAuth2

        profileStore = Self.makeProfileStore(container: container, authStore: resolvedAuth, auth: resolvedAuth2)

        configuration = container.require(ConfigurationProtocol.self)
        trendingsService = container.require(TrendingsServiceProtocol.self)
        opportunitiesService = container.require(OpportunitiesServiceProtocol.self)
        projectionsService = container.require(ProjectionsServiceProtocol.self)
        gamesService = container.require(GamesServiceProtocol.self)
        promoCodeService = container.require(PromoCodeServiceProtocol.self)
        metricsCollector = container.require(MetricsCollectorProtocol.self)
        metricsCollector.startCollecting()

        // Store container on AppDelegate so silent push can resolve services
        (UIApplication.shared.delegate as? AppDelegate)?.container = container

        signInStore = Self.makeSignInStore(
            container: container,
            authStore: resolvedAuth,
            trendingsService: trendingsService,
            opportunitiesService: opportunitiesService,
            projectionsService: projectionsService,
            gamesService: gamesService
        )

        DataRefreshTask.register(
            trendingsService: trendingsService,
            opportunitiesService: opportunitiesService,
            projectionsService: projectionsService,
            gamesService: gamesService
        )
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

        logger.info(\"\"\"
        App Launch — \\(appName, privacy: .public) \\
        v\\(version, privacy: .public) (\\(build, privacy: .public)) \\
        [\\(configuration, privacy: .public)]
        \"\"\")
        logger.info(\"\"\"
        Device — \\(device.model, privacy: .public) · \\
        \\(device.systemName, privacy: .public) \\(osVersion, privacy: .public)
        \"\"\")
        logger.debug("Bundle ID — \\(bundleID, privacy: .public)")
    }}

    @State private var splashDismissed = false
    @State private var pendingSignUpResult: AuthResult?

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
                .task {{
                    authStore.send(.checkStoredCredential)
                    profileStore.send(.onAppear)
                    await prefetchAllData()
                    await Self.registerForPushNotifications()
                }}
                .onReceive(
                    NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
                ) {{ _ in
                    analyticsAdapter.logEvent(AnalyticsEvent.appBackgrounded, parameters: nil)
                    DataRefreshTask.scheduleIfNeeded()
                }}
                .onReceive(
                    NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
                ) {{ _ in
                    analyticsAdapter.logEvent(AnalyticsEvent.appForegrounded, parameters: nil)
                }}
                .preferredColorScheme(.dark)
        }}
    }}

    @MainActor
    private static func makeProfileStore(
        container: Container,
        authStore: Store<AuthState, AuthIntent>,
        auth: AuthenticationProtocol
    ) -> Store<ProfileState, ProfileIntent> {{
        let storage = container.require(StorageProtocol.self)
        let eraseDeviceData: @MainActor @Sendable () -> Void = {{
            try? storage.deleteAll(from: .file)
            try? storage.deleteAll(from: .userDefaults)
            try? storage.deleteAll(from: .keychain)
            authStore.send(.signOutRequested)
        }}
        let signOut: @MainActor @Sendable () -> Void = {{ authStore.send(.signOutRequested) }}
        let removeAccount: @MainActor @Sendable () async throws -> Void = {{ try await auth.deleteAccount() }}
        let reduce = ProfileState.makeReduce(
            storage: storage,
            analytics: FirebaseAnalyticsAdapter(),
            onSignOutRequested: signOut,
            onEraseDeviceData: eraseDeviceData,
            onRemoveAccount: removeAccount
        )
        return Store(initial: ProfileState(), reduce: reduce)
    }}

    @MainActor
    // swiftlint:disable:next function_parameter_count
    private static func makeSignInStore(
        container: Container,
        authStore: Store<AuthState, AuthIntent>,
        trendingsService: TrendingsServiceProtocol,
        opportunitiesService: OpportunitiesServiceProtocol,
        projectionsService: ProjectionsServiceProtocol,
        gamesService: GamesServiceProtocol
    ) -> Store<SignInState, SignInIntent> {{
        let auth = container.require(AuthenticationProtocol.self)
        let storage = container.require(StorageProtocol.self)
        let reduce = SignInState.makeReduce(
            auth: auth,
            storage: storage
        ) {{ result in
            FirebaseAnalyticsAdapter().logEvent(AnalyticsEvent.signInCompleted, parameters: nil)
            authStore.send(.signInSucceeded(result))
            Task {{
                await prefetchAllData(
                    trendingsService: trendingsService,
                    opportunitiesService: opportunitiesService,
                    projectionsService: projectionsService,
                    gamesService: gamesService
                )
            }}
        }}
        return Store(
            initial: SignInState(),
            reduce: reduce
        )
    }}

    private func prefetchAllData() async {{
        await Self.prefetchAllData(
            trendingsService: trendingsService,
            opportunitiesService: opportunitiesService,
            projectionsService: projectionsService,
            gamesService: gamesService
        )
    }}

    private static func prefetchAllData(
        trendingsService: TrendingsServiceProtocol,
        opportunitiesService: OpportunitiesServiceProtocol,
        projectionsService: ProjectionsServiceProtocol,
        gamesService: GamesServiceProtocol
    ) async {{
        let log = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
            category: "AppLifecycle"
        )
        await withTaskGroup(of: Void.self) {{ group in
            group.addTask {{
                do {{
                    let players = try await trendingsService.fetchPlayers()
                    log.info("Prefetched \\(players.count, privacy: .public) players")
                }} catch {{
                    log.error("Trending prefetch failed: \\(error.diagnosticDescription, privacy: .public)")
                }}
            }}
            group.addTask {{
                do {{
                    let result = try await opportunitiesService.fetchOpportunities()
                    log.info("Prefetched \\(result.opportunities.count, privacy: .public) opportunities")
                }} catch {{
                    log.error("Opportunities prefetch failed: \\(error.diagnosticDescription, privacy: .public)")
                }}
            }}
            group.addTask {{
                do {{
                    let projections = try await projectionsService.fetchProjections()
                    log.info("Prefetched \\(projections.count, privacy: .public) projections")
                }} catch {{
                    log.error("Projections prefetch failed: \\(error.diagnosticDescription, privacy: .public)")
                }}
            }}
            group.addTask {{
                do {{
                    let schedule = try await gamesService.fetchTodaySchedule()
                    log.info("Prefetched today schedule: \\(schedule.gameCount, privacy: .public) game(s)")
                }} catch {{
                    log.error("Today schedule prefetch failed: \\(error.diagnosticDescription, privacy: .public)")
                }}
            }}
        }}
    }}

    /// Requests notification permission and registers with APNs.
    /// Called after launch so the prompt appears after the user sees the app.
    private static func registerForPushNotifications() async {{
        do {{
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {{ return }}
            await MainActor.run {{
                UIApplication.shared.registerForRemoteNotifications()
            }}
        }} catch {{
            // Permission denied or unavailable — silent failure is intentional
        }}
    }}

    private var signInView: some View {{
        SignInView(store: signInStore, animateIn: splashDismissed, auth: auth) {{ result in
            analyticsAdapter.logEvent(AnalyticsEvent.signUpCompleted, parameters: nil)
            pendingSignUpResult = result
        }}
    }}

    private var rootView: some View {{
        ZStack {{
            switch authStore.state.session {{
            case .undetermined:
                Color.clear

            case .unauthenticated:
                if let pendingResult = pendingSignUpResult {{
                    promoCodeInterstitial(for: pendingResult)
                        .compositingGroup()
                        .transition(.opacity)
                }} else {{
                    signInView
                        .compositingGroup()
                        .transition(.opacity)
                }}

            case let .authenticated(credential):
                AppShell(
                    boardStore: boardStore,
                    profileStore: profileStore,
                    credential: credential,
                    trendingsService: trendingsService,
                    gamesService: gamesService,
                    promoCodeService: promoCodeService
                )
                .compositingGroup()
                .transition(.opacity)
            }}

            if !splashDismissed {{
                SplashView(onDismiss: {{
                    splashDismissed = true
                }}, authSessionResolved: authSessionResolved)
            }}
        }}
        .animation(.easeInOut(duration: 0.4), value: {{
            if case .authenticated = authStore.state.session {{ return true }}
            return false
        }}())
    }}

    private func promoCodeInterstitial(for result: AuthResult) -> some View {{
        let ts = trendingsService, os = opportunitiesService, ps = projectionsService, gs = gamesService
        let store = Store(
            initial: PromoCodeState(),
            reduce: PromoCodeState.makeReduce(service: promoCodeService) {{
                authStore.send(.signInSucceeded(result))
                pendingSignUpResult = nil
                Task {{
                    await Self.prefetchAllData(
                        trendingsService: ts,
                        opportunitiesService: os,
                        projectionsService: ps,
                        gamesService: gs
                    )
                }}
            }}
        )
        return PromoCodeView(store: store, showSkip: true)
    }}
}}

// MARK: - AppDelegate

// swiftlint:disable:next line_length
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate, InAppMessagingDisplayDelegate {{
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "AppDelegate"
    )

    /// Stored so the silent-push handler can resolve services for a force-refresh.
    var container: Container?

    /// Pre-loads the detailed analytics preference so the adapter flag
    /// is ready before the profile store is created.
    private static func loadDetailedAnalyticsPreference() {{
        guard let data = UserDefaults.standard.data(forKey: UserPreferences.storageKey),
              let prefs = try? JSONDecoder().decode(UserPreferences.self, from: data)
        else {{
            return
        }}
        FirebaseAnalyticsAdapter.detailedEnabled = prefs.detailedAnalyticsEnabled
    }}

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {{
        #if DEBUG
            AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
            let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
            logger.debug("Bundle identifier: \\(bundleID, privacy: .public)")
        #else
            AppCheck.setAppCheckProviderFactory(AppAttestProviderFactory())
        #endif
        logger.debug("FirebaseApp.configure() — starting")
        FirebaseApp.configure()
        if FirebaseApp.app() != nil {{
            logger.debug("FirebaseApp.configure() — succeeded")
        }} else {{
            logger.error("FirebaseApp.configure() — failed, app is nil")
        }}

        // Register delegates for notifications and FCM token delivery
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self

        // Fix Firebase In-App Messaging in SwiftUI: supply the active window scene
        // so the SDK can present over the correct UIWindowScene rather than keyWindow
        InAppMessaging.inAppMessaging().delegate = self

        // Basic analytics are always collected.
        // Detailed analytics require user opt-in via the Profile toggle.
        Analytics.setAnalyticsCollectionEnabled(true)
        Analytics.logEvent(AnalyticsEvent.appStartUp, parameters: nil)
        Self.loadDetailedAnalyticsPreference()
        return true
    }}

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {{
        // Forward APNs token to Firebase Messaging so FCM can send pushes
        Messaging.messaging().apnsToken = deviceToken
        let token = deviceToken.map {{ String(format: "%02.2hhx", $0) }}.joined()
        logger.info("APNs device token: \\(token, privacy: .public)")
    }}

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {{
        logger.warning("APNs registration failed: \\(error.localizedDescription, privacy: .public)")
    }}

    // MARK: - MessagingDelegate

    /// Called by Firebase Messaging once both the APNs token and FCM registration token are ready.
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {{
        guard let fcmToken else {{ return }}
        logger.info("FCM Token — \\(fcmToken, privacy: .public)")
    }}

    // MARK: - InAppMessagingDisplayDelegate

    func messageClicked(_ inAppMessage: InAppMessagingDisplayMessage, with action: InAppMessagingAction) {{
        logger.info("In-app message clicked: \\(inAppMessage.campaignInfo.campaignName, privacy: .public)")
    }}

    func messageDismissed(_ inAppMessage: InAppMessagingDisplayMessage,
                          dismissType: InAppMessagingDismissType) {{
        logger.info("In-app message dismissed: \\(inAppMessage.campaignInfo.campaignName, privacy: .public)")
    }}

    func impressionDetected(for inAppMessage: InAppMessagingDisplayMessage) {{
        logger.info("In-app message displayed: \\(inAppMessage.campaignInfo.campaignName, privacy: .public)")
    }}

    func displayError(for inAppMessage: InAppMessagingDisplayMessage, error: Error) {{
        logger.warning("In-app message display error: \\(error.localizedDescription, privacy: .public)")
    }}

    // MARK: - UNUserNotificationCenterDelegate

    /// Case 1: Foreground notification — show banner/sound/badge while app is open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {{
        let userInfo = notification.request.content.userInfo
        logger.info("Foreground notification received: \\(userInfo, privacy: .public)")
        // Also forward to Messaging (swizzling disabled)
        Messaging.messaging().appDidReceiveMessage(userInfo)
        completionHandler([.banner, .sound, .badge])
    }}

    /// Case 2: User tapped a notification — handle deep-link or action from payload.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {{
        let userInfo = response.notification.request.content.userInfo
        logger.info("Notification tapped: \\(userInfo, privacy: .public)")
        Messaging.messaging().appDidReceiveMessage(userInfo)
        // Future: parse userInfo and post a NotificationCenter event to navigate the app
        completionHandler()
    }}

    /// Case 3: All remote notifications — foreground, background, and silent.
    /// This fires for every remote push regardless of content-available.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {{
        let state: String
        switch application.applicationState {{
        case .active:      state = "foreground"
        case .background:  state = "background"
        case .inactive:    state = "inactive"
        @unknown default:  state = "unknown"
        }}
        logger.info("Remote notification [\\(state, privacy: .public)]: \\(userInfo, privacy: .public)")

        // Forward to Messaging (swizzling disabled)
        Messaging.messaging().appDidReceiveMessage(userInfo)

        // If content-available: 1, treat as data refresh signal
        let aps = userInfo["aps"] as? [String: Any]
        let contentAvailable = aps?["content-available"] as? Int ?? 0
        guard contentAvailable == 1 else {{
            completionHandler(.noData)
            return
        }}

        logger.info("Silent push — triggering force refresh")
        guard
            let storage = container?.resolve(StorageProtocol.self),
            let trendingsService = container?.resolve(TrendingsServiceProtocol.self),
            let opportunitiesService = container?.resolve(OpportunitiesServiceProtocol.self),
            let projectionsService = container?.resolve(ProjectionsServiceProtocol.self),
            let gamesService = container?.resolve(GamesServiceProtocol.self)
        else {{
            logger.error("Silent push — DI container not ready")
            completionHandler(.failed)
            return
        }}
        Task {{
            await DataRefreshTask.forceClearAndRefresh(
                storage: storage,
                trendingsService: trendingsService,
                opportunitiesService: opportunitiesService,
                projectionsService: projectionsService,
                gamesService: gamesService
            )
            completionHandler(.newData)
        }}
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
        container.registerDomainServices()
        container.registerFeatureStores()
        return container
    }}

    private func registerSportConfiguration() {{
        register(SportConfiguration.self) {{ _ in .{slug} }}.inObjectScope(.container)
    }}

    // swiftlint:disable:next function_body_length
    private func registerCoreServices() {{
        register(LoggerProtocol.self) {{ _ in AppLogger(category: "General") }}
        register(StorageProtocol.self) {{ _ in Storage() }}
        register(ConfigurationProtocol.self) {{ resolver in
            Configuration(storage: resolver.require(StorageProtocol.self))
        }}
        register(NetworkProtocol.self, name: "firebase") {{ _ in
            let authInterceptor = FirebaseAuthInterceptor {{ forcingRefresh in
                guard let user = Auth.auth().currentUser else {{
                    throw TrendingsServiceError.unauthenticated
                }}
                return try await user.getIDToken(forcingRefresh: forcingRefresh)
            }}
            let retryPolicy = RetryPolicy(
                retryLimit: 2,
                exponentialBackoffBase: 2,
                exponentialBackoffScale: 0.5
            )
            let interceptor = Interceptor(
                adapters: [authInterceptor],
                retriers: [authInterceptor, retryPolicy]
            )
            return Network(interceptor: interceptor)
        }}
        register(NetworkProtocol.self, name: "apiKey") {{ resolver in
            let config = resolver.require(ConfigurationProtocol.self)
            let apiKeyInterceptor = APIKeyInterceptor(apiKey: config.value(for: .gameLogAPIKey))
            let retryPolicy = RetryPolicy(
                retryLimit: 2,
                exponentialBackoffBase: 2,
                exponentialBackoffScale: 0.5
            )
            let interceptor = Interceptor(
                adapters: [apiKeyInterceptor],
                retriers: [retryPolicy]
            )
            return Network(interceptor: interceptor)
        }}
        register(MetricsCollectorProtocol.self) {{ _ in MetricsCollector() }}.inObjectScope(.container)
        register(AuthenticationProtocol.self) {{ resolver in
            Authentication(configuration: resolver.require(ConfigurationProtocol.self))
        }}
    }}

    private func registerDomainServices() {{
        register(TrendingsServiceProtocol.self) {{ resolver in
            TrendingsService(
                network: resolver.require(NetworkProtocol.self, name: "firebase"),
                storage: resolver.require(StorageProtocol.self),
                configuration: resolver.require(ConfigurationProtocol.self),
                sportConfiguration: resolver.require(SportConfiguration.self)
            )
        }}.inObjectScope(.container)
        register(OpportunitiesServiceProtocol.self) {{ resolver in
            OpportunitiesService(
                network: resolver.require(NetworkProtocol.self, name: "firebase"),
                storage: resolver.require(StorageProtocol.self),
                configuration: resolver.require(ConfigurationProtocol.self),
                sportConfiguration: resolver.require(SportConfiguration.self)
            )
        }}.inObjectScope(.container)
        register(ProjectionsServiceProtocol.self) {{ resolver in
            ProjectionsService(
                network: resolver.require(NetworkProtocol.self, name: "firebase"),
                storage: resolver.require(StorageProtocol.self),
                configuration: resolver.require(ConfigurationProtocol.self),
                sportConfiguration: resolver.require(SportConfiguration.self)
            )
        }}.inObjectScope(.container)
        register(GamesServiceProtocol.self) {{ resolver in
            GamesService(
                network: resolver.require(NetworkProtocol.self, name: "apiKey"),
                firebaseNetwork: resolver.require(NetworkProtocol.self, name: "firebase"),
                storage: resolver.require(StorageProtocol.self),
                configuration: resolver.require(ConfigurationProtocol.self),
                sportConfiguration: resolver.require(SportConfiguration.self)
            )
        }}
        register(PromoCodeServiceProtocol.self) {{ resolver in
            PromoCodeService(
                network: resolver.require(NetworkProtocol.self, name: "firebase"),
                configuration: resolver.require(ConfigurationProtocol.self)
            )
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
        register(Store<BoardState, BoardIntent>.self) {{ resolver in
            let trendingsService = resolver.require(TrendingsServiceProtocol.self)
            let projectionService = resolver.require(ProjectionsServiceProtocol.self)
            let opportunityService = resolver.require(OpportunitiesServiceProtocol.self)
            let gamesService = resolver.require(GamesServiceProtocol.self)
            let positionMap = resolver.require(SportConfiguration.self).positionMap
            return MainActor.assumeIsolated {{
                Store(
                    initial: BoardState(),
                    reduce: BoardState.makeReduce(
                        trendingsService: trendingsService,
                        projectionService: projectionService,
                        opportunityService: opportunityService,
                        gamesService: gamesService,
                        positionMap: positionMap
                    )
                )
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
        return AuthResult(
            provider: .email,
            userID: result.user.uid,
            email: result.user.email,
            displayName: result.user.displayName
        )
    }}

    func signIn(withEmail email: String, password: String) async throws -> AuthResult {{
        let result = try await Auth.auth().signIn(withEmail: email, password: password)
        return AuthResult(
            provider: .email,
            userID: result.user.uid,
            email: result.user.email,
            displayName: result.user.displayName
        )
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

bootstrap_data_refresh = header() + f"""\
import BackgroundTasks
import BKSCore
import OSLog

// MARK: - DataRefreshTask

/// Registers and schedules a BGProcessingTask that refreshes trending stats
/// once per day, targeting 3am local time.
enum DataRefreshTask {{
    static let identifier = "{bundle_id}.datarefresh"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "DataRefreshTask"
    )

    // MARK: - Registration

    static func register(
        trendingsService: TrendingsServiceProtocol,
        opportunitiesService: OpportunitiesServiceProtocol,
        projectionsService: ProjectionsServiceProtocol,
        gamesService: GamesServiceProtocol
    ) {{
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) {{ task in
            guard let processingTask = task as? BGProcessingTask else {{ return }}
            handle(
                processingTask,
                trendingsService: trendingsService,
                opportunitiesService: opportunitiesService,
                projectionsService: projectionsService,
                gamesService: gamesService
            )
        }}
    }}

    // MARK: - Scheduling

    static func scheduleIfNeeded() {{
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = nextScheduledDate()

        do {{
            try BGTaskScheduler.shared.submit(request)
            logger.info("Data refresh scheduled for \\(nextScheduledDate(), privacy: .public)")
        }} catch {{
            logger.warning("Failed to schedule trend refresh: \\(error.diagnosticDescription, privacy: .public)")
        }}
    }}

    // MARK: - Execution

    private static func handle(
        _ task: BGProcessingTask,
        trendingsService: TrendingsServiceProtocol,
        opportunitiesService: OpportunitiesServiceProtocol,
        projectionsService: ProjectionsServiceProtocol,
        gamesService: GamesServiceProtocol
    ) {{
        // Reschedule immediately so the next run is already queued
        scheduleIfNeeded()

        let fetchTask = Task {{
            do {{
                let players = try await trendingsService.fetchPlayers()
                let startDate = Calendar.current.date(
                    byAdding: .day,
                    value: -15,
                    to: Date.now
                ) ?? Date.now

                let batches = stride(from: 0, to: players.count, by: 50).map {{
                    Array(players[$0 ..< min($0 + 50, players.count)]).map(\\.id)
                }}

                for batch in batches {{
                    try Task.checkCancellation()
                    _ = try await gamesService.fetchGameLogs(playerIDs: batch, startDate: startDate)
                }}

                try Task.checkCancellation()
                _ = try await opportunitiesService.fetchOpportunities()

                try Task.checkCancellation()
                _ = try await projectionsService.fetchProjections()

                try Task.checkCancellation()
                _ = try await gamesService.fetchTodaySchedule()

                logger.info("Background data refresh completed for \\(players.count) players")
                task.setTaskCompleted(success: true)
            }} catch {{
                logger.error("Background data refresh failed: \\(error.diagnosticDescription, privacy: .public)")
                task.setTaskCompleted(success: false)
            }}
        }}

        task.expirationHandler = {{
            fetchTask.cancel()
            logger.warning("Background data refresh expired before completion")
        }}
    }}

    // MARK: - Force Refresh (silent push)

    /// Clears the local file cache and fetches all data fresh from the server.
    /// Called when a silent push notification is received to ensure the board
    /// reflects the latest server state immediately.
    static func forceClearAndRefresh(
        storage: StorageProtocol,
        trendingsService: TrendingsServiceProtocol,
        opportunitiesService: OpportunitiesServiceProtocol,
        projectionsService: ProjectionsServiceProtocol,
        gamesService: GamesServiceProtocol
    ) async {{
        logger.info("Silent push — clearing cache and force-refreshing all data")

        // Wipe the file cache so every subsequent load hits the network
        try? storage.deleteAll(from: .file)

        // Re-fetch all data sources in parallel
        await withTaskGroup(of: Void.self) {{ group in
            group.addTask {{
                do {{
                    let players = try await trendingsService.fetchPlayers()
                    logger.info("Force-refreshed \\(players.count, privacy: .public) players")
                }} catch {{
                    logger.error("Force-refresh players failed: \\(error.diagnosticDescription, privacy: .public)")
                }}
            }}
            group.addTask {{
                do {{
                    let result = try await opportunitiesService.fetchOpportunities()
                    logger.info("Force-refreshed \\(result.opportunities.count, privacy: .public) opportunities")
                }} catch {{
                    logger.error("Force-refresh opportunities failed: \\(error.diagnosticDescription, privacy: .public)")
                }}
            }}
            group.addTask {{
                do {{
                    let projections = try await projectionsService.fetchProjections()
                    logger.info("Force-refreshed \\(projections.count, privacy: .public) projections")
                }} catch {{
                    logger.error("Force-refresh projections failed: \\(error.diagnosticDescription, privacy: .public)")
                }}
            }}
            group.addTask {{
                do {{
                    let schedule = try await gamesService.fetchTodaySchedule()
                    logger.info("Force-refreshed schedule: \\(schedule.gameCount, privacy: .public) game(s)")
                }} catch {{
                    logger.error("Force-refresh schedule failed: \\(error.diagnosticDescription, privacy: .public)")
                }}
            }}
        }}

        logger.info("Silent push force-refresh complete")
    }}

    // MARK: - Scheduling Helpers

    private static func nextScheduledDate() -> Date {{
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date.now)
        components.hour = 3
        components.minute = 0
        components.second = 0

        guard let todayAt3am = Calendar.current.date(from: components) else {{
            return Date.now.addingTimeInterval(24 * 60 * 60)
        }}

        // If it's already past 3am today, schedule for 3am tomorrow
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
write(os.path.join(bootstrap_dir, "DataRefreshTask.swift"), bootstrap_data_refresh)

# ─────────────────────────────────────────────────────────────────────────────
# 9a. AppShell.swift
# ─────────────────────────────────────────────────────────────────────────────

app_shell = header() + """\
// UI infrastructure — no MVI. AppShell hosts the Board feature.
import SwiftUI
import BKSCore
import BKSUICore

struct AppShell: View {
    @ObservedObject var boardStore: Store<BoardState, BoardIntent>
    @ObservedObject var profileStore: Store<ProfileState, ProfileIntent>
    let credential: StoredCredential
    let trendingsService: TrendingsServiceProtocol
    let gamesService: GamesServiceProtocol
    let promoCodeService: PromoCodeServiceProtocol
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @Environment(\\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BoardView(
            store: boardStore,
            credential: credential,
            profileStore: profileStore,
            promoCodeService: promoCodeService
        )
        .overlay(alignment: .top) {
            if !networkMonitor.isConnected {
                OfflineBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: networkMonitor.isConnected)
    }
}
"""

write(os.path.join(bootstrap_dir, "AppShell.swift"), app_shell)

# ─────────────────────────────────────────────────────────────────────────────
# 9b. Models
# ─────────────────────────────────────────────────────────────────────────────

models_dir = os.path.join(out_dir, "App/Sources/Core/Models")

player_swift = header() + """\
import Foundation
import BKSCore

struct Player: Codable, Equatable, Hashable, Identifiable, Filterable {
    let id: String
    let displayName: String
    let team: String
    let position: String?
    let headshotURL: URL?
    let externalPersonID: Int?

    // Tier
    let playerTier: PlayerTier?

    // Fantasy scoring
    let avgFantasyScore: Double?
    let avgFantasyScoreHome: Double?
    let avgFantasyScoreAway: Double?
    let avgMinutes: Double?

    // Recent game data
    let recentGameScores: [Double]?

    // Trend signals
    let trendScore: Double?
    let trendDirection: TrendDirection?
    let trendAcceleration: Double?

    // Streak & surge
    let hotStreak: Int?
    let isSurging: Bool?
    let surgingCategoryCount: Int?

    // Confidence & consistency
    let confidenceScore: Double?
    let consistencyScore: Double?

    // Playoff signal confidence (null = regular season)
    let playoffDataConfidence: Double?

    // Injury & status
    let injuryStatus: InjuryStatus?
    let previousInjuryStatus: InjuryStatus?
    let injuryStatusChangedAt: Date?
    let isReturnGameWindow: Bool?
    let daysSinceReturn: Int?
    let isRoleChange: Bool?
    let usageEfficiencySignal: UsageEfficiencySignal?

    // swiftlint:disable:next function_default_parameter_at_end
    init(
        id: String,
        displayName: String,
        team: String,
        position: String?,
        headshotURL: URL?,
        externalPersonID: Int?,
        playerTier: PlayerTier?,
        avgFantasyScore: Double? = nil,
        avgFantasyScoreHome: Double? = nil,
        avgFantasyScoreAway: Double? = nil,
        avgMinutes: Double? = nil,
        recentGameScores: [Double]? = nil,
        trendScore: Double? = nil,
        trendDirection: TrendDirection? = nil,
        trendAcceleration: Double? = nil,
        hotStreak: Int? = nil,
        isSurging: Bool? = nil,
        surgingCategoryCount: Int? = nil,
        confidenceScore: Double? = nil,
        consistencyScore: Double? = nil,
        playoffDataConfidence: Double? = nil,
        injuryStatus: InjuryStatus? = nil,
        previousInjuryStatus: InjuryStatus? = nil,
        injuryStatusChangedAt: Date? = nil,
        isReturnGameWindow: Bool? = nil,
        daysSinceReturn: Int? = nil,
        isRoleChange: Bool? = nil,
        usageEfficiencySignal: UsageEfficiencySignal? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.team = team
        self.position = position
        self.headshotURL = headshotURL
        self.externalPersonID = externalPersonID
        self.playerTier = playerTier
        self.avgFantasyScore = avgFantasyScore
        self.avgFantasyScoreHome = avgFantasyScoreHome
        self.avgFantasyScoreAway = avgFantasyScoreAway
        self.avgMinutes = avgMinutes
        self.recentGameScores = recentGameScores
        self.trendScore = trendScore
        self.trendDirection = trendDirection
        self.trendAcceleration = trendAcceleration
        self.hotStreak = hotStreak
        self.isSurging = isSurging
        self.surgingCategoryCount = surgingCategoryCount
        self.confidenceScore = confidenceScore
        self.consistencyScore = consistencyScore
        self.playoffDataConfidence = playoffDataConfidence
        self.injuryStatus = injuryStatus
        self.previousInjuryStatus = previousInjuryStatus
        self.injuryStatusChangedAt = injuryStatusChangedAt
        self.isReturnGameWindow = isReturnGameWindow
        self.daysSinceReturn = daysSinceReturn
        self.isRoleChange = isRoleChange
        self.usageEfficiencySignal = usageEfficiencySignal
    }
}

// MARK: - PlayoffConfidence

extension Player {
    /// Describes how much trust to place in trend signals during the playoffs.
    enum PlayoffConfidence: Equatable {
        /// Field is nil — regular season, full signal trust.
        case regularSeason
        /// 0–1 playoff games played (confidence < 0.15) — suppress signals entirely.
        case pending
        /// 2–4 playoff games (0.15 ≤ confidence < 1.0) — show signals dimmed with amber indicator.
        case partial(Double)
        /// 5+ playoff games (confidence == 1.0) — treat normally.
        case full
    }

    var playoffConfidence: PlayoffConfidence {
        guard let confidence = playoffDataConfidence else { return .regularSeason }
        if confidence < 0.15 { return .pending }
        if confidence < 1.0 { return .partial(confidence) }
        return .full
    }
}

enum UsageEfficiencySignal: String, Codable, Equatable, Hashable {
    case expanding
    case expandingEfficiently = "expanding_efficiently"
    case volumeInflation = "volume_inflation"
    case efficientUsage = "efficient_usage"
    case neutral
}

enum PlayerTier: String, Codable, Equatable, Hashable, CaseIterable, TierDisplayable {
    case elite
    case good
    case solid
    case bottomFeeder = "bottom_feeder"

    var tierLevel: TierLevel {
        switch self {
        case .elite: .elite
        case .good: .good
        case .solid: .solid
        case .bottomFeeder: .bottom
        }
    }

    var sortOrder: Int { tierSortOrder }
}
"""

opportunity_swift = header() + """\
import Foundation
import BKSCore

struct Opportunity: Codable, Equatable, Hashable, Identifiable, Filterable {
    let id: String
    let displayName: String
    let team: String
    let position: String?
    let opponentAbbr: String
    let headshotURL: URL?
    let externalPersonID: Int?

    // Core Scoring
    let opportunityScore: Double
    let opportunityTier: FeatureTier
    let playerTier: PlayerTier?
    let mode: String
    let platform: String

    // Key Signals
    let injuryStatus: InjuryStatus?
    let isSurging: Bool
    let isHome: Bool

    // Playoff fields (null during regular season)
    let playoffRotationMultiplier: Double?
    let rotationTier: RotationTier?
    let playoffTrendTrust: Double?
    let playoffGamesPlayed: Int?

    var additionalSearchFields: [String] { [opponentAbbr] }

    // swiftlint:disable:next function_default_parameter_at_end
    init(
        id: String,
        displayName: String,
        team: String,
        position: String?,
        opponentAbbr: String,
        headshotURL: URL?,
        externalPersonID: Int?,
        opportunityScore: Double,
        opportunityTier: FeatureTier,
        playerTier: PlayerTier?,
        mode: String,
        platform: String,
        injuryStatus: InjuryStatus?,
        isSurging: Bool,
        isHome: Bool,
        playoffRotationMultiplier: Double? = nil,
        rotationTier: RotationTier? = nil,
        playoffTrendTrust: Double? = nil,
        playoffGamesPlayed: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.team = team
        self.position = position
        self.opponentAbbr = opponentAbbr
        self.headshotURL = headshotURL
        self.externalPersonID = externalPersonID
        self.opportunityScore = opportunityScore
        self.opportunityTier = opportunityTier
        self.playerTier = playerTier
        self.mode = mode
        self.platform = platform
        self.injuryStatus = injuryStatus
        self.isSurging = isSurging
        self.isHome = isHome
        self.playoffRotationMultiplier = playoffRotationMultiplier
        self.rotationTier = rotationTier
        self.playoffTrendTrust = playoffTrendTrust
        self.playoffGamesPlayed = playoffGamesPlayed
    }
}

// MARK: - FeatureTier

/// Unified tier for feature-specific scores (opportunities and projections).
/// Raw values match the Opportunities API contract; ProjectionsService maps
/// its string responses to cases manually.
enum FeatureTier: String, Codable, Equatable, Hashable, CaseIterable, TierDisplayable {
    case elite = "elite_opp"
    case good = "good_opp"
    case solid = "solid_opp"
    case low = "low_opp"

    var tierLevel: TierLevel {
        switch self {
        case .elite: .elite
        case .good: .good
        case .solid: .solid
        case .low: .bottom
        }
    }

    var sortOrder: Int { tierSortOrder }
}

// MARK: - SeasonMode

enum SeasonMode: String, Codable, Equatable, Hashable {
    case regularSeason = "regular_season"
    case playoffs
    case offseason
}

// MARK: - RotationTier

enum RotationTier: String, Codable, Equatable, Hashable {
    case star
    case starter
    case rotation
    case fringe
    case bench
}
"""

projection_swift = header() + """\
import Foundation
import BKSCore

struct Projection: Codable, Equatable, Hashable, Identifiable, Filterable {
    let id: String
    let displayName: String
    let team: String
    let position: String?
    let headshotURL: URL?
    let externalPersonID: Int?

    // Core Scoring
    let projectionScore: Double        // predicted_fp_dk — best game's DK projection
    let projectionTier: FeatureTier
    let playerTierDk: PlayerTier?
    let playerTierFd: PlayerTier?
    let mode: String
    let platforms: [String]            // e.g. ["dk", "fd"]

    // Key Signals
    let injuryStatus: InjuryStatus?
    let isSurging: Bool

    // Schedule
    let upcomingGames: [ProjectedGame]?
    let homeGameCount: Int?
    let awayGameCount: Int?
    let avgOpponentStrength: Double?

    // Streak signals
    let hotStreak: Int?
    let coldStreak: Int?

    // Fantasy scoring context (platform-split)
    let avgFantasyScoreDk: Double?
    let avgFantasyScoreFd: Double?

    // Usage signal
    let usageEfficiencySignal: UsageEfficiencySignal?

    // Trend Context
    let trendDirection: TrendDirection?
    let confidenceScoreDk: Double?
    let confidenceScoreFd: Double?
    let consistencyScore: Double?

    // swiftlint:disable:next function_default_parameter_at_end
    init(
        id: String,
        displayName: String,
        team: String,
        position: String?,
        headshotURL: URL?,
        externalPersonID: Int?,
        projectionScore: Double,
        projectionTier: FeatureTier,
        playerTierDk: PlayerTier?,
        playerTierFd: PlayerTier?,
        mode: String,
        platforms: [String],
        injuryStatus: InjuryStatus?,
        isSurging: Bool,
        upcomingGames: [ProjectedGame]? = nil,
        homeGameCount: Int? = nil,
        awayGameCount: Int? = nil,
        avgOpponentStrength: Double? = nil,
        hotStreak: Int? = nil,
        coldStreak: Int? = nil,
        avgFantasyScoreDk: Double? = nil,
        avgFantasyScoreFd: Double? = nil,
        usageEfficiencySignal: UsageEfficiencySignal? = nil,
        trendDirection: TrendDirection? = nil,
        confidenceScoreDk: Double? = nil,
        confidenceScoreFd: Double? = nil,
        consistencyScore: Double? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.team = team
        self.position = position
        self.headshotURL = headshotURL
        self.externalPersonID = externalPersonID
        self.projectionScore = projectionScore
        self.projectionTier = projectionTier
        self.playerTierDk = playerTierDk
        self.playerTierFd = playerTierFd
        self.mode = mode
        self.platforms = platforms
        self.injuryStatus = injuryStatus
        self.isSurging = isSurging
        self.upcomingGames = upcomingGames
        self.homeGameCount = homeGameCount
        self.awayGameCount = awayGameCount
        self.avgOpponentStrength = avgOpponentStrength
        self.hotStreak = hotStreak
        self.coldStreak = coldStreak
        self.avgFantasyScoreDk = avgFantasyScoreDk
        self.avgFantasyScoreFd = avgFantasyScoreFd
        self.usageEfficiencySignal = usageEfficiencySignal
        self.trendDirection = trendDirection
        self.confidenceScoreDk = confidenceScoreDk
        self.confidenceScoreFd = confidenceScoreFd
        self.consistencyScore = consistencyScore
    }
}

// MARK: - PlayFadeRecommendation

enum PlayFadeRecommendation: String, Codable, Equatable, Hashable {
    case play
    case fade
    case neutral
}

// MARK: - ProjectedGame

struct ProjectedGame: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let gameDate: Date
    let opponentAbbr: String
    let isHome: Bool
    let opponentStrength: Double?
    let projectedScoreDk: Double?
    let projectedScoreFd: Double?
    let fpFloorDk: Double?
    let fpFloorFd: Double?
    let fpCeilingDk: Double?
    let fpCeilingFd: Double?
    let playFadeRecommendation: PlayFadeRecommendation?

    init(
        id: String,
        gameDate: Date,
        opponentAbbr: String,
        isHome: Bool,
        opponentStrength: Double? = nil,
        projectedScoreDk: Double? = nil,
        projectedScoreFd: Double? = nil,
        fpFloorDk: Double? = nil,
        fpFloorFd: Double? = nil,
        fpCeilingDk: Double? = nil,
        fpCeilingFd: Double? = nil,
        playFadeRecommendation: PlayFadeRecommendation? = nil
    ) {
        self.id = id
        self.gameDate = gameDate
        self.opponentAbbr = opponentAbbr
        self.isHome = isHome
        self.opponentStrength = opponentStrength
        self.projectedScoreDk = projectedScoreDk
        self.projectedScoreFd = projectedScoreFd
        self.fpFloorDk = fpFloorDk
        self.fpFloorFd = fpFloorFd
        self.fpCeilingDk = fpCeilingDk
        self.fpCeilingFd = fpCeilingFd
        self.playFadeRecommendation = playFadeRecommendation
    }
}
"""

today_schedule_swift = header() + """\
import Foundation

// MARK: - TodaySchedule

struct TodaySchedule: Codable, Equatable {
    /// Date string in "yyyy-MM-dd" format, determined in Eastern Time by the server.
    let date: String
    let gameCount: Int
    let games: [ScheduledGame]

    /// `true` when the server reports at least one game scheduled today.
    /// `false` means either no games today or the sync hasn't run yet — both treated the same.
    var hasGames: Bool { gameCount > 0 }
}

// MARK: - ScheduledGame

struct ScheduledGame: Codable, Equatable, Identifiable {
    let id: Int
    let homeTeamAbbr: String
    let visitorTeamAbbr: String
    let status: String
    let gameType: String
    let gameDatetime: Date
}
"""

playoff_series_swift = header() + """\
import Foundation

// MARK: - PlayoffSeries

struct PlayoffSeries: Codable, Equatable, Hashable, Identifiable {
    let seriesID: String
    let roundNumber: Int
    let roundName: String
    let conference: String
    let higherSeedTeam: String
    let lowerSeedTeam: String
    let higherSeed: Int
    let lowerSeed: Int
    let winsHigherSeed: Int
    let winsLowerSeed: Int
    let status: SeriesStatus
    let winner: String?
    let gamesPlayed: Int
    let eliminationGameNext: Bool
    let homeCourt: [String: Bool]

    var id: String { seriesID }

    /// Returns true if the higher-seed team is home for the next game.
    var isHigherSeedHomeNext: Bool? {
        homeCourt["\\(gamesPlayed + 1)"]
    }
}

// MARK: - SeriesStatus

enum SeriesStatus: String, Codable, Equatable, Hashable {
    case scheduled
    case active
    case completed
}
"""

league_state_swift = header() + """\
import Foundation

/// Top-level league/season state fetched from the server.
/// `SeasonMode` is defined in Opportunity.swift and shared here.
struct LeagueState: Codable, Equatable {
    let mode: SeasonMode
    let playoffRound: Int?
    let playoffStartDate: String?
    let regularSeasonEndDate: String?
    let season: Int?
}
"""

write(os.path.join(models_dir, "Player.swift"), player_swift)
write(os.path.join(models_dir, "Opportunity.swift"), opportunity_swift)
write(os.path.join(models_dir, "Projection.swift"), projection_swift)
write(os.path.join(models_dir, "TodaySchedule.swift"), today_schedule_swift)
write(os.path.join(models_dir, "PlayoffSeries.swift"), playoff_series_swift)
write(os.path.join(models_dir, "LeagueState.swift"), league_state_swift)

# ─────────────────────────────────────────────────────────────────────────────
# 9c. Services
# ─────────────────────────────────────────────────────────────────────────────

services_dir = os.path.join(out_dir, "App/Sources/Core/Services")

trendings_service_swift = header() + f"""\
import Alamofire
import BKSCore
import Foundation
import OSLog

// MARK: - TrendingsServiceProtocol

protocol TrendingsServiceProtocol {{
    func fetchPlayers(fields: [String]?) async throws -> [Player]
    func loadCachedPlayers() throws -> [Player]?
    func loadCachedFetchDate() throws -> Date?
}}

extension TrendingsServiceProtocol {{
    func fetchPlayers() async throws -> [Player] {{
        try await fetchPlayers(fields: nil)
    }}
}}

// MARK: - TrendingsService

final class TrendingsService: TrendingsServiceProtocol {{
    private let network: NetworkProtocol
    private let storage: StorageProtocol
    private let configuration: ConfigurationProtocol
    private let sportConfiguration: SportConfiguration
    private let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "TrendingsService"
    )
    private let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "TrendingsService"
    )

    private var cacheKey: String {{ "\\\\(sportConfiguration.cacheKeyPrefix)trending_v1" }}
    private var cacheDateKey: String {{ "\\\\(sportConfiguration.cacheKeyPrefix)trending_v1_date" }}

    init(
        network: NetworkProtocol,
        storage: StorageProtocol,
        configuration: ConfigurationProtocol,
        sportConfiguration: SportConfiguration = .{slug}
    ) {{
        self.network = network
        self.storage = storage
        self.configuration = configuration
        self.sportConfiguration = sportConfiguration
    }}

    func fetchPlayers(fields: [String]? = nil) async throws -> [Player] {{
        let url = configuration.value(for: .getPlayersURL)

        let requestFields = fields ?? sportConfiguration.trendingFields
        var parameters: Parameters?
        if !requestFields.isEmpty {{
            parameters = ["fields": requestFields.joined(separator: ",")]
        }}

        let fetchStart = Date.now
        let fetchInterval = signposter.beginInterval("fetchPlayers")
        defer {{ signposter.endInterval("fetchPlayers", fetchInterval) }}

        try Task.checkCancellation()
        let response: PlayersResponse = try await network.get(url, parameters: parameters)

        let sorted = response.data.compactMap(mapPlayer).sorted {{ $0.displayName < $1.displayName }}
        let elapsed = Date.now.timeIntervalSince(fetchStart)
        logger
            .info(
                "Fetched \\\\(sorted.count, privacy: .public) players in 1 call (\\\\(String(format: \\"%.2f\\", elapsed), privacy: .public)s)"
            )

        do {{
            try storage.save(sorted, forKey: cacheKey, in: .file)
            try storage.save(Date.now, forKey: cacheDateKey, in: .file)
        }} catch {{
            logger.warning("Failed to cache players: \\\\(error.diagnosticDescription)")
        }}

        return sorted
    }}

    func loadCachedPlayers() throws -> [Player]? {{
        try storage.load(forKey: cacheKey, from: .file)
    }}

    func loadCachedFetchDate() throws -> Date? {{
        try storage.load(forKey: cacheDateKey, from: .file)
    }}

    // MARK: - Mapping

    private func mapPlayer(_ dto: PlayerDTO) -> Player? {{
        Player(
            id: String(dto.id),
            displayName: "\\\\(dto.firstName) \\\\(dto.lastName)",
            team: dto.team,
            position: dto.position.flatMap {{ $0.isEmpty ? nil : $0 }},
            headshotURL: dto.headshotURL,
            externalPersonID: dto.externalPersonID,
            playerTier: dto.playerTier,
            avgFantasyScore: dto.avgFantasyScore,
            avgFantasyScoreHome: dto.avgFantasyScoreHome,
            avgFantasyScoreAway: dto.avgFantasyScoreAway,
            avgMinutes: dto.avgMinutes,
            recentGameScores: dto.recentGameScores,
            trendScore: dto.trendScore,
            trendDirection: dto.trendDirection,
            trendAcceleration: dto.trendAcceleration,
            hotStreak: dto.hotStreak,
            isSurging: dto.isSurging,
            surgingCategoryCount: dto.surgingCategoryCount,
            confidenceScore: dto.confidenceScore,
            consistencyScore: dto.consistencyScore,
            playoffDataConfidence: dto.playoffDataConfidence,
            injuryStatus: dto.injuryStatus.flatMap {{ InjuryStatus(rawValue: $0) }},
            previousInjuryStatus: dto.previousInjuryStatus.flatMap {{ InjuryStatus(rawValue: $0) }},
            injuryStatusChangedAt: dto.injuryStatusChangedAt.flatMap {{ Self.parseISODate($0) }},
            isReturnGameWindow: dto.isReturnGameWindow,
            daysSinceReturn: dto.daysSinceReturn,
            isRoleChange: dto.isRoleChange,
            usageEfficiencySignal: dto.usageEfficiencySignal.flatMap {{ UsageEfficiencySignal(rawValue: $0) }}
        )
    }}

    private static func parseISODate(_ string: String) -> Date? {{
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {{ return date }}
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }}
}}

// MARK: - Player DTOs

private struct PlayersResponse: Decodable {{
    let data: [PlayerDTO]
}}

private struct PlayerDTO: Decodable {{
    let id: Int
    let firstName: String
    let lastName: String
    let team: String
    let position: String?
    let headshotURL: URL?
    let externalPersonID: Int?
    let playerTier: PlayerTier?
    let avgFantasyScore: Double?
    let avgFantasyScoreHome: Double?
    let avgFantasyScoreAway: Double?
    let avgMinutes: Double?
    let recentGameScores: [Double]?
    let trendScore: Double?
    let trendDirection: TrendDirection?
    let trendAcceleration: Double?
    let hotStreak: Int?
    let isSurging: Bool?
    let surgingCategoryCount: Int?
    let confidenceScore: Double?
    let consistencyScore: Double?
    let playoffDataConfidence: Double?
    let injuryStatus: String?
    let previousInjuryStatus: String?
    let injuryStatusChangedAt: String?
    let isReturnGameWindow: Bool?
    let daysSinceReturn: Int?
    let isRoleChange: Bool?
    let usageEfficiencySignal: String?

    enum CodingKeys: String, CodingKey {{
        case id
        case firstName = "first_name"
        case lastName = "last_name"
        case team, position
        case headshotURL = "headshot_url"
        case externalPersonID = "nba_person_id"
        case playerTier = "player_tier"
        case avgFantasyScore = "avg_fantasy_score"
        case avgFantasyScoreHome = "avg_fantasy_score_home"
        case avgFantasyScoreAway = "avg_fantasy_score_away"
        case avgMinutes = "avg_minutes"
        case recentGameScores = "recent_game_scores"
        case trendScore = "trend_score"
        case trendDirection = "trend_direction"
        case trendAcceleration = "trend_acceleration"
        case hotStreak = "hot_streak"
        case isSurging = "is_surging"
        case surgingCategoryCount = "surging_category_count"
        case confidenceScore = "confidence_score"
        case consistencyScore = "consistency_score"
        case playoffDataConfidence = "playoff_data_confidence"
        case injuryStatus = "injury_status"
        case previousInjuryStatus = "previous_injury_status"
        case injuryStatusChangedAt = "injury_status_changed_at"
        case isReturnGameWindow = "is_return_game_window"
        case daysSinceReturn = "days_since_return"
        case isRoleChange = "is_role_change"
        case usageEfficiencySignal = "usage_efficiency_signal"
    }}

    init(from decoder: Decoder) throws {{
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        firstName = try container.decode(String.self, forKey: .firstName)
        lastName = try container.decode(String.self, forKey: .lastName)
        if let teamString = try? container.decode(String.self, forKey: .team) {{
            team = teamString
        }} else if let teamDict = try? container.decode([String: AnyCodableValue].self, forKey: .team) {{
            team = teamDict["abbreviation"]?.stringValue
                ?? teamDict["abbr"]?.stringValue
                ?? teamDict["full_name"]?.stringValue
                ?? teamDict["name"]?.stringValue
                ?? teamDict["city"]?.stringValue
                ?? "?"
        }} else {{
            team = "?"
        }}
        position = try container.decodeIfPresent(String.self, forKey: .position)
        headshotURL = try container.decodeIfPresent(URL.self, forKey: .headshotURL)
        externalPersonID = try container.decodeIfPresent(Int.self, forKey: .externalPersonID)
        playerTier = try container.decodeIfPresent(PlayerTier.self, forKey: .playerTier)
        avgFantasyScore = try container.decodeIfPresent(Double.self, forKey: .avgFantasyScore)
        avgFantasyScoreHome = try container.decodeIfPresent(Double.self, forKey: .avgFantasyScoreHome)
        avgFantasyScoreAway = try container.decodeIfPresent(Double.self, forKey: .avgFantasyScoreAway)
        avgMinutes = try container.decodeIfPresent(Double.self, forKey: .avgMinutes)
        recentGameScores = try container.decodeIfPresent([Double].self, forKey: .recentGameScores)
        trendScore = try container.decodeIfPresent(Double.self, forKey: .trendScore)
        trendDirection = try container.decodeIfPresent(TrendDirection.self, forKey: .trendDirection)
        trendAcceleration = try container.decodeIfPresent(Double.self, forKey: .trendAcceleration)
        hotStreak = try container.decodeIfPresent(Int.self, forKey: .hotStreak)
        isSurging = try container.decodeIfPresent(Bool.self, forKey: .isSurging)
        surgingCategoryCount = try container.decodeIfPresent(Int.self, forKey: .surgingCategoryCount)
        confidenceScore = try container.decodeIfPresent(Double.self, forKey: .confidenceScore)
        consistencyScore = try container.decodeIfPresent(Double.self, forKey: .consistencyScore)
        playoffDataConfidence = try container.decodeIfPresent(Double.self, forKey: .playoffDataConfidence)
        injuryStatus = try container.decodeIfPresent(String.self, forKey: .injuryStatus)
        previousInjuryStatus = try container.decodeIfPresent(String.self, forKey: .previousInjuryStatus)
        injuryStatusChangedAt = try container.decodeIfPresent(String.self, forKey: .injuryStatusChangedAt)
        isReturnGameWindow = try container.decodeIfPresent(Bool.self, forKey: .isReturnGameWindow)
        daysSinceReturn = try container.decodeIfPresent(Int.self, forKey: .daysSinceReturn)
        isRoleChange = try container.decodeIfPresent(Bool.self, forKey: .isRoleChange)
        usageEfficiencySignal = try container.decodeIfPresent(String.self, forKey: .usageEfficiencySignal)
    }}
}}

// MARK: - AnyCodableValue

/// Lightweight wrapper for decoding JSON values of mixed types (String, Int,
/// Double, Bool) when the exact schema is unknown — used for the polymorphic
/// `team` field which may arrive as a dictionary with heterogeneous values.
private enum AnyCodableValue: Decodable {{
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    init(from decoder: Decoder) throws {{
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {{
            self = .string(value)
        }} else if let value = try? container.decode(Int.self) {{
            self = .int(value)
        }} else if let value = try? container.decode(Double.self) {{
            self = .double(value)
        }} else if let value = try? container.decode(Bool.self) {{
            self = .bool(value)
        }} else {{
            self = .string("")
        }}
    }}

    var stringValue: String? {{
        switch self {{
        case let .string(value): value.isEmpty ? nil : value
        case let .int(value): String(value)
        case let .double(value): String(value)
        case .bool: nil
        }}
    }}
}}

// MARK: - TrendingsServiceError

enum TrendingsServiceError: LocalizedError {{
    case noTeamsFound
    case unauthenticated

    var errorDescription: String? {{
        switch self {{
        case .noTeamsFound:
            "No {league} teams were found in the response."
        case .unauthenticated:
            "You must be signed in to load player data."
        }}
    }}
}}
"""

opportunities_service_swift = header() + f"""\
import Alamofire
import BKSCore
import Foundation
import OSLog

// MARK: - OpportunitiesServiceProtocol

protocol OpportunitiesServiceProtocol {{
    func fetchOpportunities(
        limit: Int?, platform: String?, mode: String?, fields: [String]?
    ) async throws -> (opportunities: [Opportunity], seasonMode: SeasonMode)
    func loadCachedOpportunities() throws -> [Opportunity]?
    func loadCachedOpportunitiesFetchDate() throws -> Date?
    func loadCachedSeasonMode() throws -> SeasonMode?
}}

extension OpportunitiesServiceProtocol {{
    func fetchOpportunities() async throws -> (opportunities: [Opportunity], seasonMode: SeasonMode) {{
        try await fetchOpportunities(limit: nil, platform: nil, mode: nil, fields: nil)
    }}
}}

// MARK: - OpportunitiesService

final class OpportunitiesService: OpportunitiesServiceProtocol {{
    private let network: NetworkProtocol
    private let storage: StorageProtocol
    private let configuration: ConfigurationProtocol
    private let sportConfiguration: SportConfiguration
    private let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "OpportunitiesService"
    )
    private let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "OpportunitiesService"
    )

    private var cacheKey: String {{ "\\\\(sportConfiguration.cacheKeyPrefix)opportunities_v1" }}
    private var cacheDateKey: String {{ "\\\\(sportConfiguration.cacheKeyPrefix)opportunities_v1_date" }}
    private var seasonModeCacheKey: String {{ "\\\\(sportConfiguration.cacheKeyPrefix)season_mode_v1" }}

    init(
        network: NetworkProtocol,
        storage: StorageProtocol,
        configuration: ConfigurationProtocol,
        sportConfiguration: SportConfiguration = .{slug}
    ) {{
        self.network = network
        self.storage = storage
        self.configuration = configuration
        self.sportConfiguration = sportConfiguration
    }}

    func fetchOpportunities(
        limit: Int? = nil,
        platform: String? = nil,
        mode: String? = nil,
        fields: [String]? = nil
    ) async throws -> (opportunities: [Opportunity], seasonMode: SeasonMode) {{
        let url = configuration.value(for: .getOpportunitiesURL)
        let params = sportConfiguration.opportunityParams

        let requestFields = fields ?? sportConfiguration.opportunityFields
        var parameters: Parameters = [
            "limit": limit ?? params.limit,
            "platform": platform ?? params.platform,
            "mode": mode ?? params.mode,
        ]
        if !requestFields.isEmpty {{
            parameters["fields"] = requestFields.joined(separator: ",")
        }}

        let fetchStart = Date.now
        let fetchInterval = signposter.beginInterval("fetchOpportunities")
        defer {{ signposter.endInterval("fetchOpportunities", fetchInterval) }}

        try Task.checkCancellation()
        let response: OpportunitiesResponse = try await network.get(url, parameters: parameters)

        let mapped = response.data.compactMap(mapOpportunity)
        let seasonMode = response.seasonMode ?? .regularSeason
        let elapsed = Date.now.timeIntervalSince(fetchStart)
        logger
            .info(
                "Fetched \\\\(mapped.count, privacy: .public) opportunities in 1 call (\\\\(String(format: \\"%.2f\\", elapsed), privacy: .public)s)"
            )

        do {{
            try storage.save(mapped, forKey: cacheKey, in: .file)
            try storage.save(Date.now, forKey: cacheDateKey, in: .file)
            try storage.save(seasonMode, forKey: seasonModeCacheKey, in: .file)
        }} catch {{
            logger.warning("Failed to cache opportunities: \\\\(error.diagnosticDescription)")
        }}

        return (mapped, seasonMode)
    }}

    func loadCachedOpportunities() throws -> [Opportunity]? {{
        try storage.load(forKey: cacheKey, from: .file)
    }}

    func loadCachedOpportunitiesFetchDate() throws -> Date? {{
        try storage.load(forKey: cacheDateKey, from: .file)
    }}

    func loadCachedSeasonMode() throws -> SeasonMode? {{
        try storage.load(forKey: seasonModeCacheKey, from: .file)
    }}

    // MARK: - Mapping

    private func mapOpportunity(_ dto: OpportunityDTO) -> Opportunity? {{
        guard let tier = FeatureTier(rawValue: dto.opportunityTier) else {{ return nil }}
        return Opportunity(
            id: String(dto.id),
            displayName: "\\\\(dto.firstName) \\\\(dto.lastName)",
            team: dto.team,
            position: dto.position.flatMap {{ $0.isEmpty ? nil : $0 }},
            opponentAbbr: dto.opponentAbbr,
            headshotURL: dto.headshotURL,
            externalPersonID: dto.externalPersonID,
            opportunityScore: dto.opportunityScore,
            opportunityTier: tier,
            playerTier: dto.playerTier,
            mode: dto.mode,
            platform: dto.platform,
            injuryStatus: dto.injuryStatus.flatMap {{ InjuryStatus(rawValue: $0) }},
            isSurging: dto.isSurging ?? false,
            isHome: dto.isHome ?? false,
            playoffRotationMultiplier: dto.playoffRotationMultiplier,
            rotationTier: dto.rotationTier.flatMap {{ RotationTier(rawValue: $0) }},
            playoffTrendTrust: dto.playoffTrendTrust,
            playoffGamesPlayed: dto.playoffGamesPlayed
        )
    }}
}}

// MARK: - Opportunity DTOs

private struct OpportunitiesResponse: Decodable {{
    let data: [OpportunityDTO]
    let seasonMode: SeasonMode?

    enum CodingKeys: String, CodingKey {{
        case data
        case seasonMode = "season_mode"
    }}
}}

private struct OpportunityDTO: Decodable {{
    let id: Int
    let firstName: String
    let lastName: String
    let team: String
    let position: String?
    let opponentAbbr: String
    let headshotURL: URL?
    let externalPersonID: Int?

    let opportunityScore: Double
    let opportunityTier: String
    let playerTier: PlayerTier?
    let mode: String
    let platform: String

    let injuryStatus: String?
    let isSurging: Bool?
    let isHome: Bool?

    let playoffRotationMultiplier: Double?
    let rotationTier: String?
    let playoffTrendTrust: Double?
    let playoffGamesPlayed: Int?

    enum CodingKeys: String, CodingKey {{
        case id
        case firstName = "first_name"
        case lastName = "last_name"
        case team
        case position
        case opponentAbbr = "opponent_abbr"
        case headshotURL = "headshot_url"
        case externalPersonID = "nba_person_id"
        case opportunityScore = "opportunity_score"
        case opportunityTier = "opportunity_tier"
        case playerTier = "player_tier"
        case mode
        case platform
        case injuryStatus = "injury_status"
        case isSurging = "is_surging"
        case isHome = "is_home"
        case playoffRotationMultiplier = "playoff_rotation_multiplier"
        case rotationTier = "rotation_tier"
        case playoffTrendTrust = "playoff_trend_trust"
        case playoffGamesPlayed = "playoff_games_played"
    }}
}}
"""

write(os.path.join(services_dir, "TrendingsService.swift"), trendings_service_swift)
write(os.path.join(services_dir, "OpportunitiesService.swift"), opportunities_service_swift)

projections_service_swift = header() + f"""\
import Alamofire
import BKSCore
import Foundation
import OSLog

// MARK: - ProjectionsServiceProtocol

protocol ProjectionsServiceProtocol {{
    func fetchProjections(fields: [String]?) async throws -> [Projection]
    func loadCachedProjections() throws -> [Projection]?
    func loadCachedProjectionsFetchDate() throws -> Date?
}}

extension ProjectionsServiceProtocol {{
    func fetchProjections() async throws -> [Projection] {{
        try await fetchProjections(fields: nil)
    }}
}}

// MARK: - ProjectionsService

final class ProjectionsService: ProjectionsServiceProtocol {{
    private let network: NetworkProtocol
    private let storage: StorageProtocol
    private let configuration: ConfigurationProtocol
    private let sportConfiguration: SportConfiguration
    private let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "ProjectionsService"
    )
    private let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "ProjectionsService"
    )

    private var cacheKey: String {{ "\\\\(sportConfiguration.cacheKeyPrefix)projections_v1" }}
    private var cacheDateKey: String {{ "\\\\(sportConfiguration.cacheKeyPrefix)projections_v1_date" }}

    init(
        network: NetworkProtocol,
        storage: StorageProtocol,
        configuration: ConfigurationProtocol,
        sportConfiguration: SportConfiguration = .{slug}
    ) {{
        self.network = network
        self.storage = storage
        self.configuration = configuration
        self.sportConfiguration = sportConfiguration
    }}

    func fetchProjections(fields: [String]? = nil) async throws -> [Projection] {{
        let url = configuration.value(for: .getProjectionsURL)

        let params = sportConfiguration.projectionParams
        var parameters: Parameters = [
            "lookahead": params.lookahead,
            "platform": params.platform,
            "mode": params.mode,
        ]
        if let fields, !fields.isEmpty {{
            parameters["fields"] = fields.joined(separator: ",")
        }}

        let fetchStart = Date.now
        let fetchInterval = signposter.beginInterval("fetchProjections")
        defer {{ signposter.endInterval("fetchProjections", fetchInterval) }}

        try Task.checkCancellation()
        let response: ProjectionsResponse = try await network.get(url, parameters: parameters)

        let mapped = response.players.compactMap(mapProjection)
        let elapsed = Date.now.timeIntervalSince(fetchStart)
        logger.info(
            "Fetched \\\\(mapped.count, privacy: .public) projections in 1 call (\\\\(String(format: \\"%.2f\\", elapsed), privacy: .public)s)"
        )

        do {{
            try storage.save(mapped, forKey: cacheKey, in: .file)
            try storage.save(Date.now, forKey: cacheDateKey, in: .file)
        }} catch {{
            logger.warning("Failed to cache projections: \\\\(error.diagnosticDescription)")
        }}

        return mapped
    }}

    func loadCachedProjections() throws -> [Projection]? {{
        try storage.load(forKey: cacheKey, from: .file)
    }}

    func loadCachedProjectionsFetchDate() throws -> Date? {{
        try storage.load(forKey: cacheDateKey, from: .file)
    }}

    // MARK: - Mapping

    private func mapProjection(_ dto: ProjectionPlayerDTO) -> Projection? {{
        guard let tier = bestTier(from: dto.games) else {{ return nil }}
        let projectionScore = dto.games.compactMap(\\.projectionScore).max() ?? dto.avgFantasyScore ?? 0

        let upcomingGames: [ProjectedGame] = dto.games.enumerated().compactMap {{ index, game in
            ProjectedGame(
                id: "\\\\(dto.id)-game-\\\\(index)",
                gameDate: parseDate(game.date),
                opponentAbbr: game.opponent,
                isHome: game.isHome,
                opponentStrength: game.opportunityScore,
                projectedScore: game.predictedFP
            )
        }}

        return Projection(
            id: String(dto.id),
            displayName: "\\\\(dto.firstName) \\\\(dto.lastName)",
            team: dto.team,
            position: dto.position.flatMap {{ $0.isEmpty ? nil : $0 }},
            headshotURL: dto.headshotURL,
            externalPersonID: dto.externalPersonID,
            projectionScore: projectionScore,
            projectionTier: tier,
            playerTier: dto.playerTier,
            mode: sportConfiguration.projectionParams.mode,
            platform: sportConfiguration.projectionParams.platform,
            injuryStatus: dto.injuryStatus.flatMap {{ InjuryStatus(rawValue: $0) }},
            isSurging: (dto.hotStreak ?? 0) > 0,
            upcomingGames: upcomingGames.isEmpty ? nil : upcomingGames,
            homeGameCount: upcomingGames.filter(\\.isHome).count,
            awayGameCount: upcomingGames.filter {{ !$0.isHome }}.count,
            avgOpponentStrength: upcomingGames.compactMap(\\.opponentStrength).average,
            trendDirection: dto.trendDirection,
            confidenceScore: dto.confidenceScore,
            consistencyScore: nil
        )
    }}

    private func bestTier(from games: [ProjectedGameDTO]) -> FeatureTier? {{
        let tiers = games.compactMap {{ mapFeatureTier($0.projectionTier) }}
        return tiers.min {{ $0.sortOrder < $1.sortOrder }}
    }}

    private func mapFeatureTier(_ raw: String?) -> FeatureTier? {{
        switch raw?.lowercased() {{
        case "elite": return .elite
        case "good": return .good
        case "solid": return .solid
        case "low": return .low
        default: return nil
        }}
    }}

    private func parseDate(_ string: String) -> Date {{
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: string) ?? Date.now
    }}
}}

// MARK: - DTOs

private struct ProjectionsResponse: Decodable {{
    let platform: String
    let mode: String
    let lookahead: Int
    let dates: [String]
    let players: [ProjectionPlayerDTO]
}}

private struct ProjectionPlayerDTO: Decodable {{
    let id: Int
    let firstName: String
    let lastName: String
    let position: String?
    let team: String
    let externalPersonID: Int?
    let headshotURL: URL?
    let avgFantasyScore: Double?
    let trendDirection: TrendDirection?
    let trendScore: Double?
    let confidenceScore: Double?
    let hotStreak: Int?
    let coldStreak: Int?
    let injuryStatus: String?
    let playerTier: PlayerTier?
    let games: [ProjectedGameDTO]

    enum CodingKeys: String, CodingKey {{
        case id
        case firstName = "first_name"
        case lastName = "last_name"
        case position
        case team
        case externalPersonID = "nba_person_id"
        case headshotURL = "headshot_url"
        case avgFantasyScore = "avg_fantasy_score"
        case trendDirection = "trend_direction"
        case trendScore = "trend_score"
        case confidenceScore = "confidence_score"
        case hotStreak = "hot_streak"
        case coldStreak = "cold_streak"
        case injuryStatus = "injury_status"
        case playerTier = "player_tier"
        case games
    }}
}}

private struct ProjectedGameDTO: Decodable {{
    let date: String
    let opponent: String
    let isHome: Bool
    let predictedFP: Double?
    let fpFloor: Double?
    let fpCeiling: Double?
    let confidenceBand: Double?
    let projectionScore: Double?
    let projectionTier: String?
    let opportunityScore: Double?
    let opportunityTier: String?
    let opportunityPercentile: Double?
    let isBackToBack: Bool?
    let teamRestDays: Int?
    let blowoutProb: Double?
    let vegasImpliedTeamTotal: Double?
    let vegasOverUnder: Double?
    let vegasSpread: Double?
    let matchupMultiplier: Double?

    enum CodingKeys: String, CodingKey {{
        case date
        case opponent
        case isHome = "is_home"
        case predictedFP = "predicted_fp"
        case fpFloor = "fp_floor"
        case fpCeiling = "fp_ceiling"
        case confidenceBand = "confidence_band"
        case projectionScore = "projection_score"
        case projectionTier = "projection_tier"
        case opportunityScore = "opportunity_score"
        case opportunityTier = "opportunity_tier"
        case opportunityPercentile = "opportunity_percentile"
        case isBackToBack = "is_back_to_back"
        case teamRestDays = "team_rest_days"
        case blowoutProb = "blowout_prob"
        case vegasImpliedTeamTotal = "vegas_implied_team_total"
        case vegasOverUnder = "vegas_over_under"
        case vegasSpread = "vegas_spread"
        case matchupMultiplier = "matchup_multiplier"
    }}
}}

// MARK: - Helpers

private extension Array where Element == Double {{
    var average: Double? {{
        isEmpty ? nil : reduce(0, +) / Double(count)
    }}
}}
"""

games_service_swift = header() + f"""\
import Alamofire
import BKSCore
import Foundation
import OSLog

// MARK: - GamesServiceProtocol

protocol GamesServiceProtocol {{
    func fetchGameLog(playerID: String, teamID: String) async throws -> PlayerGameLog
    func fetchGameLogs(playerIDs: [String], startDate: Date) async throws -> [PlayerGameLog]
    func loadCachedGameLog(playerID: String) throws -> PlayerGameLog?
    func fetchTodaySchedule() async throws -> TodaySchedule
    func loadCachedTodaySchedule() throws -> TodaySchedule?
}}

// MARK: - GamesService

final class GamesService: GamesServiceProtocol {{

    private let network: NetworkProtocol
    private let firebaseNetwork: NetworkProtocol
    private let storage: StorageProtocol
    private let configuration: ConfigurationProtocol
    private let sportConfiguration: SportConfiguration
    private let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "GamesService"
    )

    private static let gameLogCachePrefix = "game_log_"
    private var todayScheduleCacheKey: String {{ "\\\\(sportConfiguration.cacheKeyPrefix)today_schedule_v1" }}
    private var todayScheduleCacheDateKey: String {{ "\\\\(sportConfiguration.cacheKeyPrefix)today_schedule_v1_date" }}
    private static let dateFormatter: DateFormatter = {{
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }}()

    init(
        network: NetworkProtocol,
        firebaseNetwork: NetworkProtocol,
        storage: StorageProtocol,
        configuration: ConfigurationProtocol,
        sportConfiguration: SportConfiguration = .{slug}
    ) {{
        self.network = network
        self.firebaseNetwork = firebaseNetwork
        self.storage = storage
        self.configuration = configuration
        self.sportConfiguration = sportConfiguration
    }}

    // MARK: - Public

    func fetchGameLog(playerID: String, teamID: String) async throws -> PlayerGameLog {{
        let baseURL = configuration.value(for: .gameLogBaseURL)
        let season = currentSeason()

        let response: StatsResponse = try await network.get(
            "\\\\(baseURL)/stats",
            parameters: [
                "player_ids[]": playerID,
                "seasons[]": season,
                "per_page": 100,
            ]
        )

        let entries = response.data.compactMap {{ mapGameEntry($0, teamID: teamID) }}
        let sorted = entries.sorted {{ $0.gameDate > $1.gameDate }}

        let gameLog = PlayerGameLog(
            playerID: playerID,
            entries: sorted,
            fetchedAt: Date()
        )

        cacheGameLog(gameLog)
        return gameLog
    }}

    func fetchGameLogs(playerIDs: [String], startDate: Date) async throws -> [PlayerGameLog] {{
        let baseURL = configuration.value(for: .gameLogBaseURL)
        let dateString = Self.dateFormatter.string(from: startDate)

        var entriesByPlayerID: [String: [GameEntry]] = [:]

        var cursor: Int?
        repeat {{
            try Task.checkCancellation()
            var params: Parameters = [
                "player_ids[]": playerIDs,
                "per_page": 100,
                "start_date": dateString,
            ]
            if let cursor {{
                params["cursor"] = cursor
            }}

            let response: StatsResponse = try await network.get(
                "\\\\(baseURL)/stats",
                parameters: params
            )

            for stat in response.data {{
                guard let team = stat.team, let entry = mapGameEntry(stat, teamID: String(team.id)) else {{
                    continue
                }}
                entriesByPlayerID[String(stat.player.id), default: []].append(entry)
            }}

            cursor = response.meta.nextCursor
        }} while cursor != nil

        let now = Date()
        return playerIDs.compactMap {{ playerID in
            guard let entries = entriesByPlayerID[playerID], !entries.isEmpty else {{ return nil }}
            let log = PlayerGameLog(
                playerID: playerID,
                entries: entries.sorted {{ $0.gameDate > $1.gameDate }},
                fetchedAt: now
            )
            cacheGameLog(log)
            return log
        }}
    }}

    private func cacheGameLog(_ log: PlayerGameLog) {{
        do {{
            try storage.save(log, forKey: Self.gameLogCachePrefix + log.playerID, in: .file)
        }} catch {{
            logger.warning("Failed to cache game log for player \\\\(log.playerID): \\\\(error.diagnosticDescription)")
        }}
    }}

    func loadCachedGameLog(playerID: String) throws -> PlayerGameLog? {{
        try storage.load(forKey: Self.gameLogCachePrefix + playerID, from: .file)
    }}

    func fetchTodaySchedule() async throws -> TodaySchedule {{
        let url = configuration.value(for: .getTodayGamesURL)
        try Task.checkCancellation()
        let response: TodayScheduleResponse = try await firebaseNetwork.get(url, parameters: nil)
        let schedule = TodaySchedule(
            date: response.date,
            gameCount: response.gameCount,
            games: response.games.map {{ dto in
                ScheduledGame(
                    id: dto.gameID,
                    homeTeamAbbr: dto.homeTeamAbbr,
                    visitorTeamAbbr: dto.visitorTeamAbbr,
                    status: dto.status,
                    gameType: dto.gameType,
                    gameDatetime: parseDate(dto.gameDatetime)
                )
            }}
        )
        do {{
            try storage.save(schedule, forKey: todayScheduleCacheKey, in: .file)
            try storage.save(Date.now, forKey: todayScheduleCacheDateKey, in: .file)
        }} catch {{
            logger.warning("Failed to cache today schedule: \\\\(error.diagnosticDescription)")
        }}
        logger.info("Fetched today schedule: \\\\(schedule.gameCount, privacy: .public) game(s) on \\\\(schedule.date, privacy: .public)")
        return schedule
    }}

    func loadCachedTodaySchedule() throws -> TodaySchedule? {{
        try storage.load(forKey: todayScheduleCacheKey, from: .file)
    }}

    // MARK: - Mapping

    // swiftlint:disable:next function_body_length
    private func mapGameEntry(_ stat: StatDTO, teamID: String) -> GameEntry? {{
        guard let game = stat.game else {{ return nil }}

        let gameDate = parseDate(game.date ?? "")

        let isHome: Bool = {{
            if let homeTeam = game.homeTeam {{
                return String(homeTeam.id) == teamID
            }}
            if let homeID = game.homeTeamID {{
                return String(homeID) == teamID
            }}
            return false
        }}()

        let opponent = isHome ? game.visitorTeam : game.homeTeam
        let opponentName = opponent?.fullName ?? ""
        let opponentAbbr: String = {{
            if let abbr = opponent?.abbreviation, !abbr.isEmpty {{
                return abbr
            }}
            let oppID = isHome ? game.visitorTeamID : game.homeTeamID
            if let oppID {{
                return sportConfiguration.teamAbbreviation(for: oppID)
            }}
            return ""
        }}()

        let teamScore = isHome ? (game.homeTeamScore ?? 0) : (game.visitorTeamScore ?? 0)
        let opponentScore = isHome ? (game.visitorTeamScore ?? 0) : (game.homeTeamScore ?? 0)
        let won = teamScore > opponentScore

        let result: GameResult = won
            ? .win(teamScore: teamScore, opponentScore: opponentScore)
            : .loss(teamScore: teamScore, opponentScore: opponentScore)

        return GameEntry(
            gameID: String(game.id),
            gameDate: gameDate,
            opponent: opponentName,
            opponentAbbreviation: opponentAbbr,
            isHomeGame: isHome,
            result: result,
            atBats: stat.atBats ?? 0,
            single: stat.single ?? 0,
            double: stat.double ?? 0,
            triple: stat.triple ?? 0,
            homeRun: stat.homeRun ?? 0,
            rbi: stat.rbi ?? 0,
            run: stat.run ?? 0,
            walk: stat.walk ?? 0,
            hitByPitch: stat.hitByPitch ?? 0,
            stolenBase: stat.stolenBase ?? 0,
            sacrificeFly: stat.sacrificeFly ?? 0,
            sacrificeHit: stat.sacrificeHit ?? 0,
            inningsPitched: stat.inningsPitched ?? 0.0,
            strikeoutPitching: stat.strikeoutPitching ?? 0,
            win: stat.win ?? 0,
            earnedRunAllowed: stat.earnedRunAllowed ?? 0,
            hitAgainst: stat.hitAgainst ?? 0,
            walkAgainst: stat.walkAgainst ?? 0,
            hitBatsmanAgainst: stat.hitBatsmanAgainst ?? 0,
            completeGame: stat.completeGame ?? 0,
            completeGameShutout: stat.completeGameShutout ?? 0,
            noHitter: stat.noHitter ?? 0,
            plusMinus: String(stat.plusMinus ?? 0)
        )
    }}

    private func parseDate(_ string: String) -> Date {{
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {{ return date }}
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) {{ return date }}

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        return dayFormatter.date(from: String(string.prefix(10))) ?? Date()
    }}

    private func currentSeason() -> Int {{
        let calendar = Calendar.current
        let now = Date()
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        return month >= 3 ? year : year - 1
    }}

}}

// MARK: - DTOs

private struct StatsResponse: Decodable {{
    let data: [StatDTO]
    let meta: StatsMetaDTO
}}

private struct StatDTO: Decodable {{
    let id: Int
    let player: StatPlayerDTO
    let game: GameInfoDTO?
    let team: StatsTeamDTO?

    let atBats: Int?
    let single: Int?
    let double: Int?
    let triple: Int?
    let homeRun: Int?
    let rbi: Int?
    let run: Int?
    let walk: Int?
    let hitByPitch: Int?
    let stolenBase: Int?
    let sacrificeFly: Int?
    let sacrificeHit: Int?

    let inningsPitched: Double?
    let strikeoutPitching: Int?
    let win: Int?
    let earnedRunAllowed: Int?
    let hitAgainst: Int?
    let walkAgainst: Int?
    let hitBatsmanAgainst: Int?
    let completeGame: Int?
    let completeGameShutout: Int?
    let noHitter: Int?

    let plusMinus: Int?

    enum CodingKeys: String, CodingKey {{
        case id, player, game, team
        case atBats = "at_bats"
        case single
        case double
        case triple
        case homeRun = "home_run"
        case rbi
        case run
        case walk
        case hitByPitch = "hit_by_pitch"
        case stolenBase = "stolen_base"
        case sacrificeFly = "sacrifice_fly"
        case sacrificeHit = "sacrifice_hit"
        case inningsPitched = "innings_pitched"
        case strikeoutPitching = "strikeout_pitching"
        case win
        case earnedRunAllowed = "earned_run_allowed"
        case hitAgainst = "hit_against"
        case walkAgainst = "walk_against"
        case hitBatsmanAgainst = "hit_batsman_against"
        case completeGame = "complete_game"
        case completeGameShutout = "complete_game_shutout"
        case noHitter = "no_hitter"
        case plusMinus = "plus_minus"
    }}
}}

private struct StatPlayerDTO: Decodable {{
    let id: Int
}}

private struct GameInfoDTO: Decodable {{
    let id: Int
    let date: String?
    let season: Int?
    let status: String?
    let homeTeamScore: Int?
    let visitorTeamScore: Int?
    let homeTeam: StatsTeamDTO?
    let visitorTeam: StatsTeamDTO?
    let homeTeamID: Int?
    let visitorTeamID: Int?

    enum CodingKeys: String, CodingKey {{
        case id, date, season, status
        case homeTeamScore = "home_team_score"
        case visitorTeamScore = "visitor_team_score"
        case homeTeam = "home_team"
        case visitorTeam = "visitor_team"
        case homeTeamID = "home_team_id"
        case visitorTeamID = "visitor_team_id"
    }}
}}

private struct StatsTeamDTO: Decodable {{
    let id: Int
    let abbreviation: String
    let city: String
    let name: String
    let fullName: String

    enum CodingKeys: String, CodingKey {{
        case id, abbreviation, city, name
        case fullName = "full_name"
    }}
}}

private struct StatsMetaDTO: Decodable {{
    let nextCursor: Int?
    let perPage: Int

    enum CodingKeys: String, CodingKey {{
        case nextCursor = "next_cursor"
        case perPage = "per_page"
    }}
}}

// MARK: - Today Schedule DTOs

private struct TodayScheduleResponse: Decodable {{
    let date: String
    let gameCount: Int
    let games: [ScheduledGameDTO]

    enum CodingKeys: String, CodingKey {{
        case date
        case gameCount = "game_count"
        case games
    }}
}}

private struct ScheduledGameDTO: Decodable {{
    let gameID: Int
    let homeTeamAbbr: String
    let visitorTeamAbbr: String
    let status: String
    let gameType: String
    let gameDatetime: String

    enum CodingKeys: String, CodingKey {{
        case gameID = "game_id"
        case homeTeamAbbr = "home_team_abbr"
        case visitorTeamAbbr = "visitor_team_abbr"
        case status
        case gameType = "game_type"
        case gameDatetime = "game_datetime"
    }}
}}

// MARK: - GamesServiceError

enum GamesServiceError: LocalizedError {{
    case noScheduleFound
    case noCompletedGames
    case playerNotFoundInBoxscore

    var errorDescription: String? {{
        switch self {{
        case .noScheduleFound:
            "Could not load team schedule."
        case .noCompletedGames:
            "No completed games found for this team."
        case .playerNotFoundInBoxscore:
            "Player stats not found in game boxscore."
        }}
    }}
}}
"""

playoff_service_swift = header() + f"""\
import BKSCore
import Foundation
import OSLog

// MARK: - PlayoffServiceProtocol

protocol PlayoffServiceProtocol {{
    func fetchLeagueState() async throws -> LeagueState
    func fetchBracket() async throws -> [PlayoffSeries]
    func loadCachedLeagueState() throws -> LeagueState?
    func loadCachedBracket() throws -> [PlayoffSeries]?
}}

// MARK: - PlayoffService

final class PlayoffService: PlayoffServiceProtocol {{

    private let network: NetworkProtocol
    private let storage: StorageProtocol
    private let configuration: ConfigurationProtocol
    private let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "PlayoffService"
    )

    private static let leagueStateCacheKey = "{slug}_league_state_v1"
    private static let bracketCacheKey = "{slug}_playoff_bracket_v1"

    init(
        network: NetworkProtocol,
        storage: StorageProtocol,
        configuration: ConfigurationProtocol
    ) {{
        self.network = network
        self.storage = storage
        self.configuration = configuration
    }}

    // MARK: - Public

    func fetchLeagueState() async throws -> LeagueState {{
        let url = configuration.value(for: .getLeagueStateURL)
        let response: LeagueStateResponse = try await network.get(url, parameters: nil)
        let state = LeagueState(
            mode: SeasonMode(rawValue: response.mode) ?? .regularSeason,
            playoffRound: response.playoffRound,
            playoffStartDate: response.playoffStartDate,
            regularSeasonEndDate: response.regularSeasonEndDate,
            season: response.season
        )
        do {{
            try storage.save(state, forKey: Self.leagueStateCacheKey, in: .file)
        }} catch {{
            logger.warning("Failed to cache league state: \\\\(error.diagnosticDescription)")
        }}
        logger.info("Fetched league state: \\\\(response.mode, privacy: .public)")
        return state
    }}

    func fetchBracket() async throws -> [PlayoffSeries] {{
        let url = configuration.value(for: .getPlayoffBracketURL)
        let response: BracketResponse = try await network.get(url, parameters: nil)
        let series = response.series.map(mapSeries)
        do {{
            try storage.save(series, forKey: Self.bracketCacheKey, in: .file)
        }} catch {{
            logger.warning("Failed to cache playoff bracket: \\\\(error.diagnosticDescription)")
        }}
        logger.info("Fetched playoff bracket: \\\\(series.count, privacy: .public) series")
        return series
    }}

    func loadCachedLeagueState() throws -> LeagueState? {{
        try storage.load(forKey: Self.leagueStateCacheKey, from: .file)
    }}

    func loadCachedBracket() throws -> [PlayoffSeries]? {{
        try storage.load(forKey: Self.bracketCacheKey, from: .file)
    }}

    // MARK: - Mapping

    private func mapSeries(_ dto: SeriesDTO) -> PlayoffSeries {{
        PlayoffSeries(
            seriesID: dto.seriesID,
            roundNumber: dto.roundNumber,
            roundName: dto.roundName,
            conference: dto.conference,
            higherSeedTeam: dto.higherSeedTeam,
            lowerSeedTeam: dto.lowerSeedTeam,
            higherSeed: dto.higherSeed,
            lowerSeed: dto.lowerSeed,
            winsHigherSeed: dto.winsHigherSeed,
            winsLowerSeed: dto.winsLowerSeed,
            status: SeriesStatus(rawValue: dto.status) ?? .scheduled,
            winner: dto.winner,
            gamesPlayed: dto.gamesPlayed,
            eliminationGameNext: dto.eliminationGameNext,
            homeCourt: dto.homeCourtPattern
        )
    }}
}}

// MARK: - DTOs

private struct LeagueStateResponse: Decodable {{
    let mode: String
    let playoffRound: Int?
    let playoffStartDate: String?
    let regularSeasonEndDate: String?
    let season: Int?

    enum CodingKeys: String, CodingKey {{
        case mode
        case playoffRound = "playoff_round"
        case playoffStartDate = "playoff_start_date"
        case regularSeasonEndDate = "regular_season_end_date"
        case season
    }}
}}

private struct BracketResponse: Decodable {{
    let series: [SeriesDTO]
}}

private struct SeriesDTO: Decodable {{
    let seriesID: String
    let roundNumber: Int
    let roundName: String
    let conference: String
    let higherSeedTeam: String
    let lowerSeedTeam: String
    let higherSeed: Int
    let lowerSeed: Int
    let winsHigherSeed: Int
    let winsLowerSeed: Int
    let status: String
    let winner: String?
    let gamesPlayed: Int
    let eliminationGameNext: Bool
    let homeCourtPattern: [String: Bool]

    enum CodingKeys: String, CodingKey {{
        case seriesID = "series_id"
        case roundNumber = "round_number"
        case roundName = "round_name"
        case conference
        case higherSeedTeam = "higher_seed_team"
        case lowerSeedTeam = "lower_seed_team"
        case higherSeed = "higher_seed"
        case lowerSeed = "lower_seed"
        case winsHigherSeed = "wins_higher_seed"
        case winsLowerSeed = "wins_lower_seed"
        case status
        case winner
        case gamesPlayed = "games_played"
        case eliminationGameNext = "elimination_game_next"
        case homeCourtPattern = "home_court_pattern"
    }}
}}
"""

write(os.path.join(services_dir, "ProjectionsService.swift"), projections_service_swift)
write(os.path.join(services_dir, "GamesService.swift"), games_service_swift)
write(os.path.join(services_dir, "PlayoffService.swift"), playoff_service_swift)

promo_code_service_swift = header() + f"""\
import BKSCore
import Foundation
import OSLog

// MARK: - PromoCodeServiceProtocol

protocol PromoCodeServiceProtocol {{
    func redeemPromoCode(_ code: String) async throws -> PromoRedemptionResult
}}

// MARK: - PromoRedemptionResult

struct PromoRedemptionResult: Decodable {{
    let uid: String
    let tier: String
    let code: String
    let status: String
}}

// MARK: - PromoCodeError

enum PromoCodeError: LocalizedError {{
    case invalidCode
    case alreadyRedeemed
    case missingCode
    case serverError

    var errorDescription: String? {{
        switch self {{
        case .invalidCode:
            String(localized: "promoCode.error.invalidCode",
                   defaultValue: "This promo code isn\\'t valid. Check the code and try again.")
        case .alreadyRedeemed:
            String(localized: "promoCode.error.alreadyRedeemed",
                   defaultValue: "You\\'ve already redeemed this code.")
        case .missingCode:
            String(localized: "promoCode.error.missingCode",
                   defaultValue: "Please enter a promo code.")
        case .serverError:
            String(localized: "promoCode.error.serverError",
                   defaultValue: "Something went wrong. Try again later.")
        }}
    }}
}}

// MARK: - PromoCodeService

final class PromoCodeService: PromoCodeServiceProtocol {{
    private let network: NetworkProtocol
    private let configuration: ConfigurationProtocol
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "PromoCodeService"
    )

    init(network: NetworkProtocol, configuration: ConfigurationProtocol) {{
        self.network = network
        self.configuration = configuration
    }}

    func redeemPromoCode(_ code: String) async throws -> PromoRedemptionResult {{
        let url = configuration.value(for: .redeemPromoCodeURL)
        let body = PromoCodeRequest(code: code)
        logger.debug("Redeeming promo code")
        do {{
            let result: PromoRedemptionResult = try await network.post(url, body: body)
            logger.info("Promo code redeemed — tier: \\\\(result.tier, privacy: .public)")
            return result
        }} catch let error as NetworkError {{
            throw mapError(error)
        }}
    }}

    private func mapError(_ error: NetworkError) -> Error {{
        guard case let .httpError(statusCode, _) = error else {{ return error }}
        switch statusCode {{
        case 400: return PromoCodeError.missingCode
        case 404: return PromoCodeError.invalidCode
        case 409: return PromoCodeError.alreadyRedeemed
        default:
            logger.error("Promo code HTTP error: \\\\(statusCode, privacy: .public)")
            return PromoCodeError.serverError
        }}
    }}
}}

// MARK: - Request DTO

private struct PromoCodeRequest: Encodable {{
    let code: String
}}
"""

write(os.path.join(services_dir, "PromoCodeService.swift"), promo_code_service_swift)

# ─────────────────────────────────────────────────────────────────────────────
# 9d. Core UI files
# ─────────────────────────────────────────────────────────────────────────────

core_ui_dir = os.path.join(out_dir, "App/Sources/Core/UI")

tier_types_ui_swift = header() + """\
import SwiftUI
import BKSCore
import BKSUICore

// MARK: - PlayerTier + UI

extension PlayerTier {
    var displayName: String { tierDisplayName + " Tier" }
    var color: Color { tierColor }

    var systemImage: String {
        switch self {
        case .elite: "crown.fill"
        case .good: "star.fill"
        case .solid: "checkmark.shield.fill"
        case .bottomFeeder: "figure.walk"
        }
    }

    var label: String {
        switch self {
        case .elite: "Elite"
        case .good: "Good"
        case .solid: "Solid"
        case .bottomFeeder: "Bottom Feeder"
        }
    }
}

// MARK: - RotationTier + UI

extension RotationTier {
    /// Localized display label for the rotation tier.
    var displayLabel: String {
        switch self {
        case .star:
            String(localized: "rotationTier.star", defaultValue: "Star")
        case .starter:
            String(localized: "rotationTier.starter", defaultValue: "Starter")
        case .rotation:
            String(localized: "rotationTier.rotation", defaultValue: "Rotation")
        case .fringe:
            String(localized: "rotationTier.fringe", defaultValue: "Fringe")
        case .bench:
            String(localized: "rotationTier.bench", defaultValue: "Bench")
        }
    }

    /// Color representing the rotation tier.
    var color: Color {
        switch self {
        case .star: Color(red: 1.0, green: 0.843, blue: 0.0)
        case .starter: Color(red: 0.290, green: 0.565, blue: 0.851)
        case .rotation: Color(red: 0.204, green: 0.780, blue: 0.349)
        case .fringe: .orange
        case .bench: Color(red: 0.557, green: 0.557, blue: 0.576)
        }
    }
}

// MARK: - FeatureTier + UI

extension FeatureTier {
    var displayName: String { tierDisplayName }
    var color: Color { tierColor }
}
"""

search_tips_view_swift = header() + """\
import SwiftUI

/// Sport-specific search tips popover content.
struct SearchTipsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "trending.searchTips.title", defaultValue: "Search Tips"))
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                searchTipRow(
                    icon: "person.fill",
                    label: String(localized: "trending.searchTips.playerName", defaultValue: "Player Name"),
                    example: String(localized: "trending.searchTips.playerName.example", defaultValue: "e.g. Shohei")
                )
                searchTipRow(
                    icon: "tshirt.fill",
                    label: String(localized: "trending.searchTips.teamAbbr", defaultValue: "Team Abbreviation"),
                    example: String(localized: "trending.searchTips.teamAbbr.example", defaultValue: "e.g. LAD")
                )
                searchTipRow(
                    icon: "building.2.fill",
                    label: String(localized: "trending.searchTips.teamName", defaultValue: "Team Name"),
                    example: String(localized: "trending.searchTips.teamName.example", defaultValue: "e.g. Dodgers")
                )
                searchTipRow(
                    icon: "line.3.horizontal.decrease.circle.fill",
                    label: String(localized: "trending.searchTips.position", defaultValue: "Position"),
                    example: String(localized: "trending.searchTips.position.example", defaultValue: "e.g. SP")
                )
            }
        }
        .font(.caption)
        .foregroundStyle(.primary)
        .padding()
        .frame(width: 260)
    }

    private func searchTipRow(icon: String, label: String, example: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.medium))
                Text(example)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
"""

season_mode_banner_swift = header() + """\
import BKSCore
import BKSUICore
import SwiftUI

struct SeasonModeBanner: View {
    let mode: SeasonMode

    var body: some View {
        switch mode {
        case .regularSeason:
            EmptyView()
        case .playoffs:
            bannerCapsule(
                icon: "trophy.fill",
                text: String(localized: "seasonMode.playoffs", defaultValue: "Playoffs"),
                color: .orange
            )
        case .offseason:
            bannerCapsule(
                icon: "moon.fill",
                text: String(localized: "seasonMode.offseason", defaultValue: "Offseason"),
                color: .gray
            )
        }
    }

    private func bannerCapsule(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.85))
        .clipShape(Capsule())
        .padding(.top, 4)
        .accessibilityLabel(text)
    }
}
"""

write(os.path.join(core_ui_dir, "TierTypes+UI.swift"), tier_types_ui_swift)
write(os.path.join(core_ui_dir, "SearchTipsView.swift"), search_tips_view_swift)
write(os.path.join(core_ui_dir, "SeasonModeBanner.swift"), season_mode_banner_swift)

# ─────────────────────────────────────────────────────────────────────────────
# 9e. Core Utilities
# ─────────────────────────────────────────────────────────────────────────────

utilities_dir = os.path.join(out_dir, "App/Sources/Core/Utilities")

filterable_swift = header() + """\
import Foundation
import BKSCore

// MARK: - Injury availability

extension Filterable where Self: InjuryTracking {
    /// Returns `true` when the player is out or doubtful and should be
    /// excluded from active lists.
    var isUnavailable: Bool {
        switch injuryStatus {
        case .out, .doubtful: true
        default: false
        }
    }
}

/// Domain models that carry an injury status conform to this protocol
/// so the generic `isUnavailable` logic can apply.
protocol InjuryTracking {
    var injuryStatus: InjuryStatus? { get }
}

extension Player: InjuryTracking {}
extension Opportunity: InjuryTracking {}
extension Projection: InjuryTracking {}

// MARK: - Position-aware filtering

extension Array where Element: Filterable {
    /// Filters the array by search text and position chip.
    /// Pass the sport's `SportPositionMap` to control which raw position
    /// strings each chip label matches.
    func filtered(search: String, chip: String?, positionMap: SportPositionMap) -> [Element] {
        filter { item in
            let matchesSearch: Bool = {
                guard !search.isEmpty else { return true }
                if item.displayName.localizedCaseInsensitiveContains(search) { return true }
                if item.team.localizedCaseInsensitiveContains(search) { return true }
                for field in item.additionalSearchFields
                    where field.localizedCaseInsensitiveContains(search) { return true }
                return false
            }()
            let matchesPosition = positionMap.matchesChip(chip, position: item.position)
            return matchesSearch && matchesPosition
        }
    }
}
"""

player_lookup_swift = header() + """\
import Foundation

/// Finds a `Player` record from an array by `externalPersonID` (preferred)
/// or `displayName` + `team` fallback. Sport-agnostic — works for any sport
/// whose player model carries an optional external data-provider ID.
enum PlayerLookup {
    static func find(
        externalPersonID: Int?,
        displayName: String,
        team: String,
        in players: [Player]
    ) -> Player? {
        if let personID = externalPersonID,
           let match = players.first(where: { $0.externalPersonID == personID }) {
            return match
        }
        return players.first { $0.displayName == displayName && $0.team == team }
    }
}
"""

write(os.path.join(utilities_dir, f"Filterable+{swift_name}.swift"), filterable_swift)
write(os.path.join(utilities_dir, "PlayerLookup.swift"), player_lookup_swift)

# ─────────────────────────────────────────────────────────────────────────────
# 9f. Trending Store
# ─────────────────────────────────────────────────────────────────────────────

trending_store_dir = os.path.join(out_dir, "App/Sources/Features/Trending/Store")

trending_state_swift = header() + f"""\
import OSLog
import BKSCore
import SwiftUI

struct TrendingState {{
    var navigationPath = NavigationPath()
    var trends: ViewState<[Player]> = .idle
    var hotPlayers: [Player] = []
    var coldPlayers: [Player] = []
    var filteredHotPlayers: [Player] = []
    var filteredColdPlayers: [Player] = []
    var searchText = ""
    var selectedPosition: String?
    var lastUpdated: Date?

    private static let stalenessThreshold = CacheFreshness.defaultThreshold

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "TrendingState"
    )

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func makeReduce(
        trendingsService: TrendingsServiceProtocol,
        positionMap: SportPositionMap
    ) -> Reduce<Self, TrendingIntent> {{
        {{ state, intent in
            switch intent {{
            case .onAppear:
                if CacheFreshness.isFresh(lastUpdated: state.lastUpdated, threshold: stalenessThreshold),
                   case .loaded = state.trends
                {{
                    logger.debug("Trends cache is fresh, skipping fetch")
                    return nil
                }}
                state.trends = .loading
                return await fetchTrends(trendingsService: trendingsService)

            case .refreshRequested:
                state.trends = .loading
                return await fetchTrends(trendingsService: trendingsService, forceNetwork: true)

            case let .trendsLoaded(players):
                let available = players.filter {{ !Self.isUnavailable($0) }}
                let hot = available
                    .filter {{ $0.trendDirection == .up }}
                    .sorted {{
                        let tierA = $0.playerTier?.sortOrder ?? Int.max
                        let tierB = $1.playerTier?.sortOrder ?? Int.max
                        if tierA != tierB {{ return tierA < tierB }}
                        return Self.weightedScore($0) > Self.weightedScore($1)
                    }}
                let cold = available
                    .filter {{ $0.trendDirection == .down }}
                    .sorted {{
                        let tierA = $0.playerTier?.sortOrder ?? Int.max
                        let tierB = $1.playerTier?.sortOrder ?? Int.max
                        if tierA != tierB {{ return tierA < tierB }}
                        return Self.weightedScore($0) < Self.weightedScore($1)
                    }}
                state.hotPlayers = hot
                state.coldPlayers = cold
                state.trends = .loaded(hot + cold)
                state.lastUpdated = Date.now
                applyFilters(&state, positionMap: positionMap)
                return nil

            case let .trendsFailed(error):
                if case .loaded = state.trends {{
                    logger.warning("Trends refresh failed but keeping existing data: \\\\(error.diagnosticDescription)")
                    return nil
                }}
                state.trends = .failed(error)
                return nil

            case let .navigationPathChanged(path):
                state.navigationPath = path
                return nil

            case let .searchTextChanged(text):
                state.searchText = text
                applyFilters(&state, positionMap: positionMap)
                return nil

            case let .positionFilterChanged(position):
                state.selectedPosition = position
                applyFilters(&state, positionMap: positionMap)
                return nil
            }}
        }}
    }}

    private static func applyFilters(_ state: inout Self, positionMap: SportPositionMap) {{
        let search = state.searchText
        let chip = state.selectedPosition

        state.filteredHotPlayers = filterPlayers(state.hotPlayers, search: search, chip: chip, positionMap: positionMap)
        state.filteredColdPlayers = filterPlayers(
            state.coldPlayers, search: search, chip: chip, positionMap: positionMap
        )
    }}

    private static func filterPlayers(
        _ players: [Player],
        search: String,
        chip: String?,
        positionMap: SportPositionMap
    ) -> [Player] {{
        players.filtered(search: search, chip: chip, positionMap: positionMap)
    }}

    private static func weightedScore(_ player: Player) -> Double {{
        player.confidenceScore ?? 0
    }}

    private static func isUnavailable(_ player: Player) -> Bool {{
        player.isUnavailable
    }}

    private static func fetchTrends(
        trendingsService: TrendingsServiceProtocol,
        forceNetwork: Bool = false
    ) async -> TrendingIntent {{
        do {{
            if !forceNetwork, let cached = try trendingsService.loadCachedPlayers(), !cached.isEmpty {{
                logger.debug("Using cached players for trends (\\\\(cached.count) players)")
                return .trendsLoaded(cached)
            }}
            if forceNetwork {{
                logger.debug("Refresh requested — fetching from network")
            }} else {{
                logger.debug("No cached players — fetching from network")
            }}
            let players = try await trendingsService.fetchPlayers()
            return .trendsLoaded(players)
        }} catch {{
            if forceNetwork, let cached = try? trendingsService.loadCachedPlayers(), !cached.isEmpty {{
                logger.warning("Network fetch failed, falling back to cache: \\\\(error.diagnosticDescription)")
                return .trendsLoaded(cached)
            }}
            return .trendsFailed(error)
        }}
    }}
}}
"""

trending_intent_swift = header() + """\
import SwiftUI

enum TrendingIntent {
    case onAppear
    case navigationPathChanged(NavigationPath)
    case trendsLoaded([Player])
    case trendsFailed(Error)
    case refreshRequested
    case searchTextChanged(String)
    case positionFilterChanged(String?)
}
"""

player_detail_state_swift = header() + f"""\
import OSLog
import BKSCore

struct PlayerDetailState {{
    let player: Player
    var gameLog: ViewState<PlayerGameLog> = .idle

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "PlayerDetailState"
    )

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func makeReduce(
        gamesService: GamesServiceProtocol
    ) -> Reduce<Self, PlayerDetailIntent> {{
        {{ state, intent in
            switch intent {{
            case .onAppear:
                return nil

            case .gameLogTabSelected:
                guard case .idle = state.gameLog else {{ return nil }}
                do {{
                    if let cached = try gamesService.loadCachedGameLog(playerID: state.player.id) {{
                        state.gameLog = .loaded(cached)
                        return nil
                    }}
                }} catch {{
                    logger.warning("Failed to load cached game log: \\\\(error.diagnosticDescription)")
                }}
                state.gameLog = .loading
                return .fetchGameLog

            case .fetchGameLog:
                do {{
                    let gameLog = try await gamesService.fetchGameLog(
                        playerID: state.player.id,
                        teamID: state.player.team
                    )
                    return .gameLogLoaded(gameLog)
                }} catch {{
                    return .gameLogFailed(error)
                }}

            case let .gameLogLoaded(gameLog):
                state.gameLog = .loaded(gameLog)
                return nil

            case let .gameLogFailed(error):
                if case .loaded = state.gameLog {{
                    logger.warning("Game log refresh failed but keeping existing data: \\\\(error.diagnosticDescription)")
                    return nil
                }}
                state.gameLog = .failed(error)
                return nil

            case .refreshRequested:
                state.gameLog = .loading
                return .fetchGameLog
            }}
        }}
    }}
}}
"""

player_detail_intent_swift = header() + """\
enum PlayerDetailIntent {
    case onAppear
    case gameLogTabSelected
    case fetchGameLog
    case gameLogLoaded(PlayerGameLog)
    case gameLogFailed(Error)
    case refreshRequested
}
"""

write(os.path.join(trending_store_dir, "TrendingState.swift"), trending_state_swift)
write(os.path.join(trending_store_dir, "TrendingIntent.swift"), trending_intent_swift)
write(os.path.join(trending_store_dir, "PlayerDetailState.swift"), player_detail_state_swift)
write(os.path.join(trending_store_dir, "PlayerDetailIntent.swift"), player_detail_intent_swift)

# ─────────────────────────────────────────────────────────────────────────────
# 9g. Trending Views
# ─────────────────────────────────────────────────────────────────────────────

trending_views_dir = os.path.join(out_dir, "App/Sources/Features/Trending/Views")

trending_view_swift = header() + f"""\
import SwiftUI
import BKSCore
import BKSUICore

struct TrendingView: View {{
    @ObservedObject var store: Store<TrendingState, TrendingIntent>
    let gamesService: GamesServiceProtocol
    let credential: StoredCredential
    @ObservedObject var profileStore: Store<ProfileState, ProfileIntent>
    @State private var showProfile = false
    @State private var toastTier: PlayerTier?
    @State private var selectedTab = TrendingTab.hot
    @Environment(\\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\\.analytics) private var analytics

    private var searchBinding: Binding<String> {{
        Binding(
            get: {{ store.state.searchText }},
            set: {{ store.send(.searchTextChanged($0)) }}
        )
    }}

    var body: some View {{
        NavigationStack(path: Binding(
            get: {{ store.state.navigationPath }},
            set: {{ store.send(.navigationPathChanged($0)) }}
        )) {{
            content
                .appBackground()
                .analyticsScreen("trending")
                .appNavigationBar(
                    title: String(localized: "trending.title", defaultValue: "Trending"),
                    subtitle: String(localized: "trending.subtitle", defaultValue: "Over the past 5 games")
                )
                .navBarTrailingIcon(
                    "person",
                    accessibilityID: "nav.profileButton",
                    accessibilityLabel: String(localized: "a11y.label.profile", defaultValue: "Profile")
                ) {{ showProfile = true }}
                .navigationDestination(isPresented: $showProfile) {{
                    ProfilePanelView(credential: credential, profileStore: profileStore)
                        .appNavigationBar(title: String(localized: "Profile", defaultValue: "Profile"))
                }}
                .navigationDestination(for: Player.self) {{ player in
                    PlayerDetailView(
                        store: Store(
                            initial: PlayerDetailState(player: player),
                            reduce: PlayerDetailState.makeReduce(gamesService: gamesService)
                        )
                    )
                    .onAppear {{
                        analytics.logDetailedEvent(AnalyticsEvent.playerTapped, parameters: [
                            AnalyticsParam.playerId: player.id,
                            AnalyticsParam.playerTier: player.playerTier.map(String.init(describing:)) ?? "unknown",
                            AnalyticsParam.trendDirection:
                                player.trendDirection.map(String.init(describing:)) ?? "unknown",
                            AnalyticsParam.isSurging: String(player.isSurging ?? false),
                            AnalyticsParam.subTab: String(describing: selectedTab)
                        ])
                    }}
                }}
        }}
        .task {{
            store.send(.onAppear)
        }}
        .onChange(of: selectedTab) {{
            analytics.logEvent(AnalyticsEvent.subTabSelected, parameters: [
                AnalyticsParam.tabName: String(describing: selectedTab),
                AnalyticsParam.feature: "trending"
            ])
        }}
        .onChange(of: store.state.searchText.isEmpty) {{
            if !store.state.searchText.isEmpty {{
                analytics.logEvent(AnalyticsEvent.searchUsed, parameters: [
                    AnalyticsParam.feature: "trending"
                ])
            }}
        }}
        .onChange(of: store.state.selectedPosition) {{
            analytics.logEvent(AnalyticsEvent.filterChanged, parameters: [
                AnalyticsParam.feature: "trending"
            ])
        }}
    }}

    private var content: some View {{
        LoadableContentView(
            state: store.state.trends,
            isEmpty: store.state.hotPlayers.isEmpty && store.state.coldPlayers.isEmpty,
            emptyIcon: "chart.line.flattrend.xyaxis",
            errorKey: "trending.error",
            retryKey: "trending.retry",
            emptyKey: "trending.empty",
            onRetry: {{ store.send(.refreshRequested) }},
            content: {{ trendList }}
        )
    }}

    private var trendList: some View {{
        let activePlayers = selectedTab == .hot
            ? store.state.filteredHotPlayers
            : store.state.filteredColdPlayers
        let activeGrouped = Dictionary(grouping: activePlayers) {{ $0.playerTier ?? .bottomFeeder }}
        let tiers: [PlayerTier] = [.elite, .good, .solid, .bottomFeeder]
        let filtersActive = !store.state.searchText.isEmpty || store.state.selectedPosition != nil
        let filteredEmpty = activePlayers.isEmpty

        return VStack(spacing: 0) {{
            SearchFilterHeader(
                searchText: searchBinding,
                selectedPosition: store.state.selectedPosition,
                filterChips: ["All"] + SportPositionMap.{slug}.filterChips,
                accessibilityPrefix: "trending",
                onPositionChanged: {{ store.send(.positionFilterChanged($0)) }},
                tipsContent: {{ SearchTipsView() }}
            )

            FeatureTabBar(
                selectedTab: $selectedTab,
                reduceMotion: reduceMotion,
                accessibilityPrefix: "trending"
            )
            .padding(.horizontal)
            .padding(.bottom, 8)

            if filtersActive, filteredEmpty {{
                FilteredEmptyView(messageKey: "trending.filter.empty")
            }} else {{
                ScrollView {{
                    VStack(spacing: AppSpacing.xl) {{
                        ForEach(tiers, id: \\.self) {{ tier in
                            let players = (activeGrouped[tier] ?? [])
                                .sorted {{ ($0.confidenceScore ?? 0) > ($1.confidenceScore ?? 0) }}
                            TrendingTierSection(
                                tier: tier,
                                players: players,
                                color: selectedTab.accentColor,
                                toastTier: $toastTier
                            )
                        }}
                    }}
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                }}
                .id(selectedTab)
                .refreshable {{
                    analytics.logEvent(AnalyticsEvent.pullToRefresh, parameters: [
                        AnalyticsParam.feature: "trending"
                    ])
                    await store.sendAsync(.refreshRequested)
                }}
                .contentMargins(.bottom, AppPadding.tabBarClearance, for: .scrollContent)
                .overlay(alignment: .bottom) {{
                    if let tier = toastTier {{
                        TierToastView(tier: tier)
                            .padding(.bottom, 16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }}
                }}
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: toastTier)
            }}
        }}
    }}

}}
"""

trending_subviews_swift = header() + """\
import SwiftUI
import BKSCore
import BKSUICore

// MARK: - TrendingTab

enum TrendingTab: CaseIterable, FeatureTab {
    case hot
    case cold

    var title: String {
        switch self {
        case .hot: String(localized: "trending.tab.hot", defaultValue: "Hot")
        case .cold: String(localized: "trending.tab.cold", defaultValue: "Cold")
        }
    }

    var icon: String {
        switch self {
        case .hot: "🔥"
        case .cold: "❄️"
        }
    }

    var accentColor: Color {
        switch self {
        case .hot: .orange
        case .cold: .cyan
        }
    }
}

// MARK: - TrendingTierSection — thin wrapper around shared TierSection

/// Trending-specific tier section that wraps each row in a NavigationLink.
struct TrendingTierSection: View {
    let tier: PlayerTier
    let players: [Player]
    let color: Color
    @Binding var toastTier: PlayerTier?

    var body: some View {
        TierSection(
            tier: tier,
            isEmpty: players.isEmpty,
            emptyKey: "trending.tier.none",
            toastTier: $toastTier
        ) {
            ForEach(Array(players.enumerated()), id: \\.element.id) { index, player in
                NavigationLink(value: player) {
                    RankingRow(player: player, color: color)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityIdentifier("player.row.\\(player.id)")
                if index < players.count - 1 {
                    Divider()
                        .overlay(Color.white.opacity(AppOpacity.cardOverlay))
                }
            }
        }
    }
}

// MARK: - RankingRow

struct RankingRow: View {
    let player: Player
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Row 1: Player name
            HStack(spacing: 4) {
                Text(player.displayName)
                    .font(AppFonts.rankingName)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(AppFonts.rankingInfo)
                    .foregroundStyle(.white.opacity(AppOpacity.dim))
            }

            // Row 2: Team · Position · Trend score
            HStack(spacing: 4) {
                Text(player.team)
                    .font(AppFonts.rankingInfo)
                    .foregroundStyle(.white.opacity(AppOpacity.muted))
                if let position = player.position {
                    Text("·")
                        .font(AppFonts.rankingInfo)
                        .foregroundStyle(.white.opacity(AppOpacity.muted))
                    Text(position)
                        .font(AppFonts.rankingInfo)
                        .foregroundStyle(.white.opacity(AppOpacity.muted))
                }
                Spacer(minLength: 0)
                Text(Self.formattedScore(player))
                    .font(AppFonts.rankingScore)
                    .foregroundStyle(Self.scoreColor(player))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            // Row 3: Badges (injury, surging, playoff pending)
            let hasBadges = player.injuryStatus != nil
                || (player.isSurging == true && player.trendDirection == .up
                    && player.playoffConfidence != .pending)
                || player.playoffConfidence == .pending
            if hasBadges {
                HStack(spacing: 3) {
                    if let status = player.injuryStatus {
                        InjuryBadge(status: status, compact: true)
                    }
                    if player.isSurging == true,
                       player.trendDirection == .up,
                       player.playoffConfidence != .pending {
                        Text("🚀")
                            .font(AppFonts.rankingBadgeIcon)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    if case .pending = player.playoffConfidence {
                        Text(String(localized: "trending.playoff.pending",
                                    defaultValue: "Building playoff data"))
                            .font(AppFonts.rankingBadgeIcon)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private static func formattedScore(_ player: Player) -> String {
        let score = player.confidenceScore ?? 0
        let prefix = player.trendDirection == .down ? "-" : ""
        return prefix + String(format: "%.2f", score)
    }

    private static func scoreColor(_ player: Player) -> Color {
        player.trendDirection == .down ? .red : .green
    }
}
"""

player_row_view_swift = header() + """\
import SwiftUI
import BKSCore
import BKSUICore

struct PlayerRowView: View {
    let player: Player

    var body: some View {
        HStack(spacing: 8) {
            headshot
            playerInfo
        }
        .padding(.vertical, 2)
    }

    private var headshot: some View {
        CachedAsyncImage(url: player.headshotURL) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
                    .accessibilityIgnoresInvertColors(true)
            default:
                Image(systemName: "person.fill")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(AppOpacity.muted))
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(Circle())
        .overlay(Circle().stroke(
            player.injuryStatus.map(\\.color) ?? .white.opacity(AppOpacity.faint),
            lineWidth: player.injuryStatus != nil ? 2 : 1
        ))
        .overlay(alignment: .topLeading) {
            if let status = player.injuryStatus {
                InjuryBadge(status: status)
                    .offset(x: -8, y: -8)
            }
        }
    }

    private var playerInfo: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(player.displayName)
                .font(AppFonts.playerName)
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(1)
            playerSubtitleRow
            playerTrendRow
        }
        .frame(height: 60)
        .accessibilityElement(children: .combine)
    }

    private var playerSubtitleRow: some View {
        HStack(spacing: 6) {
            Text(player.team).fontWeight(.semibold)
            if let position = player.position {
                rowPipe
                Text(position)
            }
        }
        .font(AppFonts.playerInfoLine)
        .foregroundStyle(.white.opacity(AppOpacity.primary))
        .lineLimit(1)
    }

    private var playerTrendRow: some View {
        HStack(spacing: 6) {
            trendArrow.frame(width: 14, alignment: .center)
            rowPipe
            trendScore.frame(width: 44, alignment: .center)
            if let tier = player.playerTier {
                rowPipe
                Image(systemName: tier.systemImage)
                    .foregroundStyle(tier.color)
                    .frame(width: 14, alignment: .center)
            }
        }
        .lineLimit(1)
        .font(AppFonts.playerInfoLine)
        .foregroundStyle(.white.opacity(AppOpacity.primary))
    }

    private var rowPipe: some View {
        Text(String(localized: "|", defaultValue: "|")).foregroundStyle(.white.opacity(AppOpacity.separator))
    }

    @ViewBuilder private var trendArrow: some View {
        switch player.playoffConfidence {
        case .pending:
            Image(systemName: "minus")
                .font(AppFonts.playerTrendArrow)
                .foregroundStyle(.white.opacity(AppOpacity.separator))
        case let .partial(confidence):
            if let direction = player.trendDirection {
                let name: String = switch direction {
                case .up: "arrow.up"
                case .down: "arrow.down"
                case .flat, .neutral: "minus"
                }
                Image(systemName: name)
                    .font(AppFonts.playerTrendArrow)
                    .foregroundStyle(Color.orange.opacity(0.4 + 0.6 * confidence))
            } else {
                Image(systemName: "minus")
                    .font(AppFonts.playerTrendArrow)
                    .foregroundStyle(.white.opacity(AppOpacity.separator))
            }
        case .regularSeason, .full:
            if let direction = player.trendDirection {
                let (name, color): (String, Color) = switch direction {
                case .up: ("arrow.up", .green)
                case .down: ("arrow.down", .red)
                case .flat, .neutral: ("minus", .white.opacity(AppOpacity.separator))
                }
                Image(systemName: name).font(AppFonts.playerTrendArrow).foregroundStyle(color)
            } else {
                Image(systemName: "minus").foregroundStyle(.white.opacity(AppOpacity.separator))
            }
        }
    }

    private var trendScore: some View {
        switch player.playoffConfidence {
        case .pending:
            return Text("–").monospacedDigit().multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(AppOpacity.separator))
        case .partial:
            let formatted = player.confidenceScore.map { String(format: "%.2f", $0) } ?? "–"
            return Text(formatted).monospacedDigit().multilineTextAlignment(.center)
                .foregroundStyle(Color.orange.opacity(0.6))
        case .regularSeason, .full:
            let formatted = player.confidenceScore.map { score -> String in
                let prefix = player.trendDirection == .down ? "-" : ""
                return prefix + String(format: "%.2f", score)
            } ?? "-"
            let color: Color = player.confidenceScore == nil
                ? .white.opacity(AppOpacity.separator)
                : (player.trendDirection == .down ? .red : .green)
            return Text(formatted).monospacedDigit().multilineTextAlignment(.center)
                .foregroundStyle(color)
        }
    }
}
"""

write(os.path.join(trending_views_dir, "TrendingView.swift"), trending_view_swift)
write(os.path.join(trending_views_dir, "TrendingSubviews.swift"), trending_subviews_swift)
write(os.path.join(trending_views_dir, "PlayerRowView.swift"), player_row_view_swift)

player_detail_view_swift = header() + """\
import SwiftUI
import BKSCore
import BKSUICore

struct PlayerDetailView: View {
    @StateObject var store: Store<PlayerDetailState, PlayerDetailIntent>

    @State private var selectedTab = DetailTab.stats
    @State private var showTierToast = false
    @Environment(\\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\\.analytics) private var analytics
    @State private var hasLoggedGameLog = false

    private var player: Player {
        store.state.player
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                PlayerDetailHeaderCard(player: player, showTierToast: $showTierToast)
                PlayerDetailFantasyBar(player: player)
                tabBar
                tabContent
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 20)
        }
        .contentMargins(.bottom, AppPadding.tabBarClearance, for: .scrollContent)
        .appBackground()
        .analyticsScreen("player_detail")
        .overlay(alignment: .bottom) {
            if showTierToast, let tier = player.playerTier {
                PlayerTierToast(tier: tier, player: player)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: showTierToast)
        .appNavigationBar(title: "")
        .task { store.send(.onAppear) }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(DetailTab.allCases, id: \\.self) { tab in
                tabButton(tab)
            }
        }
    }

    private func tabButton(_ tab: DetailTab) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                selectedTab = tab
            }
            analytics.logDetailedEvent(AnalyticsEvent.detailTabSwitched, parameters: [
                AnalyticsParam.tabName: String(describing: tab),
                AnalyticsParam.feature: "trending",
                AnalyticsParam.playerId: player.id,
                AnalyticsParam.playerTier: player.playerTier.map(String.init(describing:)) ?? "unknown"
            ])
            if tab == .gameLog {
                store.send(.gameLogTabSelected)
            }
        } label: {
            VStack(spacing: 4) {
                Text(tab.title)
                    .font(selectedTab == tab ? AppFonts.filterChip.weight(.semibold) : AppFonts.filterChip)
                    .foregroundStyle(
                        selectedTab == tab ? .white : .white.opacity(AppOpacity.muted)
                    )

                Rectangle()
                    .fill(selectedTab == tab ? .orange : .clear)
                    .frame(height: 2)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
        .accessibilityIdentifier(tab == .stats ? "detail.tab.trends" : "detail.tab.gameLog")
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .stats:
            statsContent
        case .gameLog:
            gameLogContent
        }
    }

    // MARK: - Stats

    private var statsContent: some View {
        PlayerDetailOverviewTrendCard(player: player)
    }

    // MARK: - Game Log

    @ViewBuilder
    private var gameLogContent: some View {
        switch store.state.gameLog {
        case .idle, .loading:
            GameLogPlaceholderView(style: .loading)
        case let .loaded(gameLog):
            if gameLog.entries.isEmpty {
                GameLogPlaceholderView(style: .empty)
            } else {
                GameLogTableView(entries: gameLog.entries)
                    .onAppear {
                        guard !hasLoggedGameLog else { return }
                        hasLoggedGameLog = true
                        analytics.logDetailedEvent(AnalyticsEvent.gameLogViewed, parameters: [
                            AnalyticsParam.playerId: player.id,
                            AnalyticsParam.feature: "trending",
                            AnalyticsParam.entryCount: String(gameLog.entries.count)
                        ])
                    }
            }
        case let .failed(error):
            GameLogErrorView(error: error) {
                store.send(.refreshRequested)
            }
        }
    }
}

// MARK: - DetailTab

private enum DetailTab: CaseIterable {
    case stats
    case gameLog

    var title: String {
        switch self {
        case .stats: String(localized: "Stat Trends", defaultValue: "Stat Trends")
        case .gameLog: String(localized: "Game Log", defaultValue: "Game Log")
        }
    }
}
"""

player_detail_subviews_swift = header() + """\
import SwiftUI
import BKSCore
import BKSUICore

// MARK: - PlayerDetailHeaderCard

struct PlayerDetailHeaderCard: View {
    let player: Player
    @Binding var showTierToast: Bool
    @Environment(\\.analytics) private var analytics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                headshot
                headerInfo
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .appCard()
    }

    private var headshot: some View {
        CachedAsyncImage(url: player.headshotURL) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
                    .accessibilityIgnoresInvertColors(true)
            default:
                Image(systemName: "person.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(AppOpacity.separator))
            }
        }
        .frame(width: 90, height: 105)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.sm)
                .stroke(.white.opacity(AppOpacity.divider), lineWidth: 1)
        )
        .overlay {
            if case let .partial(confidence) = player.playoffConfidence {
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .strokeBorder(Color.orange.opacity(0.4 + 0.4 * confidence), lineWidth: 2)
            }
        }
    }

    private var headerInfo: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(player.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            teamPositionRow

            Spacer(minLength: 0)

            trendRow
        }
        .frame(height: 105, alignment: .leading)
    }

    private var teamPositionRow: some View {
        HStack(spacing: 6) {
            Text(player.team).fontWeight(.semibold)
            if let position = player.position {
                headerPipe
                Text(position)
            }
            if let status = player.injuryStatus {
                headerPipe
                Text(status.rawValue).foregroundStyle(status.color)
            }
        }
        .font(AppFonts.playerInfoLine)
        .foregroundStyle(.white.opacity(AppOpacity.primary))
    }

    private var trendRow: some View {
        HStack(spacing: 6) {
            headerTrendArrow.frame(width: 14, alignment: .center)
            headerPipe
            headerTrendScore.frame(width: 44, alignment: .center)
            if let tier = player.playerTier {
                headerPipe
                Button {
                    showTierToast = true
                    analytics.logDetailedEvent(AnalyticsEvent.tierBadgeTapped, parameters: [
                        AnalyticsParam.tier: String(describing: tier),
                        AnalyticsParam.feature: "trending"
                    ])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        showTierToast = false
                    }
                } label: {
                    Image(systemName: tier.systemImage)
                        .foregroundStyle(tier.color)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "a11y.label.showTierDetails", defaultValue: "Show tier details"))
            }
        }
        .lineLimit(1)
        .font(AppFonts.playerInfoLine)
        .foregroundStyle(.white.opacity(AppOpacity.primary))
        .accessibilityElement(children: .combine)
    }

    private var headerPipe: some View {
        Text(String(localized: "|", defaultValue: "|")).foregroundStyle(.white.opacity(AppOpacity.separator))
    }

    @ViewBuilder private var headerTrendArrow: some View {
        switch player.playoffConfidence {
        case .pending:
            Image(systemName: "minus")
                .font(AppFonts.playerTrendArrow)
                .foregroundStyle(.white.opacity(AppOpacity.separator))
        case let .partial(confidence):
            if let direction = player.trendDirection {
                let name: String = switch direction {
                case .up: "arrow.up"
                case .down: "arrow.down"
                case .flat, .neutral: "minus"
                }
                Image(systemName: name)
                    .font(AppFonts.playerTrendArrow)
                    .foregroundStyle(Color.orange.opacity(0.4 + 0.6 * confidence))
            } else {
                Image(systemName: "minus")
                    .font(AppFonts.playerTrendArrow)
                    .foregroundStyle(.white.opacity(AppOpacity.separator))
            }
        case .regularSeason, .full:
            if let direction = player.trendDirection {
                let (name, color): (String, Color) = switch direction {
                case .up: ("arrow.up", .green)
                case .down: ("arrow.down", .red)
                case .flat, .neutral: ("minus", .white.opacity(AppOpacity.separator))
                }
                Image(systemName: name).font(AppFonts.playerTrendArrow).foregroundStyle(color)
            } else {
                Image(systemName: "minus").foregroundStyle(.white.opacity(AppOpacity.separator))
            }
        }
    }

    private var headerTrendScore: some View {
        switch player.playoffConfidence {
        case .pending:
            return Text("–").monospacedDigit().multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(AppOpacity.separator))
        case .partial:
            let value = player.confidenceScore.map { String(format: "%.2f", $0) } ?? "–"
            return Text(value).monospacedDigit().multilineTextAlignment(.center)
                .foregroundStyle(Color.orange.opacity(0.6))
        case .regularSeason, .full:
            let value = player.confidenceScore.map { String(format: "%.2f", $0) } ?? "-"
            let opacity = player.confidenceScore == nil ? AppOpacity.separator : AppOpacity.primary
            return Text(value).monospacedDigit().multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(opacity))
        }
    }
}

// MARK: - PlayerDetailFantasyBar

struct PlayerDetailFantasyBar: View {
    let player: Player

    var body: some View {
        HStack(spacing: 0) {
            statColumn(
                label: String(localized: "detail.stats.dkAvg", defaultValue: "DK AVG"),
                value: playerValue(player.avgFantasyScore, format: "%.1f")
            )
            statDivider
            statColumn(
                label: String(localized: "detail.stats.homeAvg", defaultValue: "Home Avg"),
                value: playerValue(player.avgFantasyScoreHome, format: "%.1f")
            )
            statDivider
            statColumn(
                label: String(localized: "detail.stats.awayAvg", defaultValue: "Away Avg"),
                value: playerValue(player.avgFantasyScoreAway, format: "%.1f")
            )
        }
        .padding(.vertical, 10)
        .appCard()
        .accessibilityElement(children: .combine)
    }

    private func statColumn(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(AppFonts.statLabel)
                .foregroundStyle(.white.opacity(AppOpacity.muted))
            Text(value)
                .font(AppFonts.statValue)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(.white.opacity(AppOpacity.divider))
            .frame(width: 1, height: 20)
    }

    private func playerValue(_ value: Double?, format: String) -> String {
        guard let value else { return "—" }
        return String(format: format, value)
    }
}

// MARK: - PlayerTierToast

struct PlayerTierToast: View {
    let tier: PlayerTier
    let player: Player
    @Environment(\\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: tier.systemImage).foregroundStyle(tier.color)
                Text("Ranked \\(tier.label)")
            }
            .font(.subheadline)
            VStack(alignment: .leading, spacing: 3) {
                if let fantasy = player.avgFantasyScore {
                    Label("\\(fantasy) DK avg", systemImage: "chart.bar.fill")
                }
                if let consistency = player.consistencyScore {
                    Label("\\(consistency * 100)% consistent", systemImage: "waveform.path.ecg")
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(AppOpacity.secondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppPadding.contentInner)
        .background {
            if reduceTransparency {
                Color.black.opacity(0.9)
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .padding(.horizontal, AppPadding.contentInner)
        .padding(.bottom, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
"""

player_detail_overview_swift = header() + """\
import SwiftUI
import BKSCore
import BKSUICore

// MARK: - PlayerDetailOverviewTrendCard

struct PlayerDetailOverviewTrendCard: View {
    let player: Player

    private var hasAnyData: Bool {
        player.trendScore != nil
            || player.confidenceScore != nil
            || player.consistencyScore != nil
            || player.trendAcceleration != nil
            || player.hotStreak != nil
            || player.recentGameScores != nil
    }

    var body: some View {
        if case .pending = player.playoffConfidence {
            playoffPendingState
        } else if hasAnyData {
            VStack(spacing: 0) {
                let rows = buildRows()
                ForEach(Array(rows.enumerated()), id: \\.offset) { index, item in
                    if index > 0 { rowDivider }
                    trendInfoRow(label: item.label, value: item.value, color: item.color)
                }
            }
            .padding(.bottom, 4)
            .appCard()
        } else {
            emptyState
        }
    }

    private var playoffPendingState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.badge")
                .font(.callout)
                .foregroundStyle(.orange.opacity(AppOpacity.dim))
            Text(String(localized: "trending.playoff.pendingDetail",
                        defaultValue: "Playoff trend data is building. Check back after a few games."))
                .font(.caption)
                .foregroundStyle(.white.opacity(AppOpacity.separator))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .appCard()
    }

    private struct TrendRow {
        let label: String
        let value: String
        let color: Color
    }

    // swiftlint:disable:next function_body_length
    private func buildRows() -> [TrendRow] {
        var rows: [TrendRow] = []

        if case let .partial(confidence) = player.playoffConfidence {
            rows.append(TrendRow(
                label: String(localized: "detail.overview.playoffConfidence",
                              defaultValue: "Playoff Data"),
                value: String(format: "%.0f%%", confidence * 100),
                color: .orange
            ))
        }

        if let score = player.trendScore {
            let formatted = String(format: "%+.0f%%", score * 100)
            rows.append(TrendRow(
                label: String(localized: "detail.overview.trendScore", defaultValue: "Trend Score"),
                value: formatted,
                color: valueColor(score)
            ))
        }

        if let confidence = player.confidenceScore {
            rows.append(TrendRow(
                label: String(localized: "detail.overview.confidence", defaultValue: "Confidence"),
                value: String(format: "%.0f%%", confidence * 100),
                color: .white
            ))
        }

        if let consistency = player.consistencyScore {
            rows.append(TrendRow(
                label: String(localized: "detail.overview.consistency", defaultValue: "Consistency"),
                value: String(format: "%.0f%%", consistency * 100),
                color: .white
            ))
        }

        if let acceleration = player.trendAcceleration {
            let formatted = String(format: "%+.0f%%", acceleration * 100)
            rows.append(TrendRow(
                label: String(localized: "detail.overview.acceleration", defaultValue: "Acceleration"),
                value: formatted,
                color: valueColor(acceleration)
            ))
        }

        if let streak = player.hotStreak, streak > 0 {
            rows.append(TrendRow(
                label: String(localized: "detail.overview.hotStreak", defaultValue: "Hot Streak"),
                value: "\\(streak) games",
                color: .orange
            ))
        }

        if let surging = player.isSurging, surging {
            let categories = player.surgingCategoryCount.map { String($0) } ?? "-"
            rows.append(TrendRow(
                label: String(localized: "detail.overview.surging", defaultValue: "Surging"),
                value: "\\(categories) categories",
                color: .green
            ))
        }

        return rows
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.callout)
                .foregroundStyle(.white.opacity(AppOpacity.dim))
            Text(String(localized: "No trend data available", defaultValue: "No trend data available"))
                .font(.caption)
                .foregroundStyle(.white.opacity(AppOpacity.separator))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .appCard()
    }

    private func trendInfoRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(AppOpacity.secondary))
            Spacer()
            Text(value)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func valueColor(_ value: Double) -> Color {
        if value > 0.02 { return .green }
        if value < -0.02 { return .red }
        return .white.opacity(AppOpacity.separator)
    }

    private var rowDivider: some View {
        Divider()
            .background(.white.opacity(AppOpacity.hairline))
            .padding(.leading, AppPadding.contentInner)
    }
}
"""

write(os.path.join(trending_views_dir, "PlayerDetailView.swift"), player_detail_view_swift)
write(os.path.join(trending_views_dir, "PlayerDetailSubviews.swift"), player_detail_subviews_swift)
write(os.path.join(trending_views_dir, "PlayerDetailOverviewView.swift"), player_detail_overview_swift)

# ─────────────────────────────────────────────────────────────────────────────
# 9h. Prospecting Store + Views
# ─────────────────────────────────────────────────────────────────────────────

prospecting_store_dir = os.path.join(out_dir, "App/Sources/Features/Prospecting/Store")
prospecting_views_dir = os.path.join(out_dir, "App/Sources/Features/Prospecting/Views")

prospecting_state_swift = header() + f"""\
import OSLog
import BKSCore
import SwiftUI

struct ProspectingState {{
    var navigationPath = NavigationPath()
    var opportunities: ViewState<[Opportunity]> = .idle
    var allOpportunities: [Opportunity] = []
    var gemsOpportunities: [Opportunity] = []
    var foolsGoldOpportunities: [Opportunity] = []
    var filteredGemsOpportunities: [Opportunity] = []
    var filteredFoolsGoldOpportunities: [Opportunity] = []
    var filteredOpportunities: [Opportunity] = []
    var searchText = ""
    var selectedPosition: String?
    var lastUpdated: Date?
    var seasonMode: SeasonMode = .regularSeason
    var todaySchedule: TodaySchedule?

    private static let stalenessThreshold = CacheFreshness.defaultThreshold

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "ProspectingState"
    )

    // swiftlint:disable:next function_body_length
    static func makeReduce(
        opportunityService: OpportunitiesServiceProtocol,
        gamesService: GamesServiceProtocol,
        positionMap: SportPositionMap
    ) -> Reduce<Self, ProspectingIntent> {{
        {{ state, intent in
            switch intent {{
            case .onAppear:
                if CacheFreshness.isFresh(lastUpdated: state.lastUpdated, threshold: stalenessThreshold),
                   case .loaded = state.opportunities
                {{
                    logger.debug("Opportunities cache is fresh, skipping fetch")
                    return nil
                }}
                state.opportunities = .loading
                return await fetchOpportunities(
                    opportunityService: opportunityService,
                    gamesService: gamesService
                )

            case .refreshRequested:
                state.opportunities = .loading
                return await fetchOpportunities(
                    opportunityService: opportunityService,
                    gamesService: gamesService,
                    forceNetwork: true
                )

            case let .opportunitiesLoaded(opportunities, seasonMode, todaySchedule):
                state.seasonMode = seasonMode
                state.todaySchedule = todaySchedule
                let available = opportunities.filter {{ !isUnavailable($0) }}
                state.allOpportunities = available
                let gemsTiers: Set<FeatureTier> = [.elite, .good]
                state.gemsOpportunities = available.filter {{ gemsTiers.contains($0.opportunityTier) }}
                state.foolsGoldOpportunities = available.filter {{ !gemsTiers.contains($0.opportunityTier) }}
                state.opportunities = .loaded(available)
                state.lastUpdated = Date.now
                applyFilters(&state, positionMap: positionMap)
                return nil

            case let .opportunitiesFailed(error):
                if case .loaded = state.opportunities {{
                    logger.warning(
                        "Opportunities refresh failed but keeping existing data: \\\\(error.diagnosticDescription)"
                    )
                    return nil
                }}
                state.opportunities = .failed(error)
                return nil

            case let .navigationPathChanged(path):
                state.navigationPath = path
                return nil

            case let .searchTextChanged(text):
                state.searchText = text
                applyFilters(&state, positionMap: positionMap)
                return nil

            case let .positionFilterChanged(position):
                state.selectedPosition = position
                applyFilters(&state, positionMap: positionMap)
                return nil
            }}
        }}
    }}

    private static func applyFilters(_ state: inout Self, positionMap: SportPositionMap) {{
        let search = state.searchText
        let chip = state.selectedPosition

        state.filteredGemsOpportunities = filterOpportunities(
            state.gemsOpportunities, search: search, chip: chip, positionMap: positionMap
        )
        state.filteredFoolsGoldOpportunities = filterOpportunities(
            state.foolsGoldOpportunities, search: search, chip: chip, positionMap: positionMap
        )
        state.filteredOpportunities = state.filteredGemsOpportunities + state.filteredFoolsGoldOpportunities
    }}

    private static func filterOpportunities(
        _ opportunities: [Opportunity],
        search: String,
        chip: String?,
        positionMap: SportPositionMap
    ) -> [Opportunity] {{
        opportunities.filtered(search: search, chip: chip, positionMap: positionMap)
    }}

    private static func isUnavailable(_ opportunity: Opportunity) -> Bool {{
        opportunity.isUnavailable
    }}

    private static func fetchOpportunities(
        opportunityService: OpportunitiesServiceProtocol,
        gamesService: GamesServiceProtocol,
        forceNetwork: Bool = false
    ) async -> ProspectingIntent {{
        let cachedSchedule = try? gamesService.loadCachedTodaySchedule()
        do {{
            if !forceNetwork, let cached = try opportunityService.loadCachedOpportunities(), !cached.isEmpty {{
                let cachedMode = (try? opportunityService.loadCachedSeasonMode()) ?? .regularSeason
                logger.debug("Using cached opportunities (\\\\(cached.count) entries)")
                return .opportunitiesLoaded(cached, cachedMode, cachedSchedule)
            }}
            if forceNetwork {{
                logger.debug("Refresh requested — fetching opportunities from network")
            }} else {{
                logger.debug("No cached opportunities — fetching from network")
            }}
            let result = try await opportunityService.fetchOpportunities()
            return .opportunitiesLoaded(result.opportunities, result.seasonMode, cachedSchedule)
        }} catch {{
            if forceNetwork, let cached = try? opportunityService.loadCachedOpportunities(), !cached.isEmpty {{
                let cachedMode = (try? opportunityService.loadCachedSeasonMode()) ?? .regularSeason
                logger.warning("Network fetch failed, falling back to cache: \\\\(error.diagnosticDescription)")
                return .opportunitiesLoaded(cached, cachedMode, cachedSchedule)
            }}
            return .opportunitiesFailed(error)
        }}
    }}
}}
"""

prospecting_intent_swift = header() + """\
import SwiftUI
import BKSCore

enum ProspectingIntent: CancellableIntent {
    case onAppear
    case navigationPathChanged(NavigationPath)
    case opportunitiesLoaded([Opportunity], SeasonMode, TodaySchedule?)
    case opportunitiesFailed(Error)
    case refreshRequested
    case searchTextChanged(String)
    case positionFilterChanged(String?)

    var cancelsInFlightWork: Bool {
        switch self {
        case .navigationPathChanged, .searchTextChanged, .positionFilterChanged:
            false
        default:
            true
        }
    }
}
"""

opportunity_detail_state_swift = header() + f"""\
import OSLog
import BKSCore

struct OpportunityDetailState {{
    let opportunity: Opportunity
    var player: ViewState<Player> = .idle
    var gameLog: ViewState<PlayerGameLog> = .idle

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "OpportunityDetailState"
    )

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func makeReduce(
        trendingsService: TrendingsServiceProtocol,
        gamesService: GamesServiceProtocol
    ) -> Reduce<Self, OpportunityDetailIntent> {{
        {{ state, intent in
            switch intent {{
            case .onAppear:
                do {{
                    if let players = try trendingsService.loadCachedPlayers(),
                       let match = PlayerLookup.find(
                           externalPersonID: state.opportunity.externalPersonID,
                           displayName: state.opportunity.displayName,
                           team: state.opportunity.team,
                           in: players
                       ) {{
                        return .playerLoaded(match)
                    }}
                }} catch {{
                    logger.warning("Failed to load cached players: \\\\(error.diagnosticDescription)")
                }}
                return .playerNotFound

            case let .playerLoaded(player):
                state.player = .loaded(player)
                return nil

            case .playerNotFound:
                state.player = .failed(OpportunityDetailError.playerNotFound)
                return nil

            case .gameLogTabSelected:
                guard case .idle = state.gameLog else {{ return nil }}
                guard case let .loaded(player) = state.player else {{
                    state.gameLog = .failed(OpportunityDetailError.playerNotFound)
                    return nil
                }}
                do {{
                    if let cached = try gamesService.loadCachedGameLog(playerID: player.id) {{
                        state.gameLog = .loaded(cached)
                        return nil
                    }}
                }} catch {{
                    logger.warning("Failed to load cached game log: \\\\(error.diagnosticDescription)")
                }}
                state.gameLog = .loading
                return .fetchGameLog

            case .fetchGameLog:
                guard case let .loaded(player) = state.player else {{ return nil }}
                do {{
                    let gameLog = try await gamesService.fetchGameLog(
                        playerID: player.id,
                        teamID: player.team
                    )
                    return .gameLogLoaded(gameLog)
                }} catch {{
                    return .gameLogFailed(error)
                }}

            case let .gameLogLoaded(gameLog):
                state.gameLog = .loaded(gameLog)
                return nil

            case let .gameLogFailed(error):
                if case .loaded = state.gameLog {{
                    logger.warning("Game log refresh failed but keeping existing data: \\\\(error.diagnosticDescription)")
                    return nil
                }}
                state.gameLog = .failed(error)
                return nil

            case .refreshRequested:
                guard case .loaded = state.player else {{ return nil }}
                state.gameLog = .loading
                return .fetchGameLog
            }}
        }}
    }}
}}

// MARK: - OpportunityDetailError

enum OpportunityDetailError: LocalizedError {{
    case playerNotFound

    var errorDescription: String? {{
        switch self {{
        case .playerNotFound:
            String(localized: "opportunityDetail.error.playerNotFound",
                   defaultValue: "Player data unavailable")
        }}
    }}
}}
"""

opportunity_detail_intent_swift = header() + """\
enum OpportunityDetailIntent {
    case onAppear
    case playerLoaded(Player)
    case playerNotFound
    case gameLogTabSelected
    case fetchGameLog
    case gameLogLoaded(PlayerGameLog)
    case gameLogFailed(Error)
    case refreshRequested
}
"""

playoff_state_swift = header() + f"""\
import BKSCore
import OSLog

// MARK: - PlayoffIntent

enum PlayoffIntent {{
    case onAppear
    case refreshRequested
    case bracketLoaded([PlayoffSeries])
    case bracketFailed(Error)
}}

// MARK: - PlayoffState

struct PlayoffState {{
    var bracket: ViewState<[PlayoffSeries]> = .idle
    var leagueState: LeagueState?
    var lastUpdated: Date?

    private static let stalenessThreshold = CacheFreshness.defaultThreshold

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "PlayoffState"
    )

    static func makeReduce(
        playoffService: PlayoffServiceProtocol
    ) -> Reduce<Self, PlayoffIntent> {{
        {{ state, intent in
            switch intent {{
            case .onAppear:
                if CacheFreshness.isFresh(lastUpdated: state.lastUpdated, threshold: stalenessThreshold),
                   case .loaded = state.bracket
                {{
                    logger.debug("Bracket cache is fresh, skipping fetch")
                    return nil
                }}
                state.bracket = .loading
                return await fetchBracket(playoffService: playoffService)

            case .refreshRequested:
                state.bracket = .loading
                return await fetchBracket(playoffService: playoffService, forceNetwork: true)

            case let .bracketLoaded(series):
                state.bracket = .loaded(series)
                state.lastUpdated = Date.now
                return nil

            case let .bracketFailed(error):
                if case .loaded = state.bracket {{
                    logger.warning("Bracket refresh failed, keeping existing data: \\\\(error.diagnosticDescription)")
                    return nil
                }}
                state.bracket = .failed(error)
                return nil
            }}
        }}
    }}

    private static func fetchBracket(
        playoffService: PlayoffServiceProtocol,
        forceNetwork: Bool = false
    ) async -> PlayoffIntent {{
        if !forceNetwork, let cached = try? playoffService.loadCachedBracket(), !cached.isEmpty {{
            logger.debug("Using cached bracket (\\\\(cached.count) series)")
            return .bracketLoaded(cached)
        }}
        do {{
            let series = try await playoffService.fetchBracket()
            return .bracketLoaded(series)
        }} catch {{
            if let cached = try? playoffService.loadCachedBracket(), !cached.isEmpty {{
                logger.warning("Network fetch failed, falling back to cache: \\\\(error.diagnosticDescription)")
                return .bracketLoaded(cached)
            }}
            return .bracketFailed(error)
        }}
    }}
}}
"""

bracket_subviews_swift = header() + """\
import SwiftUI
import BKSCore
import BKSUICore

// MARK: - ConferenceSection

struct ConferenceSection: View {
    let title: String
    let series: [PlayoffSeries]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(AppOpacity.muted))
                .padding(.horizontal, 4)

            let grouped = Dictionary(grouping: series) { $0.roundNumber }
            ForEach(grouped.keys.sorted(), id: \\.self) { round in
                let roundSeries = grouped[round] ?? []
                if let roundName = roundSeries.first?.roundName {
                    Text(roundName)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(AppOpacity.dim))
                        .padding(.horizontal, 4)
                }
                ForEach(roundSeries) { series in
                    SeriesCard(series: series)
                }
            }
        }
    }
}

// MARK: - SeriesCard

struct SeriesCard: View {
    let series: PlayoffSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            matchupRow
            statusRow
            if series.eliminationGameNext {
                eliminationBadge
            }
        }
        .padding(12)
        .appCard()
        .accessibilityElement(children: .combine)
    }

    private var matchupRow: some View {
        HStack(spacing: 0) {
            teamColumn(
                name: series.higherSeedTeam,
                seed: series.higherSeed,
                wins: series.winsHigherSeed,
                isWinner: series.winner == series.higherSeedTeam
            )
            scoreCenter
            teamColumn(
                name: series.lowerSeedTeam,
                seed: series.lowerSeed,
                wins: series.winsLowerSeed,
                isWinner: series.winner == series.lowerSeedTeam
            )
        }
    }

    private func teamColumn(name: String, seed: Int, wins: Int, isWinner: Bool) -> some View {
        VStack(spacing: 4) {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isWinner ? Color.orange : .white)
                .lineLimit(1)
            Text("#\\(seed)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(AppOpacity.muted))
            winDots(count: wins)
        }
        .frame(maxWidth: .infinity)
    }

    private var scoreCenter: some View {
        VStack(spacing: 4) {
            Text("\\(series.winsHigherSeed)-\\(series.winsLowerSeed)")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
            if let homeTeam = nextGameHomeTeam {
                HStack(spacing: 3) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 9))
                    Text(homeTeam)
                        .font(.caption2)
                }
                .foregroundStyle(.white.opacity(AppOpacity.secondary))
            }
        }
        .frame(minWidth: 60)
    }

    private var nextGameHomeTeam: String? {
        guard series.status != .completed else { return nil }
        guard let isHigherSeedHome = series.isHigherSeedHomeNext else { return nil }
        return isHigherSeedHome ? series.higherSeedTeam : series.lowerSeedTeam
    }

    private func winDots(count: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \\.self) { index in
                Circle()
                    .fill(index < count ? Color.orange : Color.white.opacity(AppOpacity.hairline))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var statusRow: some View {
        HStack {
            Text(series.status.localizedLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(series.status.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(series.status.color.opacity(0.15))
                .clipShape(Capsule())
            Spacer(minLength: 0)
            if series.status == .active {
                Text(
                    String(
                        format: String(localized: "bracket.series.game", defaultValue: "Game %@"),
                        "\\(series.gamesPlayed + 1)"
                    )
                )
                .font(.caption2)
                .foregroundStyle(.white.opacity(AppOpacity.muted))
            }
        }
    }

    private var eliminationBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .font(.caption2)
            Text(String(localized: "bracket.series.eliminationGame", defaultValue: "Elimination Game"))
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.red.opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - SeriesStatus + UI

extension SeriesStatus {
    var localizedLabel: String {
        switch self {
        case .scheduled:
            String(localized: "bracket.series.scheduled", defaultValue: "Scheduled")
        case .active:
            String(localized: "bracket.series.active", defaultValue: "Active")
        case .completed:
            String(localized: "bracket.series.completed", defaultValue: "Completed")
        }
    }

    var color: Color {
        switch self {
        case .scheduled: .white.opacity(0.5)
        case .active: .green
        case .completed: .orange
        }
    }
}
"""

bracket_view_swift = header() + """\
import SwiftUI
import BKSCore
import BKSUICore

struct BracketView: View {
    @StateObject var store: Store<PlayoffState, PlayoffIntent>

    var body: some View {
        NavigationStack {
            content
                .appBackground()
                .appNavigationBar(
                    title: String(localized: "bracket.title", defaultValue: "Bracket")
                )
        }
        .task { store.send(.onAppear) }
    }

    @ViewBuilder
    private var content: some View {
        LoadableContentView(
            state: store.state.bracket,
            isEmpty: seriesIsEmpty,
            emptyIcon: "trophy",
            errorKey: "bracket.error",
            retryKey: "bracket.retry",
            emptyKey: "bracket.empty",
            onRetry: { store.send(.refreshRequested) },
            content: { bracketList }
        )
    }

    private var seriesIsEmpty: Bool {
        if case let .loaded(series) = store.state.bracket { return series.isEmpty }
        return true
    }

    private var bracketList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                if let series = loadedSeries {
                    let east = series.filter { $0.conference == "east" }
                        .sorted { ($0.roundNumber, $0.higherSeed) < ($1.roundNumber, $1.higherSeed) }
                    let west = series.filter { $0.conference == "west" }
                        .sorted { ($0.roundNumber, $0.higherSeed) < ($1.roundNumber, $1.higherSeed) }
                    let finals = series.filter { $0.conference == "nba" }

                    if !east.isEmpty {
                        ConferenceSection(
                            title: String(localized: "bracket.east", defaultValue: "Eastern Conference"),
                            series: east
                        )
                    }
                    if !west.isEmpty {
                        ConferenceSection(
                            title: String(localized: "bracket.west", defaultValue: "Western Conference"),
                            series: west
                        )
                    }
                    if !finals.isEmpty {
                        ConferenceSection(
                            title: String(localized: "bracket.finals", defaultValue: "NBA Finals"),
                            series: finals
                        )
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .refreshable {
            await store.sendAsync(.refreshRequested)
        }
    }

    private var loadedSeries: [PlayoffSeries]? {
        if case let .loaded(series) = store.state.bracket { return series }
        return nil
    }
}
"""

write(os.path.join(prospecting_store_dir, "ProspectingState.swift"), prospecting_state_swift)
write(os.path.join(prospecting_store_dir, "ProspectingIntent.swift"), prospecting_intent_swift)
write(os.path.join(prospecting_store_dir, "OpportunityDetailState.swift"), opportunity_detail_state_swift)
write(os.path.join(prospecting_store_dir, "OpportunityDetailIntent.swift"), opportunity_detail_intent_swift)
write(os.path.join(prospecting_store_dir, "PlayoffState.swift"), playoff_state_swift)

prospecting_view_swift = header() + f"""\
import SwiftUI
import BKSCore
import BKSUICore

struct ProspectingView: View {{
    @ObservedObject var store: Store<ProspectingState, ProspectingIntent>
    let credential: StoredCredential
    @ObservedObject var profileStore: Store<ProfileState, ProfileIntent>
    let trendingsService: TrendingsServiceProtocol
    let gamesService: GamesServiceProtocol
    let playoffService: PlayoffServiceProtocol
    @State private var showProfile = false
    @State private var showBracket = false
    @State private var selectedTab = ProspectingTab.gems
    @State private var toastTier: FeatureTier?
    @Environment(\\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\\.analytics) private var analytics

    private var searchBinding: Binding<String> {{
        Binding(
            get: {{ store.state.searchText }},
            set: {{ store.send(.searchTextChanged($0)) }}
        )
    }}

    var body: some View {{
        NavigationStack(path: Binding(
            get: {{ store.state.navigationPath }},
            set: {{ store.send(.navigationPathChanged($0)) }}
        )) {{
            content
                .appBackground()
                .analyticsScreen("prospecting")
                .appNavigationBar(
                    title: String(localized: "prospecting.title", defaultValue: "Prospecting"),
                    subtitle: String(localized: "prospecting.subtitle", defaultValue: "Today's DFS opportunities")
                )
                .navBarTrailingIcon(
                    "person",
                    accessibilityID: "nav.profileButton",
                    accessibilityLabel: String(localized: "a11y.label.profile", defaultValue: "Profile")
                ) {{ showProfile = true }}
                .navigationDestination(isPresented: $showProfile) {{
                    ProfilePanelView(credential: credential, profileStore: profileStore)
                        .appNavigationBar(title: String(localized: "Profile", defaultValue: "Profile"))
                }}
                .navigationDestination(for: Opportunity.self) {{ opportunity in
                    OpportunityDetailView(
                        store: Store(
                            initial: OpportunityDetailState(opportunity: opportunity),
                            reduce: OpportunityDetailState.makeReduce(
                                trendingsService: trendingsService,
                                gamesService: gamesService
                            )
                        )
                    )
                    .onAppear {{
                        analytics.logDetailedEvent(AnalyticsEvent.opportunityTapped, parameters: [
                            AnalyticsParam.opportunityId: opportunity.id,
                            AnalyticsParam.opportunityTier: String(describing: opportunity.opportunityTier),
                            AnalyticsParam.playerTier:
                                opportunity.playerTier.map(String.init(describing:)) ?? "unknown",
                            AnalyticsParam.isSurging: String(opportunity.isSurging),
                            AnalyticsParam.subTab: String(describing: selectedTab)
                        ])
                    }}
                }}
        }}
        .task {{
            store.send(.onAppear)
        }}
        .onChange(of: selectedTab) {{
            analytics.logEvent(AnalyticsEvent.subTabSelected, parameters: [
                AnalyticsParam.tabName: String(describing: selectedTab),
                AnalyticsParam.feature: "prospecting"
            ])
        }}
        .onChange(of: store.state.searchText.isEmpty) {{
            if !store.state.searchText.isEmpty {{
                analytics.logEvent(AnalyticsEvent.searchUsed, parameters: [
                    AnalyticsParam.feature: "prospecting"
                ])
            }}
        }}
        .onChange(of: store.state.selectedPosition) {{
            analytics.logEvent(AnalyticsEvent.filterChanged, parameters: [
                AnalyticsParam.feature: "prospecting"
            ])
        }}
    }}

    private var content: some View {{
        VStack(spacing: 0) {{
            SeasonModeBanner(mode: store.state.seasonMode)

            if store.state.seasonMode == .playoffs {{
                playoffBracketButton
            }}

            if store.state.seasonMode == .offseason {{
                offseasonView
            }} else {{
                LoadableContentView(
                    state: store.state.opportunities,
                    isEmpty: store.state.allOpportunities.isEmpty,
                    emptyIcon: "sparkle.magnifyingglass",
                    errorKey: "prospecting.error",
                    retryKey: "prospecting.retry",
                    emptyKey: emptyMessageKey,
                    onRetry: {{ store.send(.refreshRequested) }},
                    content: {{ opportunityList }}
                )
            }}
        }}
    }}

    private var emptyMessageKey: LocalizedStringResource {{
        switch store.state.todaySchedule?.hasGames {{
        case false:
            return LocalizedStringResource(
                "prospecting.empty.noGames",
                defaultValue: "No games scheduled for today"
            )
        case true:
            return LocalizedStringResource(
                "prospecting.empty.noOpportunities",
                defaultValue: "There are games today but no opportunities available"
            )
        default:
            return LocalizedStringResource(
                "prospecting.empty",
                defaultValue: "No opportunities available"
            )
        }}
    }}

    private var playoffBracketButton: some View {{
        Button {{
            showBracket = true
        }} label: {{
            HStack(spacing: 6) {{
                Text(String(localized: "bracket.viewBracket", defaultValue: "View Bracket"))
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }}
            .foregroundStyle(.orange)
        }}
        .padding(.vertical, 6)
        .accessibilityLabel(String(localized: "bracket.viewBracket", defaultValue: "View Bracket"))
        .sheet(isPresented: $showBracket) {{
            BracketView(
                store: Store(
                    initial: PlayoffState(),
                    reduce: PlayoffState.makeReduce(playoffService: playoffService)
                )
            )
        }}
    }}

    private var offseasonView: some View {{
        VStack(spacing: 12) {{
            Spacer()
            Image(systemName: "moon.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(AppOpacity.dim))
            Text(String(localized: "offseason.message",
                        defaultValue: "The season is over. Check back when games resume."))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(AppOpacity.secondary))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }}
    }}

    private var opportunityList: some View {{
        let activeOpportunities: [Opportunity] = switch selectedTab {{
        case .gems: store.state.filteredGemsOpportunities
        case .foolsGold: store.state.filteredFoolsGoldOpportunities
        }}
        let allGrouped = Dictionary(grouping: store.state.allOpportunities) {{ $0.opportunityTier }}
        let grouped = Dictionary(grouping: activeOpportunities) {{ $0.opportunityTier }}
        let filtersActive = !store.state.searchText.isEmpty || store.state.selectedPosition != nil
        let filteredEmpty = activeOpportunities.isEmpty

        return VStack(spacing: 0) {{
            SearchFilterHeader(
                searchText: searchBinding,
                selectedPosition: store.state.selectedPosition,
                filterChips: ["All"] + SportPositionMap.{slug}.filterChips,
                accessibilityPrefix: "prospecting",
                onPositionChanged: {{ store.send(.positionFilterChanged($0)) }},
                tipsContent: {{ SearchTipsView() }}
            )

            FeatureTabBar(
                selectedTab: $selectedTab,
                reduceMotion: reduceMotion,
                accessibilityPrefix: "prospecting"
            )

            if filtersActive, filteredEmpty {{
                FilteredEmptyView(messageKey: "prospecting.filter.empty")
            }} else {{
                ScrollView {{
                    VStack(spacing: AppSpacing.xl) {{
                        ForEach(selectedTab.tiers, id: \\.self) {{ tier in
                            ProspectingTierSection(
                                tier: tier,
                                opportunities: grouped[tier] ?? [],
                                toastTier: $toastTier
                            )
                        }}
                    }}
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                }}
                .id(selectedTab)
                .refreshable {{
                    analytics.logEvent(AnalyticsEvent.pullToRefresh, parameters: [
                        AnalyticsParam.feature: "prospecting"
                    ])
                    await store.sendAsync(.refreshRequested)
                }}
                .contentMargins(.bottom, AppPadding.tabBarClearance, for: .scrollContent)
                .overlay(alignment: .bottom) {{
                    if let tier = toastTier {{
                        let tierOpps = allGrouped[tier] ?? []
                        let scores = tierOpps.map(\\.opportunityScore)
                        TierToastView(
                            tier: tier,
                            scoreRange: scoreRange(from: scores),
                            playerCount: tierOpps.count
                        )
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }}
                }}
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: toastTier)
            }}
        }}
    }}

    private func scoreRange(from scores: [Double]) -> ClosedRange<Double>? {{
        guard let min = scores.min(), let max = scores.max() else {{ return nil }}
        return min ... max
    }}

}}
"""

prospecting_subviews_swift = header() + """\
import SwiftUI
import BKSCore
import BKSUICore

// MARK: - ProspectingTab

enum ProspectingTab: CaseIterable, FeatureTab {
    case gems
    case foolsGold

    var title: String {
        switch self {
        case .gems: String(localized: "prospecting.tab.gems", defaultValue: "Gems")
        case .foolsGold: String(localized: "prospecting.tab.foolsGold", defaultValue: "Fool's Gold")
        }
    }

    var icon: String {
        switch self {
        case .gems: "💎"
        case .foolsGold: "🪨"
        }
    }

    var accentColor: Color {
        switch self {
        case .gems: .yellow
        case .foolsGold: .gray
        }
    }

    var tiers: [FeatureTier] {
        switch self {
        case .gems: [.elite, .good]
        case .foolsGold: [.solid, .low]
        }
    }
}

// MARK: - ProspectingTierSection — thin wrapper around shared TierSection

struct ProspectingTierSection: View {
    let tier: FeatureTier
    let opportunities: [Opportunity]
    @Binding var toastTier: FeatureTier?

    var body: some View {
        TierSection(
            tier: tier,
            isEmpty: opportunities.isEmpty,
            emptyKey: "prospecting.tier.none",
            toastTier: $toastTier
        ) {
            ForEach(Array(opportunities.enumerated()), id: \\.element.id) { index, opportunity in
                NavigationLink(value: opportunity) {
                    OpportunityRowView(opportunity: opportunity)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityIdentifier("opportunity.row.\\(opportunity.id)")
                if index < opportunities.count - 1 {
                    Divider()
                        .overlay(Color.white.opacity(AppOpacity.cardOverlay))
                }
            }
        }
    }
}
"""

opportunity_row_view_swift = header() + """\
import SwiftUI
import BKSCore
import BKSUICore

struct OpportunityRowView: View {
    let opportunity: Opportunity

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            nameRow
            infoRow
            let hasBadges = opportunity.injuryStatus != nil
                || opportunity.isSurging
                || opportunity.isHome
                || opportunity.rotationTier != nil
            if hasBadges {
                badgeRow
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var nameRow: some View {
        HStack(spacing: 4) {
            Text(opportunity.displayName)
                .font(AppFonts.rankingName)
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(AppFonts.rankingInfo)
                .foregroundStyle(.white.opacity(AppOpacity.dim))
        }
    }

    private var infoRow: some View {
        HStack(spacing: 4) {
            Text(opportunity.team)
                .font(AppFonts.rankingInfo)
                .foregroundStyle(.white.opacity(AppOpacity.muted))
            if let position = opportunity.position {
                infoDot
                Text(position)
                    .font(AppFonts.rankingInfo)
                    .foregroundStyle(.white.opacity(AppOpacity.muted))
            }
            infoDot
            Text(matchupLabel)
                .font(AppFonts.rankingInfo)
                .foregroundStyle(.white.opacity(AppOpacity.muted))
            Spacer(minLength: 0)
            Text(formattedScore)
                .font(AppFonts.rankingScore)
                .foregroundStyle(scoreColor)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var badgeRow: some View {
        HStack(spacing: 3) {
            if let status = opportunity.injuryStatus {
                InjuryBadge(status: status, compact: true)
            }
            if opportunity.isHome {
                Text("🏠")
                    .font(AppFonts.rankingBadgeIcon)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            if opportunity.isSurging {
                Text("🚀")
                    .font(AppFonts.rankingBadgeIcon)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.purple.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            if let tier = opportunity.rotationTier {
                Text(tier.displayLabel)
                    .font(AppFonts.rankingBadgeIcon)
                    .foregroundStyle(tier.color)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(tier.color.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var formattedScore: String {
        let isFoolsGold: Bool = switch opportunity.opportunityTier {
        case .solid, .low: true
        case .elite, .good: false
        }
        let prefix = isFoolsGold ? "-" : ""
        return prefix + String(format: "%.0f", opportunity.opportunityScore)
    }

    private var matchupLabel: String {
        let prefix = opportunity.isHome
            ? String(localized: "opportunity.matchup.home", defaultValue: "Home")
            : String(localized: "opportunity.matchup.away", defaultValue: "Away")
        return "\\(prefix) \\(opportunity.opponentAbbr)"
    }

    private var scoreColor: Color {
        switch opportunity.opportunityTier {
        case .elite, .good: .green
        case .solid, .low: .red
        }
    }

    private var infoDot: some View {
        Text("·")
            .font(AppFonts.rankingInfo)
            .foregroundStyle(.white.opacity(AppOpacity.muted))
    }
}
"""

write(os.path.join(prospecting_views_dir, "ProspectingView.swift"), prospecting_view_swift)
write(os.path.join(prospecting_views_dir, "ProspectingSubviews.swift"), prospecting_subviews_swift)
write(os.path.join(prospecting_views_dir, "OpportunityRowView.swift"), opportunity_row_view_swift)

# OpportunityDetailView and OpportunityDetailSubviews are large — write as plain strings
opportunity_detail_view_swift = header() + """\
import SwiftUI
import BKSCore
import BKSUICore

struct OpportunityDetailView: View {
    @StateObject var store: Store<OpportunityDetailState, OpportunityDetailIntent>

    @State private var selectedTab = OpportunityDetailTab.edge
    @State private var showTierToast = false
    @Environment(\\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\\.analytics) private var analytics
    @State private var hasLoggedGameLog = false

    private var opportunity: Opportunity {
        store.state.opportunity
    }

    private var player: Player? {
        if case let .loaded(player) = store.state.player { return player }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                OpportunityDetailHeaderCard(
                    opportunity: opportunity,
                    showTierToast: $showTierToast
                )
                OpportunityFantasyBar(player: player, isHome: opportunity.isHome)
                OpportunityDetailScoreCard(opportunity: opportunity)
                if let trust = opportunity.playoffTrendTrust, trust < 0.5 {
                    coldStartBanner
                }
                tabBar
                tabContent
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 20)
        }
        .contentMargins(.bottom, AppPadding.tabBarClearance, for: .scrollContent)
        .appBackground()
        .analyticsScreen("opportunity_detail")
        .overlay(alignment: .bottom) {
            if showTierToast, let tier = opportunity.playerTier {
                TierToastView(tier: tier)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: showTierToast)
        .appNavigationBar(title: "")
        .task { store.send(.onAppear) }
    }

    // MARK: - Cold-Start Banner

    private var coldStartBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
            Text(String(localized: "playoff.coldStart.warning",
                        defaultValue: "Early playoff sample — projections anchored to regular-season form"))
                .font(.caption)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
        .accessibilityLabel(String(localized: "playoff.coldStart.warning",
                                   defaultValue: "Early playoff sample — projections anchored to regular-season form"))
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(OpportunityDetailTab.allCases, id: \\.self) { tab in
                tabButton(tab)
            }
        }
    }

    private func tabButton(_ tab: OpportunityDetailTab) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                selectedTab = tab
            }
            analytics.logDetailedEvent(AnalyticsEvent.detailTabSwitched, parameters: [
                AnalyticsParam.tabName: String(describing: tab),
                AnalyticsParam.feature: "prospecting",
                AnalyticsParam.playerId: opportunity.id,
                AnalyticsParam.playerTier: opportunity.playerTier.map(String.init(describing:)) ?? "unknown"
            ])
            if tab == .gameLog {
                store.send(.gameLogTabSelected)
            }
        } label: {
            VStack(spacing: 4) {
                Text(tab.title)
                    .font(selectedTab == tab ? AppFonts.filterChip.weight(.semibold) : AppFonts.filterChip)
                    .foregroundStyle(
                        selectedTab == tab ? .white : .white.opacity(AppOpacity.muted)
                    )
                Rectangle()
                    .fill(selectedTab == tab ? .orange : .clear)
                    .frame(height: 2)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .edge:
            OpportunityEdgeCard(opportunity: opportunity, player: player)
        case .gameLog:
            gameLogContent
        }
    }

    @ViewBuilder
    private var gameLogContent: some View {
        switch store.state.gameLog {
        case .idle, .loading:
            GameLogPlaceholderView(style: .loading)
        case let .loaded(gameLog):
            if gameLog.entries.isEmpty {
                GameLogPlaceholderView(style: .empty)
            } else {
                GameLogTableView(entries: gameLog.entries)
                    .onAppear {
                        guard !hasLoggedGameLog else { return }
                        hasLoggedGameLog = true
                        analytics.logDetailedEvent(AnalyticsEvent.gameLogViewed, parameters: [
                            AnalyticsParam.playerId: opportunity.id,
                            AnalyticsParam.feature: "prospecting",
                            AnalyticsParam.entryCount: String(gameLog.entries.count)
                        ])
                    }
            }
        case let .failed(error):
            GameLogErrorView(error: error) {
                store.send(.refreshRequested)
            }
        }
    }
}

private enum OpportunityDetailTab: CaseIterable {
    case edge
    case gameLog

    var title: String {
        switch self {
        case .edge: String(localized: "opportunityDetail.tab.edge", defaultValue: "Today's Edge")
        case .gameLog: String(localized: "opportunityDetail.tab.gameLog", defaultValue: "Game Log")
        }
    }
}
"""

write(os.path.join(prospecting_views_dir, "OpportunityDetailView.swift"), opportunity_detail_view_swift)

# OpportunityDetailSubviews — large file, write as plain string (no substitution needed)
opportunity_detail_subviews_swift = header() + """\
import SwiftUI
import BKSCore
import BKSUICore

// MARK: - OpportunityDetailHeaderCard

struct OpportunityDetailHeaderCard: View {
    let opportunity: Opportunity
    @Binding var showTierToast: Bool
    @Environment(\\.analytics) private var analytics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                headshot
                headerInfo
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .appCard()
    }

    private var headshot: some View {
        CachedAsyncImage(url: opportunity.headshotURL) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
                    .accessibilityIgnoresInvertColors(true)
            default:
                Image(systemName: "person.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(AppOpacity.separator))
            }
        }
        .frame(width: 90, height: 105)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.sm)
                .stroke(.white.opacity(AppOpacity.divider), lineWidth: 1)
        )
    }

    private var headerInfo: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(opportunity.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            teamPositionRow
            Spacer(minLength: 0)
            matchupRow
            Spacer(minLength: 0)
            tierRow
        }
        .frame(height: 105, alignment: .leading)
    }

    private var teamPositionRow: some View {
        HStack(spacing: 6) {
            Text(opportunity.team).fontWeight(.semibold)
            if let position = opportunity.position {
                headerPipe
                Text(position)
            }
            if let status = opportunity.injuryStatus {
                headerPipe
                Text(status.rawValue).foregroundStyle(status.color)
            }
        }
        .font(AppFonts.playerInfoLine)
        .foregroundStyle(.white.opacity(AppOpacity.primary))
    }

    private var matchupRow: some View {
        HStack(spacing: 6) {
            let prefix = opportunity.isHome
                ? String(localized: "opportunity.detail.home", defaultValue: "Home")
                : String(localized: "opportunity.detail.away", defaultValue: "Away")
            Text("\\(prefix) \\(opportunity.opponentAbbr)")
        }
        .font(AppFonts.playerInfoLine)
        .foregroundStyle(.white.opacity(AppOpacity.primary))
    }

    private var tierRow: some View {
        HStack(spacing: 6) {
            Text(String(format: "%.0f", opportunity.opportunityScore))
                .monospacedDigit()
                .frame(width: 44, alignment: .center)
            if let tier = opportunity.playerTier {
                headerPipe
                Button {
                    showTierToast = true
                    analytics.logDetailedEvent(AnalyticsEvent.tierBadgeTapped, parameters: [
                        AnalyticsParam.tier: String(describing: tier),
                        AnalyticsParam.feature: "prospecting"
                    ])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        showTierToast = false
                    }
                } label: {
                    Image(systemName: tier.systemImage)
                        .foregroundStyle(tier.color)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "a11y.label.showTierDetails", defaultValue: "Show tier details"))
            }
        }
        .lineLimit(1)
        .font(AppFonts.playerInfoLine)
        .foregroundStyle(.white.opacity(AppOpacity.primary))
        .accessibilityElement(children: .combine)
    }

    private var headerPipe: some View {
        Text(String(localized: "|", defaultValue: "|")).foregroundStyle(.white.opacity(AppOpacity.separator))
    }
}

// MARK: - OpportunityFantasyBar

struct OpportunityFantasyBar: View {
    let player: Player?
    let isHome: Bool

    var body: some View {
        HStack(spacing: 0) {
            statColumn(
                label: String(localized: "opportunityDetail.stats.dkAvg", defaultValue: "DK Avg"),
                value: playerValue(player?.avgFantasyScore, format: "%.1f")
            )
            statDivider
            statColumn(
                label: isHome
                    ? String(localized: "opportunityDetail.stats.homeAvg", defaultValue: "Home Avg")
                    : String(localized: "opportunityDetail.stats.awayAvg", defaultValue: "Away Avg"),
                value: playerValue(
                    isHome ? player?.avgFantasyScoreHome : player?.avgFantasyScoreAway,
                    format: "%.1f"
                ),
                isHighlighted: true
            )
            statDivider
            statColumn(
                label: isHome
                    ? String(localized: "opportunityDetail.stats.awayAvg", defaultValue: "Away Avg")
                    : String(localized: "opportunityDetail.stats.homeAvg", defaultValue: "Home Avg"),
                value: playerValue(
                    isHome ? player?.avgFantasyScoreAway : player?.avgFantasyScoreHome,
                    format: "%.1f"
                )
            )
        }
        .padding(.vertical, 10)
        .appCard()
        .accessibilityElement(children: .combine)
    }

    private func statColumn(label: String, value: String, isHighlighted: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(AppFonts.statLabel)
                .foregroundStyle(.white.opacity(AppOpacity.muted))
            Text(value)
                .font(AppFonts.statValue)
                .foregroundStyle(isHighlighted ? .green : .white)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(.white.opacity(AppOpacity.divider))
            .frame(width: 1, height: 20)
    }

    private func playerValue(_ value: Double?, format: String) -> String {
        guard let value else { return "—" }
        return String(format: format, value)
    }
}

// MARK: - OpportunityDetailScoreCard

struct OpportunityDetailScoreCard: View {
    let opportunity: Opportunity

    var body: some View {
        HStack(spacing: 0) {
            statColumn(
                label: String(localized: "opportunity.detail.score", defaultValue: "Score"),
                value: String(format: "%.0f", opportunity.opportunityScore),
                color: opportunity.opportunityTier.color
            )
            statDivider
            statColumn(
                label: String(localized: "opportunity.detail.playerTier", defaultValue: "Player Tier"),
                value: opportunity.playerTier?.label ?? "—",
                color: opportunity.playerTier?.color ?? .white.opacity(AppOpacity.separator)
            )
            statDivider
            statColumn(
                label: String(localized: "opportunity.detail.matchup", defaultValue: "Matchup"),
                value: opportunity.opponentAbbr,
                color: .white
            )
        }
        .padding(.vertical, 10)
        .appCard()
        .accessibilityElement(children: .combine)
    }

    private func statColumn(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(AppFonts.statLabel)
                .foregroundStyle(.white.opacity(AppOpacity.muted))
            Text(value)
                .font(AppFonts.statValue)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(.white.opacity(AppOpacity.divider))
            .frame(width: 1, height: 20)
    }
}

// MARK: - OpportunityEdgeCard

struct OpportunityEdgeCard: View {
    let opportunity: Opportunity
    let player: Player?

    var body: some View {
        VStack(spacing: 0) {
            let rows = buildRows()
            ForEach(Array(rows.enumerated()), id: \\.offset) { index, item in
                if index > 0 { rowDivider }
                signalRow(label: item.label, value: item.value, color: item.color)
            }
        }
        .padding(.bottom, 4)
        .appCard()
    }

    private struct SignalRow {
        let label: String
        let value: String
        let color: Color
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func buildRows() -> [SignalRow] {
        var rows: [SignalRow] = []

        rows.append(SignalRow(
            label: String(localized: "opportunity.detail.homeAdvantage", defaultValue: "Home Advantage"),
            value: opportunity.isHome
                ? String(localized: "opportunity.detail.yes", defaultValue: "Yes")
                : String(localized: "opportunity.detail.no", defaultValue: "No"),
            color: opportunity.isHome ? .green : .white.opacity(AppOpacity.separator)
        ))

        rows.append(SignalRow(
            label: String(localized: "opportunity.detail.surging", defaultValue: "Surging"),
            value: opportunity.isSurging
                ? String(localized: "opportunity.detail.yes", defaultValue: "Yes")
                : String(localized: "opportunity.detail.no", defaultValue: "No"),
            color: opportunity.isSurging ? .green : .white.opacity(AppOpacity.separator)
        ))

        if let player {
            if let direction = player.trendDirection {
                let (label, color): (String, Color) = switch direction {
                case .up:
                    (String(localized: "opportunityDetail.edge.trendUp", defaultValue: "Trending Up"), .green)
                case .down:
                    (String(localized: "opportunityDetail.edge.trendDown", defaultValue: "Trending Down"), .red)
                case .flat, .neutral:
                    (String(localized: "opportunityDetail.edge.trendFlat", defaultValue: "Flat"),
                     .white.opacity(AppOpacity.separator))
                }
                rows.append(SignalRow(
                    label: String(localized: "opportunityDetail.edge.trend", defaultValue: "Trend"),
                    value: label,
                    color: color
                ))
            }

            if let streak = player.hotStreak, streak > 0 {
                rows.append(SignalRow(
                    label: String(localized: "opportunityDetail.edge.hotStreak", defaultValue: "Hot Streak"),
                    value: "\\(streak) games",
                    color: .orange
                ))
            }

            if let consistency = player.consistencyScore {
                rows.append(SignalRow(
                    label: String(localized: "opportunityDetail.edge.consistency", defaultValue: "Consistency"),
                    value: String(format: "%.0f%%", consistency * 100),
                    color: .white
                ))
            }

            if let signal = player.usageEfficiencySignal, signal != .neutral {
                let display = switch signal {
                case .expanding:
                    String(localized: "opportunityDetail.edge.usageExpanding", defaultValue: "Expanding")
                case .expandingEfficiently:
                    String(localized: "opportunityDetail.edge.usageExpandingEfficiently",
                           defaultValue: "Expanding Efficiently")
                case .volumeInflation:
                    String(localized: "opportunityDetail.edge.usageVolumeInflation", defaultValue: "Volume Inflation")
                case .efficientUsage:
                    String(localized: "opportunityDetail.edge.usageEfficient", defaultValue: "Efficient Usage")
                case .neutral:
                    String(localized: "opportunityDetail.edge.usageNeutral", defaultValue: "Neutral")
                }
                let color: Color = switch signal {
                case .expandingEfficiently, .efficientUsage: .green
                case .volumeInflation: .red
                default: .white
                }
                rows.append(SignalRow(
                    label: String(localized: "opportunityDetail.edge.usageSignal", defaultValue: "Usage Signal"),
                    value: display,
                    color: color
                ))
            }

            if let tier = opportunity.rotationTier {
                rows.append(SignalRow(
                    label: String(localized: "opportunityDetail.edge.rotationTier", defaultValue: "Rotation Tier"),
                    value: tier.displayLabel,
                    color: tier.color
                ))
            }

            if let games = opportunity.playoffGamesPlayed {
                rows.append(SignalRow(
                    label: String(localized: "opportunityDetail.edge.playoffGames", defaultValue: "Playoff Games"),
                    value: "\\(games)",
                    color: .white
                ))
            }

            if let trust = opportunity.playoffTrendTrust {
                let percentage = String(format: "%.0f%%", trust * 100)
                rows.append(SignalRow(
                    label: String(localized: "opportunityDetail.edge.trendTrust", defaultValue: "Trend Trust"),
                    value: percentage,
                    color: trust >= 0.8 ? .green : trust >= 0.5 ? .yellow : .orange
                ))
            }

            if let multiplier = opportunity.playoffRotationMultiplier {
                rows.append(SignalRow(
                    label: String(localized: "opportunityDetail.edge.rotationBoost",
                                  defaultValue: "Rotation Boost"),
                    value: String(format: "%.2fx", multiplier),
                    color: multiplier > 1.0 ? .green : .white.opacity(AppOpacity.separator)
                ))
            }

            if let homeAvg = player.avgFantasyScoreHome, let awayAvg = player.avgFantasyScoreAway {
                let diff = homeAvg - awayAvg
                let formatted = String(format: "%+.1f", diff)
                rows.append(SignalRow(
                    label: String(localized: "opportunityDetail.edge.venueSplit", defaultValue: "Home vs Away"),
                    value: "\\(formatted) pts",
                    color: diff > 1 ? .green : diff < -1 ? .red : .white.opacity(AppOpacity.separator)
                ))
            }
        }

        return rows
    }

    private func signalRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(AppOpacity.secondary))
            Spacer()
            Text(value)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var rowDivider: some View {
        Divider()
            .background(.white.opacity(AppOpacity.hairline))
            .padding(.leading, AppPadding.contentInner)
    }
}
"""

write(os.path.join(prospecting_views_dir, "OpportunityDetailSubviews.swift"), opportunity_detail_subviews_swift)
write(os.path.join(prospecting_views_dir, "BracketView.swift"), bracket_view_swift)
write(os.path.join(prospecting_views_dir, "BracketSubviews.swift"), bracket_subviews_swift)

# ─────────────────────────────────────────────────────────────────────────────
# 9i. Projecting Store + Views
# ─────────────────────────────────────────────────────────────────────────────

projecting_store_dir = os.path.join(out_dir, "App/Sources/Features/Projecting/Store")
projecting_views_dir = os.path.join(out_dir, "App/Sources/Features/Projecting/Views")

projecting_state_swift = header() + f"""\
import OSLog
import BKSCore
import SwiftUI

struct ProjectingState {{
    var navigationPath = NavigationPath()
    var projections: ViewState<[Projection]> = .idle
    var allProjections: [Projection] = []
    var boomProjections: [Projection] = []
    var bustProjections: [Projection] = []
    var filteredBoomProjections: [Projection] = []
    var filteredBustProjections: [Projection] = []
    var filteredProjections: [Projection] = []
    var searchText = ""
    var selectedPosition: String?
    var lastUpdated: Date?

    private static let stalenessThreshold = CacheFreshness.defaultThreshold

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "ProjectingState"
    )

    // swiftlint:disable:next function_body_length
    static func makeReduce(
        projectionService: ProjectionsServiceProtocol,
        positionMap: SportPositionMap
    ) -> Reduce<Self, ProjectingIntent> {{
        {{ state, intent in
            switch intent {{
            case .onAppear:
                if CacheFreshness.isFresh(lastUpdated: state.lastUpdated, threshold: stalenessThreshold),
                   case .loaded = state.projections
                {{
                    logger.debug("Projections cache is fresh, skipping fetch")
                    return nil
                }}
                state.projections = .loading
                return await fetchProjections(projectionService: projectionService)

            case .refreshRequested:
                state.projections = .loading
                return await fetchProjections(projectionService: projectionService, forceNetwork: true)

            case let .projectionsLoaded(projections):
                let available = projections.filter {{ !isUnavailable($0) }}
                state.allProjections = available
                let boomTiers: Set<FeatureTier> = [.elite, .good]
                state.boomProjections = available.filter {{ boomTiers.contains($0.projectionTier) }}
                state.bustProjections = available.filter {{ !boomTiers.contains($0.projectionTier) }}
                state.projections = .loaded(available)
                state.lastUpdated = Date.now
                applyFilters(&state, positionMap: positionMap)
                return nil

            case let .projectionsFailed(error):
                if case .loaded = state.projections {{
                    logger.warning(
                        "Projections refresh failed but keeping existing data: \\\\(error.diagnosticDescription)"
                    )
                    return nil
                }}
                state.projections = .failed(error)
                return nil

            case let .navigationPathChanged(path):
                state.navigationPath = path
                return nil

            case let .searchTextChanged(text):
                state.searchText = text
                applyFilters(&state, positionMap: positionMap)
                return nil

            case let .positionFilterChanged(position):
                state.selectedPosition = position
                applyFilters(&state, positionMap: positionMap)
                return nil
            }}
        }}
    }}

    private static func applyFilters(_ state: inout Self, positionMap: SportPositionMap) {{
        let search = state.searchText
        let chip = state.selectedPosition

        state.filteredBoomProjections = filterProjections(
            state.boomProjections, search: search, chip: chip, positionMap: positionMap
        )
        state.filteredBustProjections = filterProjections(
            state.bustProjections, search: search, chip: chip, positionMap: positionMap
        )
        state.filteredProjections = state.filteredBoomProjections + state.filteredBustProjections
    }}

    private static func filterProjections(
        _ projections: [Projection],
        search: String,
        chip: String?,
        positionMap: SportPositionMap
    ) -> [Projection] {{
        projections.filtered(search: search, chip: chip, positionMap: positionMap)
    }}

    private static func isUnavailable(_ projection: Projection) -> Bool {{
        projection.isUnavailable
    }}

    private static func fetchProjections(
        projectionService: ProjectionsServiceProtocol,
        forceNetwork: Bool = false
    ) async -> ProjectingIntent {{
        do {{
            if !forceNetwork, let cached = try projectionService.loadCachedProjections(), !cached.isEmpty {{
                logger.debug("Using cached projections (\\\\(cached.count) entries)")
                return .projectionsLoaded(cached)
            }}
            if forceNetwork {{
                logger.debug("Refresh requested — fetching projections from network")
            }} else {{
                logger.debug("No cached projections — fetching from network")
            }}
            let projections = try await projectionService.fetchProjections()
            return .projectionsLoaded(projections)
        }} catch {{
            if forceNetwork, let cached = try? projectionService.loadCachedProjections(), !cached.isEmpty {{
                logger.warning("Network fetch failed, falling back to cache: \\\\(error.diagnosticDescription)")
                return .projectionsLoaded(cached)
            }}
            return .projectionsFailed(error)
        }}
    }}
}}
"""

projecting_intent_swift = header() + """\
import SwiftUI
import BKSCore

enum ProjectingIntent: CancellableIntent {
    case onAppear
    case navigationPathChanged(NavigationPath)
    case projectionsLoaded([Projection])
    case projectionsFailed(Error)
    case refreshRequested
    case searchTextChanged(String)
    case positionFilterChanged(String?)

    var cancelsInFlightWork: Bool {
        switch self {
        case .navigationPathChanged, .searchTextChanged, .positionFilterChanged:
            false
        default:
            true
        }
    }
}
"""

projection_detail_state_swift = header() + f"""\
import OSLog
import BKSCore

struct ProjectionDetailState {{
    let projection: Projection
    var player: ViewState<Player> = .idle
    var gameLog: ViewState<PlayerGameLog> = .idle

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "ProjectionDetailState"
    )

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func makeReduce(
        trendingsService: TrendingsServiceProtocol,
        gamesService: GamesServiceProtocol
    ) -> Reduce<Self, ProjectionDetailIntent> {{
        {{ state, intent in
            switch intent {{
            case .onAppear:
                do {{
                    if let players = try trendingsService.loadCachedPlayers(),
                       let match = PlayerLookup.find(
                           externalPersonID: state.projection.externalPersonID,
                           displayName: state.projection.displayName,
                           team: state.projection.team,
                           in: players
                       ) {{
                        return .playerLoaded(match)
                    }}
                }} catch {{
                    logger.warning("Failed to load cached players: \\\\(error.diagnosticDescription)")
                }}
                return .playerNotFound

            case let .playerLoaded(player):
                state.player = .loaded(player)
                return nil

            case .playerNotFound:
                state.player = .failed(ProjectionDetailError.playerNotFound)
                return nil

            case .gameLogTabSelected:
                guard case .idle = state.gameLog else {{ return nil }}
                guard case let .loaded(player) = state.player else {{
                    state.gameLog = .failed(ProjectionDetailError.playerNotFound)
                    return nil
                }}
                do {{
                    if let cached = try gamesService.loadCachedGameLog(playerID: player.id) {{
                        state.gameLog = .loaded(cached)
                        return nil
                    }}
                }} catch {{
                    logger.warning("Failed to load cached game log: \\\\(error.diagnosticDescription)")
                }}
                state.gameLog = .loading
                return .fetchGameLog

            case .fetchGameLog:
                guard case let .loaded(player) = state.player else {{ return nil }}
                do {{
                    let gameLog = try await gamesService.fetchGameLog(
                        playerID: player.id,
                        teamID: player.team
                    )
                    return .gameLogLoaded(gameLog)
                }} catch {{
                    return .gameLogFailed(error)
                }}

            case let .gameLogLoaded(gameLog):
                state.gameLog = .loaded(gameLog)
                return nil

            case let .gameLogFailed(error):
                if case .loaded = state.gameLog {{
                    logger.warning("Game log refresh failed but keeping existing data: \\\\(error.diagnosticDescription)")
                    return nil
                }}
                state.gameLog = .failed(error)
                return nil

            case .refreshRequested:
                guard case .loaded = state.player else {{ return nil }}
                state.gameLog = .loading
                return .fetchGameLog
            }}
        }}
    }}
}}

// MARK: - ProjectionDetailError

enum ProjectionDetailError: LocalizedError {{
    case playerNotFound

    var errorDescription: String? {{
        switch self {{
        case .playerNotFound:
            String(localized: "projectionDetail.error.playerNotFound",
                   defaultValue: "Player data unavailable")
        }}
    }}
}}
"""

projection_detail_intent_swift = header() + """\
enum ProjectionDetailIntent {
    case onAppear
    case playerLoaded(Player)
    case playerNotFound
    case gameLogTabSelected
    case fetchGameLog
    case gameLogLoaded(PlayerGameLog)
    case gameLogFailed(Error)
    case refreshRequested
}
"""

write(os.path.join(projecting_store_dir, "ProjectingState.swift"), projecting_state_swift)
write(os.path.join(projecting_store_dir, "ProjectingIntent.swift"), projecting_intent_swift)
write(os.path.join(projecting_store_dir, "ProjectionDetailState.swift"), projection_detail_state_swift)
write(os.path.join(projecting_store_dir, "ProjectionDetailIntent.swift"), projection_detail_intent_swift)

projecting_view_swift = header() + f"""\
import SwiftUI
import BKSCore
import BKSUICore

struct ProjectingView: View {{
    @ObservedObject var store: Store<ProjectingState, ProjectingIntent>
    let credential: StoredCredential
    @ObservedObject var profileStore: Store<ProfileState, ProfileIntent>
    let trendingsService: TrendingsServiceProtocol
    let gamesService: GamesServiceProtocol
    @State private var showProfile = false
    @State private var selectedTab = ProjectingTab.boom
    @State private var toastTier: FeatureTier?
    @Environment(\\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\\.analytics) private var analytics

    private var searchBinding: Binding<String> {{
        Binding(
            get: {{ store.state.searchText }},
            set: {{ store.send(.searchTextChanged($0)) }}
        )
    }}

    var body: some View {{
        NavigationStack(path: Binding(
            get: {{ store.state.navigationPath }},
            set: {{ store.send(.navigationPathChanged($0)) }}
        )) {{
            content
                .appBackground()
                .analyticsScreen("projecting")
                .appNavigationBar(
                    title: String(localized: "projecting.title", defaultValue: "Projecting"),
                    subtitle: String(localized: "projecting.subtitle", defaultValue: "Tonight's ceiling plays")
                )
                .navBarTrailingIcon(
                    "person",
                    accessibilityID: "nav.profileButton",
                    accessibilityLabel: String(localized: "a11y.label.profile", defaultValue: "Profile")
                ) {{ showProfile = true }}
                .navigationDestination(isPresented: $showProfile) {{
                    ProfilePanelView(credential: credential, profileStore: profileStore)
                        .appNavigationBar(title: String(localized: "Profile", defaultValue: "Profile"))
                }}
                .navigationDestination(for: Projection.self) {{ projection in
                    ProjectionDetailView(
                        store: Store(
                            initial: ProjectionDetailState(projection: projection),
                            reduce: ProjectionDetailState.makeReduce(
                                trendingsService: trendingsService,
                                gamesService: gamesService
                            )
                        )
                    )
                    .onAppear {{
                        analytics.logDetailedEvent(AnalyticsEvent.projectionTapped, parameters: [
                            AnalyticsParam.projectionId: projection.id,
                            AnalyticsParam.projectionTier: String(describing: projection.projectionTier),
                            AnalyticsParam.playerTier: projection.playerTier.map(String.init(describing:)) ?? "unknown",
                            AnalyticsParam.isSurging: String(projection.isSurging),
                            AnalyticsParam.subTab: String(describing: selectedTab)
                        ])
                    }}
                }}
        }}
        .task {{
            store.send(.onAppear)
        }}
        .onChange(of: selectedTab) {{
            analytics.logEvent(AnalyticsEvent.subTabSelected, parameters: [
                AnalyticsParam.tabName: String(describing: selectedTab),
                AnalyticsParam.feature: "projecting"
            ])
        }}
    }}

    private var content: some View {{
        LoadableContentView(
            state: store.state.projections,
            isEmpty: store.state.allProjections.isEmpty,
            emptyIcon: "chart.bar.xaxis.ascending",
            errorKey: "projecting.error",
            retryKey: "projecting.retry",
            emptyKey: "projecting.empty",
            onRetry: {{ store.send(.refreshRequested) }},
            content: {{ projectionList }}
        )
    }}

    private var projectionList: some View {{
        let activeProjections: [Projection] = switch selectedTab {{
        case .boom: store.state.filteredBoomProjections
        case .bust: store.state.filteredBustProjections
        }}
        let allGrouped = Dictionary(grouping: store.state.allProjections) {{ $0.projectionTier }}
        let grouped = Dictionary(grouping: activeProjections) {{ $0.projectionTier }}
        let filtersActive = !store.state.searchText.isEmpty || store.state.selectedPosition != nil
        let filteredEmpty = activeProjections.isEmpty

        return VStack(spacing: 0) {{
            SearchFilterHeader(
                searchText: searchBinding,
                selectedPosition: store.state.selectedPosition,
                filterChips: ["All"] + SportPositionMap.{slug}.filterChips,
                accessibilityPrefix: "projecting",
                onPositionChanged: {{ store.send(.positionFilterChanged($0)) }},
                tipsContent: {{ SearchTipsView() }}
            )

            FeatureTabBar(
                selectedTab: $selectedTab,
                reduceMotion: reduceMotion,
                accessibilityPrefix: "projecting"
            )

            if filtersActive, filteredEmpty {{
                FilteredEmptyView(messageKey: "projecting.filter.empty")
            }} else {{
                ScrollView {{
                    VStack(spacing: AppSpacing.xl) {{
                        ForEach(selectedTab.tiers, id: \\.self) {{ tier in
                            ProjectingTierSection(
                                tier: tier,
                                projections: grouped[tier] ?? [],
                                toastTier: $toastTier
                            )
                        }}
                    }}
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                }}
                .id(selectedTab)
                .refreshable {{
                    analytics.logEvent(AnalyticsEvent.pullToRefresh, parameters: [
                        AnalyticsParam.feature: "projecting"
                    ])
                    await store.sendAsync(.refreshRequested)
                }}
                .contentMargins(.bottom, AppPadding.tabBarClearance, for: .scrollContent)
                .overlay(alignment: .bottom) {{
                    if let tier = toastTier {{
                        let tierProjs = allGrouped[tier] ?? []
                        let scores = tierProjs.map(\\.projectionScore)
                        TierToastView(
                            tier: tier,
                            scoreRange: scoreRange(from: scores),
                            playerCount: tierProjs.count
                        )
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }}
                }}
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: toastTier)
            }}
        }}
    }}

    private func scoreRange(from scores: [Double]) -> ClosedRange<Double>? {{
        guard let min = scores.min(), let max = scores.max() else {{ return nil }}
        return min ... max
    }}

}}
"""

projecting_subviews_swift = header() + """\
import SwiftUI
import BKSCore
import BKSUICore

// MARK: - ProjectingTab

enum ProjectingTab: CaseIterable, FeatureTab {
    case boom
    case bust

    var title: String {
        switch self {
        case .boom: String(localized: "projecting.tab.boom", defaultValue: "Boom")
        case .bust: String(localized: "projecting.tab.bust", defaultValue: "Bust")
        }
    }

    var icon: String {
        switch self {
        case .boom: "📈"
        case .bust: "📉"
        }
    }

    var accentColor: Color {
        switch self {
        case .boom: .green
        case .bust: .red
        }
    }

    var tiers: [FeatureTier] {
        switch self {
        case .boom: [.elite, .good]
        case .bust: [.solid, .low]
        }
    }
}

// MARK: - ProjectingTierSection — thin wrapper around shared TierSection

struct ProjectingTierSection: View {
    let tier: FeatureTier
    let projections: [Projection]
    @Binding var toastTier: FeatureTier?

    var body: some View {
        TierSection(
            tier: tier,
            isEmpty: projections.isEmpty,
            emptyKey: "projecting.tier.none",
            toastTier: $toastTier
        ) {
            ForEach(Array(projections.enumerated()), id: \\.element.id) { index, projection in
                NavigationLink(value: projection) {
                    ProjectionRowView(projection: projection)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityIdentifier("projection.row.\\(projection.id)")
                if index < projections.count - 1 {
                    Divider()
                        .overlay(Color.white.opacity(AppOpacity.cardOverlay))
                }
            }
        }
    }
}

// MARK: - ProjectionRowView

struct ProjectionRowView: View {
    let projection: Projection

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            nameRow
            infoRow
            let hasBadges = projection.injuryStatus != nil || projection.isSurging
            if hasBadges {
                badgeRow
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var nameRow: some View {
        HStack(spacing: 4) {
            Text(projection.displayName)
                .font(AppFonts.rankingName)
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(AppFonts.rankingInfo)
                .foregroundStyle(.white.opacity(AppOpacity.dim))
        }
    }

    private var infoRow: some View {
        HStack(spacing: 4) {
            Text(projection.team)
                .font(AppFonts.rankingInfo)
                .foregroundStyle(.white.opacity(AppOpacity.muted))
            if let position = projection.position {
                infoDot
                Text(position)
                    .font(AppFonts.rankingInfo)
                    .foregroundStyle(.white.opacity(AppOpacity.muted))
            }
            Spacer(minLength: 0)
            Text(formattedScore)
                .font(AppFonts.rankingScore)
                .foregroundStyle(scoreColor)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var badgeRow: some View {
        HStack(spacing: 3) {
            if let status = projection.injuryStatus {
                InjuryBadge(status: status, compact: true)
            }
            if projection.isSurging {
                Text("🚀")
                    .font(AppFonts.rankingBadgeIcon)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.purple.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var formattedScore: String {
        let isBust: Bool = switch projection.projectionTier {
        case .solid, .low: true
        case .elite, .good: false
        }
        let prefix = isBust ? "-" : ""
        return prefix + String(format: "%.0f", projection.projectionScore)
    }

    private var scoreColor: Color {
        switch projection.projectionTier {
        case .elite, .good: .green
        case .solid, .low: .red
        }
    }

    private var infoDot: some View {
        Text("·")
            .font(AppFonts.rankingInfo)
            .foregroundStyle(.white.opacity(AppOpacity.muted))
    }
}
"""

projection_detail_view_swift = header() + """\
import SwiftUI
import BKSCore
import BKSUICore

struct ProjectionDetailView: View {
    @StateObject var store: Store<ProjectionDetailState, ProjectionDetailIntent>

    @State private var selectedTab = ProjectionDetailTab.outlook
    @State private var showTierToast = false
    @Environment(\\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\\.analytics) private var analytics
    @State private var hasLoggedGameLog = false

    private var projection: Projection {
        store.state.projection
    }

    private var player: Player? {
        if case let .loaded(player) = store.state.player { return player }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ProjectionDetailHeaderCard(
                    projection: projection,
                    showTierToast: $showTierToast
                )
                ProjectionScheduleCard(projection: projection)
                ProjectionFantasyBar(player: player)
                ProjectionDetailScoreCard(projection: projection, player: player)
                tabBar
                tabContent
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 20)
        }
        .contentMargins(.bottom, AppPadding.tabBarClearance, for: .scrollContent)
        .appBackground()
        .analyticsScreen("projection_detail")
        .overlay(alignment: .bottom) {
            if showTierToast, let tier = projection.playerTier {
                TierToastView(tier: tier)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: showTierToast)
        .appNavigationBar(title: "")
        .task { store.send(.onAppear) }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(ProjectionDetailTab.allCases, id: \\.self) { tab in
                tabButton(tab)
            }
        }
    }

    private func tabButton(_ tab: ProjectionDetailTab) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                selectedTab = tab
            }
            analytics.logDetailedEvent(AnalyticsEvent.detailTabSwitched, parameters: [
                AnalyticsParam.tabName: String(describing: tab),
                AnalyticsParam.feature: "projecting",
                AnalyticsParam.playerId: projection.id,
                AnalyticsParam.playerTier: projection.playerTier.map(String.init(describing:)) ?? "unknown"
            ])
            if tab == .gameLog {
                store.send(.gameLogTabSelected)
            }
        } label: {
            VStack(spacing: 4) {
                Text(tab.title)
                    .font(selectedTab == tab ? AppFonts.filterChip.weight(.semibold) : AppFonts.filterChip)
                    .foregroundStyle(
                        selectedTab == tab ? .white : .white.opacity(AppOpacity.muted)
                    )
                Rectangle()
                    .fill(selectedTab == tab ? .orange : .clear)
                    .frame(height: 2)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .outlook:
            outlookContent
        case .gameLog:
            gameLogContent
        }
    }

    @ViewBuilder
    private var outlookContent: some View {
        ProjectionOutlookCard(projection: projection, player: player)
        if let player {
            PlayerDetailOverviewTrendCard(player: player)
        }
    }

    @ViewBuilder
    private var gameLogContent: some View {
        switch store.state.gameLog {
        case .idle, .loading:
            GameLogPlaceholderView(style: .loading)
        case let .loaded(gameLog):
            if gameLog.entries.isEmpty {
                GameLogPlaceholderView(style: .empty)
            } else {
                GameLogTableView(entries: gameLog.entries)
                    .onAppear {
                        guard !hasLoggedGameLog else { return }
                        hasLoggedGameLog = true
                        analytics.logDetailedEvent(AnalyticsEvent.gameLogViewed, parameters: [
                            AnalyticsParam.playerId: projection.id,
                            AnalyticsParam.feature: "projecting",
                            AnalyticsParam.entryCount: String(gameLog.entries.count)
                        ])
                    }
            }
        case let .failed(error):
            GameLogErrorView(error: error) {
                store.send(.refreshRequested)
            }
        }
    }
}

private enum ProjectionDetailTab: CaseIterable {
    case outlook
    case gameLog

    var title: String {
        switch self {
        case .outlook: String(localized: "projectionDetail.tab.outlook", defaultValue: "Trend Overview")
        case .gameLog: String(localized: "projectionDetail.tab.gameLog", defaultValue: "Game Log")
        }
    }
}
"""

projection_detail_subviews_swift = header() + """\
import SwiftUI
import BKSCore
import BKSUICore

// MARK: - ProjectionDetailHeaderCard

struct ProjectionDetailHeaderCard: View {
    let projection: Projection
    @Binding var showTierToast: Bool
    @Environment(\\.analytics) private var analytics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                headshot
                headerInfo
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .appCard()
    }

    private var headshot: some View {
        CachedAsyncImage(url: projection.headshotURL) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
                    .accessibilityIgnoresInvertColors(true)
            default:
                Image(systemName: "person.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(AppOpacity.separator))
            }
        }
        .frame(width: 90, height: 105)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.sm)
                .stroke(.white.opacity(AppOpacity.divider), lineWidth: 1)
        )
    }

    private var headerInfo: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(projection.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            teamPositionRow
            Spacer(minLength: 0)
            tierRow
        }
        .frame(height: 105, alignment: .leading)
    }

    private var teamPositionRow: some View {
        HStack(spacing: 6) {
            Text(projection.team).fontWeight(.semibold)
            if let position = projection.position {
                headerPipe
                Text(position)
            }
            if let status = projection.injuryStatus {
                headerPipe
                Text(status.rawValue).foregroundStyle(status.color)
            }
        }
        .font(AppFonts.playerInfoLine)
        .foregroundStyle(.white.opacity(AppOpacity.primary))
    }

    private var tierRow: some View {
        HStack(spacing: 6) {
            Text(String(format: "%.0f", projection.projectionScore))
                .monospacedDigit()
                .frame(width: 44, alignment: .center)
            if let tier = projection.playerTier {
                headerPipe
                Button {
                    showTierToast = true
                    analytics.logDetailedEvent(AnalyticsEvent.tierBadgeTapped, parameters: [
                        AnalyticsParam.tier: String(describing: tier),
                        AnalyticsParam.feature: "projecting"
                    ])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        showTierToast = false
                    }
                } label: {
                    Image(systemName: tier.systemImage)
                        .foregroundStyle(tier.color)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "a11y.label.showTierDetails", defaultValue: "Show tier details"))
            }
        }
        .lineLimit(1)
        .font(AppFonts.playerInfoLine)
        .foregroundStyle(.white.opacity(AppOpacity.primary))
        .accessibilityElement(children: .combine)
    }

    private var headerPipe: some View {
        Text(String(localized: "|", defaultValue: "|")).foregroundStyle(.white.opacity(AppOpacity.separator))
    }
}

// MARK: - ProjectionScheduleCard

struct ProjectionScheduleCard: View {
    let projection: Projection

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()

    var body: some View {
        if let games = projection.upcomingGames, !games.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "projectionDetail.schedule.title", defaultValue: "Next 5 Games"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(AppOpacity.secondary))

                HStack(spacing: 6) {
                    ForEach(games) { game in
                        gameChip(game)
                    }
                }
            }
            .padding(12)
            .appCard()
        } else {
            VStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(AppOpacity.dim))
                Text(String(localized: "projectionDetail.schedule.comingSoon",
                            defaultValue: "Schedule data coming soon"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(AppOpacity.separator))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .appCard()
        }
    }

    private func gameChip(_ game: ProjectedGame) -> some View {
        VStack(spacing: 3) {
            Text(Self.dateFormatter.string(from: game.gameDate))
                .font(.caption2)
                .foregroundStyle(.white.opacity(AppOpacity.secondary))
            Text(game.opponentAbbr)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
            Image(systemName: game.isHome ? "house.fill" : "car.fill")
                .font(.system(size: 8))
                .foregroundStyle(game.isHome ? .green : .white.opacity(AppOpacity.muted))
            if let score = game.projectedScore {
                Text(String(format: "%.0f", score))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(strengthColor(game.opponentStrength))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.white.opacity(AppOpacity.faint))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
    }

    private func strengthColor(_ strength: Double?) -> Color {
        guard let strength else { return .white }
        if strength >= 70 { return .red.opacity(0.9) }
        if strength >= 50 { return .white }
        return .green
    }
}

// MARK: - ProjectionFantasyBar

struct ProjectionFantasyBar: View {
    let player: Player?

    var body: some View {
        HStack(spacing: 0) {
            statColumn(
                label: String(localized: "projectionDetail.stats.dkAvg", defaultValue: "DK Avg"),
                value: playerValue(player?.avgFantasyScore, format: "%.1f")
            )
            statDivider
            statColumn(
                label: String(localized: "projectionDetail.stats.homeAvg", defaultValue: "Home Avg"),
                value: playerValue(player?.avgFantasyScoreHome, format: "%.1f")
            )
            statDivider
            statColumn(
                label: String(localized: "projectionDetail.stats.awayAvg", defaultValue: "Away Avg"),
                value: playerValue(player?.avgFantasyScoreAway, format: "%.1f")
            )
        }
        .padding(.vertical, 10)
        .appCard()
        .accessibilityElement(children: .combine)
    }

    private func statColumn(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(AppFonts.statLabel)
                .foregroundStyle(.white.opacity(AppOpacity.muted))
            Text(value)
                .font(AppFonts.statValue)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(.white.opacity(AppOpacity.divider))
            .frame(width: 1, height: 20)
    }

    private func playerValue(_ value: Double?, format: String) -> String {
        guard let value else { return "—" }
        return String(format: format, value)
    }
}

// MARK: - ProjectionDetailScoreCard

struct ProjectionDetailScoreCard: View {
    let projection: Projection
    let player: Player?

    var body: some View {
        HStack(spacing: 0) {
            statColumn(
                label: String(localized: "projection.detail.score", defaultValue: "Score"),
                value: String(format: "%.0f", projection.projectionScore),
                color: projection.projectionTier.color
            )
            statDivider
            statColumn(
                label: String(localized: "projection.detail.playerTier", defaultValue: "Player Tier"),
                value: projection.playerTier?.label ?? "—",
                color: projection.playerTier?.color ?? .white.opacity(AppOpacity.separator)
            )
            statDivider
            statColumn(
                label: String(localized: "projectionDetail.score.consistency", defaultValue: "Consistency"),
                value: consistencyValue,
                color: .white
            )
        }
        .padding(.vertical, 10)
        .appCard()
        .accessibilityElement(children: .combine)
    }

    private var consistencyValue: String {
        if let consistency = player?.consistencyScore {
            return String(format: "%.0f%%", consistency * 100)
        }
        if let consistency = projection.consistencyScore {
            return String(format: "%.0f%%", consistency * 100)
        }
        return "—"
    }

    private func statColumn(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(AppFonts.statLabel)
                .foregroundStyle(.white.opacity(AppOpacity.muted))
            Text(value)
                .font(AppFonts.statValue)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(.white.opacity(AppOpacity.divider))
            .frame(width: 1, height: 20)
    }
}

// MARK: - ProjectionOutlookCard

struct ProjectionOutlookCard: View {
    let projection: Projection
    let player: Player?

    var body: some View {
        VStack(spacing: 0) {
            let rows = buildRows()
            ForEach(Array(rows.enumerated()), id: \\.offset) { index, item in
                if index > 0 { rowDivider }
                signalRow(label: item.label, value: item.value, color: item.color)
            }
        }
        .padding(.bottom, 4)
        .appCard()
    }

    private struct SignalRow {
        let label: String
        let value: String
        let color: Color
    }

    // swiftlint:disable:next function_body_length
    private func buildRows() -> [SignalRow] {
        var rows: [SignalRow] = []

        rows.append(SignalRow(
            label: String(localized: "projection.detail.surging", defaultValue: "Surging"),
            value: projection.isSurging
                ? String(localized: "projection.detail.yes", defaultValue: "Yes")
                : String(localized: "projection.detail.no", defaultValue: "No"),
            color: projection.isSurging ? .green : .white.opacity(AppOpacity.separator)
        ))

        if let direction = projection.trendDirection {
            let (display, color): (String, Color) = switch direction {
            case .up:
                (String(localized: "projectionDetail.outlook.trendUp", defaultValue: "Trending Up"), .green)
            case .down:
                (String(localized: "projectionDetail.outlook.trendDown", defaultValue: "Trending Down"), .red)
            case .flat, .neutral:
                (String(localized: "projectionDetail.outlook.trendFlat", defaultValue: "Flat"),
                 .white.opacity(AppOpacity.separator))
            }
            rows.append(SignalRow(
                label: String(localized: "projectionDetail.outlook.trend", defaultValue: "Trend"),
                value: display,
                color: color
            ))
        }

        if let confidence = projection.confidenceScore {
            rows.append(SignalRow(
                label: String(localized: "projectionDetail.outlook.confidence", defaultValue: "Confidence"),
                value: String(format: "%.0f%%", confidence * 100),
                color: .white
            ))
        }

        let consistency = projection.consistencyScore ?? player?.consistencyScore
        if let consistency {
            rows.append(SignalRow(
                label: String(localized: "projectionDetail.outlook.consistency", defaultValue: "Consistency"),
                value: String(format: "%.0f%%", consistency * 100),
                color: .white
            ))
        }

        if let strength = projection.avgOpponentStrength {
            rows.append(SignalRow(
                label: String(localized: "projectionDetail.outlook.oppStrength", defaultValue: "Avg Opp Strength"),
                value: String(format: "%.0f", strength),
                color: strength >= 70 ? .red : strength <= 45 ? .green : .white
            ))
        }

        return rows
    }

    private func signalRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(.white.opacity(AppOpacity.secondary))
            Spacer()
            Text(value).font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(color)
        }.padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var rowDivider: some View {
        Divider().background(.white.opacity(AppOpacity.hairline)).padding(.leading, AppPadding.contentInner)
    }
}
"""

write(os.path.join(projecting_views_dir, "ProjectingView.swift"), projecting_view_swift)
write(os.path.join(projecting_views_dir, "ProjectingSubviews.swift"), projecting_subviews_swift)
write(os.path.join(projecting_views_dir, "ProjectionDetailView.swift"), projection_detail_view_swift)
write(os.path.join(projecting_views_dir, "ProjectionDetailSubviews.swift"), projection_detail_subviews_swift)

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
# 18. CLAUDE.md
# ─────────────────────────────────────────────────────────────────────────────

# Build position filter group names for the source structure comment
position_labels = ", ".join(p["label"] for p in positions)

claude_md = f"""# CLAUDE.md

## Project Overview
iOS app built with Swift and SwiftUI, targeting iOS {deploy_tgt}+. Uses Swift Package Manager for dependencies.

## Build & Test Commands
- **Build**: `xcodebuild -scheme MyApp -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16'`
- **Test**: `xcodebuild test -scheme MyApp -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16'`
- **Lint**: `swiftlint`
- **Regenerate project**: `./generate.sh` (from repo root — runs xcodegen then syncs both Package.resolved files)
  - **Never** run `xcodegen generate` directly; always use `./generate.sh` to keep the inner and outer Package.resolved in sync

## Code Standards
- Use async/await for all new concurrency code (no Combine for new work)
- All view models must be `@Observable` classes
- No force unwraps (`!`) outside of test files
- All public APIs must have doc comments
- Follow Swift naming conventions (camelCase properties, PascalCase types)
- Prefer value types (structs/enums) unless reference semantics are needed
- Run `swiftlint` before completing any task

## Localization
- All user-visible strings **must** use `String(localized:defaultValue:)` with a descriptive key and an English default value
- Keys follow the pattern `feature.context.name` (e.g., `profile.row.analytics`, `dataNotice.title`)
- The string catalog is at `Sources/App/Resources/Localizable.xcstrings`
- Supported languages: **en**, **fr-CA**, **es** — when adding new strings, add translations for all three languages in the `.xcstrings` file
- Accessibility labels and hints (`a11y.*`) follow the same rules — they must have `defaultValue:` and entries in the string catalog
- **Never** use bare `String(localized: "some.key")` without `defaultValue:` — it renders the raw key if the catalog entry is missing

## Template Origin

This project was scaffolded by the **BKS-Sports-iOS** code generator:

https://github.com/bkatnich/BKS-Sports-iOS

The generator takes `sports/{slug}.yaml` and produces the sport-specific Swift files. If the generator's templates change, re-run `./scaffold.sh {slug}` from the template repo to regenerate those files.

**Do NOT** automatically propagate changes from this project back to the template repo. Always ask for explicit permission before modifying files in the BKS-Sports-iOS generator.

## Architecture
- **Pattern**: MVI (Store/Reduce unidirectional data flow) via BKSCore
- **Navigation**: NavigationStack with typed destinations
- **DI**: Swinject container bootstrapped at app launch; `SportConfiguration` injected via SwiftUI `.environment()`

### Source Structure
```
Sources/
├── App/           — Composition root ({type_prefix}App, AppShell, DependencyContainer)
├── Core/
│   ├── Services/  — Network services (TrendingsService, OpportunitiesService, ProjectionsService, GamesService)
│   ├── Models/    — Domain models (Player, Opportunity, Projection, GameEntry, TodaySchedule)
│   ├── Sport/     — Multi-sport abstraction (SportConfiguration, SportPositionMap, ScoringCalculator)
│   ├── Utilities/ — Shared helpers (Filterable, ConfigurationKeys, PlayerLookup)
│   └── UI/        — Shared views (TierTypes+UI, TierThresholds, SearchTipsView, SeasonModeBanner)
└── Features/
    ├── Trending/
    │   ├── Views/ — TrendingView, PlayerDetailView, PlayerRowView, GameLogViews
    │   └── Store/ — TrendingState, TrendingIntent, PlayerDetailState, PlayerDetailIntent
    ├── Prospecting/
    │   ├── Views/ — ProspectingView, OpportunityDetailView, OpportunityRowView
    │   └── Store/ — ProspectingState, ProspectingIntent, OpportunityDetailState, OpportunityDetailIntent
    └── Projecting/
        ├── Views/ — ProjectingView, ProjectionDetailView
        └── Store/ — ProjectingState, ProjectingIntent, ProjectionDetailState, ProjectionDetailIntent
```

### Agent ownership boundaries
- **Core/Services/ + Core/Models/**: Data Agent
- **Core/Sport/ + Core/Utilities/ + Core/UI/**: whichever agent's task requires it; coordinate if both need changes
- **Features/*/Views/**: UI Agent
- **Features/*/Store/**: UI Agent (state) or Data Agent (service wiring)
- **Tests/**: Test Agent

## Xcode Project Protection
- **NEVER** remove or modify the `FIRAAppCheckDebugToken` environment variable from any Xcode scheme. This is the Firebase App Check debug token required for API access in debug builds. Deleting it breaks all authenticated network calls.
- **NEVER** change the Development Team identifier (`DEVELOPMENT_TEAM`) in `project.yml` or the Xcode project settings. This is tied to the signing certificate and provisioning profiles.

## Multi-Agent Workflow

### When to use agents
- Feature work spanning UI + data layers → spawn separate agents per layer
- Bug investigation with unclear cause → spawn parallel research agents with competing hypotheses
- Any PR touching 3+ modules → use agent team
- Simple single-file changes → handle directly, no agents needed

### Agent ownership boundaries
Each agent owns a distinct set of files. Two agents must never edit the same file.
- **UI Agent**: `Sources/Features/*/Views/`
- **Data Agent**: `Sources/Core/Services/`, `Sources/Core/Models/`
- **Test Agent**: `Tests/`
- Shared code (`Sources/Core/Sport/`, `Sources/Core/Utilities/`, `Sources/Core/UI/`) is owned by whichever agent's task requires the change; coordinate via the lead if both need changes

### Workflow stages
1. **Research** — Read-only agents investigate in parallel. No file writes.
2. **Plan** — Lead synthesizes findings and assigns implementation tasks with clear file ownership.
3. **Implement** — Agents work in isolated worktrees. Each agent runs `swiftlint` before finishing.
4. **Verify** — Verification agent runs full test suite and reviews diffs. Must pass before merge.

### Rules
- Always use `isolation: "worktree"` for implementation agents
- Always spawn a verification agent after implementation completes
- Research agents must be read-only
- If an agent encounters a build failure it cannot resolve in 2 attempts, report back to lead rather than continuing
"""

write(os.path.join(out_dir, "CLAUDE.md"), claude_md)

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

print()
print(f"✅ Scaffolded {app_name} at:")
print(f"   {out_dir}")
print()
print("Bootstrap:")
print(f"  App/Sources/App/Bootstrap/{type_prefix}App.swift")
print(f"  App/Sources/App/Bootstrap/AppShell.swift")
print(f"  App/Sources/App/Bootstrap/DependencyContainer.swift")
print(f"  App/Sources/App/Bootstrap/Authentication.swift")
print(f"  App/Sources/App/Bootstrap/FirebaseAnalyticsAdapter.swift")
print(f"  App/Sources/App/Bootstrap/DataRefreshTask.swift")
print()
print("Models:")
print(f"  App/Sources/Core/Models/Player.swift")
print(f"  App/Sources/Core/Models/Opportunity.swift")
print(f"  App/Sources/Core/Models/Projection.swift")
print(f"  App/Sources/Core/Models/TodaySchedule.swift")
print(f"  App/Sources/Core/Models/GameEntry.swift")
print(f"  App/Sources/Core/Models/PlayoffSeries.swift")
print(f"  App/Sources/Core/Models/LeagueState.swift")
print()
print("Services:")
print(f"  App/Sources/Core/Services/TrendingsService.swift")
print(f"  App/Sources/Core/Services/OpportunitiesService.swift")
print(f"  App/Sources/Core/Services/ProjectionsService.swift")
print(f"  App/Sources/Core/Services/GamesService.swift")
print(f"  App/Sources/Core/Services/PlayoffService.swift")
print(f"  App/Sources/Core/Services/PromoCodeService.swift")
print()
print("Sport configuration:")
print(f"  App/Sources/Core/Sport/ScoringCalculator.swift")
print(f"  App/Sources/Core/Sport/SportPositionMap.swift")
print(f"  App/Sources/Core/Sport/SportConfiguration.swift")
print(f"  App/Sources/Core/Sport/SportPositionMap+{swift_name}.swift")
print(f"  App/Sources/Core/Sport/{calc_name}.swift")
print(f"  App/Sources/Core/Sport/SportConfiguration+{swift_name}.swift")
print(f"  App/Sources/Core/Sport/SportConfiguration+Environment.swift")
print()
print("Core UI & Utilities:")
print(f"  App/Sources/Core/UI/TierThresholds+{swift_name}.swift")
print(f"  App/Sources/Core/UI/TierTypes+UI.swift")
print(f"  App/Sources/Core/UI/SearchTipsView.swift")
print(f"  App/Sources/Core/UI/SeasonModeBanner.swift")
print(f"  App/Sources/Core/Utilities/ConfigurationKeys+{swift_name}.swift")
print(f"  App/Sources/Core/Utilities/Filterable+{swift_name}.swift")
print(f"  App/Sources/Core/Utilities/PlayerLookup.swift")
print()
print("Trending feature:")
print(f"  App/Sources/Features/Trending/Store/TrendingState.swift")
print(f"  App/Sources/Features/Trending/Store/TrendingIntent.swift")
print(f"  App/Sources/Features/Trending/Store/PlayerDetailState.swift")
print(f"  App/Sources/Features/Trending/Store/PlayerDetailIntent.swift")
print(f"  App/Sources/Features/Trending/Views/TrendingView.swift")
print(f"  App/Sources/Features/Trending/Views/TrendingSubviews.swift")
print(f"  App/Sources/Features/Trending/Views/PlayerRowView.swift")
print(f"  App/Sources/Features/Trending/Views/PlayerDetailView.swift")
print(f"  App/Sources/Features/Trending/Views/PlayerDetailSubviews.swift")
print(f"  App/Sources/Features/Trending/Views/PlayerDetailOverviewView.swift")
print(f"  App/Sources/Features/Trending/Views/GameLogViews.swift")
print()
print("Prospecting feature:")
print(f"  App/Sources/Features/Prospecting/Store/ProspectingState.swift")
print(f"  App/Sources/Features/Prospecting/Store/ProspectingIntent.swift")
print(f"  App/Sources/Features/Prospecting/Store/OpportunityDetailState.swift")
print(f"  App/Sources/Features/Prospecting/Store/OpportunityDetailIntent.swift")
print(f"  App/Sources/Features/Prospecting/Store/PlayoffState.swift")
print(f"  App/Sources/Features/Prospecting/Views/ProspectingView.swift")
print(f"  App/Sources/Features/Prospecting/Views/ProspectingSubviews.swift")
print(f"  App/Sources/Features/Prospecting/Views/OpportunityRowView.swift")
print(f"  App/Sources/Features/Prospecting/Views/OpportunityDetailView.swift")
print(f"  App/Sources/Features/Prospecting/Views/OpportunityDetailSubviews.swift")
print(f"  App/Sources/Features/Prospecting/Views/BracketView.swift")
print(f"  App/Sources/Features/Prospecting/Views/BracketSubviews.swift")
print()
print("Projecting feature:")
print(f"  App/Sources/Features/Projecting/Store/ProjectingState.swift")
print(f"  App/Sources/Features/Projecting/Store/ProjectingIntent.swift")
print(f"  App/Sources/Features/Projecting/Store/ProjectionDetailState.swift")
print(f"  App/Sources/Features/Projecting/Store/ProjectionDetailIntent.swift")
print(f"  App/Sources/Features/Projecting/Views/ProjectingView.swift")
print(f"  App/Sources/Features/Projecting/Views/ProjectingSubviews.swift")
print(f"  App/Sources/Features/Projecting/Views/ProjectionDetailView.swift")
print(f"  App/Sources/Features/Projecting/Views/ProjectionDetailSubviews.swift")
print()
print("Project infrastructure:")
print(f"  App/project.yml")
print(f"  App/Config/Base.xcconfig")
print(f"  App/Config/Debug.xcconfig                        ← gitignored; add real secrets")
print(f"  App/Config/Debug.xcconfig.template")
print(f"  App/Config/Release.xcconfig                      ← gitignored; add real secrets")
print(f"  App/Config/Release.xcconfig.template")
print(f"  App/Tests/.gitkeep")
print(f"  App/Config/{app_target}Tests.xcconfig")
print(f"  App/Sources/App/Resources/Info.plist")
print(f"  App/Sources/App/Resources/Configuration.plist    ← runtime API URLs")
print(f"  App/Sources/App/Resources/{app_target}.entitlements")
print(f"  App/Sources/App/Resources/PrivacyInfo.xcprivacy")
print(f"  App/Sources/App/Resources/GoogleService-Info.plist  ← placeholder, replace with real Firebase config")
print(f"  .swiftlint.yml")
print(f"  .swiftformat")
print(f"  .gitignore")
print(f"  CLAUDE.md")
print()
print("Next steps:")
print(f"  1. Replace App/Sources/App/Resources/GoogleService-Info.plist with real Firebase config")
print(f"  2. Fill in teamAbbreviationByID in SportConfiguration+{swift_name}.swift")
print(f"  3. Fill in real API keys in App/Config/Debug.xcconfig (gitignored)")
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
