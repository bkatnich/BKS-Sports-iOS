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
#   Features/Board/ — BoardEntry, BoardEntryBuilder, BoardState, BoardIntent, BoardView (stubs)
#   Features/Profile/ — ProfileContainerView, NotificationsDetailView
#   workspace.yml, generate.sh, project.yml, xcconfig files, Info.plist, storekit stub
#
# Requirements: python3, pyyaml (pip3 install pyyaml)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── argument check ───────────────────────────────────────────────────────────

DRY_RUN=0
REGEN_PROJECT=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)       DRY_RUN=1;       shift ;;
        --regen-project) REGEN_PROJECT=1; shift ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

if [[ ${#POSITIONAL[@]} -lt 1 ]]; then
    echo "Usage: $0 [--dry-run] [--regen-project] <sport-slug> [output-dir]"
    echo "  e.g. $0 baseball"
    echo "  e.g. $0 baseball /path/to/BKS-Baseball-Client-iOS"
    echo "  e.g. $0 --dry-run baseball          (print what would be generated, no writes)"
    echo "  e.g. $0 --regen-project baseball    (overwrite existing project.yml)"
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

SCRIPT_DIR="$SCRIPT_DIR" SPORT_SLUG="$SPORT_SLUG" OUTPUT_DIR="$OUTPUT_DIR" DRY_RUN="$DRY_RUN" REGEN_PROJECT="$REGEN_PROJECT" python3 << 'PYEOF'
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
DRY_RUN        = os.environ.get("DRY_RUN", "0") == "1"
REGEN_PROJECT  = os.environ.get("REGEN_PROJECT", "0") == "1"

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
display_name = sport.get("displayName", sport["name"])
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
game_detail       = spec.get("gameDetail", {})
spread_label      = game_detail.get("spreadLabel", "Spread")
spread_pick_label = game_detail.get("spreadPickLabel", "BK Pick")

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
use_null_calc = scoring.get("useNullCalculator", False)
# Live apps that score server-side inline a private NullScoringCalculator in
# SportConfiguration instead of generating a full calculator file.
calc_ref = "NullScoringCalculator()" if use_null_calc else f"{calc_name}.shared"
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
import BKSCore
import Foundation
import OSLog

// MARK: - {name}-specific configuration keys

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
    static let redeemPromoCodeURL = ConfigurationKey(
        name: "redeemPromoCodeURL",
        defaultValue: "UNCONFIGURED_REDEEM_PROMO_CODE_URL",
        infoPlistKey: "RedeemPromoCodeURL"
    )
    static let getActivityFeedURL = ConfigurationKey(
        name: "getActivityFeedURL",
        defaultValue: "UNCONFIGURED_GET_ACTIVITY_FEED_URL",
        infoPlistKey: "GetActivityFeedURL"
    )
    static let getDailyAnalysisURL = ConfigurationKey(
        name: "getDailyAnalysisURL",
        defaultValue: "UNCONFIGURED_GET_DAILY_ANALYSIS_URL",
        infoPlistKey: "GetDailyAnalysisURL"
    )
    static let updateUserPreferencesURL = ConfigurationKey(
        name: "updateUserPreferencesURL",
        defaultValue: "UNCONFIGURED_UPDATE_USER_PREFERENCES_URL",
        infoPlistKey: "UpdateUserPreferencesURL"
    )
    static let getPlayersURL = ConfigurationKey(
        name: "getPlayersURL",
        defaultValue: "UNCONFIGURED_GET_PLAYERS_URL",
        infoPlistKey: "GetPlayersURL"
    )
    static let getBoardURL = ConfigurationKey(
        name: "getBoardURL",
        defaultValue: "UNCONFIGURED_GET_BOARD_URL",
        infoPlistKey: "GetBoardURL"
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

// MARK: - URL configuration guard

private let configLogger = os.Logger(subsystem: "{bundle_id}", category: "Configuration")

extension ConfigurationProtocol {{
    /// Returns the string value for a URL key, logging a critical error if it is still a placeholder.
    func checkedURL(for key: ConfigurationKey<String>) -> String {{
        let url = value(for: key)
        if url.hasPrefix("UNCONFIGURED_") {{
            let xconfigKey = key.infoPlistKey ?? key.name
            let message = "⚠️ URL NOT CONFIGURED: '\\(key.name)' is still a placeholder. Set \\(xconfigKey) in your xcconfig."
            configLogger.critical("\\(message, privacy: .public)")
        }}
        return url
    }}
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

visible_push_events = fcm.get("visiblePushEvents", [])

cases_block = "\n".join(
    f'    case {e["name"]:<19} = "{e["rawValue"]}"'
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

# ── PropFeedFilter (props feed filtering + persistence) ────────────────────

prop_feed_filter_swift = header() + f"""import Foundation

// MARK: - PropFeedFilter

/// Active filter state for the props feed. Persisted to UserDefaults via PropFeedFilterPersistence.
struct PropFeedFilter: Equatable, Codable {{
    var selectedStatCategories: Set<PropStatCategory> = []
    var minimumTier: PropEdgeTier = .subdued
    var instinctAgreesOnly: Bool = false

    var isActive: Bool {{
        !selectedStatCategories.isEmpty
            || minimumTier > .subdued
            || instinctAgreesOnly
    }}

    var activeFilterCount: Int {{
        (selectedStatCategories.isEmpty ? 0 : 1)
            + (minimumTier > .subdued ? 1 : 0)
            + (instinctAgreesOnly ? 1 : 0)
    }}
}}

// MARK: - PropEdgeTier+Codable

extension PropEdgeTier: Codable {{}}

// MARK: - PropFeedFilterPersistence

enum PropFeedFilterPersistence {{
    /// Bump to "propFeedFilter.v2" if any PropStatCategory rawValue is renamed
    /// to track a server stat-key change. This invalidates stored filters and
    /// returns the default rather than silently hiding mismatched props.
    private static let key = "propFeedFilter.v1"

    static func load() -> PropFeedFilter {{
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode(PropFeedFilter.self, from: data)
        else {{ return .init() }}
        return decoded
    }}

    static func save(_ filter: PropFeedFilter) {{
        guard let data = try? JSONEncoder().encode(filter) else {{ return }}
        UserDefaults.standard.set(data, forKey: key)
    }}
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Utilities", "PropFeedFilter.swift"), prop_feed_filter_swift)

# ── ETDate (server day boundaries are America/New_York) ──────────────────

et_date_swift = header() + f"""import Foundation

// MARK: - ETDate

/// Day-boundary helpers pinned to America/New_York.
///
/// The server's data day rolls at midnight Eastern, not device-local midnight.
/// Every cache-staleness decision on the board must use these helpers — using
/// `Calendar.current` makes a Pacific user's 5 AM open look like "yesterday is
/// still today" and the board serves a stale slate until manual refresh.
enum ETDate {{

    /// Eastern Time zone. Falls back to the device zone only if the identifier
    /// is missing from the OS database (never happens on shipping iOS).
    static let timeZone = TimeZone(identifier: "America/New_York") ?? .current

    private static let calendar: Calendar = {{
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }}()

    private static let dayFormatter: DateFormatter = {{
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        return formatter
    }}()

    /// True when both instants fall on the same Eastern-Time calendar day.
    static func isSameETDay(_ lhs: Date, _ rhs: Date) -> Bool {{
        calendar.isDate(lhs, inSameDayAs: rhs)
    }}

    /// The Eastern-Time day for `date` as "yyyy-MM-dd" — the same format the
    /// server uses for `TodaySchedule.date` and silent-push `date` fields.
    static func dateString(for date: Date = .now) -> String {{
        dayFormatter.string(from: date)
    }}

    /// True when a server "yyyy-MM-dd" day string matches the current ET day.
    /// Used to reject disk-cached schedules from a previous server day.
    static func isCurrentETDay(serverDateString: String, now: Date = .now) -> Bool {{
        serverDateString == dateString(for: now)
    }}
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Utilities", "ETDate.swift"), et_date_swift)

# ─────────────────────────────────────────────────────────────────────────────
# 1c. NotificationPreferenceKey+<Sport>.swift
#     Sport-specific notification preference key and accessor.
# ─────────────────────────────────────────────────────────────────────────────

notif_prefs = fcm.get("notificationPreferences", [])

notif_pref_key_swift = header() + f"""import BKSCore

// MARK: - {swift_name} notification preference keys

extension NotificationPreferenceKey {{
    /// Playoff series/elimination alerts — {slug}-specific.
    public static let playoffAlerts    = NotificationPreferenceKey(rawValue: "playoff_alerts")
    /// Game schedule updates (games_update) — {slug}-specific.
    public static let gameUpdates      = NotificationPreferenceKey(rawValue: "game_updates")
    /// Pre-game data freshness alerts (data_freshness) — {slug}-specific.
    public static let pregameAlerts    = NotificationPreferenceKey(rawValue: "pregame_alerts")
    /// Analysis and predictions ready (analysis_ready, prop_predictions_ready) — {slug}-specific.
    public static let predictionsReady = NotificationPreferenceKey(rawValue: "predictions_ready")
}}

// MARK: - {swift_name} preference accessors

extension NotificationPreferences {{
    /// Playoff alerts preference. Stored in `sportPreferences["playoff_alerts"]`.
    public var playoffAlerts: Bool? {{
        get {{ sportPreferences["playoff_alerts"] }}
        set {{ sportPreferences["playoff_alerts"] = newValue }}
    }}

    /// Game updates preference. Stored in `sportPreferences["game_updates"]`.
    public var gameUpdates: Bool? {{
        get {{ sportPreferences["game_updates"] }}
        set {{ sportPreferences["game_updates"] = newValue }}
    }}

    /// Pre-game alerts preference. Stored in `sportPreferences["pregame_alerts"]`.
    public var pregameAlerts: Bool? {{
        get {{ sportPreferences["pregame_alerts"] }}
        set {{ sportPreferences["pregame_alerts"] = newValue }}
    }}

    /// Predictions ready preference. Stored in `sportPreferences["predictions_ready"]`.
    public var predictionsReady: Bool? {{
        get {{ sportPreferences["predictions_ready"] }}
        set {{ sportPreferences["predictions_ready"] = newValue }}
    }}
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Utilities", f"NotificationPreferenceKey+{swift_name}.swift"), notif_pref_key_swift)

# ─────────────────────────────────────────────────────────────────────────────
# 1d. NotificationPreferenceKey+FCM.swift
#     Maps raw FCM event strings → preference keys for this sport.
# ─────────────────────────────────────────────────────────────────────────────

notif_fcm_swift = header() + f"""import BKSCore

extension NotificationPreferenceKey {{
    /// Maps FCM event strings to preference keys for the {swift_name} app.
    /// Sport-specific events are handled here; core events delegate to BKSCore.
    init?(fcmEvent: String) {{
        switch fcmEvent {{
        case "series_clinch", "elimination_game", "bracket_advance", "champion":
            self = .playoffAlerts
        case "analysis_ready", "prop_predictions_ready":
            self = .predictionsReady
        case "games_update":
            self = .gameUpdates
        case "data_freshness":
            self = .pregameAlerts
        default:
            guard let key = NotificationPreferenceKey(coreEvent: fcmEvent) else {{ return nil }}
            self = key
        }}
    }}
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Utilities", "NotificationPreferenceKey+FCM.swift"), notif_fcm_swift)

fetch_coalescer_swift = header() + f"""import OSLog

// MARK: - FetchCoalescer

/// Actor that coalesces concurrent async fetch calls into a single in-flight Task.
///
/// When a second caller arrives while a fetch is already running, it joins the
/// existing Task rather than spawning a new network request. This prevents duplicate
/// Cloud Run cold-starts when a silent push and the board's onAppear race.
///
/// Caller cancellation is intentionally decoupled from the shared Task: if a caller
/// is cancelled (e.g. the view disappears mid-flight), the underlying network request
/// continues to completion so the next caller finds `inflight` still set and joins it
/// rather than firing a duplicate request.
actor FetchCoalescer<Value: Sendable> {{
    private var inflight: Task<Value, Error>?

    func run(
        logger: os.Logger,
        label: StaticString,
        work: @Sendable @escaping () async throws -> Value
    ) async throws -> Value {{
        let task: Task<Value, Error>
        if let existing = inflight {{
            logger.debug("\\(label, privacy: .public) — joining in-flight request")
            task = existing
        }} else {{
            // Cleanup task clears `inflight` once work finishes (success or failure)
            // so the next caller spawns a fresh request rather than joining a dead task.
            let newTask = Task<Value, Error> {{ try await work() }}
            inflight = newTask
            task = newTask
            Task<Void, Never> {{
                _ = try? await newTask.value
                self.clearInflight()
            }}
        }}

        // Await the shared task's result without propagating this caller's cancellation
        // into it. If this caller is cancelled, CancellationError is thrown here, but
        // the shared task keeps running so subsequent callers can still join it.
        return try await withTaskCancellationHandler {{
            try await task.value
        }} onCancel: {{
            // Intentionally empty: do not cancel the shared task on caller cancellation.
        }}
    }}

    private func clearInflight() {{
        inflight = nil
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
    if "termLines" in p:
        # Explicit line groups — controls wrapping in the generated source.
        group_lines = [", ".join(f'"{t}"' for t in group) for group in p["termLines"]]
        inner = ",\n                ".join(group_lines)
        terms_lines.append(f'            "{label}": [\n                {inner}\n            ]')
        continue
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

if not use_null_calc:
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
    team_pairs = [f'{k}: "{v}"' for k, v in sorted(raw_team_ids.items())]
    team_rows = [", ".join(team_pairs[i:i + 5]) for i in range(0, len(team_pairs), 5)]
    team_id_lines = ",\n            ".join(team_rows)
    team_lookup_value = f"[\n            {team_id_lines}\n        ]"
    team_lookup_comment = ""
else:
    team_lookup_value = "[:]"
    team_lookup_comment = f"         // TODO: populate {league} team ID → abbreviation lookup"

sport_config = header() + f"""\
import BKSCore
import BKSUICore

// MARK: - {league} {name}

extension SportConfiguration {{
    var splashSubtitle: String {{
        String(localized: "splash.subtitle", defaultValue: "{display_name} Edition")
    }}

    /// Sport configuration for {league} {name}.
    static let {slug} = SportConfiguration(
        slug: "{slug}",
        sportName: String(localized: "splash.sportName", defaultValue: "{name}"),
        cacheKeyPrefix: "{slug}_",
        positionMap: .{slug},
        scoringCalculator: {calc_ref},
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

if use_null_calc:
    sport_config += f"""
// MARK: - NullScoringCalculator

private struct NullScoringCalculator: ScoringCalculator {{
    func score(for entry: GameEntry) -> Double {{ 0 }}
}}
"""

write(os.path.join(out_dir, "App/Sources/Core/Sport", f"SportConfiguration+{swift_name}.swift"), sport_config)

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

bootstrap_app = header() + f"""import BackgroundTasks
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
    private let boardService: BoardServiceProtocol
    private let gamesService: any GamesServiceProtocol
    private let promoCodeService: PromoCodeServiceProtocol
    private let activityService: any ActivityFeedServiceProtocol
    private let configuration: ConfigurationProtocol
    private let storage: StorageProtocol
    private let termsURL: URL
    private let privacyURL: URL
    private let analyticsAdapter = FirebaseAnalyticsAdapter()
    private let metricsCollector: MetricsCollectorProtocol
    private let subscriptionService: SubscriptionService

    @State private var splashDismissed = false
    @State private var pendingConsentResult: AuthResult?
    @State private var isErasingCache = false
    /// True once refreshEntitlement() has completed. Guards the board from fetching
    /// before the backend has confirmed the user's subscription state, preventing
    /// spurious 402 responses for users on non-expiring tiers (e.g. Insider).
    @State private var entitlementReady = false
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
        let config = container.require(ConfigurationProtocol.self)
        configuration = config
        storage = container.require(StorageProtocol.self)

        termsURL = URL(string: config.value(for: .termsOfServiceURL))
            ?? URL(string: "https://www.blackkatt.ca/terms-of-service.html")!  // swiftlint:disable:this force_unwrapping
        privacyURL = URL(string: config.value(for: .privacyPolicyURL))
            ?? URL(string: "https://www.blackkatt.ca/privacy-policy.html")!  // swiftlint:disable:this force_unwrapping

        boardService = container.require(BoardServiceProtocol.self)
        gamesService = container.require(GamesServiceProtocol.self)

        promoCodeService = container.require(PromoCodeServiceProtocol.self)
        activityService = container.require(ActivityFeedServiceProtocol.self)
        metricsCollector = container.require(MetricsCollectorProtocol.self)
        subscriptionService = container.require(SubscriptionService.self)
        Self.startServices(metrics: metricsCollector, subscription: subscriptionService)

        (profileStore, signInStore) = Self.makeFlowStores(container: container, authStore: resolvedAuth, auth: auth)
        Self.registerDataRefresh(board: boardService)
    }}

    private static func makeFlowStores(
        container: Container,
        authStore: Store<AuthState, AuthIntent>,
        auth: AuthenticationProtocol
    ) -> (Store<ProfileState, ProfileIntent>, Store<SignInState, SignInIntent>) {{
        let profileStore = BKSAppScaffold.makeProfileStore(
            container: container,
            authStore: authStore,
            auth: auth
        ) {{ prefs in
            AppDelegate.notificationPreferences = prefs
            let svc = container.require(UserPreferencesServiceProtocol.self)
            try? await svc.updatePreferences(prefs)
        }}

        let langService = container.require(LanguagePreferenceServiceProtocol.self)
        let signInStore = BKSAppScaffold.makeSignInStore(
            container: container,
            authStore: authStore
        ) {{
            Task {{ await langService.syncLanguage() }}
        }}

        return (profileStore, signInStore)
    }}

    private static func startServices(
        metrics: MetricsCollectorProtocol,
        subscription: SubscriptionService
    ) {{
        metrics.startCollecting()
        subscription.startTransactionListener()
    }}

    private static func registerDataRefresh(board: BoardServiceProtocol) {{
        DataRefreshTask.register(identifier: DataRefreshTaskID.identifier) {{
            _ = try await board.fetchBoard()
        }}
    }}

    private var authSessionResolved: Bool {{
        switch authStore.state.session {{
        case .undetermined: return false
        default: return true
        }}
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
                    onEraseCachedData: eraseCachedData,
                    onForceRefresh: forceRefreshGameData,
                    entitlementReady: entitlementReady
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
                let t0 = Date()
                Self.logger.debug("AppTask: started")
                let appLaunchStart = t0
                let appLaunchID = Perf.begin("AppLaunchPostFirstFrame")
                defer {{ Perf.end("AppLaunchPostFirstFrame", id: appLaunchID, startedAt: appLaunchStart) }}

                authStore.send(.checkStoredCredential)
                Self.logger.debug("AppTask: checkStoredCredential sent (\\(Date().timeIntervalSince(t0), privacy: .public)s)")
                profileStore.send(.onAppear)
                Self.logger.debug("AppTask: profileStore.onAppear sent (\\(Date().timeIntervalSince(t0), privacy: .public)s)")

                let log = Self.logger
                await Perf.measure("SubscriptionRefresh") {{
                    await subscriptionService.refreshEntitlement()
                }}
                log.debug("AppTask: refreshEntitlement done (\\(Date().timeIntervalSince(t0), privacy: .public)s)")

                entitlementReady = true
                Self.logger.debug("AppTask: entitlementReady=true (\\(Date().timeIntervalSince(t0), privacy: .public)s)")

                // Push registration is independent of subscription state — fire after
                // entitlementReady so it never blocks the board from fetching.
                // On first launch requestAuthorization() awaits the system alert; keeping
                // it out of the entitlement gate prevents an indefinite block.
                Task {{
                    await Perf.measure("PushNotificationRegister") {{
                        await BKSAppScaffold.registerForPushNotifications()
                    }}
                    log.debug("AppTask: push registration done (\\(Date().timeIntervalSince(t0), privacy: .public)s)")
                }}

                await Perf.measure("SubscriptionFetchProducts") {{
                    await subscriptionService.fetchProducts()
                }}
                Self.logger.debug("AppTask: fetchProducts done (\\(Date().timeIntervalSince(t0), privacy: .public)s)")

                #if DEBUG
                frameMonitor.start()
                #endif
            }}
            .onChange(of: authSessionResolved) {{ _, resolved in
                Self.logger.debug("authSessionResolved changed → \\(resolved, privacy: .public) session=\\(String(describing: authStore.state.session), privacy: .public)")
                if resolved, case .authenticated = authStore.state.session {{
                    Task {{ await syncPreferencesToServer() }}
                }}
            }}
            .onChange(of: entitlementReady) {{ _, ready in
                Self.logger.debug("entitlementReady changed → \\(ready, privacy: .public)")
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
                GamedayTopicManager.shared.syncIfNeeded()
                // Self-heal on foreground: overnight gameday pushes are sent to a
                // date-stamped topic the device only subscribes to on open, so they
                // can never warm the cache for the first open of a new ET day.
                // .onAppear is cheap — its reducer skips when the cache is fresh.
                boardStore.send(.onAppear)
            }}
            .onReceive(
                NotificationCenter.default.publisher(for: DataRefreshTask.dataDidRefreshNotification)
                    .receive(on: RunLoop.main)
            ) {{ _ in
                boardStore.send(.backgroundRefreshRequested)
            }}
            .onReceive(
                NotificationCenter.default.publisher(for: PushNotificationNames.visiblePushTapped)
            ) {{ notification in
                guard let eventRaw = notification.object as? String else {{ return }}
                boardStore.send(.pushNotificationTapped(eventRaw))
                boardStore.send(.backgroundRefreshRequested)
            }}
            .onReceive(
                NotificationCenter.default.publisher(for: PushNotificationNames.foregroundPushReceived)
                    .receive(on: RunLoop.main)
            ) {{ notification in
                // Server contract: any gameday event arriving in the foreground must
                // refresh the board in place. Unknown event names are ignored here —
                // silent content-available pushes route via dataDidRefreshNotification.
                guard let eventRaw = notification.object as? String,
                      VisiblePushEvent(rawValue: eventRaw) != nil
                        || DataRefreshTask.SilentPushEvent(rawValue: eventRaw) != nil
                else {{ return }}
                boardStore.send(.backgroundRefreshRequested)
            }}
            .onChange(of: boardStore.state.loadState.isLoading) {{ wasLoading, nowLoading in
                if wasLoading, !nowLoading, isErasingCache {{
                    isErasingCache = false
                }}
            }}
            .preferredColorScheme(.dark)
        }}
    }}

    // MARK: - Preference sync

    /// Pushes locally-stored notification preferences to the server immediately after
    /// auth resolves. Guards against divergence when a toggle was made while offline.
    private func syncPreferencesToServer() async {{
        let svc = (UIApplication.shared.delegate as? AppDelegate)?
            .container?.resolve(UserPreferencesServiceProtocol.self)
        guard let svc else {{ return }}
        let prefs = profileStore.state.preferences
        try? await svc.updatePreferences(prefs)
        Self.logger.debug("Preferences synced to server on auth resolution")
    }}

    // MARK: - Cache erase

    private func eraseCachedData() {{
        isErasingCache = true
        boardStore.send(.refreshRequested)
        Task.detached(priority: .userInitiated) {{ [storage] in
            try? storage.deleteAll(from: .file)
        }}
    }}

    private func forceRefreshGameData() {{
        // Keys from services defined in this repo — authoritative source of truth.
        // "daily_analysis_v2" is owned by BKSCore.DailyAnalysisService (private constant).
        let gameDataKeys = boardService.cacheKeys + ["daily_analysis_v2"]
        Task.detached(priority: .userInitiated) {{ [storage] in
            for key in gameDataKeys {{
                try? storage.delete(forKey: key, from: .file)
            }}
        }}
    }}

    // MARK: - Subscription consent

    private func subscriptionConsentView(for result: AuthResult) -> some View {{
        SubscriptionConsentView(
            rows: consentTermRows,
            title: String(localized: "consent.title", defaultValue: "Welcome to {app_name}"),
            subtitle: String(
                localized: "consent.subtitle",
                defaultValue: "Your subscription keeps the insights sharp all season."
            ),
            termsURL: termsURL,
            privacyURL: privacyURL,
            promoCodeService: promoCodeService,
            subscriptionService: subscriptionService
        ) {{
            saveConsentAccepted(to: storage)
            authStore.send(.signInSucceeded(result))
            pendingConsentResult = nil
        }}
    }}

    private var consentTermRows: [TermRow] {{
        [
            TermRow(
                icon: "{slug}.fill",
                title: String(localized: "consent.term.daily.title",
                              defaultValue: "Daily picks, every game day"),
                detail: String(localized: "consent.term.daily.detail",
                               defaultValue: "Board, projections, and prop opportunities updated each morning.")
            ),
            TermRow(
                icon: "arrow.clockwise",
                title: String(localized: "consent.term.cancel.title",
                              defaultValue: "Cancel any time"),
                detail: String(localized: "consent.term.cancel.detail",
                               defaultValue: "No commitment. Cancel before renewal and you won't be charged.")
            ),
            TermRow(
                icon: "creditcard",
                title: String(localized: "consent.term.billing.title",
                              defaultValue: "$2.99 / month after trial"),
                detail: String(localized: "consent.term.billing.detail",
                               defaultValue: "Billed monthly through your App Store account.")
            )
        ]
    }}
}}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: BKSAppDelegate {{
    override func makeContainer() -> Container {{ Container.defaultContainer() }}

    override func fcmTopics(config: ConfigurationProtocol) -> [String] {{
        [config.value(for: .fcmPlayoffTopic)]
    }}

    override func shouldSuppressForegroundPush(eventRaw: String) -> Bool {{
        eventRaw == DataRefreshTask.SilentPushEvent.playersUpdate.rawValue
            || eventRaw == "snapshot_ready"
    }}

    override func preferenceKey(for fcmEvent: String) -> NotificationPreferenceKey? {{
        NotificationPreferenceKey(fcmEvent: fcmEvent)
    }}

    override func handleNotificationTap(eventRaw: String, userInfo: [AnyHashable: Any]) {{
        if VisiblePushEvent(rawValue: eventRaw) != nil {{
            NotificationCenter.default.post(
                name: PushNotificationNames.visiblePushTapped,
                object: eventRaw,
                userInfo: userInfo
            )
        }} else {{
            super.handleNotificationTap(eventRaw: eventRaw, userInfo: userInfo)
        }}
    }}

    override func handleSilentPush(eventRaw: String, userInfo: [AnyHashable: Any]) async {{
        guard
            let storage = container?.resolve(StorageProtocol.self),
            let board = container?.resolve(BoardServiceProtocol.self)
        else {{ return }}
        await DataRefreshTask.handleSilentPush(userInfo: userInfo, storage: storage) {{
            _ = try await board.fetchBoard()
        }}
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

    private func registerSportServices() {{
        register(BoardServiceProtocol.self) {{ resolver in
            BoardService(
                network: resolver.require(NetworkProtocol.self, name: "{firebase_network_name}"),
                storage: resolver.require(StorageProtocol.self),
                configuration: resolver.require(ConfigurationProtocol.self),
                sportConfiguration: resolver.require((any SportConfigurationProtocol).self)
            )
        }}.inObjectScope(.container)
        register(GamesServiceProtocol.self) {{ resolver in
            GamesService(
                network: resolver.require(NetworkProtocol.self, name: "{firebase_network_name}"),
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
            let analysisService = resolver.require(DailyAnalysisServiceProtocol.self)
            let positionMap = resolver.require((any SportConfigurationProtocol).self).positionMap
            return MainActor.assumeIsolated {{
                Store(
                    initial: BoardState(),
                    reduce: BoardState.makeReduce(
                        boardService: boardService,
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
# 8e. GamedayTopicManager.swift
#     Date-scoped FCM gameday topic subscription manager. Generic across all
#     sports — keyed by fcm.gamedayTopic from the YAML (e.g. "gameday").
#     Subscribes to "gameday_YYYYMMDD" and unsubscribes the previous day on
#     every foreground resume, but only when the date has actually changed.
# ─────────────────────────────────────────────────────────────────────────────

fcm_gameday     = fcm.get("gamedayTopic", "gameday")

gameday_topic_manager_swift = header() + f"""import FirebaseMessaging
import Foundation
import OSLog

// MARK: - GamedayTopicManager

/// Manages the date-scoped FCM gameday topic subscription.
///
/// Subscribes to today's topic (`gameday_YYYYMMDD`) and unsubscribes from
/// yesterday's on every foreground resume, but only when the date has changed
/// since the last successful subscription. Safe to call repeatedly — the
/// guard on `lastSubscribedDate` makes it idempotent within a single day.
///
/// Date boundary uses America/New_York ({league} game-day timezone) so a user in
/// a western timezone foregrounding after midnight ET gets the correct topic.
@MainActor
final class GamedayTopicManager {{

    static let shared = GamedayTopicManager()

    private let defaults = UserDefaults.standard
    private let lastSubscribedKey = "gameday.lastSubscribedDate"
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "GamedayTopic"
    )

    private static let formatter: DateFormatter = {{
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "America/New_York")
        return fmt
    }}()

    func syncIfNeeded() {{
        let today = Self.formatter.string(from: Date())
        let lastSubscribed = defaults.string(forKey: lastSubscribedKey)
        guard lastSubscribed != today else {{ return }}

        subscribe(to: "gameday_\\(today)")

        if let lastDate = lastSubscribed {{
            unsubscribe(from: "gameday_\\(lastDate)")
        }}

        defaults.set(today, forKey: lastSubscribedKey)
    }}

    private func subscribe(to topic: String) {{
        Messaging.messaging().subscribe(toTopic: topic) {{ [weak self] error in
            if let error {{
                self?.logger.error(
                    "subscribe \\(topic, privacy: .public) failed: \\(error.localizedDescription, privacy: .public)"
                )
            }} else {{
                self?.logger.info("subscribed to \\(topic, privacy: .public)")
            }}
        }}
    }}

    private func unsubscribe(from topic: String) {{
        Messaging.messaging().unsubscribe(fromTopic: topic) {{ [weak self] error in
            if let error {{
                self?.logger.error(
                    "unsubscribe \\(topic, privacy: .public) failed: \\(error.localizedDescription, privacy: .public)"
                )
            }} else {{
                self?.logger.info("unsubscribed from \\(topic, privacy: .public)")
            }}
        }}
    }}
}}
"""

utilities_dir = os.path.join(out_dir, "App/Sources/Core/Utilities")
write(os.path.join(utilities_dir, "GamedayTopicManager.swift"), gameday_topic_manager_swift)

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
    let onForceRefresh: () -> Void
    let entitlementReady: Bool
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
                onEraseCachedData: onEraseCachedData,
                onForceRefresh: onForceRefresh,
                entitlementReady: entitlementReady
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

opportunity_swift = header() + f"""import Foundation
import BKSCore

struct Opportunity: Codable, Equatable, Hashable, Identifiable,
                   Filterable, InjuryTracking {{
    let id: String
    let displayName: String
    let team: String
    let position: String?
    let opponentAbbr: String
    let headshotURL: URL?
    let externalPersonID: Int?

    // Core scoring
    let opportunityScore: Double?
    let opportunityTier: TierLevel

    // Key signals
    let injuryStatus: InjuryStatus?
    let isSurging: Bool
    let isHome: Bool
    let gameDateTime: Date?

    // Top pick signals
    let isTopPick: Bool
    let topPickRank: Int?
    let topPickReasons: [String]

    // {swift_name}-specific playoff signals
    let playoffRotationMultiplier: Double?
    let rotationTier: RotationTier?
    let playoffTrendTrust: Double?
    let playoffGamesPlayed: Int?

    // Game context
    let battingOrder: Int?
    let probablePitcher: String?
    let parkFactor: Double?

    // {league} trend slopes
    let trendHits: Double?
    let trendHR: Double?
    let trendRBI: Double?
    let trendRuns: Double?
    let trendSB: Double?
    let trendDoubles: Double?
    let trendTB: Double?

    // Season per-game averages
    let seasonHitsPG: Double?
    let seasonHRPG: Double?
    let seasonRBIPG: Double?
    let seasonRunsPG: Double?
    let seasonSBPG: Double?
    let seasonBBPG: Double?
    let seasonKPG: Double?
    let seasonAvg: Double?

    // Advanced {league} metrics
    let wobaProxy: Double?
    let obpProxy: Double?
    let avgPaPerGame: Double?
    let playoffWobaProxy: Double?
    let playoffObpProxy: Double?
    let playoffAvgPaPerGame: Double?

    // Model confidence and streak context from the board endpoint
    let confidenceScore: Double?
    let hotStreak: Int?
    let coldStreak: Int?

    // Sportsbook prop lines — keyed by market key e.g. "hits_0.5", "home_runs_0.5"
    let propLines: [String: PropLine]?

    var additionalSearchFields: [String] {{ [opponentAbbr] }}

    // swiftlint:disable:next function_body_length
    init(
        id: String,
        displayName: String,
        team: String,
        position: String?,
        opponentAbbr: String,
        headshotURL: URL?,
        externalPersonID: Int?,
        opportunityScore: Double?,
        opportunityTier: TierLevel,
        injuryStatus: InjuryStatus?,
        isSurging: Bool,
        isHome: Bool,
        gameDateTime: Date? = nil,
        isTopPick: Bool = false,
        topPickRank: Int? = nil,
        topPickReasons: [String] = [],
        playoffRotationMultiplier: Double? = nil,
        rotationTier: RotationTier? = nil,
        playoffTrendTrust: Double? = nil,
        playoffGamesPlayed: Int? = nil,
        battingOrder: Int? = nil,
        probablePitcher: String? = nil,
        parkFactor: Double? = nil,
        trendHits: Double? = nil,
        trendHR: Double? = nil,
        trendRBI: Double? = nil,
        trendRuns: Double? = nil,
        trendSB: Double? = nil,
        trendDoubles: Double? = nil,
        trendTB: Double? = nil,
        seasonHitsPG: Double? = nil,
        seasonHRPG: Double? = nil,
        seasonRBIPG: Double? = nil,
        seasonRunsPG: Double? = nil,
        seasonSBPG: Double? = nil,
        seasonBBPG: Double? = nil,
        seasonKPG: Double? = nil,
        seasonAvg: Double? = nil,
        wobaProxy: Double? = nil,
        obpProxy: Double? = nil,
        avgPaPerGame: Double? = nil,
        playoffWobaProxy: Double? = nil,
        playoffObpProxy: Double? = nil,
        playoffAvgPaPerGame: Double? = nil,
        confidenceScore: Double? = nil,
        hotStreak: Int? = nil,
        coldStreak: Int? = nil,
        propLines: [String: PropLine]? = nil
    ) {{
        self.id = id
        self.displayName = displayName
        self.team = team
        self.position = position
        self.opponentAbbr = opponentAbbr
        self.headshotURL = headshotURL
        self.externalPersonID = externalPersonID
        self.opportunityScore = opportunityScore
        self.opportunityTier = opportunityTier
        self.injuryStatus = injuryStatus
        self.isSurging = isSurging
        self.isHome = isHome
        self.gameDateTime = gameDateTime
        self.isTopPick = isTopPick
        self.topPickRank = topPickRank
        self.topPickReasons = topPickReasons
        self.playoffRotationMultiplier = playoffRotationMultiplier
        self.rotationTier = rotationTier
        self.playoffTrendTrust = playoffTrendTrust
        self.playoffGamesPlayed = playoffGamesPlayed
        self.battingOrder = battingOrder
        self.probablePitcher = probablePitcher
        self.parkFactor = parkFactor
        self.trendHits = trendHits
        self.trendHR = trendHR
        self.trendRBI = trendRBI
        self.trendRuns = trendRuns
        self.trendSB = trendSB
        self.trendDoubles = trendDoubles
        self.trendTB = trendTB
        self.seasonHitsPG = seasonHitsPG
        self.seasonHRPG = seasonHRPG
        self.seasonRBIPG = seasonRBIPG
        self.seasonRunsPG = seasonRunsPG
        self.seasonSBPG = seasonSBPG
        self.seasonBBPG = seasonBBPG
        self.seasonKPG = seasonKPG
        self.seasonAvg = seasonAvg
        self.wobaProxy = wobaProxy
        self.obpProxy = obpProxy
        self.avgPaPerGame = avgPaPerGame
        self.playoffWobaProxy = playoffWobaProxy
        self.playoffObpProxy = playoffObpProxy
        self.playoffAvgPaPerGame = playoffAvgPaPerGame
        self.confidenceScore = confidenceScore
        self.hotStreak = hotStreak
        self.coldStreak = coldStreak
        self.propLines = propLines
    }}
}}

// MARK: - PropLine

struct PropLine: Codable, Equatable, Hashable {{
    let stat: String
    let line: Double
    let overOdds: Int
    let underOdds: Int
    /// Platt-calibrated model probability (0–1). Multiply by 100 for display %.
    let calibratedProbOver: Double
    let hasEdge: Bool
    let displayLabel: String
}}

// MARK: - RotationTier

enum RotationTier: String, Codable, Equatable, Hashable {{
    case ace
    case rotation
    case bullpen
    case closer
    case swingman
}}
"""

projection_swift = header() + f"""import BKSCore
import Foundation

struct Projection: Codable, Equatable, Hashable, Identifiable,
                   Filterable, InjuryTracking {{
    let id: String
    let displayName: String
    let team: String
    let position: String?
    let headshotURL: URL?
    let externalPersonID: Int?

    // Core scoring
    let rankingScore: Double
    let playFadeRecommendation: PlayFadeRecommendation?

    // Key signals
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

    // Trend
    let trendDirection: TrendDirection?
    let trendScore: Double?
    let confidenceScore: Double?
    let consistencyScore: Double?
    let usageEfficiencySignal: UsageEfficiencySignal?

    // Trend slopes ({league}-specific: rolling-window linear regression per category)
    let trendHits: Double?
    let trendHR: Double?
    let trendRBI: Double?
    let trendRuns: Double?
    let trendSB: Double?
    let trendDoubles: Double?
    let trendTB: Double?

    // Season per-game averages
    let seasonHitsPG: Double?
    let seasonHRPG: Double?
    let seasonRBIPG: Double?
    let seasonRunsPG: Double?
    let seasonSBPG: Double?
    let seasonBBPG: Double?
    let seasonKPG: Double?
    let seasonAvg: Double?

    // Season totals
    let seasonH: Int?
    let seasonHR: Int?
    let seasonRBI: Int?
    let seasonR: Int?
    let seasonTB: Int?
    let season2B: Int?
    let season3B: Int?
    let seasonSB: Int?
    let seasonBB: Int?
    let seasonK: Int?
    let seasonAB: Int?
    let seasonGP: Int?

    // Advanced {league} metrics
    let wobaProxy: Double?
    let obpProxy: Double?
    let avgPaPerGame: Double?
    let seasonOBP: Double?
    let seasonSLG: Double?
    let seasonOPS: Double?
    let seasonWAR: Double?
    let seasonXBHRate: Double?
    let seasonBBRate: Double?

    // swiftlint:disable:next function_default_parameter_at_end function_body_length
    init(
        id: String,
        displayName: String,
        team: String,
        position: String?,
        headshotURL: URL?,
        externalPersonID: Int?,
        rankingScore: Double,
        playFadeRecommendation: PlayFadeRecommendation? = nil,
        injuryStatus: InjuryStatus?,
        isSurging: Bool,
        upcomingGames: [ProjectedGame]? = nil,
        homeGameCount: Int? = nil,
        awayGameCount: Int? = nil,
        avgOpponentStrength: Double? = nil,
        hotStreak: Int? = nil,
        coldStreak: Int? = nil,
        trendDirection: TrendDirection? = nil,
        trendScore: Double? = nil,
        confidenceScore: Double? = nil,
        consistencyScore: Double? = nil,
        usageEfficiencySignal: UsageEfficiencySignal? = nil,
        trendHits: Double? = nil,
        trendHR: Double? = nil,
        trendRBI: Double? = nil,
        trendRuns: Double? = nil,
        trendSB: Double? = nil,
        trendDoubles: Double? = nil,
        trendTB: Double? = nil,
        seasonHitsPG: Double? = nil,
        seasonHRPG: Double? = nil,
        seasonRBIPG: Double? = nil,
        seasonRunsPG: Double? = nil,
        seasonSBPG: Double? = nil,
        seasonBBPG: Double? = nil,
        seasonKPG: Double? = nil,
        seasonAvg: Double? = nil,
        seasonH: Int? = nil,
        seasonHR: Int? = nil,
        seasonRBI: Int? = nil,
        seasonR: Int? = nil,
        seasonTB: Int? = nil,
        season2B: Int? = nil,
        season3B: Int? = nil,
        seasonSB: Int? = nil,
        seasonBB: Int? = nil,
        seasonK: Int? = nil,
        seasonAB: Int? = nil,
        seasonGP: Int? = nil,
        wobaProxy: Double? = nil,
        obpProxy: Double? = nil,
        avgPaPerGame: Double? = nil,
        seasonOBP: Double? = nil,
        seasonSLG: Double? = nil,
        seasonOPS: Double? = nil,
        seasonWAR: Double? = nil,
        seasonXBHRate: Double? = nil,
        seasonBBRate: Double? = nil
    ) {{
        self.id = id
        self.displayName = displayName
        self.team = team
        self.position = position
        self.headshotURL = headshotURL
        self.externalPersonID = externalPersonID
        self.rankingScore = rankingScore
        self.playFadeRecommendation = playFadeRecommendation
        self.injuryStatus = injuryStatus
        self.isSurging = isSurging
        self.upcomingGames = upcomingGames
        self.homeGameCount = homeGameCount
        self.awayGameCount = awayGameCount
        self.avgOpponentStrength = avgOpponentStrength
        self.hotStreak = hotStreak
        self.coldStreak = coldStreak
        self.trendDirection = trendDirection
        self.trendScore = trendScore
        self.confidenceScore = confidenceScore
        self.consistencyScore = consistencyScore
        self.usageEfficiencySignal = usageEfficiencySignal
        self.trendHits = trendHits
        self.trendHR = trendHR
        self.trendRBI = trendRBI
        self.trendRuns = trendRuns
        self.trendSB = trendSB
        self.trendDoubles = trendDoubles
        self.trendTB = trendTB
        self.seasonHitsPG = seasonHitsPG
        self.seasonHRPG = seasonHRPG
        self.seasonRBIPG = seasonRBIPG
        self.seasonRunsPG = seasonRunsPG
        self.seasonSBPG = seasonSBPG
        self.seasonBBPG = seasonBBPG
        self.seasonKPG = seasonKPG
        self.seasonAvg = seasonAvg
        self.seasonH = seasonH
        self.seasonHR = seasonHR
        self.seasonRBI = seasonRBI
        self.seasonR = seasonR
        self.seasonTB = seasonTB
        self.season2B = season2B
        self.season3B = season3B
        self.seasonSB = seasonSB
        self.seasonBB = seasonBB
        self.seasonK = seasonK
        self.seasonAB = seasonAB
        self.seasonGP = seasonGP
        self.wobaProxy = wobaProxy
        self.obpProxy = obpProxy
        self.avgPaPerGame = avgPaPerGame
        self.seasonOBP = seasonOBP
        self.seasonSLG = seasonSLG
        self.seasonOPS = seasonOPS
        self.seasonWAR = seasonWAR
        self.seasonXBHRate = seasonXBHRate
        self.seasonBBRate = seasonBBRate
    }}
}}
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

# ── Props feed models (LLM-enriched board props) ──────────────────────────────

top_prop_opportunity_swift = header() + f"""import Foundation

// MARK: - TopPropOpportunity

struct TopPropOpportunity: Decodable, Equatable, Hashable, Identifiable {{
    var id: String {{ "\\(playerID)_\\(market)" }}

    let playerID: String
    let playerName: String
    let team: String?
    let position: String?
    let gameID: String?
    let market: String
    /// Raw stat category from the server (e.g. "hits", "strikeouts", "total_bases").
    /// Prefer this over parsing the market string.
    let stat: String?
    /// Canonical prop line. Sourced from the first bookmaker entry; falls back to
    /// parsing the market key (e.g. "hits_0.5" → 0.5) when bookmakers is absent.
    let line: Double
    let direction: PropDirection
    let ourProbability: Double
    let marketProbability: Double
    let edgePP: Double
    let predictedValue: Double?
    let displayLabel: String?
    let bookmakers: [String: BookmakerLine]?
    let instinctAgrees: Bool?
    let instinctConfidence: InstinctConfidence?
    let instinctSuggestedValue: Double?
    let instinctInsight: String?
    /// True when the server's LLM ranked this prop below confidence threshold after math scoring.
    /// Use this as the orange-badge gate — it is stable even when `blackkatt_instinct` is absent.
    let llmFade: Bool
    /// True when Haiku nominated this prop from the near-miss pool; did not clear the math threshold.
    let llmNominated: Bool

    // MARK: - Coding keys

    enum CodingKeys: String, CodingKey {{
        case playerID = "player_id"
        case playerName = "player_name"
        case team
        case position
        case gameID = "game_id"
        case market
        case stat
        case blackkattInstinct = "blackkatt_instinct"
        case bookmakers
        case llmFade = "llm_fade"
        case llmNominated = "llm_nominated"
    }}

    private enum InstinctKeys: String, CodingKey {{
        case direction
        case predictedValue = "predicted_value"
        case probability
        case marketProbability = "market_probability"
        case edgePP = "edge_pp"
        case displayLabel = "display_label"
        case agrees
        case confidence
        case suggestedValue = "suggested_value"
        case insight
    }}

    init(from decoder: Decoder) throws {{
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playerID = try container.decode(String.self, forKey: .playerID)
        playerName = try container.decode(String.self, forKey: .playerName)
        team = try container.decodeIfPresent(String.self, forKey: .team)
        position = try container.decodeIfPresent(String.self, forKey: .position)
        gameID = try container.decodeIfPresent(String.self, forKey: .gameID)
        market = try container.decode(String.self, forKey: .market)
        stat = try container.decodeIfPresent(String.self, forKey: .stat)
        bookmakers = try container.decodeIfPresent([String: BookmakerLine].self, forKey: .bookmakers)

        // blackkatt_instinct may be absent when Haiku enrichment fails — degrade gracefully
        // rather than throwing and dropping the entire top_prop_opportunities array.
        if let instinct = try? container.nestedContainer(keyedBy: InstinctKeys.self, forKey: .blackkattInstinct) {{
            let rawDirection = try instinct.decode(String.self, forKey: .direction)
            direction = PropDirection(rawValue: rawDirection) ?? .over
            ourProbability = try instinct.decode(Double.self, forKey: .probability)
            marketProbability = try instinct.decode(Double.self, forKey: .marketProbability)
            edgePP = try instinct.decode(Double.self, forKey: .edgePP)
            predictedValue = try instinct.decodeIfPresent(Double.self, forKey: .predictedValue)
            displayLabel = try instinct.decodeIfPresent(String.self, forKey: .displayLabel)
            instinctAgrees = try instinct.decodeIfPresent(Bool.self, forKey: .agrees)
            instinctConfidence = try instinct.decodeIfPresent(InstinctConfidence.self, forKey: .confidence)
            instinctSuggestedValue = try instinct.decodeIfPresent(Double.self, forKey: .suggestedValue)
            instinctInsight = try instinct.decodeIfPresent(String.self, forKey: .insight)
        }} else {{
            direction = .over
            ourProbability = 0
            marketProbability = 0
            edgePP = 0
            predictedValue = nil
            displayLabel = nil
            instinctAgrees = nil
            instinctConfidence = nil
            instinctSuggestedValue = nil
            instinctInsight = nil
        }}
        llmFade = try container.decodeIfPresent(Bool.self, forKey: .llmFade) ?? false
        llmNominated = try container.decodeIfPresent(Bool.self, forKey: .llmNominated) ?? false

        // Derive canonical line from bookmakers, falling back to parsing the market key.
        // All supported books post the same line for standard 0.5/1.5 markets so book
        // choice doesn't matter here; min key for determinism.
        if let firstLine = bookmakers?.min(by: {{ $0.key < $1.key }})?.value.line {{
            line = firstLine
        }} else {{
            line = market.split(separator: "_").last.flatMap {{ Double($0) }} ?? 0.5
        }}
    }}

    // MARK: - Display helpers

    /// Human-readable subtitle combining market name, prop line, and projected value.
    /// Uses server-provided displayLabel when available (substituting the raw stat id
    /// for a display-friendly name), constructing locally otherwise and appending
    /// predictedValue so the user can see the projected stat total (e.g. "proj 1.0").
    var marketSubtitle: String {{
        if let label = displayLabel {{
            return Self.humanizeStatID(in: label)
        }}
        let name = market.split(separator: "_").dropLast().joined(separator: " ").capitalized
        let dir = direction == .over ? "O" : "U"
        let lineStr = line.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", line)
            : String(format: "%.1f", line)
        var subtitle = "\\(name) · \\(dir) \\(lineStr)"
        if let proj = predictedValue {{
            let projStr = proj.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", proj)
                : String(format: "%.1f", proj)
            subtitle += " · proj \\(projStr)"
        }}
        return subtitle
    }}

    /// Compact right-side label: "nn% Over n.n Hits"
    var propLineLabel: String {{
        let pct = Int(ourProbability * 100)
        let dir = direction == .over ? "Over" : "Under"
        let lineStr = line.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", line)
            : String(format: "%.1f", line)
        return "\\(pct)% \\(dir) \\(lineStr) \\(statDisplayName)"
    }}

    /// Replaces any known raw stat id token (e.g. "TOTAL_BASES", "total_bases") within
    /// a server-provided label string with its display-friendly equivalent.
    private static func humanizeStatID(in label: String) -> String {{
        let table: [(id: String, display: String)] = [
            ("total_bases", String(localized: "prop.stat.total_bases", defaultValue: "Total Bases")),
            ("hits_allowed", String(localized: "prop.stat.hits_allowed", defaultValue: "Hits Allowed")),
            ("earned_runs", String(localized: "prop.stat.earned_runs", defaultValue: "Earned Runs")),
            ("pitching_outs", String(localized: "prop.stat.pitching_outs", defaultValue: "Pitching Outs")),
            ("stolen_bases", String(localized: "prop.stat.stolen_bases", defaultValue: "Stolen Bases")),
            ("home_runs", String(localized: "prop.stat.home_runs", defaultValue: "Home Runs")),
            ("strikeouts", String(localized: "prop.stat.strikeouts", defaultValue: "Strikeouts")),
            ("hits", String(localized: "prop.stat.hits", defaultValue: "Hits")),
            ("rbis", String(localized: "prop.stat.rbis", defaultValue: "RBIs")),
            ("runs", String(localized: "prop.stat.runs", defaultValue: "Runs")),
            ("walks", String(localized: "prop.stat.walks", defaultValue: "Walks")),
        ]
        var result = label
        for entry in table {{
            result = result.replacingOccurrences(
                of: entry.id,
                with: entry.display,
                options: .caseInsensitive
            )
        }}
        return result
    }}

    /// UX-friendly display name for the stat category (e.g. "total_bases" → "Total Bases").
    var statDisplayName: String {{
        switch stat {{
        case "hits":
            return String(localized: "prop.stat.hits", defaultValue: "Hits")
        case "strikeouts":
            return String(localized: "prop.stat.strikeouts", defaultValue: "Strikeouts")
        case "total_bases":
            return String(localized: "prop.stat.total_bases", defaultValue: "Total Bases")
        case "rbis":
            return String(localized: "prop.stat.rbis", defaultValue: "RBIs")
        case "runs":
            return String(localized: "prop.stat.runs", defaultValue: "Runs")
        case "walks":
            return String(localized: "prop.stat.walks", defaultValue: "Walks")
        case "stolen_bases":
            return String(localized: "prop.stat.stolen_bases", defaultValue: "Stolen Bases")
        case "home_runs":
            return String(localized: "prop.stat.home_runs", defaultValue: "Home Runs")
        case "pitching_outs":
            return String(localized: "prop.stat.pitching_outs", defaultValue: "Pitching Outs")
        case "hits_allowed":
            return String(localized: "prop.stat.hits_allowed", defaultValue: "Hits Allowed")
        case "earned_runs":
            return String(localized: "prop.stat.earned_runs", defaultValue: "Earned Runs")
        default:
            guard let raw = stat else {{
                return String(localized: "prop.stat.unknown", defaultValue: "Props")
            }}
            return raw.split(separator: "_").map(\\.capitalized).joined(separator: " ")
        }}
    }}

    /// Edge tier derived from edgePP. Single call site — do not recompute inline.
    var tier: PropEdgeTier {{ PropEdgeTier(edgePP: edgePP) }}

    /// Typed stat category. Returns nil for unrecognized server stat strings.
    var statCategory: PropStatCategory? {{ PropStatCategory(rawStat: stat) }}

    /// Best available American odds for the model's recommended direction across all bookmakers.
    var bestOdds: Int? {{
        guard let books = bookmakers, !books.isEmpty else {{ return nil }}
        return direction == .over
            ? books.values.map(\\.overOdds).max()
            : books.values.map(\\.underOdds).max()
    }}
}}

// MARK: - BookmakerLine

struct BookmakerLine: Codable, Equatable, Hashable {{
    let line: Double
    let overOdds: Int
    let underOdds: Int

    enum CodingKeys: String, CodingKey {{
        case line
        case overOdds = "over_odds"
        case underOdds = "under_odds"
    }}
}}

// MARK: - PropDirection

enum PropDirection: String, Codable, Equatable, Hashable {{
    case over
    case under
}}

// MARK: - InstinctConfidence

enum InstinctConfidence: String, Codable, Equatable, Hashable {{
    case high
    case medium
    case low

    var displayLabel: String {{
        switch self {{
        case .high:
            return String(localized: "prop.instinct.confidence.high", defaultValue: "High Confidence")
        case .medium:
            return String(localized: "prop.instinct.confidence.medium", defaultValue: "Medium Confidence")
        case .low:
            return String(localized: "prop.instinct.confidence.low", defaultValue: "Low Confidence")
        }}
    }}
}}
"""

prop_slate_synthesis_swift = f"""// Copyright 2026 Black Katt Technologies Inc.
// iOS {deploy_tgt}+

// MARK: - PropSlateSynthesis

/// Cross-prop strategy summary produced by the server's Sonnet pass.
/// Present only after ~12:30 PM ET and absent when the Sonnet call fails (non-fatal).
struct PropSlateSynthesis: Equatable {{

    // MARK: - Pick

    /// One conviction-ranked prop entry from the server's reranking pass.
    /// Order reflects Sonnet's conviction ranking — do NOT assume index correspondence
    /// with `top_prop_opportunities` (which is math-sorted by edge_pp).
    /// Match by `playerID + market` if cross-referencing.
    struct Pick: Equatable {{
        let playerID: String
        let market: String
        let conviction: SlateConviction
        let convictionReason: String
    }}

    // MARK: - Fields

    let rankedPicks: [Pick]
    let dailyPropNarrative: String
    let contradictions: [String]
}}

// MARK: - SlateConviction

enum SlateConviction: String, Equatable {{
    case high
    case medium
    case low
}}
"""

prop_edge_tier_swift = header() + f"""import SwiftUI

// MARK: - PropEdgeTier

/// Single source of truth for edge-tier ranking and color.
/// All card strips, divider dots, and row strips read `stripColor` from here.
/// Do not add a second color mapping anywhere in the UI layer.
enum PropEdgeTier: Int, CaseIterable, Comparable {{
    case subdued  // < 2pp
    case lean     // ≥ 2pp
    case solid    // ≥ 5pp
    case strong   // ≥ 8pp
    case elite    // ≥ 12pp

    init(edgePP: Double) {{
        switch edgePP {{
        case ..<2:   self = .subdued
        case ..<5:   self = .lean
        case ..<8:   self = .solid
        case ..<12:  self = .strong
        default:     self = .elite
        }}
    }}

    /// Color used for left-edge strips, tier divider dots, and edge value text.
    /// Change here only; do not duplicate this mapping.
    var stripColor: Color {{
        switch self {{
        case .elite:   return Color(red: 1.000, green: 0.843, blue: 0.000) // gold
        case .strong:  return Color(red: 0.753, green: 0.753, blue: 0.753) // silver
        case .solid:   return Color(red: 0.804, green: 0.498, blue: 0.196) // bronze
        case .lean:    return Color(red: 1.000, green: 0.929, blue: 0.000) // yellow
        case .subdued: return Color(red: 0.533, green: 0.529, blue: 0.502) // gray
        }}
    }}

    /// User-visible tier label shown in dividers and hero badge.
    var label: String {{
        switch self {{
        case .elite:
            return String(localized: "prop.tier.elite", defaultValue: "ELITE EDGE")
        case .strong:
            return String(localized: "prop.tier.strong", defaultValue: "STRONG EDGE")
        case .solid:
            return String(localized: "prop.tier.solid", defaultValue: "SOLID EDGE")
        case .lean:
            return String(localized: "prop.tier.lean", defaultValue: "LEAN")
        case .subdued:
            return String(localized: "prop.tier.subdued", defaultValue: "SUBDUED")
        }}
    }}

    static func < (lhs: Self, rhs: Self) -> Bool {{
        lhs.rawValue < rhs.rawValue
    }}
}}
"""

prop_stat_category_swift = header() + f"""import Foundation

// MARK: - PropStatCategory

/// Typed stat category for prop filtering and display.
/// `rawValue` strings must match the server's `stat` field exactly.
/// CaseIterable order drives filter chip display order in the sheet.
///
/// Persistence trap: `selectedStatCategories` is stored in UserDefaults by rawValue.
/// If a rawValue is renamed to track a server change, bump `PropFeedFilterPersistence.key`
/// to `"propFeedFilter.v2"` or stored filters will silently hide non-matching props.
enum PropStatCategory: String, CaseIterable, Codable, Hashable, Identifiable {{
    case hits          = "hits"
    case rbis          = "rbis"
    case totalBases    = "total_bases"
    case homeRuns      = "home_runs"
    case runs          = "runs"
    case walks         = "walks"
    case stolenBases   = "stolen_bases"
    case strikeouts    = "strikeouts"
    case pitchingOuts  = "pitching_outs"
    case hitsAllowed   = "hits_allowed"
    case earnedRuns    = "earned_runs"

    var id: String {{ rawValue }}

    var shortLabel: String {{
        switch self {{
        case .hits:
            return String(localized: "prop.stat.hits", defaultValue: "Hits")
        case .rbis:
            return String(localized: "prop.stat.rbis", defaultValue: "RBI")
        case .totalBases:
            return String(localized: "prop.stat.total_bases", defaultValue: "Total Bases")
        case .homeRuns:
            return String(localized: "prop.stat.home_runs", defaultValue: "Home Runs")
        case .runs:
            return String(localized: "prop.stat.runs", defaultValue: "Runs")
        case .walks:
            return String(localized: "prop.stat.walks", defaultValue: "Walks")
        case .stolenBases:
            return String(localized: "prop.stat.stolen_bases", defaultValue: "Stolen Bases")
        case .strikeouts:
            return String(localized: "prop.stat.strikeouts", defaultValue: "Strikeouts")
        case .pitchingOuts:
            return String(localized: "prop.stat.pitching_outs", defaultValue: "Pitching Outs")
        case .hitsAllowed:
            return String(localized: "prop.stat.hits_allowed", defaultValue: "Hits Allowed")
        case .earnedRuns:
            return String(localized: "prop.stat.earned_runs", defaultValue: "Earned Runs")
        }}
    }}

    var isBatterStat: Bool {{
        switch self {{
        case .hits, .rbis, .totalBases, .homeRuns, .runs, .walks, .stolenBases:
            return true
        case .strikeouts, .pitchingOuts, .hitsAllowed, .earnedRuns:
            return false
        }}
    }}

    init?(rawStat: String?) {{
        guard let raw = rawStat else {{ return nil }}
        self.init(rawValue: raw)
    }}
}}
"""

write_if_absent(os.path.join(models_dir, "TopPropOpportunity.swift"), top_prop_opportunity_swift)
write_if_absent(os.path.join(models_dir, "PropSlateSynthesis.swift"), prop_slate_synthesis_swift)
write_if_absent(os.path.join(models_dir, "PropEdgeTier.swift"), prop_edge_tier_swift)
write_if_absent(os.path.join(models_dir, "PropStatCategory.swift"), prop_stat_category_swift)

# ─────────────────────────────────────────────────────────────────────────────
# 9c. Services
# ─────────────────────────────────────────────────────────────────────────────

services_dir = os.path.join(out_dir, "App/Sources/Core/Services")





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
display = gamelog.get("display", {})
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

games_service_swift = header() + f"""import BKSCore
import BKSUICore
import Foundation

// MARK: - GamesServiceProtocol

protocol GamesServiceProtocol: BKSCore.GamesServiceProtocol {{
    func fetchGameLog(playerID: String, teamID: String) async throws -> PlayerGameLog
}}

// MARK: - GamesService

final class GamesService: GamesServiceProtocol {{

    private let storage: StorageProtocol
    private let sportConfiguration: any SportConfigurationProtocol

    init(
        network: NetworkProtocol,
        firebaseNetwork: NetworkProtocol,
        storage: StorageProtocol,
        configuration: ConfigurationProtocol,
        sportConfiguration: any SportConfigurationProtocol = SportConfiguration.{slug}
    ) {{
        self.storage = storage
        self.sportConfiguration = sportConfiguration
    }}

    // MARK: - Public

    // Game log fetching is not currently surfaced in the app.
    // These stubs satisfy BKSCore.GamesServiceProtocol requirements.
    func fetchGameLog(playerID: String, teamID: String, postseason: Bool) async throws -> PlayerGameLog {{
        throw GamesServiceError.noCompletedGames
    }}

    func fetchGameLog(playerID: String, teamID: String) async throws -> PlayerGameLog {{
        throw GamesServiceError.noCompletedGames
    }}

    func fetchGameLogs(playerIDs: [String], startDate: Date) async throws -> [PlayerGameLog] {{
        []
    }}

    // Playoff bracket data is not currently surfaced in the app.
    // This stub satisfies the BKSCore.GamesServiceProtocol requirement.
    func fetchPlayoffBracket() async throws -> [PlayoffSeries] {{
        []
    }}

    func loadCachedGameLog(playerID: String) throws -> PlayerGameLog? {{
        nil
    }}

    // Schedule data is now owned by BoardService (get-board). This stub satisfies the
    // BKSCore protocol requirement; callers should use BoardService.loadCachedTodaySchedule().
    func fetchTodaySchedule() async throws -> TodaySchedule {{
        throw GamesServiceError.noScheduleFound
    }}

    func loadCachedTodaySchedule() throws -> TodaySchedule? {{
        let key = "\\(sportConfiguration.cacheKeyPrefix)today_schedule_v1"
        return try storage.load(forKey: key, from: .file)
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


write(os.path.join(services_dir, "GamesService.swift"), games_service_swift)

# ── BoardService (board endpoint: schedule + players + odds + props) ──────────

board_service_swift = f"""// Copyright 2026 Black Katt Technologies Inc.
// iOS {deploy_tgt}+
// swiftlint:disable file_length

import Alamofire
import BKSCore
import BKSUICore
import Foundation
import OSLog

// MARK: - BoardServiceProtocol

protocol BoardServiceProtocol {{
    /// Fetches today's board (games + optional embedded analysis). Not paginated.
    func fetchBoard() async throws -> BoardPageResult
    /// Reads the today schedule written by the most recent `fetchBoard` call from disk cache.
    func loadCachedTodaySchedule() throws -> TodaySchedule?
    /// All storage keys written by this service. Used by force-refresh to invalidate on-disk caches.
    var cacheKeys: [String] {{ get }}
}}

// MARK: - BoardPageResult

struct BoardPageResult {{
    let date: String
    let seasonMode: SeasonMode
    let games: [ScheduledGame]
    let dailyAnalysis: DailyAnalysis?
    let scheduleSyncedAt: String?
    let topPropOpportunities: [TopPropOpportunity]?
    let propSlateSynthesis: PropSlateSynthesis?
    let projections: [Projection]
}}

// MARK: - BoardService

final class BoardService: BoardServiceProtocol {{
    private let network: NetworkProtocol
    private let storage: StorageProtocol
    private let configuration: ConfigurationProtocol
    private let sportConfiguration: any SportConfigurationProtocol
    private let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "BoardService"
    )
    private let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "BoardService"
    )
    private let coalescer = FetchCoalescer<BoardPageResult>()

    private var seasonModeKey: String {{ "\\(sportConfiguration.cacheKeyPrefix)season_mode_v1" }}
    private var scheduleCacheKey: String {{ "\\(sportConfiguration.cacheKeyPrefix)today_schedule_v1" }}
    private var scheduleDateKey: String {{ "\\(sportConfiguration.cacheKeyPrefix)today_schedule_v1_date" }}

    var cacheKeys: [String] {{ [seasonModeKey, scheduleCacheKey, scheduleDateKey] }}

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

    func fetchBoard() async throws -> BoardPageResult {{
        try await coalescer.run(logger: logger, label: "fetchBoard") {{
            try await self._fetchBoard()
        }}
    }}

    private func _fetchBoard() async throws -> BoardPageResult {{
        let url = configuration.checkedURL(for: .getBoardURL)
        let fetchInterval = signposter.beginInterval("fetchBoard")
        defer {{ signposter.endInterval("fetchBoard", fetchInterval) }}
        try Task.checkCancellation()

        let response: BoardResponse = try await network.get(url)
        let games = response.games.map(mapGame)
        let seasonMode = SeasonMode(rawValue: response.seasonMode) ?? .regularSeason
        let dailyAnalysis = response.analysis.flatMap {{ assembleAnalysis($0) }}
        let topProps = response.topPropOpportunities
        let slateSynthesis = response.propSlateSynthesis.map {{ dto in
            PropSlateSynthesis(
                rankedPicks: dto.rankedPicks.map {{
                    PropSlateSynthesis.Pick(
                        playerID: $0.playerID,
                        market: $0.market,
                        conviction: SlateConviction(rawValue: $0.conviction) ?? .low,
                        convictionReason: $0.convictionReason
                    )
                }},
                dailyPropNarrative: dto.dailyPropNarrative,
                contradictions: dto.contradictions
            )
        }}
        let projections = (response.playerProjections ?? [:]).compactMap {{ key, dto in
            dto.toProjection(id: key)
        }}

        logger.info(
            "fetchBoard: games=\\(games.count, privacy: .public) projections=\\(projections.count, privacy: .public) analysis=\\(dailyAnalysis != nil ? "yes" : "no", privacy: .public) topProps=\\(topProps?.count ?? 0, privacy: .public) slateSynthesis=\\(slateSynthesis != nil ? "yes" : "no", privacy: .public)"
        )

        writeScheduleCache(games: games, date: response.date, seasonMode: seasonMode)

        return BoardPageResult(
            date: response.date,
            seasonMode: seasonMode,
            games: games,
            dailyAnalysis: dailyAnalysis,
            scheduleSyncedAt: response.scheduleSyncedAt,
            topPropOpportunities: topProps,
            propSlateSynthesis: slateSynthesis,
            projections: projections
        )
    }}

    // MARK: - Cache

    private func writeScheduleCache(games: [ScheduledGame], date: String, seasonMode: SeasonMode) {{
        let schedule = TodaySchedule(date: date, gameCount: games.count, games: games)
        let now = Date.now
        do {{
            try storage.save(seasonMode, forKey: seasonModeKey, in: .file)
            try storage.save(schedule, forKey: scheduleCacheKey, in: .file)
            try storage.save(now, forKey: scheduleDateKey, in: .file)
        }} catch {{
            let msg = "BoardService: failed to write disk caches: \\(error.diagnosticDescription)"
            logger.warning("\\(msg, privacy: .public)")
            DiagnosticLogger.error(msg, category: "BoardService")
        }}
    }}

    func loadCachedTodaySchedule() throws -> TodaySchedule? {{
        try storage.load(forKey: scheduleCacheKey, from: .file)
    }}

    // MARK: - Analysis assembly

    /// Assembles a DailyAnalysis from the embedded board analysis DTO.
    /// Returns nil if date parsing fails so a bad analysis field never crashes board load.
    private func assembleAnalysis(_ dto: BoardAnalysisDTO) -> DailyAnalysis? {{
        guard let generatedAt = parseISO8601Full(dto.generatedAt) else {{
            logger.warning("BoardService: could not parse analysis generated_at '\\(dto.generatedAt, privacy: .public)'")
            return nil
        }}
        let insights = assembleGameInsights(dto.gameInsights)
        return DailyAnalysis(
            date: dto.date,
            cached: false,
            slateInsight: dto.slateInsight ?? "",
            slateNarrativeSections: nil,
            topProjections: dto.topProjections ?? [],
            keyTrends: dto.keyTrends ?? [],
            emergingPlays: dto.emergingPlays ?? [],
            dataConfidence: dto.dataConfidence,
            gameInsights: insights,
            generatedAt: generatedAt,
            model: dto.model
        )
    }}

    private func assembleGameInsights(_ dtos: [String: BoardGameInsightDTO]?) -> [String: GameInsight]? {{
        guard let dtos, !dtos.isEmpty else {{
            logger.debug("BoardService: assembleGameInsights — dtos nil or empty, returning nil")
            return nil
        }}
        logger.debug("BoardService: assembleGameInsights — keys=[\\(dtos.keys.sorted().joined(separator: ", "), privacy: .public)]")
        var insights: [String: GameInsight] = [:]
        for (key, dto) in dtos {{
            guard let generatedAt = parseISO8601Full(dto.generatedAt) else {{
                logger.warning("BoardService: dropping game_insight \\(key, privacy: .public): invalid date")
                continue
            }}
            insights[key] = GameInsight(
                gameId: dto.gameId,
                homeTeam: dto.homeTeam,
                awayTeam: dto.awayTeam,
                generatedAt: generatedAt,
                gameEnvironment: dto.gameEnvironment,
                lineMovementSignal: dto.lineMovementSignal,
                matchupNarrative: dto.matchupNarrative,
                keyPlayers: dto.keyPlayers,
                gameStackTargets: dto.gameStackTargets,
                injuryFlags: dto.injuryFlags
            )
        }}
        return insights.isEmpty ? nil : insights
    }}

    // MARK: - Game / odds mapping

    private func mapGame(_ dto: BoardGameDTO) -> ScheduledGame {{
        ScheduledGame(
            id: dto.gameID,
            homeTeamAbbr: dto.homeTeamAbbr,
            visitorTeamAbbr: dto.visitorTeamAbbr,
            status: dto.status,
            gameType: dto.gameType,
            gameDatetime: parseISO8601(dto.gameDatetime) ?? .distantFuture,
            homeOdds: dto.homeOdds.map(mapOdds),
            visitorOdds: dto.visitorOdds.map(mapOdds),
            homeProjTotal: dto.homeProjTotal,
            visitorProjTotal: dto.visitorProjTotal,
            projTotal: dto.projTotal,
            bkWinner: dto.bkWinner,
            bkWinnerConfidence: dto.bkWinnerConfidence,
            bkSpreadPick: dto.bkSpreadPick,
            bkSpreadPickCovers: dto.bkSpreadPickCovers,
            bkSpreadConfidence: dto.bkSpreadConfidence,
            vegasOverUnder: dto.vegasOverUnder,
            bkOuPick: dto.bkOuPick.flatMap(OUPick.init(rawValue:)),
            bkOuEdge: dto.bkOuEdge,
            bkOuConfidence: dto.bkOuConfidence,
            ouPick: dto.ouPick.flatMap(OUPick.init(rawValue:)),
            ouPickRationale: dto.ouPickRationale,
            isDoubleheader: dto.isDoubleheader,
            gameSequence: dto.gameSequence,
            scoringTier: dto.scoringTier
        )
    }}

    private func mapOdds(_ dto: BoardGameSideOddsDTO) -> GameSideOdds {{
        GameSideOdds(
            impliedTeamTotal: dto.impliedTeamTotal,
            overUnder: dto.overUnder,
            spread: dto.spread,
            isFavorite: dto.isFavorite ?? false,
            marketWinProb: dto.marketWinProb,
            divergence: dto.divergence
        )
    }}

    // MARK: - Date parsing

    private static let iso8601WithOffset: ISO8601DateFormatter = {{
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }}()

    private static let iso8601Full: ISO8601DateFormatter = {{
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }}()

    private func parseISO8601(_ string: String?) -> Date? {{
        guard let string else {{ return nil }}
        return Self.iso8601WithOffset.date(from: string)
            ?? Self.iso8601Full.date(from: string)
    }}

    private func parseISO8601Full(_ string: String) -> Date? {{
        Self.iso8601Full.date(from: string)
            ?? Self.iso8601WithOffset.date(from: string)
    }}
}}

// MARK: - Response DTOs

private struct BoardResponse: Decodable {{
    let date: String
    let seasonMode: String
    let gameCount: Int
    let games: [BoardGameDTO]
    let scheduleSyncedAt: String?
    let analysis: BoardAnalysisDTO?
    let topPropOpportunities: [TopPropOpportunity]?
    let playerProjections: [String: ProjectionPlayerDTO]?
    let propSlateSynthesis: PropSlateSynthesisDTO?

    enum CodingKeys: String, CodingKey {{
        case date
        case seasonMode = "season_mode"
        case gameCount = "game_count"
        case games
        case scheduleSyncedAt = "schedule_synced_at"
        case analysis
        case topPropOpportunities = "top_prop_opportunities"
        case playerProjections = "player_projections"
        case propSlateSynthesis = "prop_slate_synthesis"
    }}
}}

private struct BoardAnalysisDTO: Decodable {{
    let date: String
    let generatedAt: String
    let model: String?
    let dataConfidence: String?
    let slateInsight: String?
    let topProjections: [String]?
    let keyTrends: [String]?
    let emergingPlays: [String]?
    let gameInsights: [String: BoardGameInsightDTO]?

    enum CodingKeys: String, CodingKey {{
        case date
        case generatedAt = "generated_at"
        case model
        case dataConfidence = "data_confidence"
        case slateInsight = "slate_insight"
        case topProjections = "top_projections"
        case keyTrends = "key_trends"
        case emergingPlays = "emerging_plays"
        case gameInsights = "game_insights"
    }}

    init(from decoder: Decoder) throws {{
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        generatedAt = try container.decode(String.self, forKey: .generatedAt)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        dataConfidence = try container.decodeIfPresent(String.self, forKey: .dataConfidence)
        slateInsight = try container.decodeIfPresent(String.self, forKey: .slateInsight)
        topProjections = try container.decodeIfPresent([String].self, forKey: .topProjections)
        keyTrends = try container.decodeIfPresent([String].self, forKey: .keyTrends)
        emergingPlays = try container.decodeIfPresent([String].self, forKey: .emergingPlays)

        // Decode game_insights entry-by-entry; a bad entry is skipped rather than failing the whole DTO.
        if let insightsContainer = try? container.nestedContainer(
            keyedBy: DynamicKey.self, forKey: .gameInsights
        ) {{
            var parsed: [String: BoardGameInsightDTO] = [:]
            for key in insightsContainer.allKeys {{
                if let dto = try? insightsContainer.decode(BoardGameInsightDTO.self, forKey: key) {{
                    parsed[key.stringValue] = dto
                }}
            }}
            gameInsights = parsed.isEmpty ? nil : parsed
        }} else {{
            gameInsights = nil
        }}
    }}
}}

private struct PropSlateSynthesisDTO: Decodable {{
    let rankedPicks: [SlatePickDTO]
    let dailyPropNarrative: String
    let contradictions: [String]

    enum CodingKeys: String, CodingKey {{
        case rankedPicks = "ranked_picks"
        case dailyPropNarrative = "daily_prop_narrative"
        case contradictions
    }}

    init(from decoder: Decoder) throws {{
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rankedPicks = try container.decodeIfPresent([SlatePickDTO].self, forKey: .rankedPicks) ?? []
        dailyPropNarrative = try container.decode(String.self, forKey: .dailyPropNarrative)
        contradictions = try container.decodeIfPresent([String].self, forKey: .contradictions) ?? []
    }}
}}

private struct SlatePickDTO: Decodable {{
    let playerID: String
    let market: String
    let conviction: String
    let convictionReason: String

    enum CodingKeys: String, CodingKey {{
        case playerID = "player_id"
        case market
        case conviction
        case convictionReason = "conviction_reason"
    }}
}}

private struct BoardGameInsightDTO: Decodable {{
    let gameId: String
    let homeTeam: String
    let awayTeam: String
    let generatedAt: String
    let gameEnvironment: GameInsight.GameEnvironment
    let lineMovementSignal: GameInsight.LineMovementSignal
    let matchupNarrative: String
    let keyPlayers: [String]
    let gameStackTargets: [String]
    let injuryFlags: [String]

    enum CodingKeys: String, CodingKey {{
        case gameId = "game_id"
        case homeTeam = "home_team"
        case awayTeam = "away_team"
        case generatedAt = "generated_at"
        case gameEnvironment = "game_environment"
        case lineMovementSignal = "line_movement_signal"
        case matchupNarrative = "matchup_narrative"
        case keyPlayers = "key_players"
        case gameStackTargets = "game_stack_targets"
        case injuryFlags = "injury_flags"
    }}

    init(from decoder: Decoder) throws {{
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gameId = try container.decode(String.self, forKey: .gameId)
        homeTeam = try container.decode(String.self, forKey: .homeTeam)
        awayTeam = try container.decode(String.self, forKey: .awayTeam)
        generatedAt = try container.decode(String.self, forKey: .generatedAt)
        gameEnvironment = (try? container.decode(
            GameInsight.GameEnvironment.self, forKey: .gameEnvironment
        )) ?? .neutral
        lineMovementSignal = (try? container.decode(
            GameInsight.LineMovementSignal.self, forKey: .lineMovementSignal
        )) ?? .neutral
        matchupNarrative = try container.decode(String.self, forKey: .matchupNarrative)
        keyPlayers = (try container.decodeIfPresent([String].self, forKey: .keyPlayers)) ?? []
        gameStackTargets = (try container.decodeIfPresent([String].self, forKey: .gameStackTargets)) ?? []
        injuryFlags = (try container.decodeIfPresent([String].self, forKey: .injuryFlags)) ?? []
    }}
}}

private struct BoardGameDTO: Decodable {{
    let gameID: Int
    let gameType: String
    let homeTeamAbbr: String
    let visitorTeamAbbr: String
    let gameDatetime: String
    let isDoubleheader: Bool
    let gameSequence: Int
    let status: String
    let homeOdds: BoardGameSideOddsDTO?
    let visitorOdds: BoardGameSideOddsDTO?
    let bkWinner: String?
    let bkWinnerConfidence: Double?
    let bkSpreadPick: String?
    let bkSpreadPickCovers: Bool?
    let bkSpreadConfidence: Double?
    let vegasOverUnder: Double?
    // Picks decode as raw strings, not OUPick — a novel server value must degrade
    // to nil in mapGame, not throw and kill the whole board decode.
    let bkOuPick: String?
    let bkOuEdge: Double?
    let bkOuConfidence: Double?
    let ouPick: String?
    let ouPickRationale: String?
    let projTotal: Double?
    let homeProjTotal: Double?
    let visitorProjTotal: Double?
    let scoringTier: ScoringTier?

    enum CodingKeys: String, CodingKey {{
        case gameID = "game_id"
        case gameType = "game_type"
        case homeTeamAbbr = "home_team_abbr"
        case visitorTeamAbbr = "visitor_team_abbr"
        case gameDatetime = "game_datetime"
        case isDoubleheader = "is_doubleheader"
        case gameSequence = "game_sequence"
        case status
        case homeOdds = "home_odds"
        case visitorOdds = "visitor_odds"
        case bkWinner = "bk_winner"
        case bkWinnerConfidence = "bk_winner_confidence"
        case bkSpreadPick = "bk_spread_pick"
        case bkSpreadPickCovers = "bk_spread_pick_covers"
        case bkSpreadConfidence = "bk_spread_confidence"
        case vegasOverUnder = "vegas_over_under"
        case bkOuPick = "bk_ou_pick"
        case bkOuEdge = "bk_ou_edge"
        case bkOuConfidence = "bk_ou_confidence"
        case ouPick = "ou_pick"
        case ouPickRationale = "ou_pick_rationale"
        case projTotal = "proj_total"
        case homeProjTotal = "home_proj_total"
        case visitorProjTotal = "visitor_proj_total"
        case scoringTier = "scoring_tier"
    }}
}}

private struct BoardGameSideOddsDTO: Decodable {{
    let impliedTeamTotal: Double
    let overUnder: Double
    let spread: Double
    let isFavorite: Bool?
    let marketWinProb: Double?
    let divergence: Double?

    enum CodingKeys: String, CodingKey {{
        case impliedTeamTotal = "implied_team_total"
        case overUnder = "over_under"
        case spread
        case isFavorite = "is_favorite"
        case marketWinProb = "market_win_prob"
        case divergence
    }}
}}

private struct DynamicKey: CodingKey {{
    var stringValue: String
    var intValue: Int? {{ nil }}
    init(stringValue: String) {{ self.stringValue = stringValue }}
    init?(intValue: Int) {{ nil }}
}}

private struct PropLineDTO: Decodable {{
    let stat: String
    let line: Double
    let overOdds: Int
    let underOdds: Int
    let calibratedProbOver: Double
    let hasEdge: Bool
    let displayLabel: String

    enum CodingKeys: String, CodingKey {{
        case stat, line
        case overOdds = "over_odds"
        case underOdds = "under_odds"
        case calibratedProbOver = "calibrated_prob_over"
        case hasEdge = "has_edge"
        case displayLabel = "display_label"
    }}
}}

// MARK: - Projection DTOs (embedded in board response)

/// Decodes a Double from either a JSON number or a numeric string.
/// Handles backend inconsistency where fields like season_avg arrive as strings.
struct FlexDouble: Decodable {{
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

struct ProjectionPlayerDTO: Decodable {{
    let id: Int?
    let firstName: String?
    let lastName: String?
    let position: String?
    let team: String?
    let externalPersonID: Int?
    let headshotURL: URL?
    let trendDirection: TrendDirection?
    let trendScore: Double?
    let confidenceScore: Double?
    let hotStreak: Int?
    let coldStreak: Int?
    let injuryStatus: String?
    let playFadeRecommendation: PlayFadeRecommendation?
    let games: [ProjectedGameDTO]?

    let trendHits: FlexDouble?
    let trendHR: FlexDouble?
    let trendRBI: FlexDouble?
    let trendRuns: FlexDouble?
    let trendSB: FlexDouble?
    let trendDoubles: FlexDouble?
    let trendTB: FlexDouble?

    let seasonHitsPG: FlexDouble?
    let seasonHRPG: FlexDouble?
    let seasonRBIPG: FlexDouble?
    let seasonRunsPG: FlexDouble?
    let seasonSBPG: FlexDouble?
    let seasonBBPG: FlexDouble?
    let seasonKPG: FlexDouble?
    let seasonAvg: FlexDouble?

    let seasonH: Int?
    let seasonHR: Int?
    let seasonRBI: Int?
    let seasonR: Int?
    let seasonTB: Int?
    let season2B: Int?
    let season3B: Int?
    let seasonSB: Int?
    let seasonBB: Int?
    let seasonK: Int?
    let seasonAB: Int?
    let seasonGP: Int?

    let wobaProxy: FlexDouble?
    let obpProxy: FlexDouble?
    let avgPaPerGame: FlexDouble?
    let seasonOBP: FlexDouble?
    let seasonSLG: FlexDouble?
    let seasonOPS: FlexDouble?
    let seasonWAR: FlexDouble?
    let seasonXBHRate: FlexDouble?
    let seasonBBRate: FlexDouble?

    enum CodingKeys: String, CodingKey {{
        case id
        case firstName = "first_name"
        case lastName = "last_name"
        case position
        case team
        case externalPersonID = "mlb_person_id"
        case headshotURL = "headshot_url"
        case trendDirection = "trend_direction"
        case trendScore = "trend_score"
        case confidenceScore = "confidence_score"
        case hotStreak = "hot_streak"
        case coldStreak = "cold_streak"
        case injuryStatus = "injury_status"
        case playFadeRecommendation = "play_fade_recommendation"
        case games
        case trendHits = "trend_hits"
        case trendHR = "trend_hr"
        case trendRBI = "trend_rbi"
        case trendRuns = "trend_runs"
        case trendSB = "trend_sb"
        case trendDoubles = "trend_doubles"
        case trendTB = "trend_tb"
        case seasonHitsPG = "season_hits_pg"
        case seasonHRPG = "season_hr_pg"
        case seasonRBIPG = "season_rbi_pg"
        case seasonRunsPG = "season_runs_pg"
        case seasonSBPG = "season_sb_pg"
        case seasonBBPG = "season_bb_pg"
        case seasonKPG = "season_k_pg"
        case seasonAvg = "season_avg"
        case seasonH = "season_h"
        case seasonHR = "season_hr"
        case seasonRBI = "season_rbi"
        case seasonR = "season_r"
        case seasonTB = "season_tb"
        case season2B = "season_2b"
        case season3B = "season_3b"
        case seasonSB = "season_sb"
        case seasonBB = "season_bb"
        case seasonK = "season_k"
        case seasonAB = "season_ab"
        case seasonGP = "season_gp"
        case wobaProxy = "woba_proxy"
        case obpProxy = "obp_proxy"
        case avgPaPerGame = "avg_pa_per_game"
        case seasonOBP = "season_obp"
        case seasonSLG = "season_slg"
        case seasonOPS = "season_ops"
        case seasonWAR = "season_war"
        case seasonXBHRate = "season_xbh_rate"
        case seasonBBRate = "season_bb_rate"
    }}
}}

struct ProjectedGameDTO: Decodable {{
    let date: String
    let opponent: String
    let isHome: Bool?
    let opportunityScore: Double?
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
        case opportunityScore = "opp_ranking_score"
        case isBackToBack = "is_back_to_back"
        case teamRestDays = "team_rest_days"
        case blowoutProb = "blowout_prob"
        case vegasImpliedTeamTotal = "vegas_implied_team_total"
        case vegasOverUnder = "vegas_over_under"
        case vegasSpread = "vegas_spread"
        case matchupMultiplier = "matchup_multiplier"
    }}
}}

// MARK: - Projection mapping

extension ProjectionPlayerDTO {{
    private static let dateFormatter: DateFormatter = {{
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }}()

    // swiftlint:disable:next function_body_length
    func toProjection(id: String) -> Projection? {{
        let games = self.games ?? []
        guard !games.isEmpty else {{ return nil }}
        let rankingScore = games.compactMap(\\.opportunityScore).max() ?? 0

        let upcomingGames: [ProjectedGame] = games.enumerated().compactMap {{ index, game in
            let date = Self.dateFormatter.date(from: game.date) ?? .now
            return ProjectedGame(
                id: "\\(id)-game-\\(index)",
                gameDate: date,
                opponentAbbr: game.opponent,
                isHome: game.isHome ?? false,
                opponentStrength: game.opportunityScore
            )
        }}

        return Projection(
            id: id,
            displayName: [firstName, lastName]
                .compactMap {{ $0?.isEmpty == false ? $0 : nil }}
                .joined(separator: " "),
            team: team ?? "",
            position: position.flatMap {{ $0.isEmpty ? nil : $0 }},
            headshotURL: headshotURL,
            externalPersonID: externalPersonID,
            rankingScore: rankingScore,
            playFadeRecommendation: playFadeRecommendation,
            injuryStatus: injuryStatus.flatMap {{ InjuryStatus(rawValue: $0) }},
            isSurging: (hotStreak ?? 0) > 0,
            upcomingGames: upcomingGames.isEmpty ? nil : upcomingGames,
            homeGameCount: upcomingGames.filter(\\.isHome).count,
            awayGameCount: upcomingGames.filter {{ !$0.isHome }}.count,
            avgOpponentStrength: upcomingGames.compactMap(\\.opponentStrength).average,
            hotStreak: hotStreak,
            coldStreak: coldStreak,
            trendDirection: trendDirection,
            trendScore: trendScore,
            confidenceScore: confidenceScore,
            trendHits: trendHits?.value,
            trendHR: trendHR?.value,
            trendRBI: trendRBI?.value,
            trendRuns: trendRuns?.value,
            trendSB: trendSB?.value,
            trendDoubles: trendDoubles?.value,
            trendTB: trendTB?.value,
            seasonHitsPG: seasonHitsPG?.value,
            seasonHRPG: seasonHRPG?.value,
            seasonRBIPG: seasonRBIPG?.value,
            seasonRunsPG: seasonRunsPG?.value,
            seasonSBPG: seasonSBPG?.value,
            seasonBBPG: seasonBBPG?.value,
            seasonKPG: seasonKPG?.value,
            seasonAvg: seasonAvg?.value,
            seasonH: seasonH,
            seasonHR: seasonHR,
            seasonRBI: seasonRBI,
            seasonR: seasonR,
            seasonTB: seasonTB,
            season2B: season2B,
            season3B: season3B,
            seasonSB: seasonSB,
            seasonBB: seasonBB,
            seasonK: seasonK,
            seasonAB: seasonAB,
            seasonGP: seasonGP,
            wobaProxy: wobaProxy?.value,
            obpProxy: obpProxy?.value,
            avgPaPerGame: avgPaPerGame?.value,
            seasonOBP: seasonOBP?.value,
            seasonSLG: seasonSLG?.value,
            seasonOPS: seasonOPS?.value,
            seasonWAR: seasonWAR?.value,
            seasonXBHRate: seasonXBHRate?.value,
            seasonBBRate: seasonBBRate?.value
        )
    }}
}}

// MARK: - Helpers

extension Array where Element == Double {{
    var average: Double? {{
        isEmpty ? nil : reduce(0, +) / Double(count)
    }}
}}
"""

write_if_absent(os.path.join(services_dir, "BoardService.swift"), board_service_swift)

# ─────────────────────────────────────────────────────────────────────────────
# 9d. Core Utilities files (continued)
# ─────────────────────────────────────────────────────────────────────────────

utilities_dir = os.path.join(out_dir, "App/Sources/Core/Utilities")


# ─────────────────────────────────────────────────────────────────────────────
# 9d-ii. Sport-specific model extensions
# ─────────────────────────────────────────────────────────────────────────────

game_entry_basketball_swift = header() + f"""import BKSCore

// MARK: - GameEntry {swift_name} stat accessors

public extension GameEntry {{
    var single: Int           {{ stats["single"] ?? 0 }}
    var double: Int           {{ stats["double"] ?? 0 }}
    var triple: Int           {{ stats["triple"] ?? 0 }}
    var homeRun: Int           {{ stats["homeRun"] ?? 0 }}
    var rbi: Int           {{ stats["rbi"] ?? 0 }}
    var run: Int           {{ stats["run"] ?? 0 }}
    var walk: Int           {{ stats["walk"] ?? 0 }}
    var hitByPitch: Int           {{ stats["hitByPitch"] ?? 0 }}
    var stolenBase: Int           {{ stats["stolenBase"] ?? 0 }}
    var sacrificeFly: Int           {{ stats["sacrificeFly"] ?? 0 }}
    var sacrificeHit: Int           {{ stats["sacrificeHit"] ?? 0 }}
    var inningsPitched: Double           {{ Double(stats["inningsPitched"] ?? 0) / 10.0 }}
    var strikeoutPitching: Int           {{ stats["strikeoutPitching"] ?? 0 }}
    var win: Int           {{ stats["win"] ?? 0 }}
    var earnedRunAllowed: Int           {{ stats["earnedRunAllowed"] ?? 0 }}
    var hitAgainst: Int           {{ stats["hitAgainst"] ?? 0 }}
    var walkAgainst: Int           {{ stats["walkAgainst"] ?? 0 }}
    var hitBatsmanAgainst: Int           {{ stats["hitBatsmanAgainst"] ?? 0 }}
    var completeGame: Int           {{ stats["completeGame"] ?? 0 }}
    var completeGameShutout: Int           {{ stats["completeGameShutout"] ?? 0 }}
    var noHitter: Int           {{ stats["noHitter"] ?? 0 }}

    var atBats: Int {{
        (stats["single"] ?? 0) + (stats["double"] ?? 0) + (stats["triple"] ?? 0) + (stats["homeRun"] ?? 0)
    }}
    var hits: Int {{ single + double + triple + homeRun }}

    /// Sport-specific DNP check. Overrides the BKSCore default.
    var isDNP: Bool {{ (stats["single"] ?? 0) == 0 && inningsPitched == 0.0 }}
}}

// MARK: - PlayerGameLog {swift_name} averages

public extension PlayerGameLog {{
    var averageHomeRuns: Double {{
        guard !entries.isEmpty else {{ return 0 }}
        return Double(entries.reduce(0) {{ $0 + $1.homeRun }}) / Double(entries.count)
    }}

    var averageRBI: Double {{
        guard !entries.isEmpty else {{ return 0 }}
        return Double(entries.reduce(0) {{ $0 + $1.rbi }}) / Double(entries.count)
    }}

    var averageInningsPitched: Double {{
        guard !entries.isEmpty else {{ return 0 }}
        return entries.reduce(0.0) {{ $0 + $1.inningsPitched }} / Double(entries.count)
    }}

    var averageStrikeouts: Double {{
        guard !entries.isEmpty else {{ return 0 }}
        return Double(entries.reduce(0) {{ $0 + $1.strikeoutPitching }}) / Double(entries.count)
    }}

    var averageHits: Double {{
        guard !entries.isEmpty else {{ return 0 }}
        return Double(entries.reduce(0) {{ $0 + $1.hits }}) / Double(entries.count)
    }}

    var averageBattingAverage: Double {{
        let totalAB = entries.reduce(0) {{ $0 + $1.atBats }}
        guard totalAB > 0 else {{ return 0 }}
        return Double(entries.reduce(0) {{ $0 + $1.hits }}) / Double(totalAB)
    }}

    var averageERA: Double {{
        let totalIP = entries.reduce(0.0) {{ $0 + $1.inningsPitched }}
        guard totalIP > 0 else {{ return 0 }}
        return Double(entries.reduce(0) {{ $0 + $1.earnedRunAllowed }}) * 9.0 / totalIP
    }}

    var winPercentage: Double {{
        let decisionsGames = entries.filter {{ $0.inningsPitched > 0 }}.count
        guard decisionsGames > 0 else {{ return 0 }}
        return Double(entries.reduce(0) {{ $0 + $1.win }}) / Double(decisionsGames)
    }}
}}
"""

# proj_accessor_lines drives the legacy camelCase group (locally-computed stat lines,
# matching GameEntry stat keys). The snake_case API group below must be maintained
# manually per sport — keys come from the server projected_stats schema, not YAML.
projected_stat_line_basketball_swift = header() + f"""import BKSCore

// MARK: - ProjectedStatLine {swift_name} stat accessors

public extension ProjectedStatLine {{
    // Server-side projected_stats keys (snake_case from API response)
    var hits: Double?             {{ stats["hits"] }}
    var homeRuns: Double?         {{ stats["home_runs"] }}
    var rbis: Double?             {{ stats["rbis"] }}
    var runs: Double?             {{ stats["runs"] }}
    var stolenBases: Double?      {{ stats["stolen_bases"] }}
    var walks: Double?            {{ stats["walks"] }}

    // Legacy camelCase accessors (kept for compatibility with locally-computed stat lines)
    var homeRun: Double?          {{ stats["homeRun"] }}
    var rbi: Double?              {{ stats["rbi"] }}
    var run: Double?              {{ stats["run"] }}
    var single: Double?           {{ stats["single"] }}
    var double: Double?           {{ stats["double"] }}
    var triple: Double?           {{ stats["triple"] }}
    var stolenBase: Double?       {{ stats["stolenBase"] }}
    var walk: Double?             {{ stats["walk"] }}
    var inningsPitched: Double?   {{ stats["inningsPitched"] }}
    var strikeoutPitching: Double? {{ stats["strikeoutPitching"] }}
    var earnedRunAllowed: Double? {{ stats["earnedRunAllowed"] }}
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
props_views_dir   = os.path.join(out_dir, "App/Sources/Features/Board/Views/Props")
profile_views_dir = os.path.join(out_dir, "App/Sources/Features/Profile/Views")

# ── BoardEntry.swift ───────────────────────────────────────────────────────────────────

board_entry_swift = header() + f"""import Foundation
import BKSCore

// MARK: - BoardEntry
//
// Composite model combining opportunities, projections, and game data
// into a single display-ready record.
// Add sport-specific fields below the Sport-specific marker.

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
    let confidenceScore: Double?

    // Trend layer
    let hotStreak: Int?
    let coldStreak: Int?
    let usageEfficiencySignal: UsageEfficiencySignal?

    // Opportunity layer
    let opportunityScore: Double?
    let opportunityTier: TierLevel?
    let isTopPick: Bool
    let topPickRank: Int?

    // Status
    let injuryStatus: InjuryStatus?

    // MARK: - Sport-specific fields

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

    // Pitcher classification
    let rotationTier: RotationTier?

    // Trend slopes
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

    // MARK: - BoardEntryDisplayable stubs (protocol required by BKSUICore; no fantasy data stored)
    var projectedScore: Double? {{ nil }}
    var projectedScoreFd: Double? {{ nil }}
    var playoffDataConfidence: Double? {{ nil }}
    var avgFantasyScoreHome: Double? {{ nil }}
    var avgFantasyScoreAway: Double? {{ nil }}
    var isConfirmedStarter: Bool? {{ nil }}
    var projectionTier: TierLevel? {{ nil }}
    var playerTier: TierLevel? {{ nil }}
    var isTopCeiling: Bool {{ false }}
    var topCeilingRank: Int? {{ nil }}
    var isTopValue: Bool {{ false }}
    var topValueRank: Int? {{ nil }}
}}
"""

# ── BoardEntryBuilder.swift ──────────────────────────────────────────────────────────

board_entry_builder_swift = header() + f"""import BKSCore
import Foundation
import OSLog

// MARK: - BoardEntryBuilder

private let logger = os.Logger(subsystem: "{bundle_id}", category: "BoardEntryBuilder")

private let todayDateParser: DateFormatter = {{
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}}()

enum BoardEntryBuilder {{

    static func build(
        players: [Player],
        projections: [Projection] = [],
        opportunities: [Opportunity],
        todayDateString: String?
    ) -> [BoardEntry] {{
        // Parse the server date string once; compare game dates with Calendar rather than
        // round-tripping each Date back through a DateFormatter per game.
        let todayDate = todayDateString.flatMap {{ todayDateParser.date(from: $0) }}

        // Primary join: {league} person ID when available on both sides.
        // Fallback: displayName+team when externalPersonID is nil everywhere.
        let hasIDOnProj = projections.contains {{ $0.externalPersonID != nil }}
        let hasIDOnOpp  = opportunities.contains {{ $0.externalPersonID != nil }}

        if hasIDOnProj && hasIDOnOpp {{
            return buildByID(projections: projections, opportunities: opportunities, todayDate: todayDate)
        }} else {{
            logger.warning("externalPersonID nil on all records — falling back to name+team join")
            return buildByName(projections: projections, opportunities: opportunities, todayDate: todayDate)
        }}
    }}

    // MARK: - ID join

    private static func buildByID(
        projections: [Projection],
        opportunities: [Opportunity],
        todayDate: Date?
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
            makeEntry(id: String(pid), proj: projMap[pid], opp: oppMap[pid], todayDate: todayDate)
        }}
        logger.debug("ID join: \\(entries.count, privacy: .public) entries (projections: \\(projections.count, privacy: .public), opportunities: \\(opportunities.count, privacy: .public))")
        return entries
    }}

    // MARK: - Name+team fallback join

    private static func buildByName(
        projections: [Projection],
        opportunities: [Opportunity],
        todayDate: Date?
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
            if let entry = makeEntry(id: opp.id, proj: proj, opp: opp, todayDate: todayDate) {{
                entries.append(entry)
            }}
        }}

        // Projection-only entries with no matching opportunity.
        for proj in projections {{
            let key = nameKey(proj.displayName, proj.team)
            guard !usedKeys.contains(key) else {{ continue }}
            if let entry = makeEntry(id: proj.id, proj: proj, opp: nil, todayDate: todayDate) {{
                entries.append(entry)
            }}
        }}

        logger.debug("Name join: \\(entries.count, privacy: .public) entries (projections: \\(projections.count, privacy: .public), opportunities: \\(opportunities.count, privacy: .public))")
        return entries
    }}

    private static func nameKey(_ displayName: String, _ team: String) -> String {{
        "\\(displayName.lowercased())|\\(team.lowercased())"
    }}

    // MARK: - Entry construction

    // swiftlint:disable:next function_body_length
    private static func makeEntry(
        id: String,
        proj: Projection?,
        opp: Opportunity?,
        todayDate: Date?
    ) -> BoardEntry? {{
        let tonightGame: ProjectedGame? = todayDate.flatMap {{ today in
            proj?.upcomingGames?.first {{
                Calendar.current.isDate($0.gameDate, inSameDayAs: today)
            }}
        }}

        let confidenceScore = proj?.confidenceScore

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
            confidenceScore: confidenceScore,
            hotStreak: proj?.hotStreak,
            coldStreak: proj?.coldStreak,
            usageEfficiencySignal: proj?.usageEfficiencySignal,
            opportunityScore: opp?.opportunityScore,
            opportunityTier: opp?.opportunityTier,
            isTopPick: opp?.isTopPick ?? false,
            topPickRank: opp?.topPickRank,
            injuryStatus: injuryStatus,
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
            seasonOBP: proj?.seasonOBP,
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
    let playoffSeries: [PlayoffSeries]
    let totalOpportunities: Int
    /// ISO 8601 UTC timestamp of the last sync_today_games run. Nil until the board response arrives.
    let scheduleSyncedAt: String?
    /// Server-ranked prop opportunities. Nil before ~12:30 PM ET.
    let topPropOpportunities: [TopPropOpportunity]?
    /// Cross-prop strategy summary from the server's Sonnet pass. Nil before ~12:30 PM ET.
    let propSlateSynthesis: PropSlateSynthesis?
}}

// MARK: - BoardViewMode

enum BoardViewMode: String, Hashable {{
    case props
    /// Deferred: requires per-player salary data not yet available from the backend.
    case draftKings
    /// Deferred: requires per-player salary data not yet available from the backend.
    case fanDuel
}}

// MARK: - BoardIntent

enum BoardIntent: CancellableIntent {{
    case onAppear
    case refreshRequested
    /// Triggered by background data refresh (silent push / BGTask). Does not cancel an in-flight fetch.
    case backgroundRefreshRequested
    case entriesLoaded(BoardLoadResult)
    case loadFailed(Error)
    case navigationPathChanged(NavigationPath)
    case pushNotificationTapped(String)
    case deepLinkHandled
    case refreshBannerExpired
    case diskCacheLoaded(BoardLoadResult)
    /// Paint cached board state as soon as BoardView mounts — before entitlement is known.
    /// Must not chain .backgroundRefreshRequested; the network fetch is gated separately
    /// on entitlementReady to preserve the 402 guard.
    case hydrateFromDisk
    /// User committed a new prop feed filter from the filter sheet.
    case propFeedFilterChanged(PropFeedFilter)

    var cancelsInFlightWork: Bool {{
        switch self {{
        // Pure synchronous mutations — never interrupt long-running fetches.
        case .navigationPathChanged, .pushNotificationTapped,
             .deepLinkHandled, .refreshBannerExpired, .diskCacheLoaded,
             .hydrateFromDisk, .propFeedFilterChanged:
            false
        // backgroundRefreshRequested is cancellable so the Store tracks it in
        // currentTask. This lets a subsequent .refreshRequested cancel it, and
        // ensures the dedup guard in makeReduce operates on committed state
        // rather than racing against an untracked in-flight task.
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
    var loadState: ViewState<[BoardEntry]> = .loading
    var allEntries: [BoardEntry] = []
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
    /// Server-ranked prop opportunities. Nil before ~12:30 PM ET.
    var topPropOpportunities: [TopPropOpportunity]?
    /// Cross-prop strategy summary from the server's Sonnet pass. Nil before ~12:30 PM ET.
    var propSlateSynthesis: PropSlateSynthesis?
    var dailyAnalysis: DailyAnalysis?
    /// True while a background network refresh is in flight after serving a disk-cache hit.
    var isBackgroundRefreshing: Bool = false

    // MARK: - Props feed state

    /// Active filter for the props feed. Loaded from UserDefaults on first use.
    var propFeedFilter: PropFeedFilter = PropFeedFilterPersistence.load()
    /// Top 3 props from the filtered+sorted set. Updated by recomputeFilteredProps only.
    private(set) var bestBetProps: [TopPropOpportunity] = []
    /// Full filtered+sorted prop list (all tiers). Updated by recomputeFilteredProps only.
    private(set) var filteredTopProps: [TopPropOpportunity] = []
    /// Count of top-10 unfiltered props hidden by the active filter. Drives filter badge.
    private(set) var hiddenHighValueCount: Int = 0

    private static let stalenessThreshold = CacheFreshness.defaultThreshold

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "BoardState"
    )
    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "BoardState"
    )

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func makeReduce(
        boardService: BoardServiceProtocol,
        analysisService: DailyAnalysisServiceProtocol,
        positionMap: SportPositionMap
    ) -> Reduce<Self, BoardIntent> {{
        {{ state, intent in
            switch intent {{
            case .onAppear:
                // Force refetch if the EASTERN-TIME date has changed since last load —
                // the server's day rolls at midnight ET, so the device-local calendar
                // must not be consulted here (a PT user at 9:30 PM is already on the
                // next server day; at 5 AM they are still on the previous local day).
                let isNewDay = state.lastUpdated.map {{ !ETDate.isSameETDay($0, .now) }} ?? false
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
                // Exception: on the cold-load path (lastUpdated == nil), .loading may reflect
                // a prior cancelled attempt whose task no longer exists. In that case proceed
                // with a new fetch rather than leaving the board permanently stuck in .loading.
                if case .loading = state.loadState, state.lastUpdated != nil {{
                    logger.debug("onAppear — fetch already in flight, skipping (lastUpdated: \\(lastUpdatedDesc, privacy: .public))")
                    return nil
                }}
                logger.debug("onAppear — triggering fetch (isNewDay: \\(isNewDay, privacy: .public) lastUpdated: \\(lastUpdatedDesc, privacy: .public))")
                // If hydrateFromDisk already painted the board (.loaded but no lastUpdated),
                // skip the loading-skeleton reset and go straight to a background refresh
                // so the cached content stays visible during the network round-trip.
                if case .loaded = state.loadState, state.lastUpdated == nil {{
                    logger.debug("onAppear — disk already hydrated, background refresh starting")
                    state.isBackgroundRefreshing = true
                    return await fetchAll(
                        boardService: boardService,
                        analysisService: analysisService
                    )
                }}
                state.loadState = .loading
                // Await disk first. If a cache hit is found, .diskCacheLoaded commits
                // disk state immediately (SwiftUI renders it), then chains
                // .backgroundRefreshRequested which fires the network fetch.
                let diskResult = await Perf.measure("BoardDiskHydration") {{
                    await loadFromDisk(
                        boardService: boardService,
                        analysisService: analysisService
                    )
                }}
                if let diskResult {{
                    logger.debug("onAppear — disk cache hit, instant render (\\(diskResult.entries.count, privacy: .public) entries), background refresh starting")
                    return .diskCacheLoaded(diskResult)
                }}
                return await fetchAll(
                    boardService: boardService,
                    analysisService: analysisService
                )

            case .refreshRequested:
                state.isBackgroundRefreshing = false
                state.allEntries = []
                state.todayGames = []
                state.dailyAnalysis = nil
                state.topPropOpportunities = nil
                state.propSlateSynthesis = nil
                state.loadState = .loading
                return await fetchAll(
                    boardService: boardService,
                    analysisService: analysisService
                )

            case .backgroundRefreshRequested:
                // .backgroundRefreshRequested is cancellable (cancelsInFlightWork = true),
                // so the Store cancels any prior in-flight task before running this one.
                // The .loading guard below is a secondary safety net for the rare window
                // where a fetch started so recently that loadState is already .loading
                // but the prior task hasn't been registered in currentTask yet.
                if case .loading = state.loadState {{ return nil }}
                // Keep loadState as-is so the live board is not replaced by a skeleton.
                // isBackgroundRefreshing signals the banner overlay instead.
                state.isBackgroundRefreshing = true
                return await fetchAll(
                    boardService: boardService,
                    analysisService: analysisService
                )

            case let .entriesLoaded(result):
                state.isBackgroundRefreshing = false
                state.allEntries = result.entries
                state.loadState = .loaded(result.entries)
                state.lastUpdated = .now
                state.todayGames = result.games.sorted {{ $0.gameDatetime < $1.gameDatetime }}
                state.gameCount = result.games.count
                state.lockTime = result.lockTime
                state.seasonMode = result.seasonMode
                state.gameOdds = result.gameOdds
                state.serverDateString = result.serverDateString
                if let syncedAt = result.scheduleSyncedAt {{ state.scheduleSyncedAt = syncedAt }}
                if let analysis = result.dailyAnalysis {{ state.dailyAnalysis = analysis }}
                if let props = result.topPropOpportunities {{ state.topPropOpportunities = props }}
                state.propSlateSynthesis = result.propSlateSynthesis
                // ORDERING: must be called after topPropOpportunities is assigned above.
                // Do NOT call recomputeFilteredProps from .diskCacheLoaded — that result
                // always carries topPropOpportunities == nil and produces a silent empty feed.
                recomputeFilteredProps(&state)
                return nil

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
                guard state.isBackgroundRefreshing else {{ return nil }}
                state.isBackgroundRefreshing = false
                return nil

            case let .navigationPathChanged(path):
                state.navigationPath = path
                return nil

            case let .propFeedFilterChanged(newFilter):
                state.propFeedFilter = newFilter
                PropFeedFilterPersistence.save(newFilter)
                recomputeFilteredProps(&state)
                return nil

            case .pushNotificationTapped:
                return nil

            case .deepLinkHandled:
                return nil

            case .hydrateFromDisk:
                // Fires as soon as BoardView mounts, before entitlement is known.
                // Paints cached games/analysis so the board isn't blank during the
                // StoreKit refresh. Returns nil — must NOT chain .backgroundRefreshRequested
                // because entitlement is not yet confirmed (fetchBoard would 402).
                // The network fetch is triggered separately by .onAppear once
                // entitlementReady flips true.
                guard state.lastUpdated == nil else {{
                    // Real data already loaded (e.g. foreground restore); skip.
                    return nil
                }}
                guard let diskResult = await loadFromDisk(
                    boardService: boardService,
                    analysisService: analysisService
                ) else {{ return nil }}
                // Apply disk state directly — do not go through .diskCacheLoaded,
                // which would chain .backgroundRefreshRequested before entitlement is ready.
                state.allEntries = diskResult.entries
                state.loadState = .loaded(diskResult.entries)
                state.todayGames = diskResult.games.sorted {{ $0.gameDatetime < $1.gameDatetime }}
                state.gameCount = diskResult.games.count
                state.lockTime = diskResult.lockTime
                state.seasonMode = diskResult.seasonMode
                state.gameOdds = diskResult.gameOdds
                state.serverDateString = diskResult.serverDateString
                if let analysis = diskResult.dailyAnalysis {{ state.dailyAnalysis = analysis }}
                return nil

            case let .diskCacheLoaded(result):
                state.allEntries = result.entries
                state.loadState = .loaded(result.entries)
                state.todayGames = result.games.sorted {{ $0.gameDatetime < $1.gameDatetime }}
                state.gameCount = result.games.count
                state.lockTime = result.lockTime
                state.seasonMode = result.seasonMode
                state.gameOdds = result.gameOdds
                state.serverDateString = result.serverDateString
                if let analysis = result.dailyAnalysis {{ state.dailyAnalysis = analysis }}
                state.isBackgroundRefreshing = true
                // Return .backgroundRefreshRequested rather than awaiting fetchAll inline.
                // This lets the Store commit the disk-cache state immediately (giving
                // SwiftUI a frame to render it), then process the network fetch as a
                // separate reduce iteration. Previously, awaiting fetchAll here meant the
                // snapshot wasn't committed until the network returned — the intermediate
                // disk-cache render never occurred.
                return .backgroundRefreshRequested
            }}
        }}
    }}

    // MARK: - Disk cache

    /// Reads the schedule disk cache and builds a BoardLoadResult for instant render
    /// of games and any cached analysis while the network fetch completes.
    /// Returns nil if no cached schedule exists.
    nonisolated private static func loadFromDisk(
        boardService: BoardServiceProtocol,
        analysisService: DailyAnalysisServiceProtocol
    ) async -> BoardLoadResult? {{
        let diskInterval = signposter.beginInterval("loadFromDisk")
        defer {{ signposter.endInterval("loadFromDisk", diskInterval) }}
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

        // Reject schedules from a previous ET server day — painting yesterday's
        // slate (even briefly, ahead of the entitlement-gated network fetch) is
        // the "stale board until manual refresh" bug. A cache miss here leaves
        // loadState untouched so the skeleton shows until fresh data arrives.
        guard ETDate.isCurrentETDay(serverDateString: schedule.date) else {{
            logger.info("loadFromDisk — cached schedule \\(schedule.date, privacy: .public) is a previous ET day, skipping")
            return nil
        }}

        let cachedAnalysis = try? analysisService.loadCachedDailyAnalysis()
        let games = schedule.games
        let lockTime = games.map(\\.gameDatetime).min()
        return BoardLoadResult(
            entries: [],
            projections: [],
            games: games,
            lockTime: lockTime,
            seasonMode: .regularSeason,
            gameOdds: buildGameOdds(from: games),
            serverDateString: schedule.date,
            dailyAnalysis: cachedAnalysis,
            playoffSeries: [],
            totalOpportunities: 0,
            scheduleSyncedAt: nil,
            topPropOpportunities: nil,
            propSlateSynthesis: nil
        )
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
        let fetchAllStart = Date()
        logger.debug("fetchAll: started")
        let fetchAllInterval = signposter.beginInterval("fetchAll")
        defer {{ signposter.endInterval("fetchAll", fetchAllInterval) }}
        #if DEBUG
        let fetchAllID = Perf.begin("BoardFetchAll")
        defer {{ Perf.end("BoardFetchAll", id: fetchAllID, startedAt: fetchAllStart) }}
        #endif

        let page: BoardPageResult
        do {{
            page = try await boardService.fetchBoard()
            logger.debug("fetchAll: fetchBoard returned (\\(Date().timeIntervalSince(fetchAllStart), privacy: .public)s)")
        }} catch {{
            logger.warning("fetchAll: fetchBoard failed after \\(Date().timeIntervalSince(fetchAllStart), privacy: .public)s — \\(error.localizedDescription, privacy: .public)")
            if case NetworkError.httpError(statusCode: 402, _) = error {{
                return .loadFailed(error)
            }}
            let msg = "Board: get_board fetch failed: \\(error.diagnosticDescription)"
            DiagnosticLogger.error(msg, category: "BoardState")
            return .loadFailed(error)
        }}

        let lockTime = page.games.map(\\.gameDatetime).min()
        let serverDateString = page.date.isEmpty ? nil : page.date

        // Run build + sort on the cooperative thread pool (nonisolated context) —
        // keeps MainActor free during the CPU-bound join and sort.
        let built = BoardEntryBuilder.build(
            players: [],
            projections: page.projections,
            opportunities: [],
            todayDateString: serverDateString
        )

        return .entriesLoaded(BoardLoadResult(
            entries: built,
            projections: page.projections,
            games: page.games,
            lockTime: lockTime,
            seasonMode: page.seasonMode,
            gameOdds: buildGameOdds(from: page.games),
            serverDateString: serverDateString,
            dailyAnalysis: page.dailyAnalysis,
            playoffSeries: [],
            totalOpportunities: 0,
            scheduleSyncedAt: page.scheduleSyncedAt,
            topPropOpportunities: page.topPropOpportunities,
            propSlateSynthesis: page.propSlateSynthesis
        ))
    }}

    // MARK: - Props feed compute

    /// Recomputes bestBetProps, filteredTopProps, and hiddenHighValueCount from
    /// topPropOpportunities and propFeedFilter.
    ///
    /// Call AFTER state.topPropOpportunities is assigned in .entriesLoaded.
    /// Do NOT call from .diskCacheLoaded — that result always carries nil topPropOpportunities.
    private static func recomputeFilteredProps(_ state: inout Self) {{
        guard let all = state.topPropOpportunities, !all.isEmpty else {{
            state.filteredTopProps = []
            state.bestBetProps = []
            state.hiddenHighValueCount = 0
            return
        }}

        let filter = state.propFeedFilter

        let filtered = all
            .filter {{ prop in
                let matchesStat = filter.selectedStatCategories.isEmpty
                    || filter.selectedStatCategories.contains(prop.statCategory ?? .hits)
                let meetsTier = prop.tier >= filter.minimumTier
                let meetsInstinct = !filter.instinctAgreesOnly
                    || prop.instinctAgrees == true
                return matchesStat && meetsTier && meetsInstinct
            }}
            .sorted {{ $0.edgePP > $1.edgePP }}

        state.filteredTopProps = filtered
        state.bestBetProps = Array(filtered.prefix(3))

        if filter.isActive {{
            let top10IDs = Set(
                all.sorted {{ $0.edgePP > $1.edgePP }}
                    .prefix(10)
                    .map {{ $0.id }}
            )
            let filteredIDs = Set(filtered.map {{ $0.id }})
            state.hiddenHighValueCount = top10IDs.subtracting(filteredIDs).count
        }} else {{
            state.hiddenHighValueCount = 0
        }}
    }}
}}
"""

# ── BoardView.swift ──────────────────────────────────────────────────────────────────

board_view_swift = header() + f"""import BKSCore
import BKSUICore
import OSLog
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
    let onForceRefresh: () -> Void
    let entitlementReady: Bool

    @State private var showProfile = false
    @State private var showInbox = false
    @State private var showPaywall = false
    @State private var selectedGame: ScheduledGame?
    @State private var bannerDismissTask: Task<Void, Never>?
    private let notificationLogger = PushNotificationLogger.shared
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "{bundle_id}",
        category: "BoardView"
    )

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

    private func resolvedGameInsight(for game: ScheduledGame) -> GameInsight? {{
        let key = String(game.id)
        let availableKeys = store.state.dailyAnalysis?.gameInsights?.keys.sorted() ?? []
        let result = store.state.dailyAnalysis?.gameInsights?[key]
        logger.debug("resolvedGameInsight: game.id=\\(key, privacy: .public) hit=\\(result != nil, privacy: .public) availableKeys=[\\(availableKeys.joined(separator: ", "), privacy: .public)]")
        return result
    }}

    private var titleText: String {{
        let weekday = weekdayName(from: store.state.serverDateString)
        return String(localized: "board.title", defaultValue: "\\(weekday)'s Blackboard")
    }}

    private var subtitleText: String {{
        let count = store.state.gameCount
        let dateStr = formattedDate(from: store.state.serverDateString)
        let gamesStr = String(localized: "board.subtitle.games", defaultValue: "\\(count) games")
        return "\\(dateStr) · \\(gamesStr)"
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
                        seasonMode: store.state.seasonMode,
                        onEraseCachedData: {{ // swiftlint:disable:this trailing_closure
                            showProfile = false
                            onEraseCachedData()
                        }}
                    )
                }}
                .navigationDestination(for: DailyAnalysis.self) {{ analysis in
                    SlateAnalysisView(
                        analysis: analysis,
                        games: store.state.todayGames,
                        onSelectGame: {{ selectedGame = $0 }} // swiftlint:disable:this trailing_closure
                    )
                }}
                .navigationDestination(for: BoardViewMode.self) {{ mode in
                    BoardScrollContent(
                        loadState: store.state.loadState,
                        isSubscriptionRequired: isSubscriptionRequired,
                        viewMode: mode,
                        bestBetProps: store.state.bestBetProps,
                        filteredTopProps: store.state.filteredTopProps,
                        propFeedFilter: store.state.propFeedFilter,
                        propSlateSynthesis: store.state.propSlateSynthesis,
                        onRetry: {{ store.send(.refreshRequested) }},
                        onShowPaywall: {{ showPaywall = true }},
                        onFilterChanged: {{ store.send(.propFeedFilterChanged($0)) }}
                    )
                    .appBackground()
                    .appNavigationBar(title: mode.navigationTitle)
                }}
        }}
        .task {{
            // Fires unconditionally on mount — paints cached board before entitlement resolves.
            logger.debug("BoardViewTask: sending .hydrateFromDisk")
            store.send(.hydrateFromDisk)
        }}
        .task(id: entitlementReady) {{
            logger.debug("BoardViewTask: fired entitlementReady=\\(entitlementReady, privacy: .public) loadState=\\(String(describing: store.state.loadState), privacy: .public)")
            guard entitlementReady else {{
                logger.debug("BoardViewTask: exiting — entitlementReady is false")
                return
            }}
            // Guard against a rapid true→false→true entitlementReady flip re-triggering
            // .onAppear when a fetch is already in flight. Only skip if loadState is
            // .loading AND lastUpdated is non-nil — that combination means a real fetch
            // was started. lastUpdated == nil means this is the initial cold-start state
            // (BoardState.initial sets loadState = .loading), so we must proceed.
            if case .loading = store.state.loadState, store.state.lastUpdated != nil {{
                logger.debug("BoardViewTask: exiting — fetch already in flight (lastUpdated non-nil)")
                return
            }}
            logger.debug("BoardViewTask: sending .onAppear")
            Perf.event("BoardViewTask")
            store.send(.onAppear)
        }}
        .onChange(of: store.state.isBackgroundRefreshing) {{ _, isRefreshing in
            bannerDismissTask?.cancel()
            guard isRefreshing else {{ return }}
            bannerDismissTask = Task {{
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else {{ return }}
                store.send(.refreshBannerExpired)
            }}
        }}
        .onDisappear {{
            bannerDismissTask?.cancel()
            bannerDismissTask = nil
        }}
        .sheet(item: $selectedGame) {{ game in
            let oddsKey = "\\(game.visitorTeamAbbr)@\\(game.homeTeamAbbr):\\(game.gameSequence)"
            GameDetailSheet(
                game: game,
                odds: store.state.gameOdds[oddsKey],
                spreadLabel: String(localized: "gameDetail.runLine", defaultValue: "Run Line"),
                spreadPickLabel: String(localized: "gameDetail.bkRunLinePick", defaultValue: "Run Line Pick"),
                gameInsight: resolvedGameInsight(for: game)
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
        ScrollView {{
            VStack(spacing: 0) {{
                BoardNavBar(
                    title: titleText,
                    subtitle: subtitleText,
                    isLoaded: {{
                        if case .loaded = store.state.loadState {{ return true }}
                        return false
                    }}(),
                    isRefreshing: isLoading || store.state.isBackgroundRefreshing,
                    unreadCount: notificationLogger.unreadCount,
                    onInbox: {{ showInbox = true }},
                    onProfile: {{ showProfile = true }},
                    onRefresh: {{
                        onForceRefresh()
                        store.send(.refreshRequested)
                    }}
                )
                .skeletonPulse(delay: 0, active: isLoading)

                GamesStripSkeleton(games: store.state.todayGames, isLoading: isLoading) {{ game in
                    game.isDoubleheader ? "DH · Game \\(game.gameSequence)" : nil
                }} onSelect: {{ selectedGame = $0 }}

                SlateAnalysisCard(analysis: store.state.dailyAnalysis)
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
                    .padding(.bottom, 10)
                    .accessibilityAddTraits(.isHeader)
                    .skeletonPulse(delay: 0.3, active: isLoading)

                PlayerModeLauncherView(
                    loadState: store.state.loadState,
                    topPropOpportunities: store.state.topPropOpportunities
                )
                .skeletonPulse(delay: 0.35, active: isLoading)
            }}
        }}
        .overlay(alignment: .top) {{
            if store.state.isBackgroundRefreshing && store.state.lastUpdated != nil {{
                Text(String(localized: "board.refreshing", defaultValue: "Refreshing…"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 80)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }}
        }}
        .animation(.easeInOut(duration: 0.3), value: store.state.isBackgroundRefreshing)
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

    private static let longDateFormatter: DateFormatter = {{
        let fmt = DateFormatter()
        fmt.dateStyle = .long
        fmt.timeStyle = .none
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

    private func formattedDate(from serverDateString: String?) -> String {{
        let date: Date
        if let dateString = serverDateString,
           let parsed = Self.dateParseFormatter.date(from: dateString) {{
            date = parsed
        }} else {{
            date = Date.now
        }}
        return Self.longDateFormatter.string(from: date)
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
    var profileStore: Store<ProfileState, ProfileIntent>
    let promoCodeService: PromoCodeServiceProtocol
    let seasonMode: SeasonMode
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
            NotificationsDetailView(profileStore: profileStore, seasonMode: seasonMode)
        }}
    }}
}}
"""

# Build one Toggle block per notificationPreferences entry in the YAML.
def make_toggle(key, raw_value, label, system_image):
    loc_key = f"profile.row.notifications.{key}"
    a11y_id = f"profile.notification.{raw_value}"
    return f"""
            Toggle(isOn: Binding(
                get: {{ profileStore.state.preferences.notificationPreferences.isEnabled(.{key}) }},
                set: {{ profileStore.send(.notificationPreferenceToggled(.{key}, $0)) }}
            )) {{
                Label(
                    String(localized: "{loc_key}",
                           defaultValue: "{label}"),
                    systemImage: "{system_image}"
                )
                .foregroundStyle(.white)
            }}
            .tint(.accentColor)
            .accessibilityIdentifier("{a11y_id}")"""

dynamic_toggles = "".join(
    make_toggle(
        p["key"],
        p["rawValue"],
        p.get("label", p["key"]),
        p.get("systemImage", "bell.fill"),
    )
    for p in notif_prefs
)

playoff_toggle_block = """
            if seasonMode == .playoffs {
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
                .accessibilityIdentifier("profile.notification.playoff_alerts")
            }""" if has_playoffs else ""

notif_detail_body = dynamic_toggles + playoff_toggle_block

notifications_detail_swift = header() + f"""import BKSCore
import BKSUICore
import SwiftUI

// MARK: - NotificationsDetailView
//
// Sport-specific notification preferences injected into BKSNotificationsView.

struct NotificationsDetailView: View {{
    var profileStore: Store<ProfileState, ProfileIntent>
    let seasonMode: SeasonMode

    var body: some View {{
        BKSNotificationsView(
            profileStore: profileStore,
            appName: String(localized: "app.name", defaultValue: "{app_name}")
        ) {{
            Toggle(isOn: Binding(
                get: {{ profileStore.state.preferences.notificationPreferences.isEnabled(.gameUpdates) }},
                set: {{ profileStore.send(.notificationPreferenceToggled(.gameUpdates, $0)) }}
            )) {{
                Label(
                    String(localized: "profile.row.notifications.gameUpdates",
                           defaultValue: "Game Updates"),
                    systemImage: "sportscourt.fill"
                )
                .foregroundStyle(.white)
            }}
            .tint(.accentColor)
            .accessibilityIdentifier("profile.notification.game_updates")

            Toggle(isOn: Binding(
                get: {{ profileStore.state.preferences.notificationPreferences.isEnabled(.pregameAlerts) }},
                set: {{ profileStore.send(.notificationPreferenceToggled(.pregameAlerts, $0)) }}
            )) {{
                Label(
                    String(localized: "profile.row.notifications.pregameAlerts",
                           defaultValue: "Pre-Game Alerts"),
                    systemImage: "clock.fill"
                )
                .foregroundStyle(.white)
            }}
            .tint(.accentColor)
            .accessibilityIdentifier("profile.notification.pregame_alerts")

            Toggle(isOn: Binding(
                get: {{ profileStore.state.preferences.notificationPreferences.isEnabled(.predictionsReady) }},
                set: {{ profileStore.send(.notificationPreferenceToggled(.predictionsReady, $0)) }}
            )) {{
                Label(
                    String(localized: "profile.row.notifications.predictionsReady",
                           defaultValue: "Predictions Ready"),
                    systemImage: "chart.bar.fill"
                )
                .foregroundStyle(.white)
            }}
            .tint(.accentColor)
            .accessibilityIdentifier("profile.notification.predictions_ready")

            if seasonMode == .playoffs {{
                Toggle(isOn: Binding(
                    get: {{ profileStore.state.preferences.notificationPreferences.isEnabled(.playoffAlerts) }},
                    set: {{ profileStore.send(.notificationPreferenceToggled(.playoffAlerts, $0)) }}
                )) {{
                    Label(
                        String(localized: "profile.row.notifications.playoff",
                               defaultValue: "Playoff Alerts"),
                        systemImage: "trophy.fill"
                    )
                    .foregroundStyle(.white)
                }}
                .tint(.accentColor)
                .accessibilityIdentifier("profile.notification.playoff_alerts")
            }}
        }}
    }}
}}
"""

# ── BoardNavBar.swift ────────────────────────────────────────────────────────────────────────

board_nav_bar_swift = header() + f"""import BKSUICore
import SwiftUI

// MARK: - BoardNavBar

struct BoardNavBar: View {{
    let title: String
    let subtitle: String
    let isLoaded: Bool
    let isRefreshing: Bool
    let unreadCount: Int
    let onInbox: () -> Void
    let onProfile: () -> Void
    let onRefresh: () -> Void

    var body: some View {{
        AppCustomNavBar(
            title: title,
            subtitle: subtitle,
            slotWidth: 80,
            leading: {{
                RefreshIconButton(isRefreshing: isRefreshing, onRefresh: onRefresh)
                    .opacity(isLoaded || isRefreshing ? 1 : 0)
            }},
            trailing: {{
                HStack(spacing: 4) {{
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
                        .frame(width: 28, height: 44)
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
                            .frame(width: 28, height: 44)
                    }}
                    .accessibilityLabel(String(localized: "a11y.label.profile", defaultValue: "Profile"))
                }}
            }}
        )
    }}
}}

// MARK: - RefreshIconButton

/// Owns its own @State so the pulse animation lives in the same view that
/// drives opacity — avoiding the lost-animation-at-init-boundary problem
/// with AppCustomNavBar's eager leading() evaluation.
private struct RefreshIconButton: View {{
    let isRefreshing: Bool
    let onRefresh: () -> Void

    @State private var pulsing = false

    var body: some View {{
        GeometryReader {{ geo in
            let side = geo.size.height
            Button(action: onRefresh) {{
                Image("InAppIcon")
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .opacity(pulsing ? 0.35 : 1.0)
            }}
            .buttonStyle(.plain)
        }}
        .padding(.vertical, -10)
        .accessibilityLabel(String(localized: "a11y.label.refresh", defaultValue: "Refresh"))
        .onAppear {{ if isRefreshing {{ startPulse() }} }}
        .onChange(of: isRefreshing) {{ _, refreshing in
            if refreshing {{ startPulse() }} else {{ stopPulse() }}
        }}
    }}

    private func startPulse() {{
        guard !pulsing else {{ return }}
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {{
            pulsing = true
        }}
    }}

    private func stopPulse() {{
        withAnimation(.easeInOut(duration: 0.3)) {{
            pulsing = false
        }}
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
    let isSubscriptionRequired: Bool
    let viewMode: BoardViewMode
    // Props feed computed state (from BoardState.recomputeFilteredProps)
    let bestBetProps: [TopPropOpportunity]
    let filteredTopProps: [TopPropOpportunity]
    let propFeedFilter: PropFeedFilter
    let propSlateSynthesis: PropSlateSynthesis?
    let onRetry: () -> Void
    let onShowPaywall: () -> Void
    let onFilterChanged: (PropFeedFilter) -> Void
    var body: some View {{
        ScrollView {{
            switch loadState {{
            case .idle, .loading:
                BoardSkeletonView()
                    .padding(.bottom, 16)

            case .failed where isSubscriptionRequired:
                VStack(spacing: 16) {{
                    Image(systemName: "lock.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(AppOpacity.muted))
                        .accessibilityHidden(true)
                    Text(String(
                        localized: "board.subscriptionRequired.title",
                        defaultValue: "Subscription Required"
                    ))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    Text(String(
                        localized: "board.subscriptionRequired.body",
                        defaultValue: "Your trial has ended. Subscribe to keep getting daily picks."
                    ))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(AppOpacity.muted))
                        .multilineTextAlignment(.center)
                    Button(String(localized: "board.subscriptionRequired.cta", defaultValue: "View Plans")) {{
                        onShowPaywall()
                    }}
                    .buttonStyle(.borderedProminent)
                }}
                .padding(.top, 40)
                .padding(.horizontal, 24)

            case .failed:
                VStack(spacing: 12) {{
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(AppOpacity.muted))
                        .accessibilityHidden(true)
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
                switch viewMode {{
                case .props:
                    PropsFeedView(
                        bestBetProps: bestBetProps,
                        filteredTopProps: filteredTopProps,
                        propFeedFilter: propFeedFilter,
                        propSlateSynthesis: propSlateSynthesis,
                        activeFilterCount: propFeedFilter.activeFilterCount,
                        onFilterChanged: onFilterChanged
                    )

                case .draftKings, .fanDuel:
                    comingSoonPlaceholder
                }}
            }}
        }}
        .contentMargins(.bottom, AppPadding.tabBarClearance, for: .scrollContent)
    }}

    private var comingSoonPlaceholder: some View {{
        VStack(spacing: 12) {{
            Image(systemName: "clock")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(AppOpacity.muted))
                .accessibilityHidden(true)
            Text(String(localized: "board.comingSoon.title", defaultValue: "Coming Soon"))
                .font(.headline)
                .foregroundStyle(.white)
            Text(String(localized: "board.comingSoon.body", defaultValue: "Fantasy lineup support is on the way."))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(AppOpacity.muted))
                .multilineTextAlignment(.center)
        }}
        .padding(.top, 60)
        .padding(.horizontal, 24)
    }}
}}

// MARK: - GamesStripSkeleton

/// Shows placeholder chips while loading, then the real GamesStrip once data is available.
struct GamesStripSkeleton: View {{
    let games: [ScheduledGame]
    let isLoading: Bool
    let chipLabel: (ScheduledGame) -> String?
    let onSelect: (ScheduledGame) -> Void

    var body: some View {{
        Group {{
            if games.isEmpty && isLoading {{
                HStack(spacing: 8) {{
                    ForEach(0..<4, id: \\.self) {{ index in
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 88, height: 44)
                            .skeletonPulse(delay: Double(index) * 0.08, active: true)
                    }}
                }}
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }} else if !games.isEmpty {{
                GamesStrip(games: games, chipLabel: chipLabel, onSelect: onSelect)
                    .padding(.top, 8)
                    .skeletonPulse(delay: 0.1, active: isLoading)
            }}
        }}
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

# ─────────────────────────────────────────────────────────────────────────────
# Props feed views  (Features/Board/Views/Props/)
#
# All five files are write_if_absent — they require sport-specific styling.
# PropPlayerRow and TierDividerRow are fully generic; EdgePropCard, AllPropRow,
# and PropsFeedView contain a stat/odds row that callers style per-sport.
# ─────────────────────────────────────────────────────────────────────────────

prop_player_row_swift = header() + """\
import SwiftUI

// MARK: - PropPlayerRow

/// Player identity row: optional leading slot + name/team/pos + optional trailing slot.
/// Does NOT own the tier strip — callers render the strip alongside their full card content
/// so it spans the entire card height, not just this row.
struct PropPlayerRow<Leading: View, Trailing: View>: View {
    let prop: TopPropOpportunity
    var nameFontSize: CGFloat = 15
    var nameWeight: Font.Weight = .semibold
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    private var teamPosLabel: String? {
        guard let team = prop.team else { return nil }
        return prop.position.map { "\\(team)/\\($0)" } ?? team
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            leading()
            Text(prop.playerName)
                .font(.system(size: nameFontSize, weight: nameWeight))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let label = teamPosLabel {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 8)
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// No leading, no trailing — default convenience
extension PropPlayerRow where Leading == EmptyView, Trailing == EmptyView {
    init(
        prop: TopPropOpportunity,
        nameFontSize: CGFloat = 15,
        nameWeight: Font.Weight = .semibold
    ) {
        self.prop = prop
        self.nameFontSize = nameFontSize
        self.nameWeight = nameWeight
        self.leading = { EmptyView() }
        self.trailing = { EmptyView() }
    }
}
"""

tier_divider_row_swift = header() + """\
import SwiftUI

// MARK: - TierDividerRow

/// Colored label row separating tier groups in the ALL PROPS section.
/// Rendered once per non-empty tier (descending). Subdued tier uses SubduedDisclosureRow instead.
struct TierDividerRow: View {
    let tier: PropEdgeTier

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tier.stripColor)
                .frame(width: 9, height: 9)

            Text(tier.label)
                .font(.system(size: 11, weight: .medium))
                .kerning(1.2)
                .foregroundStyle(tier.stripColor)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(tier.label)
    }
}

// MARK: - SubduedDisclosureRow

/// Collapsed disclosure row for subdued props. Gray to stay in the tier system.
/// Collapsed by default — subdued plays are below the model's confidence threshold.
struct SubduedDisclosureRow: View {
    let count: Int
    let props: [TopPropOpportunity]
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(PropEdgeTier.subdued.stripColor)
                        .frame(width: 9, height: 9)

                    Text(String(
                        localized: "props.subdued.count",
                        defaultValue: "\\(count) subdued props"
                    ))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))

                    Spacer()

                    Text(isExpanded
                         ? String(localized: "props.subdued.hide", defaultValue: "Hide")
                         : String(localized: "props.subdued.show", defaultValue: "Show"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.04))
                )
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "props.subdued.a11y.label",
                                       defaultValue: "\\(count) subdued props"))
            .accessibilityValue(isExpanded
                ? String(localized: "props.subdued.a11y.expanded", defaultValue: "expanded")
                : String(localized: "props.subdued.a11y.collapsed", defaultValue: "collapsed"))
            .accessibilityHint(String(localized: "props.subdued.a11y.hint",
                                      defaultValue: "Double tap to show or hide"))

            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(props) { prop in
                        AllPropRow(prop: prop)
                            .padding(.horizontal, 16)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
"""

edge_prop_card_swift = header() + f"""import BKSUICore
import SwiftUI

// MARK: - EdgePropCard

/// Card shown in the TODAY'S BEST BETS section.
/// All ranks show identical formatting: player identity row + stat/odds row.
struct EdgePropCard: View {{
    let prop: TopPropOpportunity
    let rank: Int

    @State private var isExpanded = false

    private var tierColor: Color {{ prop.tier.stripColor }}

    private func sortedBooks() -> [(name: String, odds: Int, line: Double)] {{
        guard let books = prop.bookmakers else {{ return [] }}
        return books
            .map {{ key, val in
                let odds = prop.direction == .over ? val.overOdds : val.underOdds
                return (name: key.capitalized, odds: odds, line: val.line)
            }}
            .sorted {{ $0.odds > $1.odds }}
    }}

    var body: some View {{
        cardContent
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {{
                RoundedRectangle(cornerRadius: 13)
                    .fill(Color.white.opacity(0.05))
            }}
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }}

    @ViewBuilder
    private var cardContent: some View {{
        HStack(spacing: 10) {{
            RoundedRectangle(cornerRadius: 2)
                .fill(tierColor)
                .frame(width: 5)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 2) {{
                PropPlayerRow(
                    prop: prop,
                    nameFontSize: 16,
                    nameWeight: .bold,
                    leading: {{
                        Text("#\\(rank)")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                    }},
                    trailing: {{ EmptyView() }}
                )
                statOddsRow.padding(.top, -6)
                aiPickChip
                conflictWarning
            }}
            .padding(.vertical, 12)
            .padding(.trailing, 12)
        }}
    }}

    private var statCategoryLabel: some View {{
        Text((prop.statCategory?.shortLabel ?? prop.statDisplayName).uppercased())
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
    }}

    private var statLine: some View {{
        let dirLabel = prop.direction == .over
            ? String(localized: "gameDetail.call.over", defaultValue: "OVER")
            : String(localized: "gameDetail.call.under", defaultValue: "UNDER")
        let lineStr = prop.line.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", prop.line)
            : String(format: "%.1f", prop.line)

        return Text("\\(dirLabel) \\(lineStr)")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.7))
    }}

    // MARK: - Stat / odds row

    @ViewBuilder
    private var statOddsRow: some View {{
        let books = sortedBooks()
        if books.count > 1 {{
            VStack(alignment: .leading, spacing: 4) {{
                Button {{
                    withAnimation(.easeInOut(duration: 0.2)) {{ isExpanded.toggle() }}
                }} label: {{
                    HStack(alignment: .firstTextBaseline, spacing: 0) {{
                        statCategoryLabel
                        Text(" ")
                        statLine
                        Spacer(minLength: 8)
                        if let best = books.first {{
                            let oddsStr = best.odds > 0 ? "+\\(best.odds)" : "\\(best.odds)"
                            Text("\\(oddsStr)  \\(best.name)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }}
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.leading, 6)
                    }}
                }}
                .buttonStyle(.plain)

                if isExpanded {{
                    VStack(alignment: .leading, spacing: 3) {{
                        ForEach(books, id: \\.name) {{ book in
                            HStack(spacing: 0) {{
                                let oddsStr = book.odds > 0 ? "+\\(book.odds)" : "\\(book.odds)"
                                Text(oddsStr)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .frame(width: 44, alignment: .leading)
                                Text(book.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.6))
                                if book.line != prop.line {{
                                    let lineStr = book.line.truncatingRemainder(dividingBy: 1) == 0
                                        ? String(format: " (%.0f)", book.line)
                                        : String(format: " (%.1f)", book.line)
                                    Text(lineStr)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.4))
                                }}
                            }}
                        }}
                    }}
                    .padding(.leading, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }}
            }}
        }} else {{
            HStack(alignment: .firstTextBaseline, spacing: 0) {{
                statCategoryLabel
                Text(" ")
                statLine
                Spacer(minLength: 8)
                if let best = books.first {{
                    let oddsStr = best.odds > 0 ? "+\\(best.odds)" : "\\(best.odds)"
                    Text("\\(oddsStr)  \\(best.name)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }}
            }}
        }}
    }}

    // MARK: - AI Pick chip

    @ViewBuilder
    private var aiPickChip: some View {{
        if prop.llmNominated {{
            HStack(spacing: 4) {{
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(.purple.opacity(0.9))
                Text(String(localized: "props.card.aiPick", defaultValue: "AI Pick"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.purple.opacity(0.9))
            }}
        }}
    }}

    // MARK: - Conflict warning (all ranks)

    @ViewBuilder
    private var conflictWarning: some View {{
        if prop.llmFade {{
            HStack(spacing: 4) {{
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text(String(localized: "props.card.conflict", defaultValue: "Model conflicts with recent form"))
                    .font(.system(size: 12))
                    .foregroundStyle(.orange.opacity(0.9))
            }}
            if let insight = prop.instinctInsight, insight.count > 10 {{
                Text(insight)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }}
        }}
    }}

    // MARK: - Accessibility

    private var accessibilityLabel: String {{
        let dir = prop.direction == .over
            ? String(localized: "props.card.a11y.over", defaultValue: "over")
            : String(localized: "props.card.a11y.under", defaultValue: "under")
        let pct = Int(prop.ourProbability * 100)
        let lineStr = prop.line.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", prop.line)
            : String(format: "%.1f", prop.line)
        let stat = prop.statCategory?.shortLabel ?? prop.statDisplayName
        let rankLabel = String(
            format: String(localized: "props.card.a11y.rank", defaultValue: "Rank %@"),
            String(rank)
        )
        let pctLabel = String(
            format: String(localized: "props.card.a11y.probability", defaultValue: "%@%% model probability"),
            String(pct)
        )
        let edgeLabel = String(
            format: String(localized: "props.card.a11y.edge", defaultValue: "+%.1f percentage point edge"),
            prop.edgePP
        )

        var parts: [String] = [
            rankLabel,
            "\\(prop.playerName), \\(stat), \\(dir) \\(lineStr)",
            pctLabel,
            edgeLabel,
        ]
        if let odds = prop.bestOdds {{
            let oddsStr = odds > 0 ? "+\\(odds)" : "\\(odds)"
            let oddsLabel = String(
                format: String(localized: "props.card.a11y.bestOdds", defaultValue: "best odds %@"),
                oddsStr
            )
            parts.append(oddsLabel)
        }}
        if prop.llmNominated {{
            parts.append(String(localized: "props.card.a11y.aiPick", defaultValue: "AI nominated pick"))
        }}
        if prop.llmFade {{
            parts.append(String(localized: "props.card.a11y.disagrees", defaultValue: "model disagrees"))
            if let insight = prop.instinctInsight, insight.count > 10 {{
                parts.append(insight)
            }}
        }}
        return parts.joined(separator: ". ")
    }}
}}
"""

all_prop_row_swift = header() + f"""import SwiftUI

// MARK: - AllPropRow

/// Compact prop row used in the ALL PROPS section beneath the hero cards.
/// Matches the visual style of Best Bets ranks 2 and 3.
struct AllPropRow: View {{
    let prop: TopPropOpportunity

    @State private var isExpanded = false

    private var tierColor: Color {{ prop.tier.stripColor }}

    private func sortedBooks() -> [(name: String, odds: Int, line: Double)] {{
        guard let books = prop.bookmakers else {{ return [] }}
        return books
            .map {{ key, val in
                let odds = prop.direction == .over ? val.overOdds : val.underOdds
                return (name: key.capitalized, odds: odds, line: val.line)
            }}
            .sorted {{ $0.odds > $1.odds }}
    }}

    var body: some View {{
        HStack(spacing: 10) {{
            RoundedRectangle(cornerRadius: 2)
                .fill(tierColor)
                .frame(width: 5)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 2) {{
                PropPlayerRow(
                    prop: prop,
                    nameFontSize: 16,
                    nameWeight: .bold,
                    leading: {{ EmptyView() }},
                    trailing: {{ EmptyView() }}
                )
                statRow.padding(.top, -6)
                aiPickChip
                conflictWarning
            }}
            .padding(.vertical, 12)
            .padding(.trailing, 12)
        }}
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {{
            RoundedRectangle(cornerRadius: 13)
                .fill(Color.white.opacity(0.05))
        }}
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }}

    @ViewBuilder
    private var statRow: some View {{
        let dirLabel = prop.direction == .over
            ? String(localized: "gameDetail.call.over", defaultValue: "OVER")
            : String(localized: "gameDetail.call.under", defaultValue: "UNDER")
        let lineStr = prop.line.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", prop.line)
            : String(format: "%.1f", prop.line)
        let books = sortedBooks()

        if books.count > 1 {{
            VStack(alignment: .leading, spacing: 4) {{
                Button {{
                    withAnimation(.easeInOut(duration: 0.2)) {{ isExpanded.toggle() }}
                }} label: {{
                    HStack(alignment: .firstTextBaseline, spacing: 0) {{
                        Text((prop.statCategory?.shortLabel ?? prop.statDisplayName).uppercased())
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                        Text(" ")
                        Text("\\(dirLabel) \\(lineStr)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer(minLength: 8)
                        if let best = books.first {{
                            let oddsStr = best.odds > 0 ? "+\\(best.odds)" : "\\(best.odds)"
                            Text("\\(oddsStr)  \\(best.name)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }}
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.leading, 6)
                    }}
                }}
                .buttonStyle(.plain)

                if isExpanded {{
                    VStack(alignment: .leading, spacing: 3) {{
                        ForEach(books, id: \\.name) {{ book in
                            HStack(spacing: 0) {{
                                let oddsStr = book.odds > 0 ? "+\\(book.odds)" : "\\(book.odds)"
                                Text(oddsStr)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .frame(width: 44, alignment: .leading)
                                Text(book.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.6))
                                if book.line != prop.line {{
                                    let lineStr = book.line.truncatingRemainder(dividingBy: 1) == 0
                                        ? String(format: " (%.0f)", book.line)
                                        : String(format: " (%.1f)", book.line)
                                    Text(lineStr)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.4))
                                }}
                            }}
                        }}
                    }}
                    .padding(.leading, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }}
            }}
        }} else {{
            HStack(alignment: .firstTextBaseline, spacing: 0) {{
                Text((prop.statCategory?.shortLabel ?? prop.statDisplayName).uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text(" ")
                Text("\\(dirLabel) \\(lineStr)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 8)
                if let best = books.first {{
                    let oddsStr = best.odds > 0 ? "+\\(best.odds)" : "\\(best.odds)"
                    Text("\\(oddsStr)  \\(best.name)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }}
            }}
        }}
    }}

    // MARK: - AI Pick chip

    @ViewBuilder
    private var aiPickChip: some View {{
        if prop.llmNominated {{
            HStack(spacing: 4) {{
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(.purple.opacity(0.9))
                Text(String(localized: "props.card.aiPick", defaultValue: "AI Pick"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.purple.opacity(0.9))
            }}
        }}
    }}

    // MARK: - Conflict warning

    @ViewBuilder
    private var conflictWarning: some View {{
        if prop.llmFade {{
            HStack(spacing: 4) {{
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text(String(localized: "props.card.conflict", defaultValue: "Model conflicts with recent form"))
                    .font(.system(size: 12))
                    .foregroundStyle(.orange.opacity(0.9))
            }}
            if let insight = prop.instinctInsight, insight.count > 10 {{
                Text(insight)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }}
        }}
    }}

    private var accessibilityLabel: String {{
        let dir = prop.direction == .over
            ? String(localized: "props.card.a11y.over", defaultValue: "over")
            : String(localized: "props.card.a11y.under", defaultValue: "under")
        let lineStr = prop.line.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", prop.line)
            : String(format: "%.1f", prop.line)
        let stat = prop.statCategory?.shortLabel ?? prop.statDisplayName
        var parts = [prop.tier.label, "\\(prop.playerName), \\(stat), \\(dir) \\(lineStr)"]
        if prop.llmNominated {{
            parts.append(String(localized: "props.card.a11y.aiPick", defaultValue: "AI nominated pick"))
        }}
        if prop.llmFade {{
            parts.append(String(localized: "props.card.a11y.disagrees", defaultValue: "model disagrees"))
            if let insight = prop.instinctInsight, insight.count > 10 {{
                parts.append(insight)
            }}
        }}
        return parts.joined(separator: ". ")
    }}
}}
"""

props_feed_view_swift = header() + f"""import BKSUICore
import SwiftUI

// MARK: - PropsFeedView

/// Root compositor for the Props feed screen.
/// Presents an edge-ranked feed in two sections:
///   • TODAY'S BEST BETS — top 3 as rich cards
///   • ALL PROPS — remainder grouped by tier with TierDividerRows; subdued collapsed
///
/// No FAB. Filter is a nav-bar trailing toolbar button per design spec.
/// No SlateBestChip — the #1 card is the best bet at position zero.
struct PropsFeedView: View {{
    let bestBetProps: [TopPropOpportunity]
    let filteredTopProps: [TopPropOpportunity]
    let propFeedFilter: PropFeedFilter
    let propSlateSynthesis: PropSlateSynthesis?
    let activeFilterCount: Int
    let onFilterChanged: (PropFeedFilter) -> Void

    @State private var showFilterSheet = false
    @State private var filterSnapshot: PropFeedFilter
    @State private var committed = false

    init(
        bestBetProps: [TopPropOpportunity],
        filteredTopProps: [TopPropOpportunity],
        propFeedFilter: PropFeedFilter,
        propSlateSynthesis: PropSlateSynthesis?,
        activeFilterCount: Int,
        onFilterChanged: @escaping (PropFeedFilter) -> Void
    ) {{
        self.bestBetProps = bestBetProps
        self.filteredTopProps = filteredTopProps
        self.propFeedFilter = propFeedFilter
        self.propSlateSynthesis = propSlateSynthesis
        self.activeFilterCount = activeFilterCount
        self.onFilterChanged = onFilterChanged
        self._filterSnapshot = State(initialValue: propFeedFilter)
    }}

    // MARK: - Derived lists

    private var allPropsRemainder: [TopPropOpportunity] {{
        guard filteredTopProps.count > 3 else {{ return [] }}
        return Array(filteredTopProps.dropFirst(3))
    }}

    /// All derived groupings computed in one pass over allPropsRemainder.
    private var groupedRemainder: GroupedRemainder {{
        GroupedRemainder(from: allPropsRemainder)
    }}

    private var availableStats: [PropStatCategory] {{
        var seen = Set<PropStatCategory>()
        var result: [PropStatCategory] = []
        for prop in filteredTopProps {{
            if let cat = prop.statCategory, seen.insert(cat).inserted {{ result.append(cat) }}
        }}
        return result
    }}

    // MARK: - Body

    var body: some View {{
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {{
            if let synthesis = propSlateSynthesis {{
                PropSlateSynthesisCard(synthesis: synthesis)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
            }}
            bestBetsSection
            if !allPropsRemainder.isEmpty {{ allPropsSection }}
        }}
        .toolbar {{
            ToolbarItem(placement: .navigationBarTrailing) {{
                HStack(spacing: 7) {{
                    if activeFilterCount > 0 {{
                        Text("\\(activeFilterCount)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color(red: 0.094, green: 0.373, blue: 0.647)))
                            .accessibilityHidden(true)
                    }}
                    Button {{
                        filterSnapshot = propFeedFilter
                        committed = false
                        showFilterSheet = true
                    }} label: {{
                        Image(systemName: "slider.horizontal.3")
                    }}
                    .accessibilityLabel(
                        activeFilterCount > 0
                            ? String(localized: "props.filter.fab.a11y.active",
                                     defaultValue: "\\(activeFilterCount) active filters")
                            : String(localized: "props.filter.fab.a11y.base",
                                     defaultValue: "Filter props")
                    )
                    .accessibilityHint(String(
                        localized: "props.filter.fab.a11y.hint",
                        defaultValue: "Opens filter options"
                    ))
                }}
            }}
        }}
        .sheet(isPresented: $showFilterSheet) {{
            PropsFeedFilterSheet(
                isPresented: $showFilterSheet,
                currentFilter: filterSnapshot,
                availableStats: availableStats,
                filteredCount: filteredTopProps.count,
                onFilterChanged: {{ onFilterChanged($0) }},
                onCommit: {{ filter in
                    committed = true
                    onFilterChanged(filter)
                }},
                onRollback: {{ original in
                    if !committed {{ onFilterChanged(original) }}
                }}
            )
        }}
    }}

    // MARK: - Best Bets Section

    private var bestBetsSection: some View {{
        VStack(alignment: .leading, spacing: 0) {{
            bestBetsHeader

            if bestBetProps.isEmpty {{
                emptyBestBets
            }} else {{
                VStack(spacing: 8) {{
                    ForEach(Array(bestBetProps.enumerated()), id: \\.element.id) {{ index, prop in
                        EdgePropCard(prop: prop, rank: index + 1)
                    }}
                }}
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }}
        }}
    }}

    private var bestBetsHeader: some View {{
        HStack(spacing: 6) {{
            Image(systemName: "star.fill")
                .font(.system(size: 11))
                .foregroundStyle(.yellow.opacity(0.8))
                .accessibilityHidden(true)

            Text(String(localized: "props.feed.bestBets.title", defaultValue: "TODAY'S BEST BETS"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .kerning(0.8)

            Spacer()

            let count = bestBetProps.count
            Text(count == 1
                 ? String(localized: "props.feed.propCount.singular", defaultValue: "1 prop")
                 : String(localized: "props.feed.propCount.plural", defaultValue: "\\(count) props"))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
        }}
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(String(localized: "props.bestBets.header.a11y",
                                   defaultValue: "Today's Best Bets, \\(bestBetProps.count) props"))
    }}

    private var emptyBestBets: some View {{
        VStack(spacing: 10) {{
            Image(systemName: "{slug}")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.3))
                .accessibilityHidden(true)
            Text(String(localized: "props.feed.empty", defaultValue: "No props match the active filter"))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
        }}
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }}

    // MARK: - All Props Section

    private var allPropsSection: some View {{
        let grouped = groupedRemainder
        return VStack(alignment: .leading, spacing: 0) {{
            allPropsHeader

            ForEach(grouped.tiers, id: \\.rawValue) {{ tier in
                let propsForTier = grouped.byTier[tier] ?? []
                if tier != .elite {{
                    TierDividerRow(tier: tier)
                        .padding(.horizontal, 16)
                }}
                VStack(spacing: 8) {{
                    ForEach(propsForTier) {{ prop in
                        AllPropRow(prop: prop)
                            .padding(.horizontal, 16)
                    }}
                }}
            }}

            if !grouped.subdued.isEmpty {{
                SubduedDisclosureRow(count: grouped.subdued.count, props: grouped.subdued)
                    .padding(.bottom, 8)
            }}
        }}
    }}

    private var allPropsHeader: some View {{
        HStack(spacing: 6) {{
            Image(systemName: "list.bullet")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityHidden(true)

            Text(String(localized: "props.feed.allProps.title", defaultValue: "ALL PROPS"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .kerning(0.8)

            Spacer()

            let count = allPropsRemainder.count
            Text(count == 1
                 ? String(localized: "props.feed.allProps.count.singular", defaultValue: "1 prop")
                 : String(localized: "props.feed.allProps.count.plural", defaultValue: "\\(count) props"))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
        }}
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(String(localized: "props.allProps.header.a11y",
                                   defaultValue: "All Props, \\(allPropsRemainder.count) props"))
    }}
}}

// MARK: - GroupedRemainder

/// Partitions the allPropsRemainder list in a single O(N) pass, avoiding
/// repeated filter calls in the ForEach body.
private struct GroupedRemainder {{
    let tiers: [PropEdgeTier]
    let byTier: [PropEdgeTier: [TopPropOpportunity]]
    let subdued: [TopPropOpportunity]

    init(from props: [TopPropOpportunity]) {{
        var tierOrder: [PropEdgeTier] = []
        var seenTiers = Set<PropEdgeTier>()
        var byTier: [PropEdgeTier: [TopPropOpportunity]] = [:]
        var subdued: [TopPropOpportunity] = []

        for prop in props {{
            if prop.tier == .subdued {{
                subdued.append(prop)
            }} else {{
                if seenTiers.insert(prop.tier).inserted {{
                    tierOrder.append(prop.tier)
                }}
                byTier[prop.tier, default: []].append(prop)
            }}
        }}

        self.tiers = tierOrder
        self.byTier = byTier
        self.subdued = subdued
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
write_if_absent(os.path.join(board_views_dir,   "BoardScrollContent.swift"),       board_scroll_content_swift)
# BoardDetailView, BoardDetailSubviews, BoardDetailHeaderCard are intentionally not scaffolded.
# The player detail UI has been consolidated into BKSUICore shared components.
# Add sport-specific detail views manually if needed.
write_if_absent(os.path.join(props_views_dir,   "PropPlayerRow.swift"),            prop_player_row_swift)
write_if_absent(os.path.join(props_views_dir,   "TierDividerRow.swift"),           tier_divider_row_swift)
write_if_absent(os.path.join(props_views_dir,   "EdgePropCard.swift"),             edge_prop_card_swift)
write_if_absent(os.path.join(props_views_dir,   "AllPropRow.swift"),               all_prop_row_swift)
write_if_absent(os.path.join(props_views_dir,   "PropsFeedView.swift"),            props_feed_view_swift)

# ── Props feed: synthesis card, filter sheet, player-mode launcher ────────────

prop_slate_synthesis_card_swift = f"""// Copyright 2026 Black Katt Technologies Inc.
// iOS {deploy_tgt}+

import SwiftUI

// MARK: - PropSlateSynthesisCard

/// Slate-level cross-prop strategy summary produced by the server's Sonnet pass.
/// Rendered above TODAY'S BEST BETS when prop_slate_synthesis is present in the board response.
struct PropSlateSynthesisCard: View {{
    let synthesis: PropSlateSynthesis

    var body: some View {{
        VStack(alignment: .leading, spacing: 8) {{
            header
            narrativeText
            if !synthesis.contradictions.isEmpty {{
                contradictionChips
            }}
        }}
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {{
            RoundedRectangle(cornerRadius: 13)
                .fill(Color.white.opacity(0.05))
                .overlay {{
                    RoundedRectangle(cornerRadius: 13)
                        .strokeBorder(Color.cyan.opacity(0.18), lineWidth: 1)
                }}
        }}
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }}

    // MARK: - Subviews

    private var header: some View {{
        HStack(spacing: 6) {{
            Image(systemName: "brain")
                .font(.system(size: 11))
                .foregroundStyle(.cyan.opacity(0.8))
                .accessibilityHidden(true)
            Text(String(localized: "props.slate.narrative.header", defaultValue: "SLATE ANALYSIS"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .kerning(0.8)
        }}
    }}

    private var narrativeText: some View {{
        Text(synthesis.dailyPropNarrative)
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
    }}

    private var contradictionChips: some View {{
        VStack(alignment: .leading, spacing: 4) {{
            ForEach(Array(synthesis.contradictions.enumerated()), id: \\.offset) {{ _, contradiction in
                HStack(alignment: .top, spacing: 4) {{
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow.opacity(0.8))
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                    Text(contradiction)
                        .font(.system(size: 12))
                        .foregroundStyle(.yellow.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }}
            }}
        }}
    }}

    // MARK: - Accessibility

    private var accessibilityLabel: String {{
        var parts: [String] = [
            String(localized: "props.slate.narrative.header.a11y", defaultValue: "Slate Analysis"),
            synthesis.dailyPropNarrative,
        ]
        for contradiction in synthesis.contradictions {{
            parts.append(
                String(
                    format: String(
                        localized: "props.slate.contradiction.a11y",
                        defaultValue: "Tension: %@"
                    ),
                    contradiction
                )
            )
        }}
        return parts.joined(separator: ". ")
    }}
}}
"""

props_feed_filter_sheet_swift = header() + f"""import SwiftUI

// MARK: - PropsFeedFilterSheet

/// Half-sheet filter for the props feed. Detents: .fraction(0.52) / .large.
/// Changes preview live via onFilterChanged. On dismiss-without-commit, rolls back
/// to the snapshot taken at sheet open via onRollback.
struct PropsFeedFilterSheet: View {{
    @Binding var isPresented: Bool
    let currentFilter: PropFeedFilter
    let availableStats: [PropStatCategory]
    let filteredCount: Int
    let onFilterChanged: (PropFeedFilter) -> Void
    let onCommit: (PropFeedFilter) -> Void
    let onRollback: (PropFeedFilter) -> Void

    @State private var localFilter: PropFeedFilter
    @State private var committed = false

    init(
        isPresented: Binding<Bool>,
        currentFilter: PropFeedFilter,
        availableStats: [PropStatCategory],
        filteredCount: Int,
        onFilterChanged: @escaping (PropFeedFilter) -> Void,
        onCommit: @escaping (PropFeedFilter) -> Void,
        onRollback: @escaping (PropFeedFilter) -> Void
    ) {{
        self._isPresented = isPresented
        self.currentFilter = currentFilter
        self.availableStats = availableStats
        self.filteredCount = filteredCount
        self.onFilterChanged = onFilterChanged
        self.onCommit = onCommit
        self.onRollback = onRollback
        self._localFilter = State(initialValue: currentFilter)
    }}

    var body: some View {{
        NavigationStack {{
            ScrollView {{
                VStack(alignment: .leading, spacing: 24) {{
                    statCategorySection
                    minimumTierSection
                    instinctSection
                }}
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }}
            .navigationTitle(String(localized: "props.filter.title", defaultValue: "Filter Props"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {{
                ToolbarItem(placement: .navigationBarLeading) {{
                    Button(String(localized: "props.filter.reset", defaultValue: "Reset")) {{
                        localFilter = .init()
                        onFilterChanged(localFilter)
                    }}
                    .font(.system(size: 15))
                    .disabled(localFilter == .init())
                }}
            }}
            .safeAreaInset(edge: .bottom) {{
                commitButton
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
            }}
        }}
        .presentationDetents([.fraction(0.52), .large])
        .presentationDragIndicator(.visible)
        .onDisappear {{
            if !committed {{ onRollback(currentFilter) }}
        }}
    }}

    // MARK: - Stat category chips

    private var statCategorySection: some View {{
        VStack(alignment: .leading, spacing: 10) {{
            filterSectionLabel(String(localized: "props.filter.stat.label", defaultValue: "Stat Category"))

            let batStats = availableStats.filter {{ $0.isBatterStat }}
            let pitchStats = availableStats.filter {{ !$0.isBatterStat }}

            if !batStats.isEmpty {{
                Text(String(localized: "props.filter.stat.batters", defaultValue: "Batters"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .accessibilityAddTraits(.isHeader)
                FlowChips(items: batStats, selection: $localFilter.selectedStatCategories) {{ $0.shortLabel }}
            }}
            if !pitchStats.isEmpty {{
                Text(String(localized: "props.filter.stat.pitchers", defaultValue: "Pitchers"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)
                FlowChips(items: pitchStats, selection: $localFilter.selectedStatCategories) {{ $0.shortLabel }}
            }}
        }}
        .onChange(of: localFilter.selectedStatCategories) {{ _, _ in onFilterChanged(localFilter) }}
    }}

    // MARK: - Minimum tier picker

    private var minimumTierSection: some View {{
        VStack(alignment: .leading, spacing: 10) {{
            filterSectionLabel(String(localized: "props.filter.minTier.label", defaultValue: "Minimum Edge"))
            Picker("", selection: $localFilter.minimumTier) {{
                Text(String(localized: "props.filter.tier.any", defaultValue: "Any")).tag(PropEdgeTier.subdued)
                Text(String(localized: "props.filter.tier.lean", defaultValue: "Lean+")).tag(PropEdgeTier.lean)
                Text(String(localized: "props.filter.tier.solid", defaultValue: "Solid+")).tag(PropEdgeTier.solid)
                Text(String(localized: "props.filter.tier.strong", defaultValue: "Strong+")).tag(PropEdgeTier.strong)
            }}
            .pickerStyle(.segmented)
            .onChange(of: localFilter.minimumTier) {{ _, _ in onFilterChanged(localFilter) }}
        }}
    }}

    // MARK: - Instinct toggle

    private var instinctSection: some View {{
        VStack(alignment: .leading, spacing: 10) {{
            filterSectionLabel(String(localized: "props.filter.instinct.label", defaultValue: "BlackKatt Instinct"))
            Toggle(
                String(localized: "props.filter.instinct.toggle",
                       defaultValue: "Instinct agrees only"),
                isOn: $localFilter.instinctAgreesOnly
            )
            .tint(.green)
            .onChange(of: localFilter.instinctAgreesOnly) {{ _, _ in onFilterChanged(localFilter) }}
        }}
    }}

    // MARK: - Commit button

    private var commitButton: some View {{
        let title = filteredCount == 0
            ? String(localized: "props.filter.show.empty", defaultValue: "No Props Match")
            : String(localized: "props.filter.show.count", defaultValue: "Show \\(filteredCount) Props")

        return Button {{
            committed = true
            onCommit(localFilter)
            isPresented = false
        }} label: {{
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(filteredCount == 0 ? Color.gray.opacity(0.3) : Color.accentColor)
                )
        }}
        .disabled(filteredCount == 0)
        .accessibilityLabel(title)
        .accessibilityHint(String(localized: "props.filter.show.hint",
                                  defaultValue: "Applies filters and closes sheet"))
    }}

    private func filterSectionLabel(_ text: String) -> some View {{
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            .textCase(.uppercase)
            .kerning(0.5)
            .accessibilityAddTraits(.isHeader)
    }}
}}

// MARK: - FlowChips

/// Multi-select chip grid that wraps to multiple lines.
private struct FlowChips: View {{
    let items: [PropStatCategory]
    @Binding var selection: Set<PropStatCategory>
    let label: (PropStatCategory) -> String

    var body: some View {{
        // Simple wrapping layout using ViewThatFits fallback approach
        // LazyVGrid provides consistent column sizing without a custom Layout.
        LazyVGrid(columns: [
            GridItem(.adaptive(minimum: 80, maximum: 140), spacing: 8)
        ], spacing: 8) {{
            ForEach(items) {{ item in
                let isSelected = selection.contains(item)
                Button {{
                    if isSelected {{ selection.remove(item) }} else {{ selection.insert(item) }}
                }} label: {{
                    Text(label(item))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? Color.accentColor.opacity(0.3) : .white.opacity(0.07))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(
                                            isSelected ? Color.accentColor : .white.opacity(0.15),
                                            lineWidth: 1
                                        )
                                )
                        )
                }}
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            }}
        }}
    }}
}}
"""

player_mode_launcher_view_swift = header() + f"""import BKSCore
import BKSUICore
import SwiftUI

// MARK: - PlayerModeLauncherView

struct PlayerModeLauncherView: View {{
    let loadState: ViewState<[BoardEntry]>
    let topPropOpportunities: [TopPropOpportunity]?

    var body: some View {{
        VStack(spacing: 12) {{
            PlayerModeCard(
                mode: .props,
                iconColor: .black,
                stats: propsStats
            )
            PlayerModeCard(
                mode: .draftKings,
                iconColor: Color(red: 0.33, green: 0.76, blue: 0.22),
                stats: draftKingsStats
            )
            PlayerModeCard(
                mode: .fanDuel,
                iconColor: Color(red: 0.28, green: 0.56, blue: 0.96),
                stats: fanDuelStats
            )
        }}
        .padding(.top, 4)
        .padding(.bottom, 16)
    }}

    private var propsStats: [PlayerModeStat] {{
        guard case .loaded = loadState, let props = topPropOpportunities, !props.isEmpty else {{
            return []
        }}
        let topEdges = props.filter {{ $0.edgePP >= 10 }}.count
        let bestHitRate = props.map {{ $0.ourProbability }}.max().map {{ Int($0 * 100) }}
        return [
            PlayerModeStat(
                value: "\\(props.count)",
                label: String(localized: "launcher.props.count", defaultValue: "props")
            ),
            PlayerModeStat(
                value: "\\(topEdges)",
                label: String(localized: "launcher.props.topEdges", defaultValue: "top edges"),
                isHighlighted: true
            ),
            bestHitRate.map {{
                PlayerModeStat(
                    value: "\\($0)%",
                    label: String(localized: "launcher.props.hitRate", defaultValue: "best hit rate")
                )
            }},
        ].compactMap {{ $0 }}
    }}

    private var draftKingsStats: [PlayerModeStat] {{
        [
            PlayerModeStat(
                value: "$50K",
                label: String(localized: "launcher.dk.cap", defaultValue: "cap")
            ),
        ]
    }}

    private var fanDuelStats: [PlayerModeStat] {{
        [
            PlayerModeStat(
                value: "$35K",
                label: String(localized: "launcher.fd.cap", defaultValue: "cap")
            ),
        ]
    }}
}}

// MARK: - PlayerModeCard

private struct PlayerModeCard: View {{
    let mode: BoardViewMode
    let iconColor: Color
    let stats: [PlayerModeStat]

    var body: some View {{
        NavigationLink(value: mode) {{
            HStack(alignment: .center, spacing: 14) {{
                ZStack {{
                    RoundedRectangle(cornerRadius: 10)
                        .fill(iconColor)
                        .frame(width: 60, height: 60)
                        .accessibilityHidden(true)

                    if let tag = mode.modeTag {{
                        Text(tag)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }}
                }}

                VStack(alignment: .leading, spacing: 2) {{
                    HStack {{
                        Text(mode.displayName)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer()
                    }}

                    if !stats.isEmpty {{
                        HStack(alignment: .top, spacing: 20) {{
                            ForEach(stats) {{ stat in
                                PlayerModeStatView(stat: stat)
                            }}
                            Spacer()
                        }}
                        .padding(.top, 4)
                    }}
                }}

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(AppOpacity.muted))
            }}
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appCard()
        }}
        .containerRelativeFrame(.horizontal) {{ width, _ in width - 32 }}
        .buttonStyle(.plain)
        .accessibilityLabel(statsAccessibilityLabel)
        .accessibilityHint(String(localized: "a11y.launcher.card.hint", defaultValue: "Open"))
    }}

    private var statsAccessibilityLabel: String {{
        var parts = [mode.displayName]
        for stat in stats {{
            parts.append("\\(stat.value) \\(stat.label)")
        }}
        return parts.joined(separator: ", ")
    }}
}}

// MARK: - PlayerModeStatView

private struct PlayerModeStatView: View {{
    let stat: PlayerModeStat

    var body: some View {{
        VStack(alignment: .center, spacing: 1) {{
            Text(stat.value)
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundStyle(
                    stat.isHighlighted
                        ? Color(red: 0.33, green: 0.76, blue: 0.22)
                        : .white
                )
            Text(stat.label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(AppOpacity.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }}
    }}
}}

// MARK: - PlayerModeStat

private struct PlayerModeStat: Identifiable {{
    var id: String {{ label }}
    let value: String
    let label: String
    var isHighlighted: Bool = false
}}

// MARK: - BoardViewMode helpers

extension BoardViewMode {{
    var displayName: String {{
        switch self {{
        case .props:
            return String(localized: "board.view.props", defaultValue: "Sports Markets")
        case .draftKings:
            return String(localized: "board.view.draftKings.short", defaultValue: "DraftKings")
        case .fanDuel:
            return String(localized: "board.view.fanDuel.short", defaultValue: "FanDuel")
        }}
    }}

    var modeTag: String? {{
        switch self {{
        case .props: return String(localized: "board.view.props.tag", defaultValue: "Props")
        case .draftKings: return String(localized: "board.view.dfs.tag", defaultValue: "DFS")
        case .fanDuel: return String(localized: "board.view.dfs.tag", defaultValue: "DFS")
        }}
    }}

    var navigationTitle: String {{
        switch self {{
        case .props:
            return String(localized: "board.view.props", defaultValue: "Sports Markets")
        case .draftKings:
            return String(localized: "board.view.draftKings", defaultValue: "DraftKings")
        case .fanDuel:
            return String(localized: "board.view.fanDuel", defaultValue: "FanDuel")
        }}
    }}
}}
"""

write_if_absent(os.path.join(props_views_dir,   "PropSlateSynthesisCard.swift"),   prop_slate_synthesis_card_swift)
write_if_absent(os.path.join(props_views_dir,   "PropsFeedFilterSheet.swift"),     props_feed_filter_sheet_swift)
write_if_absent(os.path.join(board_views_dir,   "PlayerModeLauncherView.swift"),   player_mode_launcher_view_swift)
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

# project.yml is write_if_absent by default — existing projects typically
# have a hand-tuned project.yml. Pass --regen-project to overwrite.
if REGEN_PROJECT:
    write(os.path.join(out_dir, "App/project.yml"), project_yml)
else:
    write_if_absent(os.path.join(out_dir, "App/project.yml"), project_yml)

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

# ── Board performance baselines (XCTest measure blocks) ────────────────────

board_performance_tests_swift = header() + f"""import XCTest
@testable import {type_prefix}
@testable import BKSCore

/// Performance baselines for the Board cold-launch flow.
///
/// Run via: `xcodebuild test -project App/{type_prefix}.xcodeproj -scheme {type_prefix}
/// -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17'
/// -only-testing:{type_prefix}Tests/BoardPerformanceTests`.
///
/// XCTest records and pins baselines per host machine. The first run establishes
/// the baseline; subsequent runs fail if they regress by more than the configured
/// percentage (default 10%).
final class BoardPerformanceTests: XCTestCase {{

    /// Measures the synchronous `BoardEntryBuilder.build` join for a realistic
    /// slate. This is the largest single block of CPU work on the Board cold path.
    func testBoardEntryBuildPerformance() {{
        let projections = SeedData.makeProjections(count: 400)
        let opportunities = SeedData.makeOpportunities(count: 400)
        let today = "2026-05-16"

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {{
            _ = BoardEntryBuilder.build(
                players: [],
                projections: projections,
                opportunities: opportunities,
                todayDateString: today
            )
        }}
    }}

    /// Measures `applyFilters`-equivalent work under a realistic search-as-you-type scenario.
    func testBoardApplyFiltersPerformance() {{
        let projections = SeedData.makeProjections(count: 400)
        let opportunities = SeedData.makeOpportunities(count: 400)
        let entries = BoardEntryBuilder.build(
            players: [],
            projections: projections,
            opportunities: opportunities,
            todayDateString: "2026-05-16"
        )
        let search = "smi"

        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {{
            _ = entries.filter {{ entry in
                entry.displayName.lowercased().contains(search)
                    || entry.team.lowercased().contains(search)
                    || (entry.position?.lowercased().contains(search) ?? false)
            }}
        }}
    }}
}}

// MARK: - Seed data

/// Test data factories producing realistic slates for performance benchmarks.
///
/// Names and teams vary so the filter benchmark exercises real string scanning
/// rather than short-circuiting on identical values.
enum SeedData {{

    private static let firstNames = [
        "Aaron", "Blake", "Carlos", "David", "Evan",
        "Fernando", "George", "Henry", "Ivan", "Jake",
        "Kevin", "Luis", "Marcus", "Nathan", "Oscar",
        "Pablo", "Quinn", "Rafael", "Samuel", "Tyler",
        "Uriel", "Victor", "Walter", "Xavier", "Yoan",
        "Zack", "Smith", "Jones", "Brown", "Davis",
    ]

    private static let lastNames = [
        "Smith", "Johnson", "Williams", "Brown", "Jones",
        "Garcia", "Miller", "Davis", "Martinez", "Hernandez",
        "Lopez", "Gonzalez", "Wilson", "Anderson", "Thomas",
        "Taylor", "Moore", "Jackson", "Martin", "Lee",
        "Perez", "Thompson", "White", "Harris", "Sanchez",
        "Clark", "Ramirez", "Lewis", "Robinson", "Walker",
    ]

    private static let teams = [
        "NYY", "BOS", "LAD", "CHC", "SFG",
        "HOU", "ATL", "NYM", "PHI", "TBR",
        "SEA", "MIN", "CLE", "DET", "BAL",
        "TOR", "OAK", "TEX", "KCR", "CWS",
        "STL", "MIL", "CIN", "PIT", "COL",
        "ARI", "SDP", "MIA", "WSN", "LAA",
    ]

    private static let positions = ["SP", "RP", "C", "1B", "2B", "3B", "SS", "OF", "DH"]

    private static let opponents = [
        "NYY", "BOS", "LAD", "CHC", "SFG",
        "HOU", "ATL", "NYM", "PHI", "TBR",
    ]

    private static func name(at index: Int) -> String {{
        let first = firstNames[index % firstNames.count]
        let last = lastNames[(index * 7 + 3) % lastNames.count]
        return "\\(first) \\(last)"
    }}

    private static func team(at index: Int) -> String {{
        teams[index % teams.count]
    }}

    private static func position(at index: Int) -> String {{
        positions[index % positions.count]
    }}

    private static func tier(at index: Int) -> TierLevel {{
        switch index % 4 {{
        case 0: return .elite
        case 1: return .good
        case 2: return .solid
        default: return .bottom
        }}
    }}

    private static func gameDate() -> Date {{
        // Fixed date matching today's slate string
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 16
        components.hour = 19
        components.minute = 10
        return Calendar.current.date(from: components) ?? Date()
    }}

    private static func makeTodayGame(index: Int, today: Date) -> ProjectedGame {{
        ProjectedGame(
            id: "game-proj-\\(index)",
            gameDate: today,
            gameDateTime: today,
            opponentAbbr: opponents[index % opponents.count],
            isHome: index.isMultiple(of: 2)
        )
    }}

    static func makeProjections(count: Int) -> [Projection] {{
        let today = gameDate()
        return (0..<count).map {{ index in
            let hotStreak: Int? = index.isMultiple(of: 4) ? (index % 5) + 1 : nil
            let coldStreak: Int? = index.isMultiple(of: 7) ? (index % 3) + 1 : nil
            let trendDir: TrendDirection = index.isMultiple(of: 3) ? .up : (index.isMultiple(of: 5) ? .down : .flat)
            let confidence = 0.5 + Double(index % 50) / 100.0
            let rankScore = 20.0 + Double(index % 30)
            let seasonAvg = 0.220 + Double(index % 80) / 1000.0
            let seasonOBP = 0.300 + Double(index % 60) / 1000.0
            let seasonSLG = 0.380 + Double(index % 100) / 1000.0
            let seasonOPS = 0.680 + Double(index % 150) / 1000.0
            let seasonWAR = Double(index % 50) / 10.0
            return Projection(
                id: "proj-\\(index)",
                displayName: name(at: index),
                team: team(at: index),
                position: position(at: index),
                headshotURL: nil,
                externalPersonID: 500_000 + index,
                rankingScore: rankScore,
                injuryStatus: nil,
                isSurging: index.isMultiple(of: 5),
                upcomingGames: [makeTodayGame(index: index, today: today)],
                hotStreak: hotStreak,
                coldStreak: coldStreak,
                trendDirection: trendDir,
                confidenceScore: confidence,
                seasonAvg: seasonAvg,
                seasonOBP: seasonOBP,
                seasonSLG: seasonSLG,
                seasonOPS: seasonOPS,
                seasonWAR: seasonWAR
            )
        }}
    }}

    // swiftlint:disable:next function_body_length
    static func makeOpportunities(count: Int) -> [Opportunity] {{
        let today = gameDate()
        return (0..<count).map {{ index in
            let personID = 500_000 + index
            let oppScore = 50.0 + Double(index % 50)
            let isTopPick = index.isMultiple(of: 10)
            let topPickRank: Int? = isTopPick ? index / 10 + 1 : nil
            let topPickReasons: [String] = isTopPick ? ["Hot streak", "Favorable matchup"] : []
            let battingOrder: Int? = index.isMultiple(of: 9) ? nil : (index % 9) + 1
            let parkFactor = 0.9 + Double(index % 20) / 100.0
            let trendHits = Double(index % 30) / 10.0
            let seasonAvg = 0.220 + Double(index % 80) / 1000.0
            let wobaProxy = 0.300 + Double(index % 70) / 1000.0
            let obpProxy = 0.310 + Double(index % 60) / 1000.0
            let avgPaPerGame = 3.5 + Double(index % 15) / 10.0
            return Opportunity(
                id: "opp-\\(index)",
                displayName: name(at: index),
                team: team(at: index),
                position: position(at: index),
                opponentAbbr: opponents[index % opponents.count],
                headshotURL: nil,
                externalPersonID: personID,
                opportunityScore: oppScore,
                opportunityTier: tier(at: index),
                injuryStatus: nil,
                isSurging: index.isMultiple(of: 5),
                isHome: index.isMultiple(of: 2),
                gameDateTime: today,
                isTopPick: isTopPick,
                topPickRank: topPickRank,
                topPickReasons: topPickReasons,
                battingOrder: battingOrder,
                probablePitcher: "Starter \\(index % 15)",
                parkFactor: parkFactor,
                trendHits: trendHits,
                seasonAvg: seasonAvg,
                wobaProxy: wobaProxy,
                obpProxy: obpProxy,
                avgPaPerGame: avgPaPerGame
            )
        }}
    }}
}}
"""

write_if_absent(os.path.join(out_dir, "App/Tests/BoardPerformanceTests.swift"), board_performance_tests_swift)

et_date_tests_swift = header() + f"""import XCTest
@testable import {type_prefix}

/// Server data days roll at midnight America/New_York, not device-local midnight.
/// These tests pin the ET day-boundary logic that gates board cache staleness:
/// a Pacific user opening the app at 5 AM local must be treated as a NEW server
/// day even though the local calendar has not flipped yet.
final class ETDateTests: XCTestCase {{

    /// 2026-06-11T03:59Z == 2026-06-10 23:59 EDT (UTC-4 in June).
    private let lateNightET = Date(timeIntervalSince1970: 1_781_150_340)
    /// 2026-06-11T04:01Z == 2026-06-11 00:01 EDT — two minutes later, new ET day.
    private let justAfterMidnightET = Date(timeIntervalSince1970: 1_781_150_460)
    /// 2026-06-11T23:00Z == 2026-06-11 19:00 EDT — same ET day as 00:01 EDT.
    private let eveningSameETDay = Date(timeIntervalSince1970: 1_781_218_800)
    /// 2026-01-15T04:59Z == 2026-01-14 23:59 EST (UTC-5 in January).
    private let winterLateNightET = Date(timeIntervalSince1970: 1_768_453_140)

    func testMidnightETBoundarySplitsDays() {{
        XCTAssertFalse(
            ETDate.isSameETDay(lateNightET, justAfterMidnightET),
            "23:59 ET and 00:01 ET the next day must be different ET days"
        )
    }}

    func testSameETDayAcrossWholeDay() {{
        XCTAssertTrue(
            ETDate.isSameETDay(justAfterMidnightET, eveningSameETDay),
            "00:01 ET and 19:00 ET on the same date must be the same ET day"
        )
    }}

    func testDateStringUsesEasternTimeInSummer() {{
        XCTAssertEqual(ETDate.dateString(for: lateNightET), "2026-06-10")
        XCTAssertEqual(ETDate.dateString(for: justAfterMidnightET), "2026-06-11")
    }}

    func testDateStringUsesEasternTimeInWinter() {{
        // EST (UTC-5): 04:59Z is still the previous ET day.
        XCTAssertEqual(ETDate.dateString(for: winterLateNightET), "2026-01-14")
    }}

    func testIsCurrentETDayMatchesServerDateString() {{
        XCTAssertTrue(ETDate.isCurrentETDay(serverDateString: "2026-06-10", now: lateNightET))
        XCTAssertFalse(ETDate.isCurrentETDay(serverDateString: "2026-06-10", now: justAfterMidnightET))
        XCTAssertTrue(ETDate.isCurrentETDay(serverDateString: "2026-06-11", now: justAfterMidnightET))
    }}
}}
"""

write_if_absent(os.path.join(out_dir, "App/Tests/ETDateTests.swift"), et_date_tests_swift)

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
  - .claude

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
iOS app — Swift {swift_ver} / Xcode {xcode_ver}, targeting iOS {deploy_tgt}+. SwiftUI + SPM.

## Build & Test Commands
- **Build**: `xcodebuild -project App/{app_target}.xcodeproj -scheme {app_target} -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
- **Test**: `xcodebuild test -project App/{app_target}.xcodeproj -scheme {app_target} -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
- **Build until clean**: Run build, fix all errors and warnings, repeat until `grep -E "error:|warning:"` returns only the `appintentsmetadataprocessor` tooling line (not a real warning). Always fix all issues before considering a task done.
- **Lint**: `swiftlint`
- **Regenerate project**: `./generate.sh` (from repo root — runs xcodegen then syncs both Package.resolved files)
  - **Never** run `xcodegen generate` directly; always use `./generate.sh` to keep the inner and outer Package.resolved in sync
- **After every build cycle** (mandatory, no exceptions): Always nuke DerivedData, re-resolve, and sync both Package.resolved files:
  ```
  rm -rf ~/Library/Developer/Xcode/DerivedData/{app_target}-*
  xcodebuild -resolvePackageDependencies -project App/{app_target}.xcodeproj -scheme {app_target}
  cp App/{app_target}.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved {app_target}.xcworkspace/xcshareddata/swiftpm/Package.resolved
  ```
  This is required after every build, tag, package bump, or significant change — not just SPM version bumps. Skipping causes stale SPM source, phantom build errors, and layout bugs that are invisible until device.
- **Before completing any task**: Run `swiftlint` and verify it produces no warnings or errors in app source. Confirm both `Package.resolved` files are in sync (inner `App/{app_target}.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` and outer `{app_target}.xcworkspace/xcshareddata/swiftpm/Package.resolved` must match). Run a full build and confirm `BUILD SUCCEEDED` with no `error:` or `warning:` lines beyond the `appintentsmetadataprocessor` tooling noise.

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
Scaffolded by **BKS-Sports-iOS**: https://github.com/bkatnich/BKS-Sports-iOS

The generator takes `sports/{slug}.yaml` and produces sport-specific Swift files. If templates change, re-run `./scaffold.sh {slug}` from the template repo.

**Do NOT** propagate changes from this project back to the template repo without explicit permission.

## Architecture
- **Pattern**: MVI (Store/Reduce unidirectional data flow) via BKSCore
- **Navigation**: NavigationStack with typed destinations
- **DI**: Swinject container bootstrapped at app launch; `SportConfiguration` injected via SwiftUI `.environment()`

### Source Structure
```
Sources/
├── App/           — Composition root ({type_prefix}App, AppShell, DependencyContainer)
├── Core/
│   ├── Services/  — Sport-specific implementations (BoardService, GamesService)
│   │              — BoardService owns get-board (schedule + players + odds + props); GamesService owns game logs + playoff bracket
│   ├── Models/    — Domain models (Opportunity, Projection, TopPropOpportunity, PropSlateSynthesis, PropEdgeTier, PropStatCategory, LeagueState)
│   ├── Sport/     — Sport extensions (SportConfiguration+<Sport>, SportPositionMap+<Sport>)
│   │              — Base types (SportConfiguration, SportPositionMap, ScoringCalculator) live in BKSCore
│   ├── Utilities/ — Shared helpers (ConfigurationKeys, VisiblePushEvent, NotificationPreferenceKey, PropFeedFilter, GamedayTopicManager)
│   │              — (Filterable, PlayerLookup, PushNotificationNames) live in BKSCore
│   └── UI/        — Shared views (TierTypes+UI, TierThresholds)
└── Features/
    ├── Board/          — Primary sport feature
    │   ├── Models/ — BoardEntry, BoardEntryBuilder
    │   ├── Store/  — BoardState, BoardIntent
    │   └── Views/  — BoardView, PlayerModeLauncherView, Props/ feed views
    ├── Profile/
    │   └── Views/  — ProfileContainerView, NotificationsDetailView
    ├── PromoCode/      — BKSUICore owns logic; directories only
    └── Subscription/   — BKSUICore owns logic; directories only
```

## Branch Policy
- **Always commit and push to `develop`** — this is the default integration branch for all work.
- **Never touch `main`** without explicit permission from the user. Do not push, merge, rebase, or force-push to `main` under any circumstances unless directly instructed.
- If a task would require merging to `main`, stop and ask first.

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
- Shared code (`Sources/Core/Sport/`, `Sources/Core/Utilities/`) is owned by whichever agent's task requires the change; coordinate via the lead if both need changes

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

ios_advisor_skill_path = os.path.join(SCRIPT_DIR, ".claude", "skills", "ios-advisor", "SKILL.md")
if os.path.exists(ios_advisor_skill_path):
    with open(ios_advisor_skill_path) as f:
        ios_advisor_skill = f.read()
    write(os.path.join(out_dir, ".claude", "skills", "ios-advisor", "SKILL.md"), ios_advisor_skill)
else:
    print(f"  warning: {ios_advisor_skill_path} not found — skipping ios-advisor skill")

# run-<app> skill: simulator driver + manifest, tokenized per sport.
run_skill_name = f"run-{prefix.lower()}-{slug}"
run_skill_src = os.path.join(SCRIPT_DIR, "assets", "skills", "run-app")
if os.path.isdir(run_skill_src):
    for fname in ("SKILL.md", "driver.swift"):
        with open(os.path.join(run_skill_src, fname)) as f:
            content = f.read()
        content = (content
                   .replace("com.blackkatt.bksbaseball", bundle_id)
                   .replace("BKS Baseball", app_name)
                   .replace("BKSBaseball", type_prefix)
                   .replace("bks-baseball", f"{prefix.lower()}-{slug}"))
        write(os.path.join(out_dir, ".claude", "skills", run_skill_name, fname), content)
else:
    print(f"  warning: {run_skill_src} not found — skipping {run_skill_name} skill")

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
print(f"  App/Sources/Core/Services/BoardService.swift")
print(f"  App/Sources/Core/Services/GamesService.swift")
print()
print("Sport configuration (BKSCore owns base types; scaffold generates sport extensions):")
print(f"  App/Sources/Core/Sport/SportPositionMap+{swift_name}.swift")
if not use_null_calc:
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
print(f"  App/Tests/BoardPerformanceTests.swift")
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
        "revision" : "dfd64e581d939ea23d984b7b5e3a168176737942",
        "version" : "2.4.14"
      }
    },
    {
      "identity" : "bksuicore",
      "kind" : "remoteSourceControl",
      "location" : "git@github.com:bkatnich/BKSUICore.git",
      "state" : {
        "revision" : "1f3c5a280072f406179ee80cd6745c5be7b2319f",
        "version" : "1.5.62"
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
        "revision" : "81558271e243f8f47dfe8e9fdd55f3c2b5413f68",
        "version" : "1.37.0"
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
        if [[ "${SCAFFOLD_OPEN:-1}" == "1" ]]; then
            echo "  Opening project in Xcode (packages pre-pinned, no resolution required)..."
            open "$XCODEPROJ"
        fi
    fi
else
    echo ""
    echo "  warning: xcodegen not found — skipping project generation"
    echo "           Install via: brew install xcodegen"
    echo "           Then run:    cd $APP_DIR && xcodegen generate --spec project.yml"
fi
