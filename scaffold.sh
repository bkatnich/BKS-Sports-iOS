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
#   GameLogViews.swift
#   Features/Board/ — BoardEntry, BoardEntryBuilder, BoardState, BoardIntent, BoardView (stubs)
#   Features/Profile/ — ProfileContainerView, NotificationsDetailView
#   workspace.yml, generate.sh, project.yml, xcconfig files, Info.plist, storekit stub
#
# Requirements: python3, pyyaml (pip3 install pyyaml)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── argument check ───────────────────────────────────────────────────────────

DRY_RUN=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

if [[ ${#POSITIONAL[@]} -lt 1 ]]; then
    echo "Usage: $0 [--dry-run] <sport-slug> [output-dir]"
    echo "  e.g. $0 baseball"
    echo "  e.g. $0 baseball /path/to/BKS-Baseball-Client-iOS"
    echo "  e.g. $0 --dry-run baseball    (print what would be generated, no writes)"
    exit 1
fi

SPORT_SLUG="${POSITIONAL[0]}"
YAML_FILE="$SCRIPT_DIR/sports/${SPORT_SLUG}.yaml"

if [[ ! -f "$YAML_FILE" ]]; then
    echo "Error: sport spec not found at $YAML_FILE"
    echo "Create it first — see sports/basketball.yaml as a reference."
    exit 1
fi

# Optional explicit output directory; defaults to auto-derived sibling repo
OUTPUT_DIR="${POSITIONAL[1]:-}"

if [[ $DRY_RUN -eq 1 ]]; then
    echo "🔍 Dry run — no files will be written."
fi

# ── python helper: parse yaml and emit scaffold ───────────────────────────────

SCRIPT_DIR="$SCRIPT_DIR" SPORT_SLUG="$SPORT_SLUG" OUTPUT_DIR="$OUTPUT_DIR" DRY_RUN="$DRY_RUN" python3 << 'PYEOF'
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
DRY_RUN     = os.environ.get("DRY_RUN", "0") == "1"

# ── load spec ─────────────────────────────────────────────────────────────────

with open(os.path.join(SCRIPT_DIR, "sports", f"{SPORT_SLUG}.yaml")) as f:
    spec = yaml.safe_load(f)

# ── validate required top-level sections ──────────────────────────────────────

required_sections = ["sport", "positions", "tiers", "scoring", "api", "gamelog", "fcm", "subscription"]
missing_sections  = [k for k in required_sections if k not in spec]
if missing_sections:
    sys.exit(f"ERROR: {SPORT_SLUG}.yaml is missing required section(s): {', '.join(missing_sections)}")

required_sport_keys = ["name", "slug", "prefix", "appName", "bundleId", "deploymentTarget", "xcodeVersion", "swiftVersion"]
missing_sport_keys  = [k for k in required_sport_keys if k not in spec.get("sport", {})]
if missing_sport_keys:
    sys.exit(f"ERROR: {SPORT_SLUG}.yaml sport section is missing required key(s): {', '.join(missing_sport_keys)}")

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
gamelog         = spec.get("gamelog", {})
# isDNPCondition from YAML is intentionally not used in code generation.
# isDNP is hardcoded in the GameEntry+Sport template using raw dict access
# because atBats is a computed property, not a stored stat key.
season       = spec.get("season", {})
has_playoffs = season.get("hasPlayoffs", False)
season_modes = season.get("modes", ["regular_season", "playoffs", "offseason"])

def season_mode_case(raw):
    """Convert a snake_case mode string to a Swift enum case declaration."""
    parts = raw.split("_")
    camel = parts[0] + "".join(p.title() for p in parts[1:])
    if camel == raw:
        return f'    case {camel}'
    return f'    case {camel} = "{raw}"'

season_mode_cases = "\n".join(season_mode_case(m) for m in season_modes)

swift_name  = name.replace(" ", "")         # "BaseBall" -> "Baseball"
type_prefix = f"{prefix}{swift_name}"       # "BKSBaseball"
calc_name   = scoring.get("calculator", f"{swift_name}ScoringCalculator")
platform_label = (
    scoring.get("platform", "DraftKings")
    .replace("draftkings", "DraftKings")
    .replace("fanduel", "FanDuel")
)
scoring_platform = scoring.get("platform", "dk")   # raw platform slug (e.g. "dk", "fd")

# Output directory: explicit arg or auto-derived sibling of this repo
if OUTPUT_DIR:
    out_dir = os.path.abspath(OUTPUT_DIR)
else:
    repo_parent = os.path.dirname(SCRIPT_DIR)
    out_dir     = os.path.join(repo_parent, f"{prefix}-{name.replace(' ', '')}-Client-iOS")

def mkdir(path):
    os.makedirs(path, exist_ok=True)

def write(path, content):
    rel = os.path.relpath(path, out_dir)
    if DRY_RUN:
        print(f"  would write  {rel}")
        return
    mkdir(os.path.dirname(path))
    with open(path, "w") as f:
        f.write(content)
    print(f"  wrote  {rel}")

def write_if_absent(path, content):
    """Write only when the file does not already exist.
    Use this for files that require manual sport-specific implementation
    so that re-running the scaffold never overwrites hand-written code."""
    rel = os.path.relpath(path, out_dir)
    if DRY_RUN:
        if os.path.exists(path):
            print(f"  would skip   {rel}  (already exists)")
        else:
            print(f"  would write  {rel}  (stub — requires manual implementation)")
        return
    mkdir(os.path.dirname(path))
    if os.path.exists(path):
        print(f"  skip   {rel}  (already exists — manual implementation preserved)")
        return
    with open(path, "w") as f:
        f.write(content)
    print(f"  wrote  {rel}  (stub — requires manual implementation)")

# ── copyright header ──────────────────────────────────────────────────────────

def header(year=2026):
    return f"// Copyright {year} Black Katt Technologies Inc.\n\n"

# ─────────────────────────────────────────────────────────────────────────────
# 1. ConfigurationKeys+<Sport>.swift
# ─────────────────────────────────────────────────────────────────────────────

players_api      = api.get("players", {})
opps_api         = api.get("opportunities", {})
proj_api         = api.get("projections", {})
board_api        = api.get("board", {})
gamelog_api      = api.get("gameLog", {})
external_id_key  = api.get("externalPersonIDKey", "external_person_id")

opp_params        = opps_api.get("params", {})
ou_push_threshold = str(opp_params.get("ouPushThreshold", "0.5"))

players_url      = players_api.get("url", "")
opps_url         = opps_api.get("url", "")
proj_url         = proj_api.get("url", "")
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
import OSLog

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
        defaultValue: "{scoring_platform}"
    )
    static let ouPushThreshold = ConfigurationKey(
        name: "ouPushThreshold",
        defaultValue: "{ou_push_threshold}"
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
        defaultValue: "UNCONFIGURED_GET_PLAYERS_URL",
        infoPlistKey: "GetPlayersURL"
    )
    static let getOpportunitiesURL = ConfigurationKey(
        name: "getOpportunitiesURL",
        defaultValue: "UNCONFIGURED_GET_OPPORTUNITIES_URL",
        infoPlistKey: "GetOpportunitiesURL"
    )
    static let getBoardURL = ConfigurationKey(
        name: "getBoardURL",
        defaultValue: "UNCONFIGURED_GET_BOARD_URL",
        infoPlistKey: "GetBoardURL"
    )
    static let getProjectionsURL = ConfigurationKey(
        name: "getProjectionsURL",
        defaultValue: "UNCONFIGURED_GET_PROJECTIONS_URL",
        infoPlistKey: "GetProjectionsURL"
    )
    static let getLeagueStateURL = ConfigurationKey(
        name: "getLeagueStateURL",
        defaultValue: "UNCONFIGURED_GET_LEAGUE_STATE_URL",
        infoPlistKey: "GetLeagueStateURL"
    )
    static let getPlayoffBracketURL = ConfigurationKey(
        name: "getPlayoffBracketURL",
        defaultValue: "UNCONFIGURED_GET_PLAYOFF_BRACKET_URL",
        infoPlistKey: "GetPlayoffBracketURL"
    )
    static let getDailyAnalysisURL = ConfigurationKey(
        name: "getDailyAnalysisURL",
        defaultValue: "UNCONFIGURED_GET_DAILY_ANALYSIS_URL",
        infoPlistKey: "GetDailyAnalysisURL"
    )
    static let getActivityFeedURL = ConfigurationKey(
        name: "getActivityFeedURL",
        defaultValue: "UNCONFIGURED_GET_ACTIVITY_FEED_URL",
        infoPlistKey: "GetActivityFeedURL"
    )
    static let updateUserPreferencesURL = ConfigurationKey(
        name: "updateUserPreferencesURL",
        defaultValue: "UNCONFIGURED_UPDATE_USER_PREFERENCES_URL",
        infoPlistKey: "UpdateUserPreferencesURL"
    )
    static let redeemPromoCodeURL = ConfigurationKey(
        name: "redeemPromoCodeURL",
        defaultValue: "UNCONFIGURED_REDEEM_PROMO_CODE_URL",
        infoPlistKey: "RedeemPromoCodeURL"
    )
    static let termsOfServiceURL = ConfigurationKey(
        name: "termsOfServiceURL",
        defaultValue: "https://www.blackkatt.ca/terms-of-service.html"
    )
    static let privacyPolicyURL = ConfigurationKey(
        name: "privacyPolicyURL",
        defaultValue: "https://www.blackkatt.ca/privacy-policy.html"
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

// MARK: - URL configuration guard

private let configLogger = os.Logger(subsystem: "{bundle_id}", category: "Configuration")

extension ConfigurationProtocol {{
    /// Returns the string value for a URL key, logging a critical error if it is still a placeholder.
    func checkedURL(for key: ConfigurationKey<String>) -> String {{
        let url = value(for: key)
        if url.hasPrefix("UNCONFIGURED_") {{
            let xconfigKey = key.infoPlistKey ?? key.name
            configLogger.critical("⚠️ URL NOT CONFIGURED: '\\(key.name, privacy: .public)' is still a placeholder. Set \\(xconfigKey, privacy: .public) in your xcconfig.")
        }}
        return url
    }}
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Utilities", f"ConfigurationKeys+{swift_name}.swift"), config_keys)

# ─────────────────────────────────────────────────────────────────────────────
# 1b. VisiblePushEvent.swift
#     Visible (banner) push notification event types for this sport.
#     Cases drive deep-link routing in AppDelegate.handleNotificationTap.
# ─────────────────────────────────────────────────────────────────────────────

visible_push_events = fcm.get("visiblePushEvents", [])

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
"""

write(os.path.join(out_dir, "App/Sources/Core/Utilities", "VisiblePushEvent.swift"), visible_push_swift)

# ─────────────────────────────────────────────────────────────────────────────
# 1c. NotificationPreferenceKey+<Sport>.swift
#     Sport-specific notification preference key and accessor.
# ─────────────────────────────────────────────────────────────────────────────

notif_prefs = fcm.get("notificationPreferences", [])

notif_pref_key_swift = header() + f"""\
import BKSCore

// MARK: - {name} notification preference keys

extension NotificationPreferenceKey {{
    /// Playoff series/elimination alerts — {slug}-specific.
    public static let playoffAlerts = NotificationPreferenceKey(rawValue: "playoff_alerts")
"""
for pref in notif_prefs:
    notif_pref_key_swift += f"""\
    /// {pref.get('label', pref['key'])} — {slug}-specific.
    public static let {pref['key']} = NotificationPreferenceKey(rawValue: "{pref['rawValue']}")
"""
notif_pref_key_swift += f"""\
}}

// MARK: - {name} preference accessors

extension NotificationPreferences {{
    /// Playoff alerts preference. Stored in `sportPreferences["playoff_alerts"]`.
    public var playoffAlerts: Bool? {{
        get {{ sportPreferences[NotificationPreferenceKey.playoffAlerts.rawValue] }}
        set {{ sportPreferences[NotificationPreferenceKey.playoffAlerts.rawValue] = newValue }}
    }}
"""
for pref in notif_prefs:
    notif_pref_key_swift += f"""\
    /// {pref.get('label', pref['key'])} preference.
    public var {pref['key']}: Bool? {{
        get {{ sportPreferences[NotificationPreferenceKey.{pref['key']}.rawValue] }}
        set {{ sportPreferences[NotificationPreferenceKey.{pref['key']}.rawValue] = newValue }}
    }}
"""
notif_pref_key_swift += "}\n"

write(os.path.join(out_dir, "App/Sources/Core/Utilities", f"NotificationPreferenceKey+{swift_name}.swift"), notif_pref_key_swift)

# ─────────────────────────────────────────────────────────────────────────────
# 1d. NotificationPreferenceKey+FCM.swift
#     Maps raw FCM event strings → preference keys for this sport.
# ─────────────────────────────────────────────────────────────────────────────

if visible_push_events:
    from collections import defaultdict as _defaultdict
    pref_to_events = _defaultdict(list)
    for e in visible_push_events:
        pref_key = e.get("preferenceKey", "playoffAlerts")
        pref_to_events[pref_key].append(e["rawValue"])
    fcm_case_lines = []
    for pref_key, raw_values in pref_to_events.items():
        quoted = ", ".join(f'"{v}"' for v in raw_values)
        fcm_case_lines.append(f'        case {quoted}:\n            self = .{pref_key}')
    fcm_cases = "\n".join(fcm_case_lines)
else:
    fcm_cases = ""

notif_fcm_swift = header() + f"""\
import BKSCore

extension NotificationPreferenceKey {{
    /// Maps FCM event strings to preference keys for the {name} app.
    /// Sport-specific playoff events are handled here; core events delegate to BKSCore.
    init?(fcmEvent: String) {{
        switch fcmEvent {{
{fcm_cases}
        default:
            guard let key = NotificationPreferenceKey(coreEvent: fcmEvent) else {{ return nil }}
            self = key
        }}
    }}
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Utilities", "NotificationPreferenceKey+FCM.swift"), notif_fcm_swift)

fetch_coalescer_swift = f"""\
{header()}

import OSLog

// MARK: - FetchCoalescer

/// Actor that coalesces concurrent async fetch calls into a single in-flight Task.
///
/// When a second caller arrives while a fetch is already running, it awaits the
/// existing Task's result rather than spawning a new network request. This prevents
/// duplicate Cloud Run cold-starts when a silent push and the board's onAppear race.
actor FetchCoalescer<Value: Sendable> {{
    private var inflight: Task<Value, Error>?

    func run(
        logger: os.Logger,
        label: StaticString,
        work: @Sendable @escaping () async throws -> Value
    ) async throws -> Value {{
        if let existing = inflight {{
            logger.debug("\\(label, privacy: .public) — joining in-flight request")
            return try await existing.value
        }}
        let task = Task<Value, Error> {{ try await work() }}
        inflight = task
        defer {{ inflight = nil }}
        return try await task.value
    }}
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Utilities", "FetchCoalescer.swift"), fetch_coalescer_swift)

# DiagnosticLogger lives in BKSCore (Sources/Utilities/DiagnosticLogger.swift) as a public class.
# Do NOT generate a local copy — it would cause a duplicate symbol error.
# All call sites (DiagnosticLogger.error/warning) work via the BKSCore public API.

# ─────────────────────────────────────────────────────────────────────────────
# 2. SportPositionMap extension
# ─────────────────────────────────────────────────────────────────────────────

chips = [p["label"] for p in positions]
chips_str = '", "'.join(chips)

terms_lines = []
for p in positions:
    label = p["label"]
    terms = p["terms"]
    quoted = [f'"{t}"' for t in terms]
    single_line = f'            "{label}": [{", ".join(quoted)}]'
    if len(single_line) <= 120:
        terms_lines.append(single_line)
    else:
        inner = ",\n                ".join(quoted)
        terms_lines.append(f'            "{label}": [\n                {inner}\n            ]')
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

// MARK: - {platform_label} {league} {name} ({formula})

/// {platform_label} Classic scoring for {league} {name}.
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
    static var {slug}{platform_label}: {calc_name} {{ .shared }}
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Sport", f"{calc_name}.swift"), calc_file)

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

# TierThresholds+{Sport}.swift is intentionally not generated.
# Threshold wiring lives in TierTypes+UI.swift via the @retroactive TierLevel
# extension, which also satisfies the TierDisplayable protocol requirement.
# A separate TierDisplayable extension would conflict with BKSUICore's default.

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
opp_params        = opps_api.get("params", {})
opp_limit         = opp_params.get("limit", 50)
opp_platform      = opp_params.get("platform", "dk")
opp_mode          = opp_params.get("mode", "balanced")
ou_push_threshold = str(opp_params.get("ouPushThreshold", "0.5"))

# Projection params
proj_params  = proj_api.get("params", {})
proj_look    = proj_params.get("lookahead", 5)
proj_plat    = proj_params.get("platform", "dk")
proj_mode    = proj_params.get("mode", "gpp")

# Team lookup — from YAML teamIDs section, or empty with TODO comment
raw_team_ids = spec.get("teamIDs", {})
if raw_team_ids:
    team_id_lines = ", ".join(f'{k}: "{v}"' for k, v in sorted(raw_team_ids.items()))
    team_lookup_value = f"[{team_id_lines}]"
    team_lookup_comment = ""
else:
    team_lookup_value = "[:]"
    team_lookup_comment = f"         // TODO: populate {league} team ID → abbreviation lookup"

sport_config = header() + f"""\
import BKSCore
import BKSUICore

// MARK: - {league} {name}

extension SportConfiguration {{
    /// Fully-formatted splash subtitle built from the localized format string.
    var splashSubtitle: String {{
        String(format: String(localized: "splash.subtitle"), sportName)
    }}

    /// Sport configuration for {league} {name} / {platform_label} Classic.
    static let {slug} = SportConfiguration(
        slug: "{slug}",
        sportName: String(localized: "splash.sportName", defaultValue: "{name}"),
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
        teamAbbreviationByID: {team_lookup_value}{team_lookup_comment}
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
# 8b. SportPositionMap+<Sport>.swift  (BKSCore owns SportPositionMap base struct)
# ─────────────────────────────────────────────────────────────────────────────


# 8c. SportConfiguration.swift (base struct)
# NOTE: The concrete SportConfiguration struct now lives in BKSUICore
# (Sources/UI/SportConfiguration.swift). Nothing is generated here.
# Each sport only needs the +Sport extension generated in section 8b.


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

    private var boardStore: Store<BoardState, BoardIntent>
    private var authStore: Store<AuthState, AuthIntent>
    private var profileStore: Store<ProfileState, ProfileIntent>
    private var signInStore: Store<SignInState, SignInIntent>

    @StateObject private var networkMonitor = NetworkMonitor()

    private let auth: AuthenticationProtocol
    private let opportunitiesService: OpportunitiesServiceProtocol
    private let projectionsService: ProjectionsServiceProtocol
    private let gamesService: any GamesServiceProtocol
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
    #if DEBUG
    @State private var frameMonitor = FrameDropMonitor()
    #endif

    init() {{
        Perf.event("AppInitBegin")
        BKSAppScaffold.logLaunchDiagnostics(logger: Self.logger)

        let appDelegate = UIApplication.shared.delegate as? AppDelegate
        let container = appDelegate?.container ?? Container.defaultContainer()

        let resolvedAuth = container.require(Store<AuthState, AuthIntent>.self)
        authStore = resolvedAuth
        boardStore = container.require(Store<BoardState, BoardIntent>.self)

        let auth = container.require(AuthenticationProtocol.self)
        self.auth = auth
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

        profileStore = BKSAppScaffold.makeProfileStore(
            container: container,
            authStore: resolvedAuth,
            auth: auth
        ) {{ prefs in
            AppDelegate.notificationPreferences = prefs
            let svc = container.require(UserPreferencesServiceProtocol.self)
            try? await svc.updatePreferences(prefs)
        }}

        let langService = container.require(LanguagePreferenceServiceProtocol.self)
        signInStore = BKSAppScaffold.makeSignInStore(
            container: container,
            authStore: resolvedAuth
        ) {{
            Task {{ await langService.syncLanguage() }}
        }}

        Self.registerDataRefresh(opps: opps, projs: projs)
    }}

    private static func registerDataRefresh(
        opps: OpportunitiesServiceProtocol,
        projs: ProjectionsServiceProtocol
    ) {{
        DataRefreshTask.register(
            identifier: DataRefreshTaskID.identifier,
            fetchOpportunities: {{ _ = try await opps.fetchOpportunities() }},
            fetchProjections: {{ _ = try await projs.fetchProjections() }},
            fetchSchedule: {{ }}
        )
    }}

    private static func resolveSportServices(
        from container: Container
    ) -> (OpportunitiesServiceProtocol, ProjectionsServiceProtocol, any GamesServiceProtocol) {{
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
                    sportConfig: SportConfiguration.{slug},
                    isErasingCache: $isErasingCache,
                    onEraseCachedData: eraseCachedData
                )
            }} consentContent: {{ result in
                subscriptionConsentView(for: result)
            }} signInContent: {{
                SignInView(store: signInStore, animateIn: splashDismissed, auth: auth) {{ result in
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
            .environment(\\.gamesService, GamesServiceBox(gamesService))
            .task {{
                authStore.send(.checkStoredCredential)
                profileStore.send(.onAppear)
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
                // Use .backgroundRefreshRequested (cancelsInFlightWork = false) so that a
                // silent push arriving during app launch does not cancel the in-flight board fetch.
                boardStore.send(.backgroundRefreshRequested)
            }}
            .onReceive(
                NotificationCenter.default.publisher(for: PushNotificationNames.visiblePushTapped)
            ) {{ notification in
                guard let eventRaw = notification.object as? String else {{ return }}
                boardStore.send(.pushNotificationTapped(eventRaw))
            }}
            .onChange(of: boardStore.state.loadState.isLoading) {{ wasLoading, nowLoading in
                if wasLoading, !nowLoading, isErasingCache {{
                    isErasingCache = false
                }}
            }}
            .preferredColorScheme(.dark)
        }}
    }}

    // MARK: - Cache erase

    private func eraseCachedData() {{
        isErasingCache = true
        boardStore.send(.refreshRequested)
        Task.detached(priority: .userInitiated) {{ [storage] in
            try? storage.deleteAll(from: .file)
        }}
    }}

    // MARK: - Subscription consent

    private func subscriptionConsentView(for result: AuthResult) -> some View {{
        let termsURL = URL(string: configuration.value(for: .termsOfServiceURL))
            ?? URL(string: "https://www.blackkatt.ca/terms-of-service.html")!  // swiftlint:disable:this force_unwrapping
        let privacyURL = URL(string: configuration.value(for: .privacyPolicyURL))
            ?? URL(string: "https://www.blackkatt.ca/privacy-policy.html")!  // swiftlint:disable:this force_unwrapping
        return SubscriptionConsentView(
            title: String(localized: "consent.title", defaultValue: "Welcome to {app_name}"),
            subtitle: String(
                localized: "consent.subtitle",
                defaultValue: "Your subscription keeps the insights sharp all season."
            ),
            termsURL: termsURL,
            privacyURL: privacyURL,
            promoCodeService: promoCodeService,
            subscriptionService: subscriptionService,
            onAccepted: {{
                saveConsentAccepted(to: storage)
                authStore.send(.signInSucceeded(result))
                pendingConsentResult = nil
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
            let projs = container?.resolve(ProjectionsServiceProtocol.self)
        else {{ return }}
        await DataRefreshTask.handleSilentPush(
            userInfo: userInfo,
            storage: storage,
            fetchOpportunities: {{ _ = try await opps.fetchOpportunities() }},
            fetchProjections: {{ _ = try await projs.fetchProjections() }},
            fetchSchedule: {{ }}
        )
    }}
}}
"""

firebase_network_name = "firebase"  # DI resolver name for the Firebase-authenticated NetworkProtocol

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
        register((any SportConfigurationProtocol).self) {{ _ in SportConfiguration.{slug} }}.inObjectScope(.container)
    }}

    // swiftlint:disable:next function_body_length
    private func registerSportServices() {{
        register(BoardServiceProtocol.self) {{ resolver in
            BoardService(
                network: resolver.require(NetworkProtocol.self, name: "{firebase_network_name}"),
                storage: resolver.require(StorageProtocol.self),
                configuration: resolver.require(ConfigurationProtocol.self),
                sportConfiguration: resolver.require((any SportConfigurationProtocol).self)
            )
        }}.inObjectScope(.container)
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
                network: resolver.require(NetworkProtocol.self, name: "{firebase_network_name}"),
                storage: resolver.require(StorageProtocol.self),
                configuration: resolver.require(ConfigurationProtocol.self),
                sportConfiguration: resolver.require((any SportConfigurationProtocol).self)
            )
        }}.inObjectScope(.container)
        register(ProjectionsServiceProtocol.self) {{ resolver in
            ProjectionsService(
                network: resolver.require(NetworkProtocol.self, name: "{firebase_network_name}"),
                storage: resolver.require(StorageProtocol.self),
                configuration: resolver.require(ConfigurationProtocol.self),
                sportConfiguration: resolver.require((any SportConfigurationProtocol).self)
            )
        }}.inObjectScope(.container)
        register(GamesServiceProtocol.self) {{ resolver in
            GamesService(
                network: resolver.require(NetworkProtocol.self, name: "apiKey"),
                firebaseNetwork: resolver.require(NetworkProtocol.self, name: "{firebase_network_name}"),
                storage: resolver.require(StorageProtocol.self),
                configuration: resolver.require(ConfigurationProtocol.self),
                sportConfiguration: resolver.require((any SportConfigurationProtocol).self)
            )
        }}
    }}

    @MainActor
    private func registerBoardStore() {{
        register(Store<BoardState, BoardIntent>.self) {{ resolver in
            let boardService = resolver.require(BoardServiceProtocol.self)
            let projectionService = resolver.require(ProjectionsServiceProtocol.self)
            let opportunityService = resolver.require(OpportunitiesServiceProtocol.self)
            let analysisService = resolver.require(DailyAnalysisServiceProtocol.self)
            let positionMap = resolver.require((any SportConfigurationProtocol).self).positionMap
            return MainActor.assumeIsolated {{
                Store(
                    initial: BoardState(),
                    reduce: BoardState.makeReduce(
                        boardService: boardService,
                        projectionService: projectionService,
                        opportunityService: opportunityService,
                        analysisService: analysisService,
                        positionMap: positionMap
                    )
                )
            }}
        }}
    }}
}}
"""

# FirebaseAnalyticsAdapter lives in BKSCore (Sources/Repositories/FirebaseAnalyticsAdapter.swift).
# Do not generate a local copy — it would cause a duplicate symbol error.

bootstrap_dir = os.path.join(out_dir, "App/Sources/App/Bootstrap")
write(os.path.join(bootstrap_dir, f"{type_prefix}App.swift"), bootstrap_app)
write(os.path.join(bootstrap_dir, "DependencyContainer.swift"), bootstrap_container)

# ─────────────────────────────────────────────────────────────────────────────
# 9a. AppShell.swift
# ─────────────────────────────────────────────────────────────────────────────

app_shell = header() + f"""\
import SwiftUI
import BKSCore
import BKSUICore

struct {swift_name}AppShell: View {{
    var boardStore: Store<BoardState, BoardIntent>
    var profileStore: Store<ProfileState, ProfileIntent>
    let credential: StoredCredential
    let promoCodeService: PromoCodeServiceProtocol
    let activityService: any ActivityFeedServiceProtocol
    let sportConfig: any SportConfigurationProtocol
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
                sportConfig: sportConfig,
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

// MARK: - Player
//
// Sport-specific player model. Add fields matching your get_players API response.
// MANUAL IMPLEMENTATION REQUIRED — this stub is not overwritten on re-scaffold.

struct Player: Codable, Equatable, Hashable, Identifiable, Filterable {
    let id: String
    let displayName: String
    let team: String
    let position: String?
    let headshotURL: URL?
    let externalPersonID: Int?

    // Tier
    let playerTier: TierLevel?

    // Trend signals
    let trendDirection: TrendDirection?
    let hotStreak: Int?
    let isSurging: Bool?

    // Injury & status
    let injuryStatus: InjuryStatus?

    var additionalSearchFields: [String] { [] }
}
"""

opportunity_swift = header() + """\
import Foundation
import BKSCore

// MARK: - Opportunity
//
// Sport-specific opportunity model. Add fields matching your get_opportunities API response.
// MANUAL IMPLEMENTATION REQUIRED — this stub is not overwritten on re-scaffold.

struct Opportunity: Codable, Equatable, Hashable, Identifiable, Filterable, OpportunityProtocol, InjuryTracking {
    let id: String
    let displayName: String
    let team: String
    let position: String?
    let opponentAbbr: String
    let headshotURL: URL?
    let externalPersonID: Int?

    // Core scoring
    let opportunityScore: Double?
    let opportunityTier: TierLevel        // non-optional per OpportunityProtocol
    let playerTierDk: TierLevel?
    let playerTierFd: TierLevel?
    let mode: String
    let platforms: [String]

    // Key signals
    let injuryStatus: InjuryStatus?
    let isSurging: Bool
    let isHome: Bool
    let gameDateTime: Date?

    // Top picks
    let isTopPick: Bool
    let topPickRank: Int?

    var additionalSearchFields: [String] { [opponentAbbr] }

    // MARK: - Sport-specific fields
    // Add fields here that are unique to this sport's opportunity data.

    // MARK: - Prop lines
    // PropLine and RotationTier must be defined here (or in a companion file) because
    // the generated view layer (PropLinesCard, rotationTierPill) references them directly.
    // Remove or replace these for sports that don't use prop lines / rotation tiers.
}

// MARK: - PropLine

struct PropLine: Codable, Equatable, Hashable {
    let stat: String
    let line: Double
    let overOdds: Int
    let underOdds: Int
    /// Platt-calibrated model probability (0–1). Multiply by 100 for display %.
    let calibratedProbOver: Double
    let hasEdge: Bool
    let displayLabel: String
}

// MARK: - RotationTier
// Sport-specific: remove for sports without pitching rotation tiers.

enum RotationTier: String, Codable, Equatable, Hashable {
    case ace
    case rotation
    case bullpen
    case closer
    case swingman
}
"""

projection_swift = header() + """\
import Foundation
import BKSCore

// MARK: - Projection
//
// Sport-specific projection model conforming to ProjectionProtocol.
// Required protocol fields are pre-populated — add sport-specific fields below the marker.
// This stub is not overwritten on re-scaffold (write_if_absent).

struct Projection: Codable, Equatable, Hashable, Identifiable,
                   Filterable, ProjectionProtocol, InjuryTracking {
    let id: String
    let displayName: String
    let team: String
    let position: String?
    let headshotURL: URL?
    let externalPersonID: Int?

    // Core scoring — required by ProjectionProtocol
    let projectionScore: Double          // DK fantasy points (non-optional per protocol)
    let projectedScoreFd: Double?
    let projectionTier: TierLevel        // non-optional per protocol
    let playerTierDk: TierLevel?
    let playerTierFd: TierLevel?
    let mode: String
    let platforms: [String]
    let playFadeRecommendation: PlayFadeRecommendation?

    // Key signals — required by ProjectionProtocol
    let injuryStatus: InjuryStatus?
    let isSurging: Bool

    // Schedule — required by ProjectionProtocol
    let upcomingGames: [ProjectedGame]?
    let homeGameCount: Int?
    let awayGameCount: Int?
    let avgOpponentStrength: Double?

    // Streak signals — required by ProjectionProtocol
    let hotStreak: Int?
    let coldStreak: Int?

    // Trend — required by ProjectionProtocol
    let trendDirection: TrendDirection?
    let confidenceScoreDk: Double?
    let confidenceScoreFd: Double?
    let consistencyScore: Double?
    let usageEfficiencySignal: UsageEfficiencySignal?

    var additionalSearchFields: [String] { [] }

    // MARK: - Sport-specific fields
    // Add fields here that are unique to this sport's projection data.
}
"""

# PlayoffSeries lives in BKSCore (Sources/Models/PlayoffBracket.swift) as a public struct.
# SeriesStatus also removed — BKSCore uses status: String directly.
# Do NOT generate a local PlayoffSeries.swift — it would cause a duplicate symbol error.

_league_playoff_fields = """
    let playoffRound: Int?
    let playoffStartDate: String?
    let regularSeasonEndDate: String?""" if has_playoffs else ""

# SeasonMode is now a public enum in BKSCore (Sources/Models/SeasonMode.swift).
# Do NOT redeclare it locally — import BKSCore and reference it directly.
league_state_swift = header() + f"""import BKSCore

// MARK: - LeagueState

struct LeagueState: Codable, Equatable {{
    let mode: SeasonMode
    let season: Int?{_league_playoff_fields}
}}
"""

write(os.path.join(models_dir, "LeagueState.swift"), league_state_swift)
# Player is now a shared public type in BKSCore — no local Player.swift generated
# write_if_absent(os.path.join(models_dir, "Player.swift"), player_swift)
write_if_absent(os.path.join(models_dir, "Opportunity.swift"), opportunity_swift)
write_if_absent(os.path.join(models_dir, "Projection.swift"), projection_swift)

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
    private let sportConfiguration: any SportConfigurationProtocol
    private let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "TrendingsService"
    )
    private let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "TrendingsService"
    )

    private var cacheKey: String {{ "\\(sportConfiguration.cacheKeyPrefix)trending_v1" }}
    private var cacheDateKey: String {{ "\\(sportConfiguration.cacheKeyPrefix)trending_v1_date" }}

    init(
        network: NetworkProtocol,
        storage: StorageProtocol,
        configuration: ConfigurationProtocol,
        sportConfiguration: any SportConfigurationProtocol = SportConfiguration.{slug}
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
                "Fetched \\(sorted.count, privacy: .public) players in 1 call (\\(String(format: \\"%.2f\\", elapsed), privacy: .public)s)"
            )

        do {{
            try storage.save(sorted, forKey: cacheKey, in: .file)
            try storage.save(Date.now, forKey: cacheDateKey, in: .file)
        }} catch {{
            logger.warning("Failed to cache players: \\(error.diagnosticDescription, privacy: .public)")
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
            displayName: "\\(dto.firstName) \\(dto.lastName)",
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
    let playerTier: String?
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
        case externalPersonID = "{external_id_key}"
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
        playerTier = try container.decodeIfPresent(String.self, forKey: .playerTier)
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
import BKSUICore
import Foundation
import OSLog

// MARK: - OpportunitiesServiceProtocol

protocol OpportunitiesServiceProtocol {{
    /// Fetches a single page and returns the raw page result including server total.
    func fetchOpportunitiesPage(
        limit: Int?, offset: Int?, platform: String?, mode: String?, fields: [String]?
    ) async throws -> OpportunitiesPageResult
    func loadCachedOpportunities() throws -> [Opportunity]?
    func loadCachedOpportunitiesFetchDate() throws -> Date?
    func loadCachedSeasonMode() throws -> SeasonMode?
}}

extension OpportunitiesServiceProtocol {{
    func fetchOpportunitiesPage() async throws -> OpportunitiesPageResult {{
        try await fetchOpportunitiesPage(limit: nil, offset: nil, platform: nil, mode: nil, fields: nil)
    }}
}}

// MARK: - OpportunitiesPageResult

struct OpportunitiesPageResult {{
    let opportunities: [Opportunity]
    let seasonMode: SeasonMode
    let total: Int
    let offset: Int
    let limit: Int
}}

// MARK: - OpportunitiesService

final class OpportunitiesService: OpportunitiesServiceProtocol {{
    private let network: NetworkProtocol
    private let storage: StorageProtocol
    private let configuration: ConfigurationProtocol
    private let sportConfiguration: any SportConfigurationProtocol
    private let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "OpportunitiesService"
    )
    private let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "OpportunitiesService"
    )
    private let coalescer = FetchCoalescer<OpportunitiesPageResult>()

    private var cacheKey: String {{ "\\(sportConfiguration.cacheKeyPrefix)opportunities_v3" }}
    private var cacheDateKey: String {{ "\\(sportConfiguration.cacheKeyPrefix)opportunities_v3_date" }}
    private var seasonModeCacheKey: String {{ "\\(sportConfiguration.cacheKeyPrefix)season_mode_v1" }}

    private static let iso8601Full: ISO8601DateFormatter = {{
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }}()

    private static let iso8601Plain: ISO8601DateFormatter = {{
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }}()

    private static func parseISO8601(_ string: String?) -> Date? {{
        guard let string else {{ return nil }}
        return iso8601Full.date(from: string) ?? iso8601Plain.date(from: string)
    }}

    init(
        network: NetworkProtocol,
        storage: StorageProtocol,
        configuration: ConfigurationProtocol,
        sportConfiguration: any SportConfigurationProtocol = SportConfiguration.{slug}
    ) {{
        self.network = network
        self.storage = storage
        self.configuration = configuration
        self.sportConfiguration = sportConfiguration
    }}

    func fetchOpportunitiesPage(
        limit: Int? = nil,
        offset: Int? = nil,
        platform: String? = nil,
        mode: String? = nil,
        fields: [String]? = nil
    ) async throws -> OpportunitiesPageResult {{
        let currentOffset = offset ?? 0
        // Coalesce concurrent page-0 calls so only one Cloud Run cold-start fires.
        if currentOffset == 0 {{
            return try await coalescer.run(logger: logger, label: "fetchOpportunitiesPage") {{
                try await self._fetchPage(limit: limit, offset: 0, platform: platform, mode: mode, fields: fields)
            }}
        }}
        return try await _fetchPage(limit: limit, offset: currentOffset, platform: platform, mode: mode, fields: fields)
    }}

    private func _fetchPage(
        limit: Int?,
        offset: Int,
        platform: String?,
        mode: String?,
        fields: [String]?
    ) async throws -> OpportunitiesPageResult {{
        let url = configuration.checkedURL(for: .getOpportunitiesURL)
        let params = sportConfiguration.opportunityParams
        let pageSize = limit ?? params.limit
        let requestFields = fields ?? sportConfiguration.opportunityFields

        let fetchInterval = signposter.beginInterval("fetchOpportunitiesPage")
        defer {{ signposter.endInterval("fetchOpportunitiesPage", fetchInterval) }}

        try Task.checkCancellation()

        var parameters: Parameters = [
            "limit": pageSize,
            "offset": offset,
            "mode": mode ?? params.mode,
        ]
        if let platform {{ parameters["platform"] = platform }}
        if !requestFields.isEmpty {{ parameters["fields"] = requestFields.joined(separator: ",") }}

        let response: OpportunitiesResponse = try await network.get(url, parameters: parameters)
        let mapped = response.data.compactMap(mapOpportunity)
        let seasonMode = response.seasonMode ?? .regularSeason
        let total = response.total ?? mapped.count

        logger.info("Fetched \\(mapped.count, privacy: .public) opportunities at offset \\(offset, privacy: .public) (total: \\(total, privacy: .public))")

        if offset == 0 {{
            do {{
                try storage.save(mapped, forKey: cacheKey, in: .file)
                try storage.save(Date.now, forKey: cacheDateKey, in: .file)
                try storage.save(seasonMode, forKey: seasonModeCacheKey, in: .file)
            }} catch {{
                let msg = "Failed to cache opportunities: \\(error.diagnosticDescription)"
                logger.warning("\\(msg, privacy: .public)")
                DiagnosticLogger.error(msg, category: "OpportunitiesService")
            }}
        }}

        return OpportunitiesPageResult(
            opportunities: mapped,
            seasonMode: seasonMode,
            total: total,
            offset: offset,
            limit: pageSize
        )
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

    // swiftlint:disable:next function_body_length
    private func mapOpportunity(_ dto: OpportunityDTO) -> Opportunity? {{
        let tier: TierLevel
        if let tierStr = dto.opportunityTier, let mapped = TierLevel(serverValue: tierStr) {{
            tier = mapped
        }} else {{
            logger.warning("Unknown opportunity tier '\\(dto.opportunityTier ?? "nil", privacy: .public)' for \\(dto.firstName, privacy: .public) \\(dto.lastName, privacy: .public) — defaulting to .bottom")
            tier = .bottom
        }}
        return Opportunity(
            id: String(dto.id),
            displayName: "\\(dto.firstName) \\(dto.lastName)",
            team: dto.team,
            position: dto.position.flatMap {{ $0.isEmpty ? nil : $0 }},
            opponentAbbr: dto.opponentAbbr,
            headshotURL: dto.headshotURL,
            externalPersonID: dto.externalPersonID,
            opportunityScore: dto.opportunityScore,
            opportunityTier: tier,
            playerTierDk: dto.playerTier.flatMap {{ TierLevel(serverValue: $0) }},
            playerTierFd: dto.playerTierFd.flatMap {{ TierLevel(serverValue: $0) }},
            mode: dto.mode ?? "",
            platforms: dto.platform.map {{ [$0] }} ?? ["dk"],
            injuryStatus: dto.injuryStatus.flatMap {{ InjuryStatus(rawValue: $0) }},
            isSurging: dto.isSurging ?? false,
            isHome: dto.isHome ?? false,
            gameDateTime: Self.parseISO8601(dto.gameDateTime),
            playoffRotationMultiplier: dto.playoffRotationMultiplier,
            rotationTier: dto.rotationTier.flatMap {{ RotationTier(rawValue: $0) }},
            playoffTrendTrust: dto.playoffTrendTrust,
            playoffGamesPlayed: dto.playoffGamesPlayed
            // Sport-specific fields: add additional Opportunity init args here
            // to match your sport's API fields (see OpportunityDTO below).
        )
    }}
}}

// MARK: - Opportunity DTOs

private struct OpportunitiesResponse: Decodable {{
    let data: [OpportunityDTO]
    let seasonMode: SeasonMode?
    let total: Int?
    let offset: Int?
    let limit: Int?

    enum CodingKeys: String, CodingKey {{
        case data
        case seasonMode = "season_mode"
        case total
        case offset
        case limit
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

    let opportunityScore: Double?
    let opportunityTier: String?
    let playerTier: String?
    let playerTierFd: String?
    let mode: String?
    let platform: String?

    let injuryStatus: String?
    let isSurging: Bool?
    let isHome: Bool?
    let gameDateTime: String?

    let playoffRotationMultiplier: Double?
    let rotationTier: String?
    let playoffTrendTrust: Double?
    let playoffGamesPlayed: Int?

    // MARK: - Sport-specific DTO fields
    // Add fields here that your sport's opportunity API returns.
    // Remove any that your API does not provide.

    enum CodingKeys: String, CodingKey {{
        case id
        case firstName = "first_name"
        case lastName = "last_name"
        case team
        case position
        case opponentAbbr = "opponent_abbr"
        case headshotURL = "headshot_url"
        case externalPersonID = "{external_id_key}"
        case opportunityScore = "opportunity_score"
        case opportunityTier = "opportunity_tier"
        case playerTier = "player_tier"
        case playerTierFd = "player_tier_fd"
        case mode
        case platform
        case injuryStatus = "injury_status"
        case isSurging = "is_surging"
        case isHome = "is_home"
        case gameDateTime = "game_datetime"
        case playoffRotationMultiplier = "playoff_rotation_multiplier"
        case rotationTier = "rotation_tier"
        case playoffTrendTrust = "playoff_trend_trust"
        case playoffGamesPlayed = "playoff_games_played"
    }}
}}
"""

write_if_absent(os.path.join(services_dir, "TrendingsService.swift"), trendings_service_swift)
write_if_absent(os.path.join(services_dir, "OpportunitiesService.swift"), opportunities_service_swift)

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
    private let sportConfiguration: any SportConfigurationProtocol
    private let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "ProjectionsService"
    )
    private let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "ProjectionsService"
    )

    private var cacheKey: String {{ "\\(sportConfiguration.cacheKeyPrefix)projections_v3" }}
    private var cacheDateKey: String {{ "\\(sportConfiguration.cacheKeyPrefix)projections_v3_date" }}
    private let coalescer = FetchCoalescer<[Projection]>()

    init(
        network: NetworkProtocol,
        storage: StorageProtocol,
        configuration: ConfigurationProtocol,
        sportConfiguration: any SportConfigurationProtocol = SportConfiguration.{slug}
    ) {{
        self.network = network
        self.storage = storage
        self.configuration = configuration
        self.sportConfiguration = sportConfiguration
    }}

    func fetchProjections(fields: [String]? = nil) async throws -> [Projection] {{
        try await coalescer.run(logger: logger, label: "fetchProjections") {{
            try await self._fetchProjections(fields: fields)
        }}
    }}

    private func _fetchProjections(fields: [String]?) async throws -> [Projection] {{
        let url = configuration.checkedURL(for: .getProjectionsURL)

        let params = sportConfiguration.projectionParams
        var parameters: Parameters = [
            "lookahead": params.lookahead,
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
            "Fetched \\(mapped.count, privacy: .public) projections in 1 call (\\(String(format: \\"%.2f\\", elapsed), privacy: .public)s)"
        )

        do {{
            try storage.save(mapped, forKey: cacheKey, in: .file)
            try storage.save(Date.now, forKey: cacheDateKey, in: .file)
        }} catch {{
            logger.warning("Failed to cache projections: \\(error.diagnosticDescription, privacy: .public)")
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
                id: "\\(dto.id)-game-\\(index)",
                gameDate: parseDate(game.date),
                opponentAbbr: game.opponent,
                isHome: game.isHome ?? false,
                opponentStrength: game.opportunityScore,
                projectedScoreDk: game.predictedFPDk,
                projectedScoreFd: game.predictedFPFd,
                fpFloorDk: game.fpFloorDk,
                fpFloorFd: game.fpFloorFd,
                fpCeilingDk: game.fpCeilingDk,
                fpCeilingFd: game.fpCeilingFd
            )
        }}

        return Projection(
            id: String(dto.id),
            displayName: "\\(dto.firstName) \\(dto.lastName)",
            team: dto.team,
            position: dto.position.flatMap {{ $0.isEmpty ? nil : $0 }},
            headshotURL: dto.headshotURL,
            externalPersonID: dto.externalPersonID,
            projectionScore: projectionScore,
            projectedScoreFd: dto.games.compactMap(\\.predictedFPFd).max(),
            projectionTier: tier,
            playerTierDk: dto.playerTierDk.flatMap {{ TierLevel(serverValue: $0) }},
            playerTierFd: dto.playerTierFd.flatMap {{ TierLevel(serverValue: $0) }},
            mode: sportConfiguration.projectionParams.mode,
            platforms: dto.games.compactMap(\\.predictedFPFd).isEmpty ? ["dk"] : ["dk", "fd"],
            playFadeRecommendation: dto.playFadeRecommendation,
            injuryStatus: dto.injuryStatus.flatMap {{ InjuryStatus(rawValue: $0) }},
            isSurging: (dto.hotStreak ?? 0) > 0,
            upcomingGames: upcomingGames.isEmpty ? nil : upcomingGames,
            homeGameCount: upcomingGames.filter(\\.isHome).count,
            awayGameCount: upcomingGames.filter {{ !$0.isHome }}.count,
            avgOpponentStrength: upcomingGames.compactMap(\\.opponentStrength).average,
            hotStreak: dto.hotStreak,
            coldStreak: dto.coldStreak,
            trendDirection: dto.trendDirection,
            confidenceScoreDk: dto.confidenceScore,
            confidenceScoreFd: dto.confidenceScoreFd,
            consistencyScore: nil,
            usageEfficiencySignal: nil
        )
    }}

    private func bestTier(from games: [ProjectedGameDTO]) -> TierLevel? {{
        let tiers = games.compactMap {{ TierLevel(serverValue: $0.projectionTier ?? "") }}
        return tiers.min {{
            (TierLevel.allCases.firstIndex(of: $0) ?? Int.max) <
            (TierLevel.allCases.firstIndex(of: $1) ?? Int.max)
        }}
    }}

    private func parseDate(_ string: String) -> Date {{
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: string) ?? Date.now
    }}
}}

// MARK: - FlexDouble
//
// Decodes a Double from either a JSON number or a numeric string.
// Some backend stat fields (e.g. season_avg, woba_proxy, OBP/SLG/OPS/WAR, trend slopes)
// may arrive as strings like ".333" instead of a JSON number. Using FlexDouble? on those
// fields prevents a single malformed value from failing the entire projections response.
//
// Usage in DTOs:  let seasonAvg: FlexDouble?
// Usage at mapping site:  seasonAvg: dto.seasonAvg?.value

private struct FlexDouble: Decodable {{
    let value: Double

    init(from decoder: Decoder) throws {{
        let container = try decoder.singleValueContainer()
        if let num = try? container.decode(Double.self) {{
            value = num
        }} else if let str = try? container.decode(String.self), let num = Double(str) {{
            value = num
        }} else {{
            throw DecodingError.typeMismatch(
                Double.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected Double or numeric String"
                )
            )
        }}
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
    let confidenceScoreFd: Double?
    let hotStreak: Int?
    let coldStreak: Int?
    let injuryStatus: String?
    let playFadeRecommendation: PlayFadeRecommendation?
    // MARK: Sport-specific stat fields
    // Add FlexDouble? fields here for any numeric stat that the backend may send as a string.
    // Example (MLB baseball):
    //   let trendHits: FlexDouble?
    //   let seasonAvg: FlexDouble?
    //   let seasonOBP: FlexDouble?
    //   let wobaProxy: FlexDouble?
    // At the mapping site use: trendHits: dto.trendHits?.value
    let playerTierDk: String?
    let playerTierFd: String?
    let games: [ProjectedGameDTO]

    enum CodingKeys: String, CodingKey {{
        case id
        case firstName = "first_name"
        case lastName = "last_name"
        case position
        case team
        case externalPersonID = "{external_id_key}"
        case headshotURL = "headshot_url"
        case avgFantasyScore = "avg_fantasy_score"
        case trendDirection = "trend_direction"
        case trendScore = "trend_score"
        case confidenceScore = "confidence_score"
        case confidenceScoreFd = "confidence_score_fd"
        case hotStreak = "hot_streak"
        case coldStreak = "cold_streak"
        case injuryStatus = "injury_status"
        case playFadeRecommendation = "play_fade_recommendation"
        case playerTierDk = "player_tier_dk"
        case playerTierFd = "player_tier_fd"
        case games
    }}
}}

private struct ProjectedGameDTO: Decodable {{
    let date: String
    let opponent: String
    let isHome: Bool?
    let predictedFPDk: Double?
    let predictedFPFd: Double?
    let fpFloorDk: Double?
    let fpFloorFd: Double?
    let fpCeilingDk: Double?
    let fpCeilingFd: Double?
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
        case predictedFPDk = "predicted_fp_dk"
        case predictedFPFd = "predicted_fp_fd"
        case fpFloorDk = "fp_floor_dk"
        case fpFloorFd = "fp_floor_fd"
        case fpCeilingDk = "fp_ceiling_dk"
        case fpCeilingFd = "fp_ceiling_fd"
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

# Extract gamelog stat fields from YAML — drives GameEntry+Sport and GamesService mapping
gamelog_stats = gamelog.get("stats", [])
# Build stats dict lines: "key": stat.key ?? 0  (Int stats) or ?? 0.0 (Double stats)
def stat_dict_line(s):
    key = s["key"]
    typ = s.get("type", "Int")
    default = "0.0" if typ == "Double" else "0"
    return f'                "{key}": stat.{key} ?? {default},'

stats_dict_lines = "\n".join(stat_dict_line(s) for s in gamelog_stats if not s.get("isPlayingTime"))

# Build GameEntry+Sport extension accessors.
# inningsPitched is stored as tenths-of-inning (Int) to avoid Float precision
# issues in Firestore; the accessor divides by 10.0 to restore the conventional value.
def stat_accessor_line(s):
    key = s["key"]
    typ = s.get("type", "Int")
    if key == "inningsPitched":
        return f'    var {key}: Double           {{ Double(stats["{key}"] ?? 0) / 10.0 }}'
    elif typ == "Double":
        return f'    var {key}: Double           {{ stats["{key}"] ?? 0.0 }}'
    else:
        return f'    var {key}: {typ}           {{ stats["{key}"] ?? 0 }}'

stat_accessor_lines = "\n".join(stat_accessor_line(s) for s in gamelog_stats if not s.get("isPlayingTime"))

# Build projected stat accessors (non-minutes stats that appear in display)
all_display_stats = display.get("primary", []) + display.get("secondary", [])
proj_stat_keys = [s["key"] for s in all_display_stats if s["key"] not in ("dk", "minutes")]
proj_accessor_lines = "\n".join(
    f'    var {k}: Double?          {{ stats["{k}"] }}'
    for k in proj_stat_keys
)

# Build PlayerGameLog average computed properties from gamelog.averages YAML entries.
# Each entry has key, sourceKey, and label. We generate a simple count-based average
# (sourceKey total / non-DNP game count), except for named special keys that get
# sport-specific formulas injected below.
gamelog_averages = gamelog.get("averages", [])
gamelog_percentages = gamelog.get("percentages", [])

# Build a lookup of stat key → type for quick access
stat_type_map = {s["key"]: s.get("type", "Int") for s in gamelog_stats}

def average_property_lines(averages, percentages, stats):
    """Return Swift source lines for PlayerGameLog computed average properties."""
    lines = []
    for avg in averages:
        key = avg["key"]
        src = avg["sourceKey"]
        src_type = stat_type_map.get(src, "Int")
        if key == "battingAverage":
            # Total hits (1B+2B+3B+HR) / atBats
            lines.append(f"""    var battingAverage: Double {{
        let ab = entries.reduce(0) {{ $0 + $1.atBats }}
        guard ab > 0 else {{ return 0 }}
        let hits = entries.reduce(0) {{ $0 + $1.single + $1.double + $1.triple + $1.homeRun }}
        return Double(hits) / Double(ab)
    }}""")
        elif key == "averageERA":
            # earnedRunAllowed * 9.0 / totalIP; guard IP > 0
            lines.append(f"""    var averageERA: Double {{
        let ip = entries.reduce(0.0) {{ $0 + $1.inningsPitched }}
        guard ip > 0 else {{ return 0 }}
        let er = entries.reduce(0) {{ $0 + $1.earnedRunAllowed }}
        return Double(er) * 9.0 / ip
    }}""")
        else:
            # Generic count-based average: total / number of played games
            if src_type == "Double":
                lines.append(f"""    var {key}: Double {{
        guard !entries.isEmpty else {{ return 0 }}
        return entries.reduce(0.0) {{ $0 + $1.{src} }} / Double(entries.count)
    }}""")
            else:
                lines.append(f"""    var {key}: Double {{
        guard !entries.isEmpty else {{ return 0 }}
        return Double(entries.reduce(0) {{ $0 + $1.{src} }}) / Double(entries.count)
    }}""")
    for pct in percentages:
        key = pct["key"]
        made = pct["madeKey"]
        attempted = pct["attemptedKey"]
        lines.append(f"""    var {key}: Double {{
        let made = entries.reduce(0) {{ $0 + $1.{made} }}
        let attempted = entries.reduce(0) {{ $0 + $1.{attempted} }}
        guard attempted > 0 else {{ return 0 }}
        return Double(made) / Double(attempted) * 100
    }}""")
    return "\n\n".join(lines)

gamelog_average_properties = average_property_lines(gamelog_averages, gamelog_percentages, gamelog_stats)

games_service_swift = header() + f"""\
import Alamofire
import BKSCore
import Foundation
import OSLog

// MARK: - GamesServiceProtocol

protocol GamesServiceProtocol: BKSCore.GamesServiceProtocol {{
    func fetchGameLog(playerID: String, teamID: String) async throws -> PlayerGameLog
}}

// MARK: - GamesService

final class GamesService: GamesServiceProtocol {{

    private let network: NetworkProtocol
    private let firebaseNetwork: NetworkProtocol
    private let storage: StorageProtocol
    private let configuration: ConfigurationProtocol
    private let sportConfiguration: any SportConfigurationProtocol
    private let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "GamesService"
    )

    private static let gameLogCachePrefix = "game_log_"
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
        sportConfiguration: any SportConfigurationProtocol = SportConfiguration.{slug}
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
            "\\(baseURL)/stats",
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
                "\\(baseURL)/stats",
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
            logger.warning("Failed to cache game log for player \\(log.playerID, privacy: .public): \\(error.diagnosticDescription, privacy: .public)")
        }}
    }}

    func loadCachedGameLog(playerID: String) throws -> PlayerGameLog? {{
        try storage.load(forKey: Self.gameLogCachePrefix + playerID, from: .file)
    }}

    // Schedule data is now owned by BoardService (get-board). This stub satisfies the
    // BKSCore protocol requirement; callers should use BoardServiceProtocol.loadCachedTodaySchedule().
    func fetchTodaySchedule() async throws -> TodaySchedule {{
        throw GamesServiceError.noScheduleFound
    }}

    func loadCachedTodaySchedule() throws -> TodaySchedule? {{
        let key = "\\(sportConfiguration.cacheKeyPrefix)today_schedule_v1"
        return try storage.load(forKey: key, from: .file)
    }}

    func fetchPlayoffBracket() async throws -> [PlayoffSeries] {{
        let url: String = configuration.value(for: .getPlayoffBracketURL)
        let response: BracketResponse = try await firebaseNetwork.get(url, parameters: nil)
        let series = response.series.map {{ dto in
            PlayoffSeries(
                seriesID: dto.seriesID,
                higherSeedTeam: dto.higherSeedTeam,
                lowerSeedTeam: dto.lowerSeedTeam,
                winsHigherSeed: dto.winsHigherSeed,
                winsLowerSeed: dto.winsLowerSeed,
                gamesPlayed: dto.gamesPlayed,
                status: dto.status,
                roundNumber: dto.roundNumber,
                roundName: dto.roundName,
                conference: dto.conference,
                gameResults: []
            )
        }}
        do {{
            try storage.save(series, forKey: "{slug}_playoff_bracket_v1", in: .file)
        }} catch {{
            logger.warning("Failed to cache playoff bracket: \\(error.localizedDescription, privacy: .public)")
        }}
        logger.info("Fetched playoff bracket: \\(series.count, privacy: .public) series")
        return series
    }}

    // MARK: - Mapping

    // swiftlint:disable:next function_body_length
    private func mapGameEntry(_ stat: StatDTO, teamID: String) -> GameEntry? {{
        guard let game = stat.game else {{ return nil }}

        let gameDate = parseDate(game.date ?? "")

        let isHome: Bool = {{
            if let homeAbbr = game.homeTeam?.abbreviation {{
                return homeAbbr.uppercased() == teamID.uppercased()
            }}
            if let homeID = game.homeTeamID {{
                return sportConfiguration.teamAbbreviation(for: homeID).uppercased() == teamID.uppercased()
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
            minutes: stat.min ?? "0",
            stats: [
{stats_dict_lines}
            ]
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

    private func parseDateOnly(_ dateString: String) -> Date {{
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: String(dateString.prefix(10))) ?? Date()
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

// MARK: - Playoff Bracket DTOs

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
    let winsHigherSeed: Int
    let winsLowerSeed: Int
    let status: String
    let gamesPlayed: Int

    enum CodingKeys: String, CodingKey {{
        case seriesID = "series_id"
        case roundNumber = "round_number"
        case roundName = "round_name"
        case conference
        case higherSeedTeam = "higher_seed_team"
        case lowerSeedTeam = "lower_seed_team"
        case winsHigherSeed = "wins_higher_seed"
        case winsLowerSeed = "wins_lower_seed"
        case status
        case gamesPlayed = "games_played"
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
            logger.warning("Failed to cache league state: \\(error.diagnosticDescription, privacy: .public)")
        }}
        logger.info("Fetched league state: \\(response.mode, privacy: .public)")
        return state
    }}

    func fetchBracket() async throws -> [PlayoffSeries] {{
        let url = configuration.value(for: .getPlayoffBracketURL)
        let response: BracketResponse = try await network.get(url, parameters: nil)
        let series = response.series.map(mapSeries)
        do {{
            try storage.save(series, forKey: Self.bracketCacheKey, in: .file)
        }} catch {{
            logger.warning("Failed to cache playoff bracket: \\(error.diagnosticDescription, privacy: .public)")
        }}
        logger.info("Fetched playoff bracket: \\(series.count, privacy: .public) series")
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

write_if_absent(os.path.join(services_dir, "ProjectionsService.swift"), projections_service_swift)
write(os.path.join(services_dir, "GamesService.swift"), games_service_swift)
# PlayoffService merged into GamesService — fetchPlayoffBracket() is now in GamesService
# write(os.path.join(services_dir, "PlayoffService.swift"), playoff_service_swift)

# ─────────────────────────────────────────────────────────────────────────────
# 9d. Core Utilities files (continued)
# ─────────────────────────────────────────────────────────────────────────────

utilities_dir = os.path.join(out_dir, "App/Sources/Core/Utilities")


# ─────────────────────────────────────────────────────────────────────────────
# 9d-ii. Sport-specific model extensions
# ─────────────────────────────────────────────────────────────────────────────

game_entry_basketball_swift = header() + f"""\
import BKSCore

// MARK: - GameEntry {swift_name} stat accessors

public extension GameEntry {{
{stat_accessor_lines}

    /// Total official at-bats (1B + 2B + 3B + HR). Derived from hit components
    /// because the server does not store atBats directly in the stats dict.
    var atBats: Int {{
        (stats["single"] ?? 0) + (stats["double"] ?? 0) + (stats["triple"] ?? 0) + (stats["homeRun"] ?? 0)
    }}

    var hits: Int {{ single + double + triple + homeRun }}

    /// Sport-specific DNP check. A hitter with zero at-bats and a pitcher with zero
    /// innings pitched did not play. Uses raw dict access because `atBats` is computed.
    var isDNP: Bool {{ (stats["single"] ?? 0) == 0 && inningsPitched == 0.0 }}
}}

// MARK: - PlayerGameLog {swift_name} averages

public extension PlayerGameLog {{
{gamelog_average_properties}
}}
"""

# proj_accessor_lines drives the legacy camelCase group (locally-computed stat lines,
# matching GameEntry stat keys). The snake_case API group below must be maintained
# manually per sport — keys come from the server projected_stats schema, not YAML.
projected_stat_line_basketball_swift = header() + f"""\
import BKSCore

// MARK: - ProjectedStatLine {swift_name} stat accessors

public extension ProjectedStatLine {{
    // MARK: - Server projected_stats keys (snake_case from API response)
    // Sport-specific: replace with this sport's server-side projected_stats field names.
    var hits: Double?              {{ stats["hits"] }}
    var homeRuns: Double?          {{ stats["home_runs"] }}
    var rbis: Double?              {{ stats["rbis"] }}
    var runs: Double?              {{ stats["runs"] }}
    var stolenBases: Double?       {{ stats["stolen_bases"] }}
    var walks: Double?             {{ stats["walks"] }}

    // MARK: - Legacy camelCase accessors (locally-computed stat lines)
    // These match GameEntry stat keys. Generated from gamelog.display YAML.
{proj_accessor_lines}
}}
"""

write(os.path.join(models_dir, f"GameEntry+{swift_name}.swift"), game_entry_basketball_swift)
write(os.path.join(models_dir, f"ProjectedStatLine+{swift_name}.swift"), projected_stat_line_basketball_swift)

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
// Sport-specific fields are in the section marked below — add or remove
// fields to match the data your API returns.

struct BoardEntry: Identifiable, Equatable, Hashable, BoardEntryDisplayable {{
    let id: String
    let displayName: String
    let team: String
    let position: String?
    let headshotURL: URL?

    // Tonight's game
    let opponentAbbr: String?
    let isHome: Bool?
    let isPlayingTonight: Bool
    let playFadeRecommendation: PlayFadeRecommendation?

    // Projection layer
    let projectedScore: Double?       // DK fantasy points
    let projectedScoreFd: Double?     // FD fantasy points
    let fpFloor: Double?
    let fpCeiling: Double?
    let fpFloorFd: Double?
    let fpCeilingFd: Double?
    let projectionTier: TierLevel?
    let confidenceScore: Double?
    let confidenceScoreFd: Double?
    let isProjectionsLoading: Bool

    // Trend layer
    let hotStreak: Int?
    let coldStreak: Int?
    let usageEfficiencySignal: UsageEfficiencySignal?
    let avgFantasyScoreHome: Double?
    let avgFantasyScoreAway: Double?

    // Opportunity layer
    let opportunityScore: Double?
    let opportunityTier: TierLevel?
    let isTopPick: Bool
    let topPickRank: Int?

    // Status
    let injuryStatus: InjuryStatus?
    let isConfirmedStarter: Bool?
    let playerTier: TierLevel?
    let seasonGames: Int?
    let playoffDataConfidence: Double?

    // Ceiling & Value slate picks
    let isTopCeiling: Bool
    let topCeilingRank: Int?
    let isTopValue: Bool
    let topValueRank: Int?

    // MARK: - Sport-specific fields
    // The fields below are populated from the sport's opportunity and projection APIs.
    // Add, remove, or rename as needed for your sport's data model.

    // Game context
    let gameDateTime: Date?
    let battingOrder: Int?
    let probablePitcher: String?
    let parkFactor: Double?
    let topPickReasons: [String]

    // Trend
    let trendDirection: TrendDirection?
    let recentGameScores: [Double]?
    let upcomingGames: [ProjectedGame]?

    // Pitcher classification (baseball-specific — remove for non-pitching sports)
    let rotationTier: RotationTier?

    // Trend slopes — rate-of-change for key stats over recent games
    let trendHits: Double?
    let trendHR: Double?
    let trendRBI: Double?
    let trendRuns: Double?
    let trendSB: Double?
    let trendDoubles: Double?
    let trendTB: Double?

    // Season advanced metrics
    let seasonAvg: Double?
    let seasonOBP: Double?
    let seasonSLG: Double?
    let seasonOPS: Double?
    let seasonWAR: Double?
    let wobaProxy: Double?
    let obpProxy: Double?
    let avgPaPerGame: Double?

    // Sportsbook prop lines — keyed by market key e.g. "hits_0.5", "home_runs_0.5"
    let propLines: [String: PropLine]?

    /// Pre-lowercased concatenation of searchable fields, built once at entry construction.
    /// Format: "displayname|team|position" — eliminates per-keystroke lowercasing in applyFilters.
    let searchHaystack: String
}}
"""

# ── BoardEntryBuilder.swift ──────────────────────────────────────────────────────────

board_entry_builder_swift = header() + f"""import Foundation
import OSLog
import BKSCore

// MARK: - BoardEntryBuilder

private let logger = os.Logger(subsystem: "{bundle_id}", category: "BoardEntryBuilder")

private let dateFormatter: DateFormatter = {{
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}}()

// swiftlint:disable:next type_body_length
enum BoardEntryBuilder {{

    static func build(
        players: [Player],
        projections: [Projection] = [],
        opportunities: [Opportunity],
        todayDateString: String?
    ) -> [BoardEntry] {{
        // Primary join: external person ID when available on both sides.
        // Fallback: displayName+team when externalPersonID is nil everywhere.
        let hasIDOnProj = projections.contains {{ $0.externalPersonID != nil }}
        let hasIDOnOpp  = opportunities.contains {{ $0.externalPersonID != nil }}

        if hasIDOnProj && hasIDOnOpp {{
            return buildByID(projections: projections, opportunities: opportunities, todayDateString: todayDateString)
        }} else {{
            logger.warning("externalPersonID nil on all records — falling back to name+team join")
            return buildByName(projections: projections, opportunities: opportunities, todayDateString: todayDateString)
        }}
    }}

    // MARK: - ID join

    private static func buildByID(
        projections: [Projection],
        opportunities: [Opportunity],
        todayDateString: String?
    ) -> [BoardEntry] {{
        var projMap: [Int: Projection] = [:]
        for proj in projections {{
            guard let pid = proj.externalPersonID, projMap[pid] == nil else {{ continue }}
            projMap[pid] = proj
        }}
        var oppMap: [Int: Opportunity] = [:]
        for opp in opportunities {{
            guard let pid = opp.externalPersonID, oppMap[pid] == nil else {{ continue }}
            oppMap[pid] = opp
        }}
        let allIDs = Set(projMap.keys).union(oppMap.keys)
        let entries = allIDs.compactMap {{ pid in
            makeEntry(id: String(pid), proj: projMap[pid], opp: oppMap[pid], todayDateString: todayDateString)
        }}
        logger.debug("ID join: \\(entries.count, privacy: .public) entries (projections: \\(projections.count, privacy: .public), opportunities: \\(opportunities.count, privacy: .public))")
        return entries
    }}

    // MARK: - Name+team fallback join

    private static func buildByName(
        projections: [Projection],
        opportunities: [Opportunity],
        todayDateString: String?
    ) -> [BoardEntry] {{
        var projByName: [String: Projection] = [:]
        for proj in projections {{
            let key = nameKey(proj.displayName, proj.team)
            if projByName[key] == nil {{ projByName[key] = proj }}
        }}

        var usedKeys = Set<String>()
        var entries: [BoardEntry] = []

        // Opportunity-anchored entries (enriched with projection if name matches).
        for opp in opportunities {{
            let key = nameKey(opp.displayName, opp.team)
            let proj = projByName[key]
            if proj != nil {{ usedKeys.insert(key) }}
            if let entry = makeEntry(id: opp.id, proj: proj, opp: opp, todayDateString: todayDateString) {{
                entries.append(entry)
            }}
        }}

        // Projection-only entries with no matching opportunity.
        for proj in projections {{
            let key = nameKey(proj.displayName, proj.team)
            guard !usedKeys.contains(key) else {{ continue }}
            if let entry = makeEntry(id: proj.id, proj: proj, opp: nil, todayDateString: todayDateString) {{
                entries.append(entry)
            }}
        }}

        logger.debug("Name join: \\(entries.count, privacy: .public) entries (projections: \\(projections.count, privacy: .public), opportunities: \\(opportunities.count, privacy: .public))")
        return entries
    }}

    private static func nameKey(_ displayName: String, _ team: String) -> String {{
        "\\(displayName.lowercased())|\\(team.lowercased())"
    }}

    // MARK: - Loading state

    // swiftlint:disable:next function_body_length
    static func markProjectionsLoading(_ entries: [BoardEntry]) -> [BoardEntry] {{
        entries.map {{ entry in
            guard !entry.isProjectionsLoading else {{ return entry }}
            return BoardEntry(
                id: entry.id,
                displayName: entry.displayName,
                team: entry.team,
                position: entry.position,
                headshotURL: entry.headshotURL,
                opponentAbbr: entry.opponentAbbr,
                isHome: entry.isHome,
                isPlayingTonight: entry.isPlayingTonight,
                playFadeRecommendation: entry.playFadeRecommendation,
                projectedScore: entry.projectedScore,
                projectedScoreFd: entry.projectedScoreFd,
                fpFloor: entry.fpFloor,
                fpCeiling: entry.fpCeiling,
                fpFloorFd: entry.fpFloorFd,
                fpCeilingFd: entry.fpCeilingFd,
                projectionTier: entry.projectionTier,
                confidenceScore: entry.confidenceScore,
                confidenceScoreFd: entry.confidenceScoreFd,
                isProjectionsLoading: true,
                hotStreak: entry.hotStreak,
                coldStreak: entry.coldStreak,
                usageEfficiencySignal: entry.usageEfficiencySignal,
                avgFantasyScoreHome: entry.avgFantasyScoreHome,
                avgFantasyScoreAway: entry.avgFantasyScoreAway,
                opportunityScore: entry.opportunityScore,
                opportunityTier: entry.opportunityTier,
                isTopPick: entry.isTopPick,
                topPickRank: entry.topPickRank,
                injuryStatus: entry.injuryStatus,
                isConfirmedStarter: entry.isConfirmedStarter,
                playerTier: entry.playerTier,
                seasonGames: entry.seasonGames,
                playoffDataConfidence: entry.playoffDataConfidence,
                isTopCeiling: entry.isTopCeiling,
                topCeilingRank: entry.topCeilingRank,
                isTopValue: entry.isTopValue,
                topValueRank: entry.topValueRank,
                gameDateTime: entry.gameDateTime,
                battingOrder: entry.battingOrder,
                probablePitcher: entry.probablePitcher,
                parkFactor: entry.parkFactor,
                topPickReasons: entry.topPickReasons,
                trendDirection: entry.trendDirection,
                recentGameScores: entry.recentGameScores,
                upcomingGames: entry.upcomingGames,
                rotationTier: entry.rotationTier,
                trendHits: entry.trendHits,
                trendHR: entry.trendHR,
                trendRBI: entry.trendRBI,
                trendRuns: entry.trendRuns,
                trendSB: entry.trendSB,
                trendDoubles: entry.trendDoubles,
                trendTB: entry.trendTB,
                seasonAvg: entry.seasonAvg,
                seasonOBP: entry.seasonOBP,
                seasonSLG: entry.seasonSLG,
                seasonOPS: entry.seasonOPS,
                seasonWAR: entry.seasonWAR,
                wobaProxy: entry.wobaProxy,
                obpProxy: entry.obpProxy,
                avgPaPerGame: entry.avgPaPerGame,
                propLines: entry.propLines,
                searchHaystack: entry.searchHaystack
            )
        }}
    }}

    // MARK: - Projection enrichment

    /// Merge a freshly-fetched projections list into an already-rendered entry array.
    ///
    /// Called after the board has rendered from opportunity data alone so that
    /// projection detail arrives without blocking the initial paint. Entries with
    /// no matching projection are returned unchanged.
    static func mergeProjections(
        into entries: [BoardEntry],
        projections: [Projection],
        todayDateString: String?
    ) -> [BoardEntry] {{
        guard !projections.isEmpty else {{ return entries }}

        // Use name+team as the stable join key for the merge path.
        var projByName: [String: Projection] = [:]
        for proj in projections {{
            let key = nameKey(proj.displayName, proj.team)
            if projByName[key] == nil {{ projByName[key] = proj }}
        }}

        return entries.map {{ entry in
            guard let proj = projByName[nameKey(entry.displayName, entry.team)] else {{ return entry }}
            return enrich(entry: entry, with: proj, todayDateString: todayDateString)
        }}
    }}

    // swiftlint:disable:next function_body_length
    private static func enrich(
        entry: BoardEntry,
        with proj: Projection,
        todayDateString: String?
    ) -> BoardEntry {{
        let tonightGame: ProjectedGame? = {{
            guard let today = todayDateString else {{ return nil }}
            return proj.upcomingGames?.first {{ dateFormatter.string(from: $0.gameDate) == today }}
        }}()

        return BoardEntry(
            id: entry.id,
            displayName: entry.displayName,
            team: entry.team,
            position: entry.position ?? proj.position,
            headshotURL: entry.headshotURL ?? proj.headshotURL,
            opponentAbbr: entry.opponentAbbr ?? tonightGame?.opponentAbbr,
            isHome: entry.isHome ?? tonightGame.map(\\.isHome),
            isPlayingTonight: entry.isPlayingTonight || tonightGame != nil,
            playFadeRecommendation: proj.playFadeRecommendation,
            projectedScore: tonightGame?.projectedScoreDk ?? proj.projectionScore,
            projectedScoreFd: proj.projectedScoreFd ?? entry.projectedScoreFd,
            fpFloor: tonightGame?.fpFloorDk ?? entry.fpFloor,
            fpCeiling: tonightGame?.fpCeilingDk ?? entry.fpCeiling,
            fpFloorFd: tonightGame?.fpFloorFd ?? entry.fpFloorFd,
            fpCeilingFd: tonightGame?.fpCeilingFd ?? entry.fpCeilingFd,
            projectionTier: proj.projectionTier,
            confidenceScore: proj.confidenceScoreDk ?? entry.confidenceScore,
            confidenceScoreFd: proj.confidenceScoreFd ?? entry.confidenceScoreFd,
            isProjectionsLoading: false,
            hotStreak: proj.hotStreak ?? entry.hotStreak,
            coldStreak: proj.coldStreak ?? entry.coldStreak,
            usageEfficiencySignal: proj.usageEfficiencySignal,
            avgFantasyScoreHome: entry.avgFantasyScoreHome,
            avgFantasyScoreAway: entry.avgFantasyScoreAway,
            opportunityScore: entry.opportunityScore,
            opportunityTier: entry.opportunityTier,
            isTopPick: entry.isTopPick,
            topPickRank: entry.topPickRank,
            injuryStatus: proj.injuryStatus ?? entry.injuryStatus,
            isConfirmedStarter: entry.isConfirmedStarter,
            playerTier: proj.projectionTier,
            seasonGames: entry.seasonGames,
            playoffDataConfidence: entry.playoffDataConfidence,
            isTopCeiling: entry.isTopCeiling,
            topCeilingRank: entry.topCeilingRank,
            isTopValue: entry.isTopValue,
            topValueRank: entry.topValueRank,
            gameDateTime: entry.gameDateTime,
            battingOrder: entry.battingOrder,
            probablePitcher: entry.probablePitcher,
            parkFactor: entry.parkFactor,
            topPickReasons: entry.topPickReasons,
            trendDirection: proj.trendDirection ?? entry.trendDirection,
            recentGameScores: entry.recentGameScores,
            upcomingGames: proj.upcomingGames ?? entry.upcomingGames,
            rotationTier: entry.rotationTier,
            trendHits: proj.trendHits ?? entry.trendHits,
            trendHR: proj.trendHR ?? entry.trendHR,
            trendRBI: proj.trendRBI ?? entry.trendRBI,
            trendRuns: proj.trendRuns ?? entry.trendRuns,
            trendSB: proj.trendSB ?? entry.trendSB,
            trendDoubles: proj.trendDoubles ?? entry.trendDoubles,
            trendTB: proj.trendTB ?? entry.trendTB,
            seasonAvg: proj.seasonAvg ?? entry.seasonAvg,
            seasonOBP: proj.seasonOBP ?? entry.seasonOBP,
            seasonSLG: proj.seasonSLG ?? entry.seasonSLG,
            seasonOPS: proj.seasonOPS ?? entry.seasonOPS,
            seasonWAR: proj.seasonWAR ?? entry.seasonWAR,
            wobaProxy: proj.wobaProxy ?? entry.wobaProxy,
            obpProxy: proj.obpProxy ?? entry.obpProxy,
            avgPaPerGame: proj.avgPaPerGame ?? entry.avgPaPerGame,
            propLines: entry.propLines,
            searchHaystack: entry.searchHaystack
        )
    }}

    // MARK: - Entry construction

    // swiftlint:disable:next function_body_length
    private static func makeEntry(
        id: String,
        proj: Projection?,
        opp: Opportunity?,
        todayDateString: String?
    ) -> BoardEntry? {{
        let tonightGame: ProjectedGame? = proj.flatMap {{ projection in
            guard let today = todayDateString else {{ return nil }}
            return projection.upcomingGames?.first {{ dateFormatter.string(from: $0.gameDate) == today }}
        }}

        let projectedScore    = tonightGame?.projectedScoreDk ?? proj?.projectionScore ?? opp?.predictedFP
        let projectedScoreFd  = proj?.projectedScoreFd
        let fpFloor           = tonightGame?.fpFloorDk ?? opp?.fpFloorDk
        let fpCeiling         = tonightGame?.fpCeilingDk ?? opp?.fpCeilingDk
        let fpFloorFd         = tonightGame?.fpFloorFd ?? opp?.fpFloorFd
        let fpCeilingFd       = tonightGame?.fpCeilingFd ?? opp?.fpCeilingFd
        let projectionTier    = proj?.projectionTier
        let confidenceScore   = proj?.confidenceScoreDk
        let confidenceScoreFd = proj?.confidenceScoreFd

        guard let displayName = proj?.displayName ?? opp?.displayName,
              let team        = proj.map(\\.team) ?? opp.map(\\.team)
        else {{ return nil }}

        let position     = proj?.position ?? opp?.position
        let headshotURL  = proj?.headshotURL ?? opp?.headshotURL
        let injuryStatus = proj?.injuryStatus ?? opp?.injuryStatus
        let opponentAbbr = tonightGame?.opponentAbbr ?? opp?.opponentAbbr
        let isHome: Bool? = tonightGame.map(\\.isHome) ?? opp.map(\\.isHome)
        // tonightGame: projection matched today's date
        // gameDateTime: opportunity has an explicit game time for today
        // opponentAbbr on opp: opportunity API only returns players with tonight's game context
        let isPlayingTonight = tonightGame != nil
            || opp?.gameDateTime != nil
            || (opp?.opponentAbbr.isEmpty == false)

        let searchHaystack = "\\(displayName.lowercased())|\\(team.lowercased())|\\(position?.lowercased() ?? "")"

        return BoardEntry(
            id: id,
            displayName: displayName,
            team: team,
            position: position,
            headshotURL: headshotURL,
            opponentAbbr: opponentAbbr,
            isHome: isHome,
            isPlayingTonight: isPlayingTonight,
            playFadeRecommendation: proj?.playFadeRecommendation,
            projectedScore: projectedScore,
            projectedScoreFd: projectedScoreFd,
            fpFloor: fpFloor,
            fpCeiling: fpCeiling,
            fpFloorFd: fpFloorFd,
            fpCeilingFd: fpCeilingFd,
            projectionTier: projectionTier,
            confidenceScore: confidenceScore,
            confidenceScoreFd: confidenceScoreFd,
            isProjectionsLoading: false,
            hotStreak: proj?.hotStreak,
            coldStreak: proj?.coldStreak,
            usageEfficiencySignal: proj?.usageEfficiencySignal,
            avgFantasyScoreHome: nil,
            avgFantasyScoreAway: nil,
            opportunityScore: opp?.opportunityScore,
            opportunityTier: opp?.opportunityTier,
            isTopPick: opp?.isTopPick ?? false,
            topPickRank: opp?.topPickRank,
            injuryStatus: injuryStatus,
            isConfirmedStarter: nil,
            playerTier: proj?.projectionTier ?? opp?.opportunityTier,
            seasonGames: nil,
            playoffDataConfidence: nil,
            isTopCeiling: false,
            topCeilingRank: nil,
            isTopValue: false,
            topValueRank: nil,
            gameDateTime: opp?.gameDateTime,
            battingOrder: opp?.battingOrder,
            probablePitcher: opp?.probablePitcher,
            parkFactor: opp?.parkFactor,
            topPickReasons: opp?.topPickReasons ?? [],
            trendDirection: proj?.trendDirection,
            recentGameScores: nil,
            upcomingGames: proj?.upcomingGames,
            rotationTier: opp?.rotationTier,
            trendHits: proj?.trendHits ?? opp?.trendHits,
            trendHR: proj?.trendHR ?? opp?.trendHR,
            trendRBI: proj?.trendRBI ?? opp?.trendRBI,
            trendRuns: proj?.trendRuns ?? opp?.trendRuns,
            trendSB: proj?.trendSB ?? opp?.trendSB,
            trendDoubles: proj?.trendDoubles ?? opp?.trendDoubles,
            trendTB: proj?.trendTB ?? opp?.trendTB,
            seasonAvg: proj?.seasonAvg ?? opp?.seasonAvg,
            seasonOBP: proj?.seasonOBP ?? opp?.obpProxy,
            seasonSLG: proj?.seasonSLG,
            seasonOPS: proj?.seasonOPS,
            seasonWAR: proj?.seasonWAR,
            wobaProxy: proj?.wobaProxy ?? opp?.wobaProxy,
            obpProxy: proj?.obpProxy ?? opp?.obpProxy,
            avgPaPerGame: proj?.avgPaPerGame ?? opp?.avgPaPerGame,
            propLines: opp?.propLines,
            searchHaystack: searchHaystack
        )
    }}
}}
"""

# ── BoardIntent.swift ───────────────────────────────────────────────────────────────

board_intent_swift = header() + f"""import SwiftUI
import BKSCore

// MARK: - BoardLoadResult

struct BoardLoadResult {{
    let entries: [BoardEntry]
    let projections: [Projection]
    let games: [ScheduledGame]
    let lockTime: Date?
    let seasonMode: SeasonMode
    let gameOdds: [String: GameOdds]
    let serverDateString: String?
    let dailyAnalysis: DailyAnalysis?
    let analysisPreview: String?
    let playoffSeries: [PlayoffSeries]
    let nextPageOffset: Int
    let hasMorePages: Bool
    let totalOpportunities: Int
    /// ISO 8601 UTC timestamp of the last sync_today_games run. Nil until the board response arrives.
    let scheduleSyncedAt: String?
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
    /// Triggered by background data refresh (silent push / BGTask). Does not cancel an in-flight fetch.
    case backgroundRefreshRequested
    case entriesLoaded(BoardLoadResult)
    case loadFailed(Error)
    case searchTextChanged(String)
    case positionFilterChanged(String?)
    case tierFilterChanged(TierLevel?)
    case viewModeChanged(BoardViewMode)
    case navigationPathChanged(NavigationPath)
    case pushNotificationTapped(String)
    case deepLinkHandled
    case refreshBannerExpired
    case diskCacheLoaded(BoardLoadResult)
    case loadNextPage
    case nextPageLoaded(OpportunitiesPageResult)
    /// Projections arrived after the board already rendered from opportunity data.
    /// Enriches existing entries without replacing them.
    case projectionsLoaded([Projection])

    var cancelsInFlightWork: Bool {{
        switch self {{
        case .navigationPathChanged, .searchTextChanged, .positionFilterChanged,
             .tierFilterChanged, .viewModeChanged, .pushNotificationTapped,
             .deepLinkHandled, .refreshBannerExpired, .diskCacheLoaded,
             .loadNextPage, .nextPageLoaded, .backgroundRefreshRequested,
             .projectionsLoaded:
            false
        default:
            true
        }}
    }}
}}
"""

# ── BoardState.swift ────────────────────────────────────────────────────────────────

board_state_swift = header() + f"""import BKSCore
import BKSUICore
import OSLog
import SwiftUI

// MARK: - BoardState

// swiftlint:disable:next type_body_length
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
    /// Vegas lines and projected totals keyed by "VISITOR@HOME:gameSequence".
    var gameOdds: [String: GameOdds] = [:]
    /// Server-authoritative date string "yyyy-MM-dd" in ET. Nil until first load.
    var serverDateString: String?
    /// ISO 8601 UTC timestamp of the last sync_today_games run. Used for "last updated" on the schedule strip.
    var scheduleSyncedAt: String?
    var viewMode: BoardViewMode = .byPosition
    var groupedEntries: [(position: String, picks: [BoardEntry])] = []
    var dailyAnalysis: DailyAnalysis?
    /// Short narrative preview from get_board. Shown on the board card before the user taps through.
    var analysisPreview: String?
    var playoffSeries: [PlayoffSeries] = []
    /// True while a background network refresh is in flight after serving a disk-cache hit.
    var isBackgroundRefreshing: Bool = false
    var nextPageOffset: Int = 0
    var hasMorePages: Bool = false
    var isLoadingNextPage: Bool = false
    /// Server-reported total player count for the current slate, independent of how many pages have loaded.
    var totalOpportunities: Int = 0
    /// Cached projections retained for appending subsequent opportunity pages.
    var cachedProjections: [Projection] = []

    private static let stalenessThreshold = CacheFreshness.defaultThreshold

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "BoardState"
    )

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func makeReduce(
        boardService: BoardServiceProtocol,
        projectionService: ProjectionsServiceProtocol,
        opportunityService: OpportunitiesServiceProtocol,
        analysisService: DailyAnalysisServiceProtocol,
        positionMap: SportPositionMap
    ) -> Reduce<Self, BoardIntent> {{
        {{ state, intent in
            switch intent {{
            case .onAppear:
                // Force refetch if the calendar date has changed since last load —
                // yesterday's players must not persist.
                let isNewDay = state.lastUpdated.map {{ !Calendar.current.isDateInToday($0) }} ?? false
                let lastUpdatedDesc = state.lastUpdated?.description ?? "nil"
                let entryCount = state.allEntries.count
                if !isNewDay,
                   CacheFreshness.isFresh(lastUpdated: state.lastUpdated, threshold: stalenessThreshold),
                   case .loaded = state.loadState,
                   !state.allEntries.isEmpty
                {{
                    logger.debug("onAppear — cache hit, skipping fetch (lastUpdated: \\(lastUpdatedDesc, privacy: .public) entries: \\(entryCount, privacy: .public))")
                    return nil
                }}
                // A fetch is already in flight (e.g. refreshRequested fired before onAppear) —
                // don't spawn a second concurrent fetch that races and doubles network load.
                if case .loading = state.loadState {{
                    logger.debug("onAppear — fetch already in flight, skipping (lastUpdated: \\(lastUpdatedDesc, privacy: .public))")
                    return nil
                }}
                logger.debug("onAppear — triggering fetch (isNewDay: \\(isNewDay, privacy: .public) lastUpdated: \\(lastUpdatedDesc, privacy: .public))")
                // Seed the games strip from disk before the full board cache check.
                if let schedule = try? boardService.loadCachedTodaySchedule() {{
                    state.todayGames = schedule.games.sorted {{ $0.gameDatetime < $1.gameDatetime }}
                    state.gameCount = schedule.games.count
                    state.serverDateString = schedule.date
                }}
                // Serve disk cache immediately so the board renders before the network
                // round-trip completes. Background fetch below overwrites with fresh data.
                state.loadState = .loading
                async let diskTask = Perf.measure("BoardDiskHydration") {{
                    await loadFromDisk(
                        boardService: boardService,
                        opportunityService: opportunityService,
                        projectionService: projectionService,
                        analysisService: analysisService,
                        positionMap: positionMap
                    )
                }}
                async let networkTask = fetchAll(
                    boardService: boardService,
                    analysisService: analysisService
                )
                if let diskResult = await diskTask {{
                    logger.debug("onAppear — disk cache hit, instant render (\\(diskResult.entries.count, privacy: .public) entries), background refresh starting")
                    state.allEntries = diskResult.entries
                    state.loadState = .loaded(diskResult.entries)
                    state.todayGames = diskResult.games.sorted {{ $0.gameDatetime < $1.gameDatetime }}
                    state.gameCount = diskResult.games.count
                    state.lockTime = diskResult.lockTime
                    state.seasonMode = diskResult.seasonMode
                    state.gameOdds = diskResult.gameOdds
                    state.serverDateString = diskResult.serverDateString
                    if let analysis = diskResult.dailyAnalysis {{ state.dailyAnalysis = analysis }}
                    state.isBackgroundRefreshing = true
                    applyFilters(&state, positionMap: positionMap)
                }}
                return await networkTask

            case .refreshRequested:
                state.isBackgroundRefreshing = false
                state.loadState = .loading
                return await fetchAll(
                    boardService: boardService,
                    analysisService: analysisService
                )

            case .backgroundRefreshRequested:
                // Skip if a fetch is already in flight — the in-flight result will be fresher.
                if case .loading = state.loadState {{ return nil }}
                if case .loaded = state.loadState {{ state.isBackgroundRefreshing = true }}
                state.loadState = .loading
                return await fetchAll(
                    boardService: boardService,
                    analysisService: analysisService
                )

            case let .entriesLoaded(result):
                state.isBackgroundRefreshing = false
                // Mark spinner on cards immediately — projections fetch is about to start.
                let loadingEntries = result.projections.isEmpty
                    ? BoardEntryBuilder.markProjectionsLoading(result.entries)
                    : result.entries
                state.allEntries = loadingEntries
                state.cachedProjections = result.projections
                state.loadState = .loaded(loadingEntries)
                state.lastUpdated = .now
                state.nextPageOffset = result.nextPageOffset
                state.hasMorePages = result.hasMorePages
                state.isLoadingNextPage = false
                state.totalOpportunities = result.totalOpportunities
                state.todayGames = result.games.sorted {{ $0.gameDatetime < $1.gameDatetime }}
                state.gameCount = result.games.count
                state.lockTime = result.lockTime
                state.seasonMode = result.seasonMode
                state.gameOdds = result.gameOdds
                state.serverDateString = result.serverDateString
                if let syncedAt = result.scheduleSyncedAt {{ state.scheduleSyncedAt = syncedAt }}
                state.playoffSeries = result.playoffSeries
                if let preview = result.analysisPreview {{ state.analysisPreview = preview }}
                if let analysis = result.dailyAnalysis {{ state.dailyAnalysis = analysis }}
                applyFilters(&state, positionMap: positionMap)
                // Phase 2 — board is now visible; fetch projections in background to enrich entries.
                return await fetchProjectionsInBackground(projectionService: projectionService)

            case let .loadFailed(error):
                state.isBackgroundRefreshing = false
                if case .loaded = state.loadState {{
                    let msg = "Board refresh failed but keeping existing data: \\(error.diagnosticDescription)"
                    logger.warning("\\(msg, privacy: .public)")
                    DiagnosticLogger.warning(msg, category: "BoardState")
                    return nil
                }}
                let msg = "Board load failed: \\(error.localizedDescription)"
                logger.error("\\(msg, privacy: .public)")
                DiagnosticLogger.error(msg, category: "BoardState")
                state.loadState = .failed(error)
                return nil

            case .refreshBannerExpired:
                state.isBackgroundRefreshing = false
                return nil

            case let .searchTextChanged(text):
                state.searchText = text
                applyFilters(&state, positionMap: positionMap)
                return nil

            case let .positionFilterChanged(position):
                state.selectedPosition = position
                applyFilters(&state, positionMap: positionMap)
                return nil

            case let .tierFilterChanged(tier):
                state.selectedTier = tier
                applyFilters(&state, positionMap: positionMap)
                return nil

            case let .viewModeChanged(mode):
                state.viewMode = mode
                applyFilters(&state, positionMap: positionMap)
                return nil

            case let .navigationPathChanged(path):
                state.navigationPath = path
                return nil

            case .pushNotificationTapped:
                return nil

            case .deepLinkHandled:
                return nil

            case let .diskCacheLoaded(result):
                state.isBackgroundRefreshing = false
                state.allEntries = result.entries
                state.loadState = .loaded(result.entries)
                state.nextPageOffset = result.nextPageOffset
                state.hasMorePages = result.hasMorePages
                state.isLoadingNextPage = false
                state.totalOpportunities = result.totalOpportunities
                state.todayGames = result.games.sorted {{ $0.gameDatetime < $1.gameDatetime }}
                state.gameCount = result.games.count
                state.lockTime = result.lockTime
                state.seasonMode = result.seasonMode
                state.gameOdds = result.gameOdds
                state.serverDateString = result.serverDateString
                applyFilters(&state, positionMap: positionMap)
                return nil

            case let .projectionsLoaded(projections):
                guard !state.allEntries.isEmpty else {{ return nil }}
                let serverDate = state.serverDateString
                let enriched = Perf.measure("BoardProjectionMerge") {{
                    BoardEntryBuilder.mergeProjections(
                        into: state.allEntries,
                        projections: projections,
                        todayDateString: serverDate
                    )
                }}
                state.allEntries = enriched
                state.cachedProjections = projections
                if case .loaded = state.loadState {{
                    state.loadState = .loaded(enriched)
                }}
                applyFilters(&state, positionMap: positionMap)
                return nil

            case .loadNextPage:
                guard state.hasMorePages, !state.isLoadingNextPage else {{ return nil }}
                state.isLoadingNextPage = true
                let offset = state.nextPageOffset
                return await loadNextPage(
                    offset: offset,
                    boardService: boardService
                )

            case let .nextPageLoaded(pageResult):
                state.isLoadingNextPage = false
                let existingIDs = Set(state.allEntries.map(\\.id))
                let newEntries = BoardEntryBuilder.build(
                    players: [],
                    projections: state.cachedProjections,
                    opportunities: pageResult.opportunities,
                    todayDateString: state.serverDateString
                ).filter {{ !existingIDs.contains($0.id) }}
                state.allEntries.append(contentsOf: newEntries)
                state.loadState = .loaded(state.allEntries)
                let nextOffset = pageResult.offset + pageResult.limit
                state.nextPageOffset = nextOffset
                state.hasMorePages = nextOffset < pageResult.total
                applyFilters(&state, positionMap: positionMap)
                return nil
            }}
        }}
    }}

    // MARK: - Disk cache

    /// Reads all disk caches synchronously and builds a `BoardLoadResult` if every
    /// required piece is present. Returns nil on any missing cache so the caller
    /// falls through to the normal loading spinner.
    nonisolated private static func loadFromDisk( // swiftlint:disable:this function_body_length
        boardService: BoardServiceProtocol,
        opportunityService: OpportunitiesServiceProtocol,
        projectionService: ProjectionsServiceProtocol,
        analysisService: DailyAnalysisServiceProtocol,
        positionMap: SportPositionMap
    ) async -> BoardLoadResult? {{
        let opportunities: [Opportunity]
        do {{
            guard let loaded = try opportunityService.loadCachedOpportunities() else {{
                logger.debug("loadFromDisk — opportunities cache miss")
                return nil
            }}
            opportunities = loaded
        }} catch {{
            let msg = "loadFromDisk — opportunities decode failed: \\(error.localizedDescription)"
            logger.warning("\\(msg, privacy: .public)")
            DiagnosticLogger.error(msg, category: "BoardState")
            return nil
        }}

        guard !opportunities.isEmpty else {{
            logger.debug("loadFromDisk — opportunities cache empty")
            DiagnosticLogger.warning("loadFromDisk — opportunities cache empty", category: "BoardState")
            return nil
        }}

        // Projections are optional for the disk-cache fast path — entries render without them
        // and get enriched via `.projectionsLoaded` once the network call completes.
        let projections: [Projection] = (try? projectionService.loadCachedProjections()) ?? []

        let schedule: TodaySchedule
        do {{
            guard let loaded = try boardService.loadCachedTodaySchedule() else {{
                logger.debug("loadFromDisk — schedule cache miss")
                return nil
            }}
            schedule = loaded
        }} catch {{
            let msg = "loadFromDisk — schedule decode failed: \\(error.localizedDescription)"
            logger.warning("\\(msg, privacy: .public)")
            DiagnosticLogger.error(msg, category: "BoardState")
            return nil
        }}

        let seasonMode = (try? opportunityService.loadCachedSeasonMode()) ?? .regularSeason
        let cachedAnalysis = try? analysisService.loadCachedDailyAnalysis()
        let entries = Perf.measure("BoardEntryBuildFromDisk") {{
            BoardEntryBuilder.build(
                players: [],
                projections: projections,
                opportunities: opportunities,
                todayDateString: schedule.date
            )
        }}
        let games = schedule.games
        let lockTime = games.map(\\.gameDatetime).min()
        return BoardLoadResult(
            entries: entries,
            projections: projections,
            games: games,
            lockTime: lockTime,
            seasonMode: seasonMode,
            gameOdds: buildGameOdds(from: games),
            serverDateString: schedule.date,
            dailyAnalysis: cachedAnalysis,
            analysisPreview: nil,
            playoffSeries: [],
            nextPageOffset: 0,
            hasMorePages: false,
            totalOpportunities: entries.count,
            scheduleSyncedAt: nil
        )
    }}

    nonisolated private static func loadNextPage(
        offset: Int,
        boardService: BoardServiceProtocol
    ) async -> BoardIntent {{
        do {{
            let page = try await boardService.fetchBoard(platform: nil, limit: nil, offset: offset)
            let adapted = OpportunitiesPageResult(
                opportunities: page.players,
                seasonMode: page.seasonMode,
                total: page.total,
                offset: page.offset,
                limit: page.limit
            )
            return .nextPageLoaded(adapted)
        }} catch {{
            let msg = "Board: next page fetch failed (offset \\(offset)): \\(error.diagnosticDescription)"
            logger.warning("\\(msg, privacy: .public)")
            DiagnosticLogger.warning(msg, category: "BoardState")
            return .loadFailed(error)
        }}
    }}

    private static func buildGameOdds(from games: [ScheduledGame]) -> [String: GameOdds] {{
        Dictionary(uniqueKeysWithValues: games.map {{ game in
            ("\\(game.visitorTeamAbbr)@\\(game.homeTeamAbbr):\\(game.gameSequence)", GameOdds(game: game))
        }})
    }}

    // MARK: - Async fetch

    // swiftlint:disable:next function_body_length
    nonisolated private static func fetchAll(
        boardService: BoardServiceProtocol,
        analysisService: DailyAnalysisServiceProtocol
    ) async -> BoardIntent {{
        #if DEBUG
        let fetchAllStart = Date()
        let fetchAllID = Perf.begin("BoardFetchAll")
        defer {{ Perf.end("BoardFetchAll", id: fetchAllID, startedAt: fetchAllStart) }}
        #endif

        // Phase 1 — get_board is the critical path. We do NOT await projections here.
        // Projections are fetched concurrently but dispatched separately so the board
        // renders as soon as get_board completes.
        let page: BoardPageResult
        do {{
            page = try await boardService.fetchBoard()
        }} catch {{
            if case NetworkError.httpError(statusCode: 402, _) = error {{
                return .loadFailed(error)
            }}
            let msg = "Board: get_board fetch failed: \\(error.diagnosticDescription)"
            logger.warning("\\(msg, privacy: .public)")
            DiagnosticLogger.error(msg, category: "BoardState")
            return .loadFailed(error)
        }}

        // Build entries from opportunity data alone — no projections needed for board cards.
        let entries = Perf.measure("BoardEntryBuildFromNetwork") {{
            BoardEntryBuilder.build(
                players: [],
                opportunities: page.players,
                todayDateString: page.date.isEmpty ? nil : page.date
            )
        }}

        let lockTime = page.games.map(\\.gameDatetime).min()
        let nextOffset = page.offset + page.limit
        let hasMore = nextOffset < page.total

        return .entriesLoaded(BoardLoadResult(
            entries: entries,
            projections: [],
            games: page.games,
            lockTime: lockTime,
            seasonMode: page.seasonMode,
            gameOdds: buildGameOdds(from: page.games),
            serverDateString: page.date.isEmpty ? nil : page.date,
            dailyAnalysis: nil,
            analysisPreview: page.analysisPreview,
            playoffSeries: [],
            nextPageOffset: nextOffset,
            hasMorePages: hasMore,
            totalOpportunities: page.total,
            scheduleSyncedAt: page.scheduleSyncedAt
        ))
    }}

    /// Fetches projections in the background and dispatches `.projectionsLoaded` when done.
    /// Called after `.entriesLoaded` so the board is already visible when this fires.
    nonisolated static func fetchProjectionsInBackground(
        projectionService: ProjectionsServiceProtocol
    ) async -> BoardIntent {{
        do {{
            let projections = try await projectionService.fetchProjections()
            return .projectionsLoaded(projections)
        }} catch {{
            let msg = "Board: background projections fetch failed: \\(error.diagnosticDescription)"
            logger.warning("\\(msg, privacy: .public)")
            DiagnosticLogger.warning(msg, category: "BoardState")
            return .projectionsLoaded([])
        }}
    }}

    // MARK: - Filtering

    private static func applyFilters(_ state: inout Self, positionMap: SportPositionMap) {{
        #if DEBUG
        let applyFiltersStart = Date()
        let applyFiltersID = Perf.begin("BoardApplyFilters")
        defer {{ Perf.end("BoardApplyFilters", id: applyFiltersID, startedAt: applyFiltersStart) }}
        #endif
        let search = state.searchText.lowercased()
        let chip = state.selectedPosition
        let tierFilter = state.selectedTier

        let base = state.allEntries
            .filter {{ $0.isPlayingTonight }}
            .filter {{ entry in
                let matchesSearch = search.isEmpty || entry.searchHaystack.contains(search)

                let matchesChip: Bool = {{
                    guard let chip, chip != "All" else {{ return true }}
                    return positionMap.matchesChip(chip, position: entry.position)
                }}()

                let matchesTier: Bool = {{
                    guard let tierFilter else {{ return true }}
                    return entry.playerTier == tierFilter
                }}()

                return matchesSearch && matchesChip && matchesTier
            }}
            .sorted {{ lhs, rhs in
                switch (lhs.opportunityScore, rhs.opportunityScore) {{
                case let (lScore?, rScore?): return lScore > rScore
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none):
                    let tierA = lhs.playerTier?.tierSortOrder ?? Int.max
                    let tierB = rhs.playerTier?.tierSortOrder ?? Int.max
                    return tierA < tierB
                }}
            }}

        state.filteredEntries = base
        state.groupedEntries = buildGroupedEntries(from: base, positionMap: positionMap)
    }}

    private static func buildGroupedEntries(
        from entries: [BoardEntry],
        positionMap: SportPositionMap
    ) -> [(position: String, picks: [BoardEntry])] {{
        positionMap.filterChips.compactMap {{ chip in
            let picks = entries
                .filter {{ positionMap.matchesChip(chip, position: $0.position) }}
                .sorted {{
                    let tierA = $0.playerTier?.tierSortOrder ?? Int.max
                    let tierB = $1.playerTier?.tierSortOrder ?? Int.max
                    if tierA != tierB {{ return tierA < tierB }}
                    return ($0.opportunityScore ?? 0) > ($1.opportunityScore ?? 0)
                }}
            guard !picks.isEmpty else {{ return nil }}
            return (position: chip, picks: picks)
        }}
    }}
}}
"""

# ── BoardView.swift ──────────────────────────────────────────────────────────────────

board_view_swift = header() + f"""import BKSCore
import BKSUICore
import SwiftUI

// MARK: - BoardView

struct BoardView: View {{
    var store: Store<BoardState, BoardIntent>
    let credential: StoredCredential
    var profileStore: Store<ProfileState, ProfileIntent>
    let promoCodeService: PromoCodeServiceProtocol
    let activityService: any ActivityFeedServiceProtocol
    let sportConfig: any SportConfigurationProtocol
    let onEraseCachedData: () -> Void

    @State private var showProfile = false
    @State private var showInbox = false
    @State private var showPaywall = false
    @State private var selectedGame: ScheduledGame?
    private let notificationLogger = PushNotificationLogger.shared

    private var searchBinding: Binding<String> {{
        Binding(
            get: {{ store.state.searchText }},
            set: {{ store.send(.searchTextChanged($0)) }}
        )
    }}

    private var viewModeBinding: Binding<BoardViewMode> {{
        Binding(
            get: {{ store.state.viewMode }},
            set: {{ store.send(.viewModeChanged($0)) }}
        )
    }}

    private var isLoading: Bool {{
        switch store.state.loadState {{
        case .idle, .loading: return true
        default: return false
        }}
    }}

    private var isSubscriptionRequired: Bool {{
        if case let .failed(error) = store.state.loadState,
           case NetworkError.httpError(statusCode: 402, _) = error {{ return true }}
        return false
    }}

    private var subtitleText: String {{
        let weekday = weekdayName(from: store.state.serverDateString)
        let count = store.state.gameCount
        let gamesLabel = String(localized: "board.subtitle.games", defaultValue: "games")
        return "\\(weekday) · \\(count) \\(gamesLabel)"
    }}

    var body: some View {{
        NavigationStack(path: Binding(
            get: {{ store.state.navigationPath }},
            set: {{ store.send(.navigationPathChanged($0)) }}
        )) {{
            boardList
                .appBackground()
                .navigationBarHidden(true)
                .navigationDestination(isPresented: $showProfile) {{
                    ProfileContainerView(
                        credential: credential,
                        profileStore: profileStore,
                        promoCodeService: promoCodeService,
                        onEraseCachedData: {{ // swiftlint:disable:this trailing_closure
                            showProfile = false
                            onEraseCachedData()
                        }}
                    )
                }}
                .navigationDestination(for: BoardEntry.self) {{ entry in
                    BoardDetailView(
                        entry: entry,
                        sportConfig: sportConfig
                    )
                    .appBackground()
                }}
                .navigationDestination(for: DailyAnalysis.self) {{ analysis in
                    SlateAnalysisView(analysis: analysis)
                }}
        }}
        .task {{
            Perf.event("BoardViewTask")
            store.send(.onAppear)
        }}
        .onChange(of: store.state.isBackgroundRefreshing) {{ _, isRefreshing in
            guard isRefreshing else {{ return }}
            Task {{
                try? await Task.sleep(for: .seconds(3))
                store.send(.refreshBannerExpired)
            }}
        }}
        .sheet(item: $selectedGame) {{ game in
            let oddsKey = "\\(game.visitorTeamAbbr)@\\(game.homeTeamAbbr):\\(game.gameSequence)"
            GameDetailSheet(
                game: game,
                odds: store.state.gameOdds[oddsKey],
                spreadLabel: String(localized: "gameDetail.spreadLine", defaultValue: "Spread Line"),
                spreadPickLabel: String(localized: "gameDetail.bkSpreadPick", defaultValue: "BK Pick")
            )
            .presentationDetents([.medium, .large])
        }}
        .sheet(isPresented: $showInbox) {{
            NotificationInboxView(
                logger: notificationLogger,
                activityService: activityService
            ) {{ _ in EmptyView() }}
        }}
        .sheet(isPresented: $showPaywall) {{
            SubscriptionPaywallView(groupID: SubscriptionProductID.subscriptionGroupID) {{
                EmptyView()
            }}
        }}
        .onReceive(NotificationCenter.default.publisher(for: PushNotificationNames.openInboxRequested)) {{ _ in
            showInbox = true
        }}
    }}

    // MARK: - Board list

    private var boardList: some View {{
        VStack(spacing: 0) {{
            BoardNavBar(
                subtitle: subtitleText,
                isLoaded: {{
                    if case .loaded = store.state.loadState {{ return true }}
                    return false
                }}(),
                unreadCount: notificationLogger.unreadCount,
                onInbox: {{ showInbox = true }},
                onProfile: {{ showProfile = true }}
            )
            .skeletonPulse(delay: 0, active: isLoading)

            if !store.state.todayGames.isEmpty {{
                GamesStrip(games: store.state.todayGames) {{ game in
                    game.isDoubleheader ? "DH · Game \\(game.gameSequence)" : nil
                }} onSelect: {{ selectedGame = $0 }}
                    .padding(.top, 8)
                    .skeletonPulse(delay: 0.1, active: isLoading)
            }}

            SlateAnalysisCard(analysis: store.state.dailyAnalysis ?? store.state.analysisPreview.map {{
                DailyAnalysis(
                    date: store.state.serverDateString ?? "",
                    cached: true,
                    slateNarrative: $0,
                    topProjections: [],
                    keyTrends: [],
                    generatedAt: Date()
                )
            }})
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .skeletonPulse(delay: 0.2, active: isLoading)

            Text(String(localized: "board.section.players", defaultValue: "Players"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(AppOpacity.muted))
                .tracking(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .accessibilityAddTraits(.isHeader)

            SearchFilterHeader(
                searchText: searchBinding,
                selectedPosition: store.state.selectedPosition,
                filterAllLabel: String(localized: "board.position.all", defaultValue: "All positions"),
                filterChips: store.state.viewMode == .flat ? SportPositionMap.{slug}.filterChips : [],
                accessibilityPrefix: "board",
                onPositionChanged: {{ store.send(.positionFilterChanged($0)) }},
                tierOptions: store.state.viewMode == .flat
                    ? TierLevel.allCases.map {{ (label: $0.tierDisplayName, id: $0.tierDisplayName) }}
                    : nil,
                tierAllLabel: String(localized: "board.tier.all", defaultValue: "All tiers"),
                selectedTierID: store.state.selectedTier.map {{ $0.tierDisplayName }},
                onTierChanged: {{ id in
                    let tier = id.flatMap {{ label in TierLevel.allCases.first {{ $0.tierDisplayName == label }} }}
                    store.send(.tierFilterChanged(tier))
                }},
                tipsContent: SearchTipsView.init
            )

            BoardViewModePicker(
                allCount: store.state.totalOpportunities > 0
                    ? store.state.totalOpportunities
                    : store.state.filteredEntries.count,
                topPicksCount: store.state.groupedEntries.reduce(0) {{ $0 + $1.picks.count }},
                viewMode: viewModeBinding
            )

            BoardScrollContent(
                loadState: store.state.loadState,
                isSubscriptionRequired: isSubscriptionRequired,
                filteredEntries: store.state.filteredEntries,
                groupedEntries: store.state.groupedEntries,
                viewMode: store.state.viewMode,
                hasMorePages: store.state.hasMorePages,
                isLoadingNextPage: store.state.isLoadingNextPage,
                onRetry: {{ store.send(.refreshRequested) }},
                onShowPaywall: {{ showPaywall = true }},
                onLoadNextPage: {{ store.send(.loadNextPage) }},
                onRefresh: {{ store.send(.refreshRequested) }}
            )
        }}
    }}

    // MARK: - Helpers

    private static let dateParseFormatter: DateFormatter = {{
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }}()

    private static let weekdayFormatter: DateFormatter = {{
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE"
        fmt.locale = .current
        return fmt
    }}()

    private func weekdayName(from serverDateString: String?) -> String {{
        guard let dateString = serverDateString,
              let date = Self.dateParseFormatter.date(from: dateString) else {{
            return Self.weekdayFormatter.string(from: Date.now)
        }}
        return Self.weekdayFormatter.string(from: date)
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

playoff_toggle = """
            Toggle(isOn: Binding(
                get: { profileStore.state.preferences.notificationPreferences.isEnabled(.playoffAlerts) },
                set: { profileStore.send(.notificationPreferenceToggled(.playoffAlerts, $0)) }
            )) {
                Label(
                    String(localized: "profile.row.notifications.playoff",
                           defaultValue: "Playoff Alerts"),
                    systemImage: "trophy.fill"
                )
                .foregroundStyle(.white)
            }
            .tint(.accentColor)
            .accessibilityIdentifier("profile.notification.playoff_alerts")""" if has_playoffs else "            EmptyView()"

notifications_detail_swift = header() + f"""import BKSCore
import BKSUICore
import SwiftUI

// MARK: - NotificationsDetailView
//
// Sport-specific notification preferences injected into BKSNotificationsView.

struct NotificationsDetailView: View {{
    @ObservedObject var profileStore: Store<ProfileState, ProfileIntent>

    var body: some View {{
        BKSNotificationsView(
            profileStore: profileStore,
            appName: String(localized: "app.name", defaultValue: "{app_name}")
        ) {{{playoff_toggle}
        }}
    }}
}}
"""

# ── BoardNavBar.swift ────────────────────────────────────────────────────────────────────────

board_nav_bar_swift = header() + f"""import BKSUICore
import SwiftUI

// MARK: - BoardNavBar

struct BoardNavBar: View {{
    let subtitle: String
    let isLoaded: Bool
    let unreadCount: Int
    let onInbox: () -> Void
    let onProfile: () -> Void

    var body: some View {{
        AppCustomNavBar(
            title: String(localized: "board.title", defaultValue: "Today's Blackboard"),
            subtitle: subtitle,
            slotWidth: 60,
            leading: {{
                if isLoaded {{
                    Image("InAppIcon")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }} else {{
                    Color.clear.frame(width: 48, height: 48)
                }}
            }},
            trailing: {{
                HStack(spacing: 16) {{
                    Button(action: onInbox) {{
                        ZStack(alignment: .topTrailing) {{
                            Image(systemName: "bell.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.white)
                            if unreadCount > 0 {{
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 4, y: -4)
                            }}
                        }}
                    }}
                    .accessibilityLabel(
                        unreadCount > 0
                            ? String(localized: "a11y.label.alertsUnread",
                                     defaultValue: "Alerts, \\(unreadCount) unread")
                            : String(localized: "a11y.label.alerts", defaultValue: "Alerts")
                    )
                    Button(action: onProfile) {{
                        Image(systemName: "person")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                    }}
                    .accessibilityLabel(String(localized: "a11y.label.profile", defaultValue: "Profile"))
                }}
            }}
        )
    }}
}}
"""

# ── BoardViewModePicker.swift ────────────────────────────────────────────────────────────────

board_view_mode_picker_swift = header() + f"""import BKSCore
import SwiftUI

// MARK: - BoardViewModePicker

struct BoardViewModePicker: View {{
    let allCount: Int
    let topPicksCount: Int
    let viewMode: Binding<BoardViewMode>

    var body: some View {{
        let allLabel = "\\(String(localized: "board.view.all", defaultValue: "All Players")) (\\(allCount))"
        let topPicksBase = String(localized: "board.view.byPosition", defaultValue: "BlackKatt Instinct")
        let topPicksLabel = "\\(topPicksBase) (\\(topPicksCount))"
        Picker(String(localized: "board.picker.label", defaultValue: "View mode"), selection: viewMode) {{
            Text(topPicksLabel).tag(BoardViewMode.byPosition)
            Text(allLabel).tag(BoardViewMode.flat)
        }}
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }}
}}
"""

# ── BoardScrollContent.swift ─────────────────────────────────────────────────────────────────

board_scroll_content_swift = header() + f"""import BKSCore
import BKSUICore
import SwiftUI

// MARK: - BoardScrollContent

struct BoardScrollContent: View {{
    let loadState: ViewState<[BoardEntry]>
    let filteredEntries: [BoardEntry]
    let groupedEntries: [(position: String, picks: [BoardEntry])]
    let viewMode: BoardViewMode
    let onRetry: () -> Void
    let onRefresh: () -> Void

    var body: some View {{
        ScrollView {{
            switch loadState {{
            case .idle, .loading:
                BoardSkeletonView()
                    .padding(.bottom, 16)

            case .failed:
                VStack(spacing: 12) {{
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(AppOpacity.muted))
                    Text(String(localized: "board.error", defaultValue: "Unable to load board"))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(AppOpacity.muted))
                        .multilineTextAlignment(.center)
                    Button(String(localized: "board.retry", defaultValue: "Try again")) {{
                        onRetry()
                    }}
                    .buttonStyle(.borderedProminent)
                }}
                .padding(.top, 40)
                .padding(.horizontal, 24)

            case .loaded:
                if filteredEntries.isEmpty {{
                    VStack(spacing: 12) {{
                        Image(systemName: "sportscourt")
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(AppOpacity.muted))
                        Text(String(localized: "board.empty", defaultValue: "No picks today"))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(AppOpacity.muted))
                            .multilineTextAlignment(.center)
                    }}
                    .padding(.top, 40)
                    .padding(.horizontal, 24)
                }} else {{
                    switch viewMode {{
                    case .flat:
                        LazyVStack(spacing: 0) {{
                            ForEach(filteredEntries, id: \\.id) {{ entry in
                                NavigationLink(value: entry) {{
                                    // TODO: replace with sport-specific card view
                                    VStack(alignment: .leading, spacing: 2) {{
                                        Text(entry.displayName)
                                            .font(.headline)
                                            .foregroundStyle(.white)
                                        if let score = entry.projectedScore {{
                                            Text(String(format: "%.1f DK pts", score))
                                                .font(.caption)
                                                .foregroundStyle(.white.opacity(AppOpacity.muted))
                                        }}
                                    }}
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                }}
                                .buttonStyle(.plain)
                                Divider().overlay(.white.opacity(0.1))
                            }}
                        }}
                        .padding(.bottom, 16)

                    case .byPosition:
                        VStack(spacing: 0) {{
                            ForEach(groupedEntries, id: \\.position) {{ group in
                                HStack {{
                                    Text(group.position)
                                        .font(AppFonts.sectionHeader)
                                        .foregroundStyle(.white.opacity(AppOpacity.primary))
                                        .tracking(1.2)
                                        .accessibilityAddTraits(.isHeader)
                                    Spacer()
                                }}
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.white.opacity(0.07))
                                ForEach(group.picks, id: \\.id) {{ entry in
                                    NavigationLink(value: entry) {{
                                        // TODO: replace with sport-specific card view
                                        Text(entry.displayName)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 12)
                                    }}
                                    .buttonStyle(.plain)
                                    Divider().overlay(.white.opacity(0.1))
                                }}
                            }}
                        }}
                        .padding(.bottom, 16)
                    }}
                }}
            }}
        }}
        .refreshable {{ onRefresh() }}
        .contentMargins(.bottom, AppPadding.tabBarClearance, for: .scrollContent)
    }}
}}
"""

# ── BoardDetailView.swift ────────────────────────────────────────────────────────────────────

board_detail_view_swift = header() + f"""import BKSCore
import BKSUICore
import SwiftUI

// MARK: - BoardDetailView

struct BoardDetailView: View {{
    let entry: BoardEntry
    let sportConfig: any SportConfigurationProtocol

    @Environment(\\.gamesService) private var gamesServiceBox
    @State private var regularSeasonLog: PlayerGameLog?
    @State private var expandedPlatform: String?

    var body: some View {{
        ScrollView {{
            VStack(spacing: 12) {{
                UnifiedHeaderCard(entry: entry, log: regularSeasonLog)

                if entry.playFadeRecommendation != nil {{
                    PlayFadeCard(entry: entry)
                }}

                DetailSectionHeader(
                    String(localized: "boardDetail.section.recentGames", defaultValue: "Recent Games")
                )

                GameLogCard(entry: entry, log: regularSeasonLog)

                if let propLines = entry.propLines, !propLines.isEmpty {{
                    DetailSectionHeader(
                        String(localized: "boardDetail.section.propLines", defaultValue: "Prop Lines")
                    )
                    PropLinesCard(propLines: propLines)
                }}

                DetailSectionHeader(
                    String(localized: "boardDetail.section.projections", defaultValue: "Projections")
                )

                ProjectionSection(entry: entry, expandedPlatform: $expandedPlatform)
            }}
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 20)
        }}
        .contentMargins(.bottom, AppPadding.tabBarClearance, for: .scrollContent)
        .appBackground()
        .appNavigationBar(
            title: String(localized: "boardDetail.title", defaultValue: "Player")
        )
        .task {{
            guard !entry.id.isEmpty, let service = gamesServiceBox?.service else {{ return }}
            let cached = try? service.loadCachedGameLog(playerID: entry.id)
            let cacheAge = cached.map {{ Date().timeIntervalSince($0.fetchedAt) }}
            let isFresh = cacheAge.map {{ $0 < 4 * 3600 }} ?? false
            if let cached {{
                regularSeasonLog = cached
            }}
            if !isFresh {{
                regularSeasonLog = try? await service.fetchGameLog(
                    playerID: entry.id,
                    teamID: entry.team,
                    postseason: false
                )
            }}
        }}
    }}
}}
"""

# ── BoardDetailSubviews.swift ─────────────────────────────────────────────────────────────────
#
# Sport-specific sections are marked with MARK comments. When scaffolding a new sport:
#   - BKInstinctCard.batterStatLine: replace stat columns with sport-relevant categories
#   - BKInstinctCard.pitcherStatLine: keep for baseball/softball, remove for non-pitching sports
#   - PropLinesCard.sortedLines: update the key ordering for sport-specific market keys
#   - GameLogCard.lastGameSummary: update the summary stat labels
#
board_detail_subviews_swift = header() + f"""// swiftlint:disable file_length
import BKSCore
import BKSUICore
import SwiftUI

// MARK: - ProjectionSection

struct ProjectionSection: View {{
    let entry: BoardEntry
    @Binding var expandedPlatform: String?

    var body: some View {{
        VStack(spacing: 8) {{
            ProjectionCardView(
                platformID: "dk",
                abbreviation: "DK",
                name: String(localized: "projection.platform.dk", defaultValue: "DraftKings"),
                color: AppColors.dkGreen,
                score: entry.projectedScore,
                floor: entry.fpFloor,
                ceiling: entry.fpCeiling,
                confidence: entry.confidenceScore,
                playoffDataConfidence: entry.playoffDataConfidence,
                projectionTier: entry.projectionTier,
                isExpanded: expandedPlatform == "dk"
            ) {{
                withAnimation(.easeInOut(duration: 0.3)) {{
                    expandedPlatform = expandedPlatform == "dk" ? nil : "dk"
                }}
            }}

            if entry.projectedScoreFd != nil {{
                ProjectionCardView(
                    platformID: "fd",
                    abbreviation: "FD",
                    name: String(localized: "projection.platform.fd", defaultValue: "FanDuel"),
                    color: Color(red: 0.11, green: 0.51, blue: 0.85),
                    score: entry.projectedScoreFd,
                    floor: entry.fpFloorFd,
                    ceiling: entry.fpCeilingFd,
                    confidence: entry.confidenceScoreFd,
                    playoffDataConfidence: entry.playoffDataConfidence,
                    projectionTier: entry.projectionTier,
                    isExpanded: expandedPlatform == "fd"
                ) {{
                    withAnimation(.easeInOut(duration: 0.3)) {{
                        expandedPlatform = expandedPlatform == "fd" ? nil : "fd"
                    }}
                }}
            }}

            BKInstinctCard(
                entry: entry,
                isExpanded: expandedPlatform == "bk"
            ) {{
                withAnimation(.easeInOut(duration: 0.3)) {{
                    expandedPlatform = expandedPlatform == "bk" ? nil : "bk"
                }}
            }}

            if expandedPlatform == nil {{
                Text(String(localized: "projection.hint.tapToExpand", defaultValue: "Tap a card to expand"))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)
            }}
        }}
    }}
}}

// MARK: - ProjectionCardView

struct ProjectionCardView: View {{
    let platformID: String
    let abbreviation: String
    let name: String
    let color: Color
    let score: Double?
    let floor: Double?
    let ceiling: Double?
    let confidence: Double?
    let playoffDataConfidence: Double?
    let projectionTier: TierLevel?
    let isExpanded: Bool
    let onTap: () -> Void

    private var isLowConfidence: Bool {{
        (confidence.map {{ $0 < 0.4 }} ?? false)
            || (playoffDataConfidence.map {{ $0 < 0.15 }} ?? false)
    }}

    var body: some View {{
        VStack(spacing: 0) {{
            Button(action: onTap) {{
                HStack(spacing: 0) {{
                    HStack(spacing: 9) {{
                        PlatformBadge(label: abbreviation, background: color, size: 26, fontSize: 10)
                        Text(name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }}
                    Spacer(minLength: 8)
                    HStack(alignment: .center, spacing: 8) {{
                        Text(String(localized: "projection.label.projScore", defaultValue: "Projected Score"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                            .tracking(0.5)
                        Text(score.map {{ "\\(Int($0))" }} ?? "—")
                            .font(.system(size: 20, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .tracking(-0.5)
                    }}
                    .frame(minWidth: 68, alignment: .trailing)
                    .padding(.leading, 8)
                    .opacity(isExpanded ? 0 : 1)
                    .animation(.easeOut(duration: 0.2), value: isExpanded)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeOut(duration: 0.25), value: isExpanded)
                        .padding(.leading, 12)
                }}
                .padding(.horizontal, 12)
                .frame(height: 46)
            }}
            .buttonStyle(.plain)
            .accessibilityLabel({{
                let scoreStr = score.map {{ String(format: "%.1f", $0) }}
                    ?? String(localized: "a11y.unavailable", defaultValue: "unavailable")
                let action = isExpanded
                    ? String(localized: "a11y.doubleTapCollapse", defaultValue: "Double tap to collapse")
                    : String(localized: "a11y.doubleTapExpand", defaultValue: "Double tap to expand")
                return "\\(name) projected score: \\(scoreStr). \\(action)"
            }}())

            if isExpanded {{
                VStack(alignment: .leading, spacing: 12) {{
                    if let projScore = score {{
                        FloorCeilingBar(
                            floor: floor,
                            ceiling: ceiling,
                            score: projScore,
                            tier: projectionTier,
                            isLowConfidence: isLowConfidence,
                            showFloorCeilingLabels: true,
                            showScoreLabel: true,
                            showEndLabels: true
                        )
                        .padding(.horizontal, 2)
                    }}

                    if isLowConfidence {{
                        HStack(spacing: 4) {{
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                                .accessibilityHidden(true)
                            Text(String(localized: "boardProjections.lowConfidence",
                                        defaultValue: "Low confidence — projections may be less reliable"))
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(AppOpacity.muted))
                        }}
                    }}
                }}
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }}
        }}
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }}
}}

// MARK: - BKInstinctCard

struct BKInstinctCard: View {{
    let entry: BoardEntry
    let isExpanded: Bool
    let onTap: () -> Void

    private var projectedStats: ProjectedStatLine? {{
        entry.upcomingGames?.first?.projectedStats
    }}

    private var confidence: Double? {{ projectedStats?.confidence }}
    private var isLowConfidence: Bool {{ (confidence ?? 1) < 0.5 }}

    // MARK: - Sport-specific: update isPitcher for sports without pitchers
    private var isPitcher: Bool {{
        entry.rotationTier != nil || entry.position?.lowercased() == "p"
    }}

    var body: some View {{
        VStack(spacing: 0) {{
            Button(action: onTap) {{
                HStack(spacing: 0) {{
                    HStack(spacing: 9) {{
                        Image("InAppIcon")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .accessibilityHidden(true)
                        Text(String(localized: "projection.platform.bk", defaultValue: "BlackKatt Instinct"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }}
                    Spacer(minLength: 8)
                    HStack(alignment: .center, spacing: 8) {{
                        Text(String(localized: "projection.label.projPts", defaultValue: "Projected Pts"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                            .tracking(0.5)
                        Text(entry.projectedScore.map {{ "\\(Int($0))" }} ?? "—")
                            .font(.system(size: 20, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .tracking(-0.5)
                    }}
                    .frame(minWidth: 68, alignment: .trailing)
                    .padding(.leading, 8)
                    .opacity(isExpanded ? 0 : 1)
                    .animation(.easeOut(duration: 0.2), value: isExpanded)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeOut(duration: 0.25), value: isExpanded)
                        .padding(.leading, 12)
                }}
                .padding(.horizontal, 12)
                .frame(height: 46)
            }}
            .buttonStyle(.plain)

            if isExpanded {{
                VStack(alignment: .leading, spacing: 12) {{
                    if let stats = projectedStats {{
                        statLineRow(stats: stats)
                            .opacity(isLowConfidence ? AppOpacity.muted : 1)
                        if isLowConfidence {{ lowConfidenceWarning }}
                    }} else {{
                        Text(String(
                            localized: "detail.proj.bk.unavailable",
                            defaultValue: "Stat breakdown not yet available"
                        ))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(AppOpacity.muted))
                        .frame(maxWidth: .infinity, alignment: .center)
                    }}
                }}
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }}
        }}
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }}

    @ViewBuilder
    private func statLineRow(stats: ProjectedStatLine) -> some View {{
        if isPitcher {{ pitcherStatLine(stats: stats) }} else {{ batterStatLine(stats: stats) }}
    }}

    // MARK: - Sport-specific: replace columns with sport-relevant stat categories
    private func batterStatLine(stats: ProjectedStatLine) -> some View {{
        HStack(spacing: 0) {{
            bkStatCol(label: "H", value: stats.hits.map {{ String(format: "%.1f", $0) }})
            bkDivider
            bkStatCol(label: "HR", value: stats.homeRuns.map {{ String(format: "%.1f", $0) }})
            bkDivider
            bkStatCol(label: "RBI", value: stats.rbis.map {{ String(format: "%.1f", $0) }})
            bkDivider
            bkStatCol(label: "R", value: stats.runs.map {{ String(format: "%.1f", $0) }})
            bkDivider
            bkStatCol(label: "SB", value: stats.stolenBases.map {{ String(format: "%.1f", $0) }})
        }}
        .frame(maxWidth: .infinity)
    }}

    // MARK: - Sport-specific: remove for non-pitching sports
    private func pitcherStatLine(stats: ProjectedStatLine) -> some View {{
        HStack(spacing: 0) {{
            bkStatCol(label: "IP", value: stats.inningsPitched.map {{ String(format: "%.1f", $0) }})
            bkDivider
            bkStatCol(label: "K", value: stats.strikeoutPitching.map {{ String(format: "%.0f", $0) }})
            bkDivider
            bkStatCol(label: "ER", value: stats.earnedRunAllowed.map {{ String(format: "%.0f", $0) }})
        }}
        .frame(maxWidth: .infinity)
    }}

    private func bkStatCol(label: String, value: String?) -> some View {{
        VStack(spacing: 3) {{
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(AppOpacity.muted))
            Text(value ?? "—")
                .font(AppFonts.statValue.monospacedDigit())
                .foregroundStyle(.white)
        }}
        .frame(maxWidth: .infinity)
    }}

    private var bkDivider: some View {{
        Rectangle()
            .fill(.white.opacity(AppOpacity.divider))
            .frame(width: 1, height: 28)
    }}

    private var lowConfidenceWarning: some View {{
        HStack(spacing: 4) {{
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(String(localized: "boardProjections.lowConfidence",
                        defaultValue: "Low confidence — projections may be less reliable"))
                .font(.caption2)
                .foregroundStyle(.white.opacity(AppOpacity.muted))
        }}
    }}
}}

// MARK: - GameLogCard

struct GameLogCard: View {{
    let entry: BoardEntry
    let log: PlayerGameLog?

    @State private var isExpanded = false

    private var recentEntries: [GameEntry] {{
        guard let log else {{ return [] }}
        return Array(log.entries.filter {{ !$0.isDNP }}.prefix(10))
    }}

    var body: some View {{
        VStack(spacing: 0) {{
            Button {{
                withAnimation(.easeOut(duration: 0.25)) {{ isExpanded.toggle() }}
            }} label: {{
                HStack {{
                    if let last = recentEntries.first {{
                        lastGameSummary(last)
                    }} else if log == nil {{
                        Text(String(localized: "detail.gamelog.loading", defaultValue: "Loading…"))
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(AppOpacity.muted))
                    }} else {{
                        Text(String(localized: "detail.gamelog.empty", defaultValue: "No games available"))
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(AppOpacity.muted))
                    }}
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeOut(duration: 0.25), value: isExpanded)
                        .padding(.leading, 12)
                }}
                .padding(.horizontal, 12)
                .frame(height: 46)
            }}
            .buttonStyle(.plain)

            if isExpanded {{
                if recentEntries.isEmpty {{
                    Text(String(localized: "detail.gamelog.empty", defaultValue: "No games available"))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(AppOpacity.muted))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }} else {{
                    GameLogTableView(entries: recentEntries)
                        .padding(.bottom, 8)
                }}
            }}
        }}
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }}

    // MARK: - Sport-specific: update summary stat labels for this sport
    private func lastGameSummary(_ game: GameEntry) -> some View {{
        HStack(spacing: 8) {{
            Text(game.opponentAbbreviation.isEmpty ? "—" : game.opponentAbbreviation)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text("\\(game.homeRun)HR · \\(game.rbi)RBI")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(AppOpacity.secondary))
        }}
    }}
}}

// MARK: - PropLinesCard

struct PropLinesCard: View {{
    let propLines: [String: PropLine]

    // MARK: - Sport-specific: update key ordering for this sport's market keys
    private var sortedLines: [(key: String, value: PropLine)] {{
        let order = [
            "hits_0.5", "total_bases_1.5", "total_bases_2.5",
            "home_runs_0.5", "rbi_0.5", "strikeouts_4.5", "strikeouts_5.5"
        ]
        return propLines.sorted {{ lhs, rhs in
            let li = order.firstIndex(of: lhs.key) ?? Int.max
            let ri = order.firstIndex(of: rhs.key) ?? Int.max
            return li == ri ? lhs.key < rhs.key : li < ri
        }}
    }}

    var body: some View {{
        VStack(spacing: 0) {{
            ForEach(Array(sortedLines.enumerated()), id: \\.element.key) {{ index, item in
                if index > 0 {{
                    Divider()
                        .background(.white.opacity(AppOpacity.hairline))
                        .padding(.leading, 12)
                }}
                propRow(item.value)
            }}
        }}
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }}

    private func propRow(_ prop: PropLine) -> some View {{
        HStack(spacing: 8) {{
            if prop.hasEdge {{
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.yellow)
                    .frame(width: 14)
                    .accessibilityLabel(String(localized: "a11y.propLine.edge", defaultValue: "Edge pick"))
            }} else {{
                Spacer().frame(width: 14)
            }}

            Text(prop.displayLabel)
                .font(.system(size: 13, weight: prop.hasEdge ? .semibold : .regular))
                .foregroundStyle(prop.hasEdge ? .white : .white.opacity(AppOpacity.secondary))
                .lineLimit(1)

            Spacer()

            HStack(spacing: 4) {{
                oddsChip(
                    label: String(localized: "propLine.over", defaultValue: "O"),
                    odds: prop.overOdds,
                    isHighlighted: prop.hasEdge
                )
                oddsChip(
                    label: String(localized: "propLine.under", defaultValue: "U"),
                    odds: prop.underOdds,
                    isHighlighted: false
                )
            }}
        }}
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }}

    private func oddsChip(label: String, odds: Int, isHighlighted: Bool) -> some View {{
        let formatted = odds > 0 ? "+\\(odds)" : "\\(odds)"
        return HStack(spacing: 2) {{
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(AppOpacity.muted))
            Text(formatted)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(isHighlighted ? .yellow : .white.opacity(AppOpacity.secondary))
        }}
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.white.opacity(isHighlighted ? 0.12 : 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }}
}}

// MARK: - RotationTier display helpers
// Sport-specific: remove or replace this extension for non-baseball sports

extension RotationTier {{
    var displayLabel: String {{
        switch self {{
        case .ace: "ACE"
        case .rotation: "ROTATION"
        case .bullpen: "BULLPEN"
        case .closer: "CLOSER"
        case .swingman: "SWINGMAN"
        }}
    }}

    var pillColor: Color {{
        switch self {{
        case .ace: Color(red: 1.0, green: 0.84, blue: 0.0)
        case .rotation: Color(red: 0.4, green: 0.8, blue: 1.0)
        case .bullpen: .white.opacity(0.6)
        case .closer: Color(red: 0.95, green: 0.6, blue: 0.2)
        case .swingman: Color(red: 0.7, green: 0.7, blue: 0.7)
        }}
    }}
}}
"""

# ── BoardDetailHeaderCard.swift ───────────────────────────────────────────────────────────────
#
# Sport-specific sections:
#   - batterStatRow: replace label/value pairs with this sport's per-game averages
#   - pitcherStatRow: remove for non-pitching sports
#   - seasonMetricsRow: replace fields with this sport's season metrics (avoidingAvg/OBP/SLG)
#   - hasSeasonMetrics: update the nil-checks to match actual BoardEntry season fields
#
board_detail_header_card_swift = header() + f"""import BKSCore
import BKSUICore
import SwiftUI

// MARK: - UnifiedHeaderCard

struct UnifiedHeaderCard: View {{
    let entry: BoardEntry
    let log: PlayerGameLog?

    // MARK: - Sport-specific: update isPitcher for sports without pitchers
    private var isPitcher: Bool {{
        entry.rotationTier != nil || entry.position?.lowercased() == "p"
    }}

    private static let timeFormatter: DateFormatter = {{
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.locale = Locale.current
        return formatter
    }}()

    var body: some View {{
        VStack(alignment: .leading, spacing: 10) {{
            HStack(alignment: .top, spacing: 12) {{
                avatarView
                VStack(alignment: .leading, spacing: 4) {{
                    Text(entry.displayName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    matchupLine
                    if entry.isConfirmedStarter == true {{
                        Label(
                            String(localized: "detail.confirmed", defaultValue: "Confirmed"),
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                    }}
                    rotationTierPill
                }}
                Spacer()
            }}

            if let activeLog = log, !activeLog.entries.isEmpty {{
                Divider().overlay(.white.opacity(AppOpacity.divider))
                if isPitcher {{
                    pitcherStatRow(log: activeLog)
                }} else {{
                    batterStatRow(log: activeLog)
                }}
            }} else if log == nil {{
                ProgressView()
                    .tint(.white.opacity(AppOpacity.muted))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            }}

            if hasSeasonMetrics {{
                Divider().overlay(.white.opacity(AppOpacity.divider))
                seasonMetricsRow
            }}
        }}
        .padding(AppPadding.cardInner)
        .appCard()
    }}

    private var avatarView: some View {{
        ZStack(alignment: .topLeading) {{
            CachedAsyncImage(url: entry.headshotURL) {{ phase in
                switch phase {{
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Circle().fill(entry.avatarColor)
                        .overlay(
                            Text(entry.initials)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                }}
            }}
            .frame(width: 56, height: 56)
            .clipShape(Circle())

            if let injury = entry.injuryStatus {{
                InjuryBadge(status: injury, compact: true)
                    .offset(x: -4, y: -4)
            }}
        }}
    }}

    private var matchupLine: some View {{
        HStack(spacing: 4) {{
            if let pos = entry.position {{
                Text(pos)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(AppOpacity.secondary))
                Text("·").foregroundStyle(.white.opacity(AppOpacity.muted))
            }}
            if let opp = entry.opponentAbbr {{
                let prefix = entry.isHome == true
                    ? String(localized: "detail.home", defaultValue: "vs")
                    : String(localized: "detail.away", defaultValue: "@")
                Text("\\(prefix) \\(opp)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(AppOpacity.secondary))
            }}
            if let dt = entry.gameDateTime {{
                Text("·").foregroundStyle(.white.opacity(AppOpacity.muted))
                Text(Self.timeFormatter.string(from: dt))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(AppOpacity.muted))
            }}
        }}
    }}

    @ViewBuilder
    private var rotationTierPill: some View {{
        if let tier = entry.rotationTier {{
            Text(tier.displayLabel)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(tier.pillColor.opacity(0.25))
                .foregroundStyle(tier.pillColor)
                .clipShape(Capsule())
        }}
    }}

    // MARK: - Sport-specific: replace per-game average labels/values
    private func batterStatRow(log: PlayerGameLog) -> some View {{
        HStack(spacing: 0) {{
            statCell(label: "AVG", value: String(format: ".%03d", Int(log.averageBattingAverage * 1000)))
            statDivider
            statCell(label: "H/G", value: String(format: "%.1f", log.averageHits))
            statDivider
            statCell(label: "HR", value: String(format: "%.1f", log.averageHomeRuns))
            statDivider
            statCell(label: "RBI", value: String(format: "%.1f", log.averageRBI))
        }}
    }}

    // MARK: - Sport-specific: remove for non-pitching sports
    private func pitcherStatRow(log: PlayerGameLog) -> some View {{
        HStack(spacing: 0) {{
            statCell(label: "IP", value: String(format: "%.1f", log.averageInningsPitched))
            statDivider
            statCell(label: "K", value: String(format: "%.1f", log.averageStrikeouts))
            statDivider
            statCell(label: "ERA", value: String(format: "%.2f", log.averageERA))
            statDivider
            statCell(label: "WIN%", value: String(format: "%.0f%%", log.winPercentage * 100))
        }}
    }}

    private var statDivider: some View {{
        Rectangle().fill(.white.opacity(AppOpacity.divider)).frame(width: 1, height: 28)
    }}

    private func statCell(label: String, value: String) -> some View {{
        VStack(spacing: 2) {{
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(AppOpacity.muted))
                .lineLimit(1)
            Text(value)
                .font(AppFonts.statValue)
                .foregroundStyle(.white)
        }}
        .frame(maxWidth: .infinity)
    }}

    // MARK: - Sport-specific: update nil-checks to match this sport's BoardEntry season fields
    private var hasSeasonMetrics: Bool {{
        entry.seasonAvg != nil || entry.seasonOBP != nil ||
        entry.seasonSLG != nil || entry.seasonOPS != nil
    }}

    // MARK: - Sport-specific: replace with this sport's season metric columns
    private var seasonMetricsRow: some View {{
        HStack(spacing: 0) {{
            if let avg = entry.seasonAvg {{
                statCell(label: "AVG", value: String(format: ".%03d", Int(avg * 1000)))
            }}
            if let obp = entry.seasonOBP {{
                if entry.seasonAvg != nil {{ statDivider }}
                statCell(label: "OBP", value: String(format: ".%03d", Int(obp * 1000)))
            }}
            if let slg = entry.seasonSLG {{
                if entry.seasonAvg != nil || entry.seasonOBP != nil {{ statDivider }}
                statCell(label: "SLG", value: String(format: ".%03d", Int(slg * 1000)))
            }}
            if let ops = entry.seasonOPS {{
                if entry.seasonAvg != nil || entry.seasonOBP != nil || entry.seasonSLG != nil {{
                    statDivider
                }}
                statCell(label: "OPS", value: String(format: ".%03d", Int(ops * 1000)))
            }}
        }}
    }}
}}

// MARK: - PlayFadeCard

struct PlayFadeCard: View {{
    let entry: BoardEntry

    private var recommendation: PlayFadeRecommendation {{ entry.playFadeRecommendation ?? .neutral }}

    private var recColor: Color {{
        switch recommendation {{
        case .play: .green
        case .fade: Color(red: 0.95, green: 0.35, blue: 0.35)
        case .neutral: .gray
        }}
    }}

    private var icon: String {{
        switch recommendation {{
        case .play: "arrow.up"
        case .fade: "arrow.down"
        case .neutral: "minus"
        }}
    }}

    private var recLabel: String {{
        switch recommendation {{
        case .play: String(localized: "boardProjections.play", defaultValue: "Play").uppercased()
        case .fade: String(localized: "boardProjections.fade", defaultValue: "Fade").uppercased()
        case .neutral: String(localized: "boardProjections.neutral", defaultValue: "Neutral").uppercased()
        }}
    }}

    var body: some View {{
        VStack(alignment: .leading, spacing: 8) {{
            HStack(alignment: .center) {{
                VStack(alignment: .leading, spacing: 2) {{
                    HStack(spacing: 6) {{
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(recColor)
                            .accessibilityHidden(true)
                        Text(recLabel)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }}
                    if let confidence = entry.confidenceScore {{
                        Text(String(format: "%.0f%% ", confidence * 100) + String(
                            localized: "boardDetail.recommendation.confidence",
                            defaultValue: "Confidence"
                        ))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(AppOpacity.primary))
                    }}
                }}

                Spacer()

                if let parkFactor = entry.parkFactor {{
                    dmsColumn(
                        title: String(localized: "detail.playfade.parkfactor", defaultValue: "Park Factor"),
                        value: String(format: "%.0f", parkFactor * 100)
                    )
                }} else if let opp = entry.opportunityScore {{
                    dmsColumn(
                        title: String(localized: "boardDetail.recommendation.dms", defaultValue: "DMS"),
                        value: "\\(Int(opp))"
                    )
                }}
            }}
        }}
        .padding(10)
        .background(recColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(recColor.opacity(0.3), lineWidth: 1)
        )
    }}

    private func dmsColumn(title: String, value: String) -> some View {{
        VStack(alignment: .trailing, spacing: 2) {{
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(recColor)
        }}
    }}
}}

// MARK: - TrendSlopesCard
// Sport-specific: update trendItems pairs to match this sport's BoardEntry trend fields

struct TrendSlopesCard: View {{
    let entry: BoardEntry

    struct TrendItem: Identifiable {{
        let id: String
        let label: String
        let slope: Double
    }}

    var trendItems: [TrendItem] {{
        var result: [TrendItem] = []
        let pairs: [(Double?, String, String)] = [
            (entry.trendHits, "hits", "Hits"),
            (entry.trendHR, "hr", "HR"),
            (entry.trendRBI, "rbi", "RBI"),
            (entry.trendRuns, "r", "R"),
            (entry.trendSB, "sb", "SB"),
            (entry.trendDoubles, "2b", "2B"),
            (entry.trendTB, "tb", "TB")
        ]
        for (slope, identifier, label) in pairs {{
            if let slope {{ result.append(.init(id: identifier, label: label, slope: slope)) }}
        }}
        return result
    }}

    var body: some View {{
        if trendItems.isEmpty {{
            EmptyView()
        }} else {{
            VStack(alignment: .leading, spacing: 8) {{
                DetailSectionHeader(
                    String(localized: "detail.section.trends", defaultValue: "RECENT TRENDS")
                )
                BadgeFlowLayout(spacing: 6) {{
                    ForEach(trendItems) {{ item in TrendPill(item: item) }}
                }}
            }}
            .padding(AppPadding.cardInner)
            .appCard()
        }}
    }}
}}

struct TrendPill: View {{
    let item: TrendSlopesCard.TrendItem

    private static let threshold = 0.05

    private var pillColor: Color {{
        if item.slope > Self.threshold {{ return .green }}
        if item.slope < -Self.threshold {{ return Color(red: 0.95, green: 0.35, blue: 0.35) }}
        return .white.opacity(AppOpacity.muted)
    }}

    private var arrow: String {{
        if item.slope > Self.threshold {{ return "↑" }}
        if item.slope < -Self.threshold {{ return "↓" }}
        return "→"
    }}

    var body: some View {{
        HStack(spacing: 3) {{
            Text(arrow).font(.system(size: 11, weight: .bold)).foregroundStyle(pillColor)
            Text(item.label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
        }}
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(pillColor.opacity(0.15))
        .clipShape(Capsule())
    }}
}}
"""

# ── Write all files ─────────────────────────────────────────────────────────────────────────

write(os.path.join(board_models_dir,  "BoardEntry.swift"),               board_entry_swift)
write_if_absent(os.path.join(board_models_dir,  "BoardEntryBuilder.swift"), board_entry_builder_swift)
write(os.path.join(board_store_dir,   "BoardIntent.swift"),              board_intent_swift)
write(os.path.join(board_store_dir,   "BoardState.swift"),               board_state_swift)
write_if_absent(os.path.join(board_views_dir,   "BoardView.swift"),                board_view_swift)
write_if_absent(os.path.join(board_views_dir,   "BoardNavBar.swift"),              board_nav_bar_swift)
write_if_absent(os.path.join(board_views_dir,   "BoardViewModePicker.swift"),      board_view_mode_picker_swift)
write_if_absent(os.path.join(board_views_dir,   "BoardScrollContent.swift"),       board_scroll_content_swift)
write_if_absent(os.path.join(board_views_dir,   "BoardDetailView.swift"),          board_detail_view_swift)
write_if_absent(os.path.join(board_views_dir,   "BoardDetailSubviews.swift"),      board_detail_subviews_swift)
write_if_absent(os.path.join(board_views_dir,   "BoardDetailHeaderCard.swift"),    board_detail_header_card_swift)
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

// xcconfig treats // as a comment — use $(SLASH) to embed // in URL values
SLASH = /

// Cloud Function URLs
REDEEM_PROMO_CODE_URL = https:$(SLASH)/<your-dev-host>/redeem_promo_code
GET_ACTIVITY_FEED_URL = https:$(SLASH)/<your-dev-host>/get_activity_feed
GET_DAILY_ANALYSIS_URL = https:$(SLASH)/<your-dev-host>/get_daily_analysis
UPDATE_USER_PREFERENCES_URL = https:$(SLASH)/<your-dev-host>/update_user_preferences
GET_LEAGUE_STATE_URL = https:$(SLASH)/<your-dev-host>/get_league_state
GET_PLAYOFF_BRACKET_URL = https:$(SLASH)/<your-dev-host>/get_playoff_bracket

// Cloud Run URLs
GET_PLAYERS_URL = https:$(SLASH)/<your-dev-host>/get_players
GET_OPPORTUNITIES_URL = https:$(SLASH)/<your-dev-host>/get_opportunities
GET_BOARD_URL = https:$(SLASH)/<your-dev-host>/get_board
GET_PROJECTIONS_URL = https:$(SLASH)/<your-dev-host>/get_projections
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

// xcconfig treats // as a comment — use $(SLASH) to embed // in URL values
SLASH = /

// Cloud Function URLs
REDEEM_PROMO_CODE_URL = https:$(SLASH)/<your-prod-host>/redeem_promo_code
GET_ACTIVITY_FEED_URL = https:$(SLASH)/<your-prod-host>/get_activity_feed
GET_DAILY_ANALYSIS_URL = https:$(SLASH)/<your-prod-host>/get_daily_analysis
UPDATE_USER_PREFERENCES_URL = https:$(SLASH)/<your-prod-host>/update_user_preferences
GET_LEAGUE_STATE_URL = https:$(SLASH)/<your-prod-host>/get_league_state
GET_PLAYOFF_BRACKET_URL = https:$(SLASH)/<your-prod-host>/get_playoff_bracket

// Cloud Run URLs
GET_PLAYERS_URL = https:$(SLASH)/<your-prod-host>/get_players
GET_OPPORTUNITIES_URL = https:$(SLASH)/<your-prod-host>/get_opportunities
GET_BOARD_URL = https:$(SLASH)/<your-prod-host>/get_board
GET_PROJECTIONS_URL = https:$(SLASH)/<your-prod-host>/get_projections
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
\t<key>GetPlayersURL</key>
\t<string>$(GET_PLAYERS_URL)</string>
\t<key>GetOpportunitiesURL</key>
\t<string>$(GET_OPPORTUNITIES_URL)</string>
\t<key>GetBoardURL</key>
\t<string>$(GET_BOARD_URL)</string>
\t<key>GetProjectionsURL</key>
\t<string>$(GET_PROJECTIONS_URL)</string>
\t<key>GetLeagueStateURL</key>
\t<string>$(GET_LEAGUE_STATE_URL)</string>
\t<key>GetPlayoffBracketURL</key>
\t<string>$(GET_PLAYOFF_BRACKET_URL)</string>
\t<key>GetDailyAnalysisURL</key>
\t<string>$(GET_DAILY_ANALYSIS_URL)</string>
\t<key>GetActivityFeedURL</key>
\t<string>$(GET_ACTIVITY_FEED_URL)</string>
\t<key>UpdateUserPreferencesURL</key>
\t<string>$(UPDATE_USER_PREFERENCES_URL)</string>
\t<key>RedeemPromoCodeURL</key>
\t<string>$(REDEEM_PROMO_CODE_URL)</string>
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
│   ├── Services/  — Sport-specific implementations (BoardService, OpportunitiesService, ProjectionsService, GamesService)
│   │              — BoardService owns get-board (schedule + players + odds); GamesService owns game logs + playoff bracket
│   ├── Models/    — Domain models (Player, Opportunity, Projection, PlayoffSeries, LeagueState)
│   ├── Sport/     — Sport extensions (SportConfiguration+<Sport>, SportPositionMap+<Sport>, <Calc>)
│   │              — Base types (SportConfiguration, SportPositionMap, ScoringCalculator) live in BKSCore
│   ├── Utilities/ — Shared helpers (ConfigurationKeys, VisiblePushEvent, NotificationPreferenceKey)
│   │              — (Filterable, PlayerLookup, PushNotificationNames) live in BKSCore
│   └── UI/        — Shared views (TierTypes+UI, TierThresholds)
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
- **Core/Sport/ + Core/Utilities/ + Core/Utilities/**: whichever agent's task requires it; coordinate if both need changes
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
- Shared code (`Sources/Core/Sport/`, `Sources/Core/Utilities/`, `Sources/Core/Utilities/`) is owned by whichever agent's task requires the change; coordinate via the lead if both need changes

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
# .claude/skills/ios-advisor.md  (iOS Architect advisor skill for Claude Code)
# ─────────────────────────────────────────────────────────────────────────────

ios_advisor_skill_path = os.path.join(SCRIPT_DIR, ".claude", "skills", "ios-advisor.md")
if os.path.exists(ios_advisor_skill_path):
    with open(ios_advisor_skill_path) as f:
        ios_advisor_skill = f.read()
    write(os.path.join(out_dir, ".claude", "skills", "ios-advisor.md"), ios_advisor_skill)
else:
    print(f"  warning: {ios_advisor_skill_path} not found — skipping ios-advisor skill")

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
print("  (FirebaseAnalyticsAdapter lives in BKSCore — not generated)")
print()
print("Models:")
print(f"  App/Sources/Core/Models/Opportunity.swift")
print(f"  App/Sources/Core/Models/Projection.swift")
print(f"  App/Sources/Core/Models/GameEntry+{swift_name}.swift")
print(f"  App/Sources/Core/Models/ProjectedStatLine+{swift_name}.swift")
print(f"  App/Sources/Core/Models/LeagueState.swift")
print("  (PlayoffSeries lives in BKSCore — not generated)")
print("  (Player lives in BKSCore — not generated)")
print("  (DiagnosticLogger lives in BKSCore — not generated)")
print()
print("Services (sport-specific implementations — protocols in BKSCore):")
print(f"  App/Sources/Core/Services/OpportunitiesService.swift")
print(f"  App/Sources/Core/Services/ProjectionsService.swift")
print(f"  App/Sources/Core/Services/GamesService.swift")
print(f"  App/Sources/Core/Services/PlayoffService.swift")
print()
print("Sport configuration (BKSCore owns base types; scaffold generates sport extensions):")
print(f"  App/Sources/Core/Sport/SportPositionMap+{swift_name}.swift")
print(f"  App/Sources/Core/Sport/{calc_name}.swift")
print(f"  App/Sources/Core/Sport/SportConfiguration+{swift_name}.swift")
print()
print("Core UI & Utilities:")
print(f"  App/Sources/Core/Utilities/TierTypes+UI.swift")
print(f"  App/Sources/Core/Utilities/ConfigurationKeys+{swift_name}.swift")
print(f"  App/Sources/Core/Utilities/VisiblePushEvent.swift")
print(f"  App/Sources/Core/Utilities/NotificationPreferenceKey+{swift_name}.swift")
print(f"  App/Sources/Core/Utilities/NotificationPreferenceKey+FCM.swift")
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
print(f"  .claude/skills/ios-advisor.md")
print(f"  workspace.yml")
print(f"  generate.sh")
print()
print("Next steps:")
print(f"  1. Replace App/Sources/App/Resources/GoogleService-Info.plist with real Firebase config")
if not raw_team_ids:
    print(f"  2. Fill in teamAbbreviationByID in SportConfiguration+{swift_name}.swift")
print(f"  3. Fill in real API keys in App/Config/Debug.xcconfig (gitignored)")
PYEOF

# ── skip remaining steps in dry-run mode ─────────────────────────────────────

if [[ $DRY_RUN -eq 1 ]]; then
    echo ""
    echo "✅ Dry run complete — no files were written."
    exit 0
fi

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

    # Inject sport-specific splash.sportName key into the generated catalog.
    # The shared catalog cannot contain this value because it differs per sport.
    SPORT_DISPLAY="$(python3 -c "import yaml; s=yaml.safe_load(open('$SCRIPT_DIR/sports/$SPORT_SLUG.yaml')); print(s['sport'].get('displayName', s['sport']['name']))")"
    python3 - "$STRINGS_DST" "$SPORT_DISPLAY" <<'PYEOF'
import sys, json

catalog_path = sys.argv[1]
sport_display = sys.argv[2]

with open(catalog_path, "r", encoding="utf-8") as f:
    catalog = json.load(f)

# French and Spanish sport names default to the English display name.
# Translators can override these values in the string catalog after generation.
catalog["strings"]["splash.sportName"] = {
    "comment": "The sport name shown in the splash screen subtitle (e.g. 'Basketball Edition').",
    "extractionState": "manual",
    "localizations": {
        "en":    {"stringUnit": {"state": "translated", "value": sport_display}},
        "es":    {"stringUnit": {"state": "translated", "value": sport_display}},
        "fr-CA": {"stringUnit": {"state": "translated", "value": sport_display}},
    }
}

with open(catalog_path, "w", encoding="utf-8") as f:
    json.dump(catalog, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF
    echo "  injected splash.sportName = \"$SPORT_DISPLAY\" into Localizable.xcstrings"
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
        "revision" : "7595cbcf59809f9977c5f6378500de2ad73b7ddb",
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
        "revision" : "b6b757c1244dbfb1c373018517c6f0ad095b64b1",
        "version" : "2.3.0"
      }
    },
    {
      "identity" : "bksuicore",
      "kind" : "remoteSourceControl",
      "location" : "git@github.com:bkatnich/BKSUICore.git",
      "state" : {
        "revision" : "525ab6b7bc29c7df4f10f9f8801a0a08da1a1298",
        "version" : "1.5.36"
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
