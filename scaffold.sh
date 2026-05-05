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
#   ConfigurationKeys+<Sport>.swift, VisiblePushEvent.swift
#   NotificationPreferenceKey+<Sport>.swift, NotificationPreferenceKey+FCM.swift
#   SportPositionMap+<Sport>.swift
#   <Calculator>.swift  (ScoringCalculator implementation)
#   SportConfiguration+<Sport>.swift
#   TierThresholds+<Sport>.swift
#   GameEntry.swift, GameLogViews.swift
#   Features/Board/ — BoardEntry, BoardEntryBuilder, BoardState, BoardIntent, BoardView (stubs)
#   Features/Profile/ — ProfileContainerView, NotificationsDetailView
#   workspace.yml, generate.sh, project.yml, xcconfig files, Info.plist, storekit stub
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

players_url      = players_api.get("url", "")
opps_url         = opps_api.get("url", "")
proj_url         = proj_api.get("url", "")
today_url        = today_api.get("url", "")
gamelog_base     = gamelog_api.get("baseURL", "")
api_key_needed   = gamelog_api.get("apiKeyRequired", False)

fcm             = spec.get("fcm", {})
fcm_gameday     = fcm.get("gamedayTopic", "gameday")
fcm_playoff     = fcm.get("playoffTopic", f"{slug}")

subscription    = spec.get("subscription", {})
sub_suffix      = subscription.get("productSuffix", "basic.monthly")
sub_group       = subscription.get("groupID", f"{type_prefix}Subscriptions")
sub_product_id  = f"{bundle_id}.{sub_suffix}"

config_keys = header() + f"""\
import Foundation
import BKSCore

// MARK: - {name}-specific configuration keys

extension ConfigurationKey where Value == Bool {{
    static let opportunitiesIncludeResting = ConfigurationKey(
        name: "opportunitiesIncludeResting",
        defaultValue: false
    )
}}

extension ConfigurationKey where Value == String {{
    static let vegasBookPreference = ConfigurationKey(
        name: "vegasBookPreference",
        defaultValue: "dk"
    )
    static let fcmGamedayTopic = ConfigurationKey(
        name: "fcmGamedayTopic",
        defaultValue: "{fcm_gameday}"
    )
    static let fcmPlayoffTopic = ConfigurationKey(
        name: "fcmPlayoffTopic",
        defaultValue: "{fcm_playoff}"
    )
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

// MARK: - Background task identifier

enum DataRefreshTaskID {{
    static let identifier = "{bundle_id}.datarefresh"
}}

// MARK: - Subscription product IDs

enum SubscriptionProductID {{
    static let basicMonthly = "{sub_product_id}"
    static let subscriptionGroupID = "{sub_group}"
    static var allCurrentProductIDs: Set<String> {{ [basicMonthly] }}
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Utilities", f"ConfigurationKeys+{swift_name}.swift"), config_keys)

# ─────────────────────────────────────────────────────────────────────────────
# 1b. VisiblePushEvent.swift
#     Visible (banner) push notification event types for this sport.
#     Cases drive deep-link routing in AppDelegate.handleNotificationTap.
# ─────────────────────────────────────────────────────────────────────────────

visible_push_events = fcm.get("visiblePushEvents", [
    {"name": "seriesClinch",    "rawValue": "series_clinch"},
    {"name": "champion",        "rawValue": "champion"},
    {"name": "eliminationGame", "rawValue": "elimination_game"},
    {"name": "bracketAdvance",  "rawValue": "bracket_advance"},
])

cases_block = "\n".join(
    f'    case {e["name"]:<18} = "{e["rawValue"]}"'
    for e in visible_push_events
)

visible_push_swift = header() + f"""\
import Foundation

// MARK: - VisiblePushEvent

/// Visible push notification event types for the {name} app.
/// These are banner notifications — the app handles taps for deep-link routing.
enum VisiblePushEvent: String {{
{cases_block}
}}

// MARK: - PushNotificationNames

enum PushNotificationNames {{
    static let visiblePushTapped = Notification.Name("{bundle_id}.visiblePushTapped")
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Utilities", "VisiblePushEvent.swift"), visible_push_swift)

# ─────────────────────────────────────────────────────────────────────────────
# 1c. NotificationPreferenceKey+<Sport>.swift
#     Sport-specific notification preference key and accessor.
# ─────────────────────────────────────────────────────────────────────────────

notif_pref_key_swift = header() + f"""\
import BKSCore

// MARK: - {name} notification preference key

extension NotificationPreferenceKey {{
    /// Playoff series/elimination alerts — {slug}-specific.
    public static let playoffAlerts = NotificationPreferenceKey(rawValue: "playoff_alerts")
}}

// MARK: - {name} preference accessors

extension NotificationPreferences {{
    /// Playoff alerts preference. Stored in `sportPreferences["playoff_alerts"]`.
    public var playoffAlerts: Bool? {{
        get {{ sportPreferences[NotificationPreferenceKey.playoffAlerts.rawValue] }}
        set {{ sportPreferences[NotificationPreferenceKey.playoffAlerts.rawValue] = newValue }}
    }}
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Utilities", f"NotificationPreferenceKey+{swift_name}.swift"), notif_pref_key_swift)

# ─────────────────────────────────────────────────────────────────────────────
# 1d. NotificationPreferenceKey+FCM.swift
#     Maps raw FCM event strings → preference keys for this sport.
# ─────────────────────────────────────────────────────────────────────────────

fcm_cases = "\n".join(
    f'        case "{e["rawValue"]}":'
    for e in visible_push_events
)

notif_fcm_swift = header() + f"""\
import BKSCore

extension NotificationPreferenceKey {{
    /// Maps FCM event strings to preference keys for the {name} app.
    /// Sport-specific playoff events are handled here; core events delegate to BKSCore.
    init?(fcmEvent: String) {{
        switch fcmEvent {{
{fcm_cases}
            self = .playoffAlerts
        default:
            guard let key = NotificationPreferenceKey(coreEvent: fcmEvent) else {{ return nil }}
            self = key
        }}
    }}
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Utilities", "NotificationPreferenceKey+FCM.swift"), notif_fcm_swift)

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
        opportunityParams: OpportunityParams(limit: {opp_limit}, mode: "{opp_mode}"),
        projectionParams: ProjectionParams(lookahead: {proj_look}, mode: "{proj_mode}"),
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

write(os.path.join(out_dir, "App/Sources/Features/Board/Views/GameLogViews.swift"), gamelog_views)

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
import BackgroundTasks
import BKSCore
import BKSUICore
import OSLog
import SwiftUI
import Swinject
import UIKit
import UserNotifications

@main
struct {type_prefix}App: App {{
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

    private let opportunitiesService: OpportunitiesServiceProtocol
    private let projectionsService: ProjectionsServiceProtocol
    private let gamesService: GamesServiceProtocol
    private let promoCodeService: PromoCodeServiceProtocol
    private let activityService: any ActivityFeedServiceProtocol
    private let configuration: ConfigurationProtocol
    private let storage: StorageProtocol
    private let analyticsAdapter = FirebaseAnalyticsAdapter()
    private let metricsCollector: MetricsCollectorProtocol
    private let subscriptionService: SubscriptionService

    @State private var splashDismissed = false
    @State private var pendingConsentResult: AuthResult?
    @State private var isErasingCache = false

    init() {{
        BKSAppScaffold.logLaunchDiagnostics(logger: Self.logger)

        let appDelegate = UIApplication.shared.delegate as? AppDelegate
        let container = appDelegate?.container ?? Container.defaultContainer()

        let resolvedAuth = container.require(Store<AuthState, AuthIntent>.self)
        authStore = resolvedAuth
        boardStore = container.require(Store<BoardState, BoardIntent>.self)

        let auth = container.require(AuthenticationProtocol.self)
        configuration = container.require(ConfigurationProtocol.self)
        storage = container.require(StorageProtocol.self)

        (opportunitiesService, projectionsService, gamesService) = Self.resolveSportServices(from: container)

        promoCodeService = container.require(PromoCodeServiceProtocol.self)
        activityService = container.require(ActivityFeedServiceProtocol.self)
        metricsCollector = container.require(MetricsCollectorProtocol.self)
        metricsCollector.startCollecting()

        let resolvedSubscription = container.require(SubscriptionService.self)
        subscriptionService = resolvedSubscription
        subscriptionService.startTransactionListener()

        let opps = opportunitiesService
        let projs = projectionsService
        let games = gamesService

        profileStore = BKSAppScaffold.makeProfileStore(
            container: container,
            authStore: resolvedAuth,
            auth: auth
        ) {{ prefs in
            AppDelegate.notificationPreferences = prefs
            let svc = container.require(UserPreferencesServiceProtocol.self)
            try? await svc.updatePreferences(prefs)
        }}

        signInStore = BKSAppScaffold.makeSignInStore(
            container: container,
            authStore: resolvedAuth
        ) {{
            Task {{ await Self.prefetch(opps: opps, projs: projs, games: games) }}
        }}

        Self.registerDataRefresh(opps: opps, projs: projs, games: games)
    }}

    private static func registerDataRefresh(
        opps: OpportunitiesServiceProtocol,
        projs: ProjectionsServiceProtocol,
        games: GamesServiceProtocol
    ) {{
        DataRefreshTask.register(
            identifier: DataRefreshTaskID.identifier,
            fetchOpportunities: {{ _ = try await opps.fetchOpportunities(includeResting: true) }},
            fetchProjections:   {{ _ = try await projs.fetchProjections() }},
            fetchSchedule:      {{ _ = try await games.fetchTodaySchedule() }}
        )
    }}

    private static func resolveSportServices(
        from container: Container
    ) -> (OpportunitiesServiceProtocol, ProjectionsServiceProtocol, GamesServiceProtocol) {{
        (
            container.require(OpportunitiesServiceProtocol.self),
            container.require(ProjectionsServiceProtocol.self),
            container.require(GamesServiceProtocol.self)
        )
    }}

    private var authSessionResolved: Bool {{
        if case .undetermined = authStore.state.session {{ return false }}
        return true
    }}

    var body: some Scene {{
        WindowGroup {{
            BKSRootView(
                authStore: authStore,
                authSessionResolved: authSessionResolved,
                pendingConsentResult: $pendingConsentResult,
                splashDismissed: $splashDismissed
            ) {{ credential in
                {swift_name}AppShell(
                    boardStore: boardStore,
                    profileStore: profileStore,
                    credential: credential,
                    promoCodeService: promoCodeService,
                    activityService: activityService,
                    isErasingCache: $isErasingCache,
                    onEraseCachedData: eraseCachedData
                )
            }} consentContent: {{ result in
                subscriptionConsentView(for: result)
            }} signInContent: {{
                SignInView(store: signInStore, animateIn: splashDismissed, auth: nil) {{ result in
                    analyticsAdapter.logEvent(AnalyticsEvent.signUpCompleted, parameters: nil)
                    if loadConsentAccepted(from: storage) {{
                        authStore.send(.signInSucceeded(result))
                    }} else {{
                        pendingConsentResult = result
                    }}
                }}
            }}
            .environmentObject(networkMonitor)
            .appConfiguration(configuration)
            .sportConfiguration(SportConfiguration.{slug})
            .analytics(analyticsAdapter)
            .environment(\\.subscriptionService, subscriptionService)
            .task {{
                authStore.send(.checkStoredCredential)
                profileStore.send(.onAppear)
                await Self.prefetch(
                    opps: opportunitiesService,
                    projs: projectionsService,
                    games: gamesService
                )
                await BKSAppScaffold.registerForPushNotifications()
                await subscriptionService.refreshEntitlement()
                await subscriptionService.fetchProducts()
            }}
            .onReceive(
                NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            ) {{ _ in
                analyticsAdapter.logEvent(AnalyticsEvent.appBackgrounded, parameters: nil)
                DataRefreshTask.scheduleIfNeeded(identifier: DataRefreshTaskID.identifier)
            }}
            .onReceive(
                NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            ) {{ _ in
                analyticsAdapter.logEvent(AnalyticsEvent.appForegrounded, parameters: nil)
            }}
            .onReceive(
                NotificationCenter.default.publisher(for: DataRefreshTask.dataDidRefreshNotification)
            ) {{ _ in
                boardStore.send(.refreshRequested)
            }}
            .onChange(of: boardStore.state.loadState.isLoading) {{ wasLoading, nowLoading in
                if wasLoading, !nowLoading, isErasingCache {{
                    isErasingCache = false
                }}
            }}
            .preferredColorScheme(.dark)
        }}
    }}

    // MARK: - Prefetch

    private static func prefetch(
        opps: OpportunitiesServiceProtocol,
        projs: ProjectionsServiceProtocol,
        games: GamesServiceProtocol
    ) async {{
        let log = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
            category: "AppLifecycle"
        )
        await withTaskGroup(of: Void.self) {{ group in
            group.addTask {{
                do {{
                    let result = try await opps.fetchOpportunities()
                    log.info("Prefetched \\(result.opportunities.count, privacy: .public) opportunities")
                }} catch {{
                    log.error("Opportunities prefetch failed: \\(error.diagnosticDescription, privacy: .public)")
                }}
            }}
            group.addTask {{
                do {{
                    let projections = try await projs.fetchProjections()
                    log.info("Prefetched \\(projections.count, privacy: .public) projections")
                }} catch {{
                    log.error("Projections prefetch failed: \\(error.diagnosticDescription, privacy: .public)")
                }}
            }}
            group.addTask {{
                do {{
                    let schedule = try await games.fetchTodaySchedule()
                    log.info("Prefetched today schedule: \\(schedule.gameCount, privacy: .public) game(s)")
                }} catch {{
                    log.error("Today schedule prefetch failed: \\(error.diagnosticDescription, privacy: .public)")
                }}
            }}
        }}
    }}

    // MARK: - Cache erase

    private func eraseCachedData() {{
        isErasingCache = true
        do {{
            try storage.deleteAll(from: .file)
        }} catch {{}}
        boardStore.send(.refreshRequested)
    }}

    // MARK: - Subscription consent

    private func subscriptionConsentView(for result: AuthResult) -> some View {{
        SubscriptionConsentView(
            title: String(localized: "consent.title", defaultValue: "Welcome to {app_name}"),
            subtitle: String(
                localized: "consent.subtitle",
                defaultValue: "Your subscription keeps the insights sharp all season."
            ),
            termsURL: URL(string: "https://www.blackkatt.ca/terms-of-service.html")!,
            privacyURL: URL(string: "https://www.blackkatt.ca/privacy-policy.html")!,
            promoCodeService: promoCodeService,
            subscriptionService: subscriptionService,
            onAccepted: {{
                saveConsentAccepted(to: storage)
                authStore.send(.signInSucceeded(result))
                pendingConsentResult = nil
                let opps = opportunitiesService
                let projs = projectionsService
                let games = gamesService
                Task {{ await Self.prefetch(opps: opps, projs: projs, games: games) }}
            }},
            termContent: {{ consentTermRows }}
        )
    }}

    @ViewBuilder
    private var consentTermRows: some View {{
        EmptyView()
    }}
}}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: BKSAppDelegate {{
    override func makeContainer() -> Container {{ Container.defaultContainer() }}

    override func fcmTopics(config: ConfigurationProtocol) -> [String] {{
        [config.value(for: .fcmGamedayTopic), config.value(for: .fcmPlayoffTopic)]
    }}

    override func shouldSuppressForegroundPush(eventRaw: String) -> Bool {{
        eventRaw == DataRefreshTask.SilentPushEvent.playersUpdate.rawValue
    }}

    override func preferenceKey(for fcmEvent: String) -> NotificationPreferenceKey? {{
        NotificationPreferenceKey(fcmEvent: fcmEvent)
    }}

    override func handleNotificationTap(eventRaw: String, userInfo: [AnyHashable: Any]) {{
        if let event = VisiblePushEvent(rawValue: eventRaw) {{
            NotificationCenter.default.post(
                name: PushNotificationNames.visiblePushTapped,
                object: event,
                userInfo: userInfo
            )
        }} else {{
            super.handleNotificationTap(eventRaw: eventRaw, userInfo: userInfo)
        }}
    }}

    override func handleSilentPush(eventRaw: String, userInfo: [AnyHashable: Any]) async {{
        guard
            let storage = container?.resolve(StorageProtocol.self),
            let opps = container?.resolve(OpportunitiesServiceProtocol.self),
            let projs = container?.resolve(ProjectionsServiceProtocol.self),
            let games = container?.resolve(GamesServiceProtocol.self)
        else {{ return }}
        await DataRefreshTask.handleSilentPush(
            userInfo: userInfo,
            storage: storage,
            fetchOpportunities: {{ _ = try await opps.fetchOpportunities(includeResting: true) }},
            fetchProjections: {{ _ = try await projs.fetchProjections() }},
            fetchSchedule: {{ _ = try await games.fetchTodaySchedule() }}
        )
    }}
}}
"""

bootstrap_container = header() + f"""\
import Alamofire
import BKSCore
import BKSUICore
import Swinject

// MARK: - Container

extension Container {{
    @MainActor
    static func defaultContainer() -> Container {{
        let container = Container()

        BKSContainerBuilder.registerCoreServices(
            on: container,
            subscriptionProductIDs: SubscriptionProductID.allCurrentProductIDs
        )

        container.registerSportConfiguration()
        container.registerSportServices()
        container.registerBoardStore()

        return container
    }}

    private func registerSportConfiguration() {{
        register(SportConfiguration.self) {{ _ in .{slug} }}.inObjectScope(.container)
    }}

    private func registerSportServices() {{
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
    }}

    @MainActor
    private func registerBoardStore() {{
        register(Store<BoardState, BoardIntent>.self) {{ resolver in
            let projectionService = resolver.require(ProjectionsServiceProtocol.self)
            let opportunityService = resolver.require(OpportunitiesServiceProtocol.self)
            let gamesService = resolver.require(GamesServiceProtocol.self)
            let analysisService = resolver.require(DailyAnalysisServiceProtocol.self)
            let positionMap = resolver.require(SportConfiguration.self).positionMap
            return MainActor.assumeIsolated {{
                Store(
                    initial: BoardState(),
                    reduce: BoardState.makeReduce(
                        projectionService: projectionService,
                        opportunityService: opportunityService,
                        gamesService: gamesService,
                        analysisService: analysisService,
                        positionMap: positionMap
                    )
                )
            }}
        }}
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

bootstrap_dir = os.path.join(out_dir, "App/Sources/App/Bootstrap")
write(os.path.join(bootstrap_dir, f"{type_prefix}App.swift"), bootstrap_app)
write(os.path.join(bootstrap_dir, "DependencyContainer.swift"), bootstrap_container)
write(os.path.join(bootstrap_dir, "FirebaseAnalyticsAdapter.swift"), bootstrap_analytics)

# ─────────────────────────────────────────────────────────────────────────────
# 9a. AppShell.swift
# ─────────────────────────────────────────────────────────────────────────────

app_shell = header() + f"""\
import SwiftUI
import BKSCore
import BKSUICore

struct {swift_name}AppShell: View {{
    @ObservedObject var boardStore: Store<BoardState, BoardIntent>
    @ObservedObject var profileStore: Store<ProfileState, ProfileIntent>
    let credential: StoredCredential
    let promoCodeService: PromoCodeServiceProtocol
    let activityService: any ActivityFeedServiceProtocol
    @Binding var isErasingCache: Bool
    let onEraseCachedData: () -> Void
    @EnvironmentObject var networkMonitor: NetworkMonitor

    var body: some View {{
        AppShell(
            isOnline: networkMonitor.isConnected,
            isErasingCache: $isErasingCache,
            isBoardLoading: boardStore.state.loadState.isLoading
        ) {{
            BoardView(
                store: boardStore,
                credential: credential,
                profileStore: profileStore,
                promoCodeService: promoCodeService,
                activityService: activityService,
                onEraseCachedData: onEraseCachedData
            )
        }}
    }}
}}
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

# ─────────────────────────────────────────────────────────────────────────────────
# 9f. Board Feature
#
#  The Board is the primary sport-specific aggregation feature. It combines
#  opportunities, projections, and game data into a single ranked slate view.
#
#  Files generated here are STUBS with correct structure and service wiring.
#  Sport-specific logic (filters, badges, detail cards, entry builder) is
#  added post-generation.
#
#  Structure:
#    Features/Board/Models/   BoardEntry.swift, BoardEntryBuilder.swift
#    Features/Board/Store/    BoardState.swift, BoardIntent.swift
#    Features/Board/Views/    BoardView.swift
#    Features/Profile/Views/  ProfileContainerView.swift, NotificationsDetailView.swift
#    Features/PromoCode/      (empty — BKSUICore owns the logic)
#    Features/Subscription/   (empty — BKSUICore owns the logic)
# ─────────────────────────────────────────────────────────────────────────────────

board_models_dir  = os.path.join(out_dir, "App/Sources/Features/Board/Models")
board_store_dir   = os.path.join(out_dir, "App/Sources/Features/Board/Store")
board_views_dir   = os.path.join(out_dir, "App/Sources/Features/Board/Views")
profile_views_dir = os.path.join(out_dir, "App/Sources/Features/Profile/Views")

# ── BoardEntry.swift ───────────────────────────────────────────────────────────────────

board_entry_swift = header() + f"""import Foundation
import BKSCore

// MARK: - BoardEntry
//
// Composite model combining opportunities, projections, and game data
// into a single display-ready record.
// Add sport-specific fields below the Sport-specific marker.

struct BoardEntry: Identifiable, Equatable, Hashable {{
    let id: String
    let displayName: String
    let team: String
    let position: String?
    let headshotURL: URL?

    // Tonight's game
    let opponentAbbr: String?
    let isHome: Bool?
    let isPlayingTonight: Bool

    // Projection layer
    let projectedScore: Double?
    let fpFloor: Double?
    let fpCeiling: Double?
    let projectionTier: TierLevel?
    let confidenceScore: Double?

    // Opportunity layer
    let opportunityScore: Double?
    let opportunityTier: TierLevel?
    let isTopPick: Bool
    let topPickRank: Int?

    // Status
    let injuryStatus: InjuryStatus?
    let playerTier: TierLevel?
    let seasonGames: Int?

    // MARK: - Sport-specific fields
    // Add fields here that are unique to this sport's board display.
}}
"""

# ── BoardEntryBuilder.swift ──────────────────────────────────────────────────────────

board_entry_builder_swift = header() + f"""import Foundation
import BKSCore

// MARK: - BoardEntryBuilder
//
// Combines raw service responses into BoardEntry display models.
// Implement buildEntries() with sport-specific merge logic.

enum BoardEntryBuilder {{

    /// Merges opportunities, projections, and game data into ranked BoardEntry records.
    static func buildEntries(
        opportunities: OpportunitiesResult,
        projections: [Projection],
        games: TodaySchedule,
        sportConfiguration: SportConfiguration
    ) -> [BoardEntry] {{
        // TODO: implement sport-specific entry building
        // Pattern:
        //   1. Index projections by player ID
        //   2. For each opportunity, find matching projection + game
        //   3. Construct BoardEntry merging all three data sources
        //   4. Sort by topPickRank, then opportunityScore
        return []
    }}
}}
"""

# ── BoardIntent.swift ───────────────────────────────────────────────────────────────

board_intent_swift = header() + f"""import SwiftUI
import BKSCore

// MARK: - BoardLoadResult

struct BoardLoadResult {{
    let entries: [BoardEntry]
    let games: [ScheduledGame]
    let lockTime: Date?
    let seasonMode: SeasonMode
    let gameOdds: [String: GameOdds]
    let serverDateString: String?
    let dailyAnalysis: DailyAnalysis?
}}

// MARK: - BoardViewMode

enum BoardViewMode: String {{
    case flat
    case byPosition
}}

// MARK: - BoardIntent

enum BoardIntent: CancellableIntent {{
    case onAppear
    case refreshRequested
    case entriesLoaded(BoardLoadResult)
    case loadFailed(Error)
    case searchTextChanged(String)
    case positionFilterChanged(String?)
    case tierFilterChanged(TierLevel?)
    case viewModeChanged(BoardViewMode)
    case navigationPathChanged(NavigationPath)
    case playoffNotificationTapped(VisiblePushEvent, [AnyHashable: Any])

    var cancelsInFlightWork: Bool {{
        switch self {{
        case .navigationPathChanged, .searchTextChanged, .positionFilterChanged,
             .tierFilterChanged, .viewModeChanged, .playoffNotificationTapped:
            false
        default:
            true
        }}
    }}
}}
"""

# ── BoardState.swift ────────────────────────────────────────────────────────────────

board_state_swift = header() + f"""import OSLog
import BKSCore
import SwiftUI

// MARK: - BoardState

struct BoardState {{
    var navigationPath = NavigationPath()
    var loadState: ViewState<[BoardEntry]> = .idle
    var allEntries: [BoardEntry] = []
    var filteredEntries: [BoardEntry] = []
    var searchText = ""
    var selectedPosition: String?
    var selectedTier: TierLevel?
    var lastUpdated: Date?
    var lockTime: Date?
    var gameCount: Int = 0
    var todayGames: [ScheduledGame] = []
    var seasonMode: SeasonMode = .regularSeason
    var gameOdds: [String: GameOdds] = [:]
    var serverDateString: String?
    var viewMode: BoardViewMode = .byPosition
    var groupedEntries: [(position: String, picks: [BoardEntry])] = []
    var dailyAnalysis: DailyAnalysis?

    private static let stalenessThreshold = CacheFreshness.defaultThreshold

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "BoardState"
    )

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func makeReduce(
        projectionService: ProjectionsServiceProtocol,
        opportunityService: OpportunitiesServiceProtocol,
        gamesService: GamesServiceProtocol,
        analysisService: DailyAnalysisServiceProtocol,
        positionMap: SportPositionMap
    ) -> Reduce<Self, BoardIntent> {{
        {{ state, intent in
            switch intent {{
            case .onAppear:
                let isNewDay = state.lastUpdated.map {{ !Calendar.current.isDateInToday($0) }} ?? false
                if !isNewDay,
                   CacheFreshness.isFresh(lastUpdated: state.lastUpdated, threshold: stalenessThreshold),
                   case .loaded = state.loadState
                {{
                    return .none
                }}
                state.loadState = .loading
                return .run {{ send in
                    do {{
                        async let opps    = opportunityService.fetchOpportunities()
                        async let projs   = projectionService.fetchProjections()
                        async let sched   = gamesService.fetchTodaySchedule()
                        async let analysis = analysisService.fetchDailyAnalysis()
                        let (o, p, s, a) = try await (opps, projs, sched, analysis)
                        let entries = BoardEntryBuilder.buildEntries(
                            opportunities: o,
                            projections: p,
                            games: s,
                            sportConfiguration: SportConfiguration.{slug}
                        )
                        await send(.entriesLoaded(BoardLoadResult(
                            entries: entries,
                            games: s.games,
                            lockTime: s.lockTime,
                            seasonMode: s.seasonMode,
                            gameOdds: s.gameOdds,
                            serverDateString: s.serverDateString,
                            dailyAnalysis: a
                        )))
                    }} catch {{
                        await send(.loadFailed(error))
                    }}
                }}

            case .refreshRequested:
                state.loadState = .loading
                return .run {{ send in
                    do {{
                        async let opps    = opportunityService.fetchOpportunities(includeResting: true)
                        async let projs   = projectionService.fetchProjections()
                        async let sched   = gamesService.fetchTodaySchedule()
                        async let analysis = analysisService.fetchDailyAnalysis()
                        let (o, p, s, a) = try await (opps, projs, sched, analysis)
                        let entries = BoardEntryBuilder.buildEntries(
                            opportunities: o,
                            projections: p,
                            games: s,
                            sportConfiguration: SportConfiguration.{slug}
                        )
                        await send(.entriesLoaded(BoardLoadResult(
                            entries: entries,
                            games: s.games,
                            lockTime: s.lockTime,
                            seasonMode: s.seasonMode,
                            gameOdds: s.gameOdds,
                            serverDateString: s.serverDateString,
                            dailyAnalysis: a
                        )))
                    }} catch {{
                        await send(.loadFailed(error))
                    }}
                }}

            case let .entriesLoaded(result):
                state.allEntries       = result.entries
                state.todayGames       = result.games
                state.lockTime         = result.lockTime
                state.seasonMode       = result.seasonMode
                state.gameOdds         = result.gameOdds
                state.serverDateString = result.serverDateString
                state.dailyAnalysis    = result.dailyAnalysis
                state.gameCount        = result.games.count
                state.lastUpdated      = .now
                state.loadState        = .loaded(result.entries)
                return .none

            case let .loadFailed(error):
                logger.error("Board load failed: \\(error.localizedDescription, privacy: .public)")
                state.loadState = .failed(error)
                return .none

            case let .searchTextChanged(text):
                state.searchText = text
                return .none

            case let .positionFilterChanged(position):
                state.selectedPosition = position
                return .none

            case let .tierFilterChanged(tier):
                state.selectedTier = tier
                return .none

            case let .viewModeChanged(mode):
                state.viewMode = mode
                return .none

            case let .navigationPathChanged(path):
                state.navigationPath = path
                return .none

            case .playoffNotificationTapped:
                // TODO: handle playoff notification deep-link routing
                return .none
            }}
        }}
    }}
}}
"""

# ── BoardView.swift ──────────────────────────────────────────────────────────────────

board_view_swift = header() + f"""import BKSCore
import BKSUICore
import SwiftUI

// MARK: - BoardView
//
// Primary sport feature view. Displays today's ranked player slate.
// Replace the placeholder list and NavigationLink destination with
// sport-specific card and detail views post-generation.

struct BoardView: View {{
    @ObservedObject var store: Store<BoardState, BoardIntent>
    let credential: StoredCredential
    @ObservedObject var profileStore: Store<ProfileState, ProfileIntent>
    let promoCodeService: PromoCodeServiceProtocol
    let activityService: any ActivityFeedServiceProtocol
    let onEraseCachedData: () -> Void

    var body: some View {{
        NavigationStack(path: Binding(
            get: {{ store.state.navigationPath }},
            set: {{ store.send(.navigationPathChanged($0)) }}
        )) {{
            Group {{
                switch store.state.loadState {{
                case .idle, .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case let .loaded(entries):
                    if entries.isEmpty {{
                        ContentUnavailableView(
                            String(localized: "board.empty", defaultValue: "No picks today"),
                            systemImage: "sportscourt"
                        )
                    }} else {{
                        entryList(entries)
                    }}

                case let .failed(error):
                    ContentUnavailableView(
                        String(localized: "board.error", defaultValue: "Could not load picks"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(error.localizedDescription)
                    )
                }}
            }}
            .navigationTitle(String(localized: "board.title", defaultValue: "Today's Picks"))
            .navigationDestination(for: BoardEntry.self) {{ entry in
                // TODO: replace with sport-specific detail view
                Text(entry.displayName)
            }}
            .navigationDestination(for: String.self) {{ destination in
                if destination == "profile" {{
                    ProfileContainerView(
                        credential: credential,
                        profileStore: profileStore,
                        promoCodeService: promoCodeService,
                        onEraseCachedData: onEraseCachedData
                    )
                }}
            }}
            .toolbar {{
                ToolbarItem(placement: .navigationBarTrailing) {{
                    Button {{ store.state.navigationPath.append("profile") }} label: {{
                        Image(systemName: "person.circle")
                    }}
                }}
            }}
        }}
        .task {{ store.send(.onAppear) }}
        .refreshable {{ store.send(.refreshRequested) }}
    }}

    private func entryList(_ entries: [BoardEntry]) -> some View {{
        List(entries) {{ entry in
            NavigationLink(value: entry) {{
                // TODO: replace with sport-specific card view
                VStack(alignment: .leading, spacing: 2) {{
                    Text(entry.displayName).font(.headline)
                    if let score = entry.projectedScore {{
                        Text(String(format: "%.1f DK pts", score))
                            .font(.caption).foregroundStyle(.secondary)
                    }}
                }}
            }}
        }}
    }}
}}
"""

# ── Profile feature ───────────────────────────────────────────────────────────────

profile_container_swift = header() + f"""import BKSCore
import BKSUICore
import SwiftUI

// MARK: - ProfileContainerView
//
// Sport-specific profile panel. Delegates to BKSProfileContainerView and
// injects the sport's notification preference detail view.

struct ProfileContainerView: View {{
    let credential: StoredCredential
    @ObservedObject var profileStore: Store<ProfileState, ProfileIntent>
    let promoCodeService: PromoCodeServiceProtocol
    let onEraseCachedData: () -> Void

    var body: some View {{
        BKSProfileContainerView(
            credential: credential,
            profileStore: profileStore,
            promoCodeService: promoCodeService,
            subscriptionGroupID: SubscriptionProductID.subscriptionGroupID,
            appName: String(localized: "app.name", defaultValue: "{app_name}"),
            onEraseCachedData: onEraseCachedData
        ) {{
            NotificationsDetailView(profileStore: profileStore)
        }}
    }}
}}
"""

notifications_detail_swift = header() + f"""import BKSCore
import BKSUICore
import SwiftUI

// MARK: - NotificationsDetailView
//
// Sport-specific notification preferences injected into BKSNotificationsView.
// Add Toggle rows here for each sport-specific NotificationPreferenceKey.

struct NotificationsDetailView: View {{
    @ObservedObject var profileStore: Store<ProfileState, ProfileIntent>

    var body: some View {{
        BKSNotificationsView(
            profileStore: profileStore,
            appName: String(localized: "app.name", defaultValue: "{app_name}")
        ) {{
            // TODO: add sport-specific notification toggles
            // Example from basketball:
            // Toggle(isOn: Binding(
            //     get: {{ profileStore.state.preferences.notificationPreferences.isEnabled(.playoffAlerts) }},
            //     set: {{ profileStore.send(.notificationPreferenceToggled(.playoffAlerts, $0)) }}
            // )) {{
            //     Label("Playoff Alerts", systemImage: "trophy.fill").foregroundStyle(.white)
            // }}
            EmptyView()
        }}
    }}
}}
"""

# ── Write all files ─────────────────────────────────────────────────────────────────────────

write(os.path.join(board_models_dir,  "BoardEntry.swift"),               board_entry_swift)
write(os.path.join(board_models_dir,  "BoardEntryBuilder.swift"),        board_entry_builder_swift)
write(os.path.join(board_store_dir,   "BoardIntent.swift"),              board_intent_swift)
write(os.path.join(board_store_dir,   "BoardState.swift"),               board_state_swift)
write(os.path.join(board_views_dir,   "BoardView.swift"),                board_view_swift)
write(os.path.join(profile_views_dir, "ProfileContainerView.swift"),     profile_container_swift)
write(os.path.join(profile_views_dir, "NotificationsDetailView.swift"),  notifications_detail_swift)

# Empty placeholder dirs — xcodegen requires paths to exist for group generation
write(os.path.join(out_dir, "App/Sources/Features/PromoCode/Store/.gitkeep"),    "")
write(os.path.join(out_dir, "App/Sources/Features/PromoCode/Views/.gitkeep"),    "")
write(os.path.join(out_dir, "App/Sources/Features/Subscription/Views/.gitkeep"), "")

# ─────────────────────────────────────────────────────────────────────────────
# 9. project.yml  (XcodeGen spec)
# ─────────────────────────────────────────────────────────────────────────────

pkg      = packages
bkscore_from  = pkg.get("bkscore",   {}).get("from", "1.0.1")
bksuicore_from = pkg.get("bksuicore", {}).get("from", "1.0.16")
swinject_from = pkg.get("swinject",  {}).get("from", "2.9.0")
firebase_from = pkg.get("firebaseSDK", {}).get("from", "11.0.0")
firebase_products = pkg.get("firebaseProducts", ["FirebaseAnalytics", "FirebaseAuth", "FirebaseAppCheck", "FirebaseFirestore", "FirebaseMessaging", "FirebaseInAppMessaging-Beta"])

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
      - path: Sources/App/Resources/InfoPlist.xcstrings
      - path: Sources/App/Resources/Localizable.xcstrings
      - path: Sources/App/Resources/PrivacyInfo.xcprivacy
      - path: Sources/App/Resources/Configuration.plist
      - path: Sources/App/Resources/GoogleService-Info.plist
      - path: Sources/App/Resources/{app_target}.storekit

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

version_xcconfig = """\
MARKETING_VERSION = 0.0.1
CURRENT_PROJECT_VERSION = 1
"""

debug_template = f"""\
// Debug.xcconfig — development configuration
// Copy this file to Debug.xcconfig and fill in your secret values.
// Debug.xcconfig is gitignored — do NOT commit it.

#include "Base.xcconfig"
#include "Version.xcconfig"

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
#include "Version.xcconfig"

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
write(os.path.join(out_dir, "App/Config/Version.xcconfig"), version_xcconfig)
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
\t\t<string>{bundle_id}.datarefresh</string>
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
\t<key>FirebaseAppDelegateProxyEnabled</key>
\t<false/>
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
\t\t<string>remote-notification</string>
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
# 10b. InfoPlist.xcstrings  (localised Info.plist strings)
# ─────────────────────────────────────────────────────────────────────────────

infoplist_xcstrings = f"""\
{{
  "sourceLanguage" : "en",
  "strings" : {{
    "CFBundleDisplayName" : {{
      "extractionState" : "manual",
      "localizations" : {{
        "en" : {{
          "stringUnit" : {{
            "state" : "translated",
            "value" : "{app_name}"
          }}
        }},
        "es" : {{
          "stringUnit" : {{
            "state" : "translated",
            "value" : "{app_name}"
          }}
        }},
        "fr-CA" : {{
          "stringUnit" : {{
            "state" : "translated",
            "value" : "{app_name}"
          }}
        }}
      }}
    }},
    "CFBundleName" : {{
      "extractionState" : "manual",
      "localizations" : {{
        "en" : {{
          "stringUnit" : {{
            "state" : "translated",
            "value" : "{app_name}"
          }}
        }},
        "es" : {{
          "stringUnit" : {{
            "state" : "translated",
            "value" : "{app_name}"
          }}
        }},
        "fr-CA" : {{
          "stringUnit" : {{
            "state" : "translated",
            "value" : "{app_name}"
          }}
        }}
      }}
    }},
    "NSHumanReadableCopyright" : {{
      "comment" : "Copyright (human-readable)",
      "extractionState" : "extracted_with_value",
      "localizations" : {{
        "en" : {{
          "stringUnit" : {{
            "state" : "new",
            "value" : "Copyright 2026 Black Katt Technologies Inc."
          }}
        }}
      }}
    }}
  }},
  "version" : "1.0"
}}
"""

write(os.path.join(out_dir, "App/Sources/App/Resources/InfoPlist.xcstrings"), infoplist_xcstrings)

# ─────────────────────────────────────────────────────────────────────────────
# 11. Configuration.plist  (runtime config — URLs baked in)
# ─────────────────────────────────────────────────────────────────────────────

config_plist = f"""\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>gameLogBaseURL</key>
\t<string>{gamelog_base}</string>
\t<key>opportunitiesIncludeResting</key>
\t<true/>
\t<key>getOpportunitiesURL</key>
\t<string>{opps_url}</string>
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
# 14b. StoreKit configuration stub
# ─────────────────────────────────────────────────────────────────────────────

storekit_stub = f"""\
{{
  "identifier" : "_{bundle_id}",
  "nonConsumableIAP" : [

  ],
  "nonRenewingSubscriptionIAP" : [

  ],
  "products" : [

  ],
  "settings" : {{

  }},
  "subscriptionGroups" : [
    {{
      "id" : "REPLACE_WITH_APP_STORE_GROUP_ID",
      "localizations" : [

      ],
      "name" : "{sub_group}",
      "subscriptions" : [
        {{
          "adHocOfferCodesAllowed" : true,
          "displayPrice" : "2.99",
          "familySharable" : false,
          "groupNumber" : 1,
          "internalID" : "REPLACE_WITH_INTERNAL_ID",
          "introductoryOffer" : null,
          "localizations" : [
            {{
              "description" : "{app_name} subscription",
              "displayName" : "{app_name}",
              "locale" : "en_US"
            }}
          ],
          "offerCodes" : [

          ],
          "paymentMode" : "SUBSCRIPTION",
          "productID" : "{sub_product_id}",
          "promotionalOffers" : [

          ],
          "recurringSubscriptionPeriod" : "P1M",
          "referenceName" : "{app_name} Basic Monthly",
          "subscriptionGroupID" : "REPLACE_WITH_APP_STORE_GROUP_ID",
          "type" : "RecurringSubscription"
        }}
      ]
    }}
  ],
  "version" : {{
    "formatVersion" : 2
  }}
}}
"""

write(os.path.join(out_dir, f"App/Sources/App/Resources/{app_target}.storekit"), storekit_stub)

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
- **Build**: `xcodebuild -scheme {app_target} -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16'`
- **Test**: `xcodebuild test -scheme {app_target} -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16'`
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
    ├── Board/          — Primary sport feature (stub — customise post-generation)
    │   ├── Models/ — BoardEntry, BoardEntryBuilder
    │   ├── Store/  — BoardState, BoardIntent
    │   └── Views/  — BoardView, GameLogViews
    ├── Profile/
    │   └── Views/  — ProfileContainerView, NotificationsDetailView
    ├── PromoCode/      — BKSUICore owns logic; directories only
    └── Subscription/   — BKSUICore owns logic; directories only
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
# workspace.yml  (xcodegen workspace config)
# ─────────────────────────────────────────────────────────────────────────────

workspace_yml = f"""\
name: {type_prefix}
fileGroups:
  - .swiftlint.yml
  - .swiftformat
options:
  groupOrdering:
    - order: [App]
projects:
  App:
    path: App
"""

write(os.path.join(out_dir, "workspace.yml"), workspace_yml)

# ─────────────────────────────────────────────────────────────────────────────
# generate.sh  (project regeneration + Package.resolved sync)
# ─────────────────────────────────────────────────────────────────────────────

generate_sh = f"""\
#!/usr/bin/env bash
# generate.sh — Regenerate the Xcode project and sync Package.resolved.
#
# Usage (from repo root):
#   ./generate.sh
#
# What it does:
#   1. Runs xcodegen against App/project.yml
#   2. Syncs the workspace Package.resolved into the xcodeproj's inner
#      project.xcworkspace so both files agree on package versions.
#      Without this sync Xcode reports "package dependencies screwed up"
#      after every xcodegen run because the inner file is overwritten
#      with whatever was last committed inside the xcodeproj bundle.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
APP_DIR="$REPO_ROOT/App"
WORKSPACE_RESOLVED="$REPO_ROOT/{type_prefix}.xcworkspace/xcshareddata/swiftpm/Package.resolved"
INNER_RESOLVED="$APP_DIR/{type_prefix}.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

# ── 1. Generate xcodeproj ─────────────────────────────────────────────────────

echo "Generating xcodeproj..."
cd "$APP_DIR"
xcodegen generate --spec project.yml

# ── 2. Sync Package.resolved ──────────────────────────────────────────────────

if [[ -f "$WORKSPACE_RESOLVED" ]]; then
    cp "$WORKSPACE_RESOLVED" "$INNER_RESOLVED"
    echo "Synced Package.resolved to xcodeproj"
else
    echo "Warning: Workspace Package.resolved not found — skipping sync"
    echo "         Run 'xcodebuild -resolvePackageDependencies' to create it."
fi

echo "Done."
"""

generate_sh_path = os.path.join(out_dir, "generate.sh")
write(generate_sh_path, generate_sh)
os.chmod(generate_sh_path, 0o755)

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
print(f"  App/Sources/App/Bootstrap/FirebaseAnalyticsAdapter.swift")
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
print(f"  App/Sources/Core/Utilities/VisiblePushEvent.swift")
print(f"  App/Sources/Core/Utilities/NotificationPreferenceKey+{swift_name}.swift")
print(f"  App/Sources/Core/Utilities/NotificationPreferenceKey+FCM.swift")
print(f"  App/Sources/Core/Utilities/Filterable+{swift_name}.swift")
print(f"  App/Sources/Core/Utilities/PlayerLookup.swift")
print()
print("Board feature (stub — add sport-specific logic post-generation):")
print(f"  App/Sources/Features/Board/Models/BoardEntry.swift")
print(f"  App/Sources/Features/Board/Models/BoardEntryBuilder.swift")
print(f"  App/Sources/Features/Board/Store/BoardIntent.swift")
print(f"  App/Sources/Features/Board/Store/BoardState.swift")
print(f"  App/Sources/Features/Board/Views/BoardView.swift")
print()
print("Profile feature:")
print(f"  App/Sources/Features/Profile/Views/ProfileContainerView.swift")
print(f"  App/Sources/Features/Profile/Views/NotificationsDetailView.swift")
print()
print("PromoCode + Subscription (BKSUICore owns logic — directories only):")
print(f"  App/Sources/Features/PromoCode/Store/  (empty)")
print(f"  App/Sources/Features/PromoCode/Views/  (empty)")
print(f"  App/Sources/Features/Subscription/Views/ (empty)")
print()
print("Project infrastructure:")
print(f"  App/project.yml")
print(f"  App/Config/Base.xcconfig")
print(f"  App/Config/Version.xcconfig")
print(f"  App/Config/Debug.xcconfig                        ← gitignored; add real secrets")
print(f"  App/Config/Debug.xcconfig.template")
print(f"  App/Config/Release.xcconfig                      ← gitignored; add real secrets")
print(f"  App/Config/Release.xcconfig.template")
print(f"  App/Tests/.gitkeep")
print(f"  App/Config/{app_target}Tests.xcconfig")
print(f"  App/Sources/App/Resources/Info.plist")
print(f"  App/Sources/App/Resources/InfoPlist.xcstrings")
print(f"  App/Sources/App/Resources/Configuration.plist    ← runtime API URLs")
print(f"  App/Sources/App/Resources/{app_target}.entitlements")
print(f"  App/Sources/App/Resources/PrivacyInfo.xcprivacy")
print(f"  App/Sources/App/Resources/GoogleService-Info.plist  ← placeholder, replace with real Firebase config")
print(f"  App/Sources/App/Resources/{app_target}.storekit   ← replace REPLACE_WITH_* values with real App Store IDs")
print(f"  .swiftlint.yml")
print(f"  .swiftformat")
print(f"  .gitignore")
print(f"  CLAUDE.md")
print(f"  workspace.yml")
print(f"  generate.sh")
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
        "revision" : "f684c8d51df7e77c8c4da52b6cdee8db12e2d8dc",
        "version" : "5.12.0"
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
