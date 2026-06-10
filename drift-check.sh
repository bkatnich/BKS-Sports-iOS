#!/usr/bin/env bash
# drift-check.sh
#
# Detects drift between what the scaffold would generate and what's on disk in
# an existing sport app. Useful after scaffold.sh templates change to see which
# generated files have diverged from their hand-edited counterparts.
#
# Usage:
#   ./drift-check.sh <sport-slug> [app-dir]
#
# Examples:
#   ./drift-check.sh basketball
#   ./drift-check.sh basketball /path/to/BKS-Basketball-Client-iOS
#
# Output:
#   MATCH   — file on disk matches what the scaffold would generate
#   DRIFT   — file differs (shows a unified diff)
#   MISSING — scaffold would create this file but it doesn't exist on disk
#   SKIP    — write_if_absent file; scaffold never overwrites, so drift is expected
#
# Exit code: 0 if no drift, 1 if any drift detected.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── arguments ────────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <sport-slug> [app-dir]"
    echo "  e.g. $0 basketball"
    echo "  e.g. $0 basketball /path/to/BKS-Basketball-Client-iOS"
    exit 1
fi

SPORT_SLUG="$1"
YAML_FILE="$SCRIPT_DIR/sports/${SPORT_SLUG}.yaml"

if [[ ! -f "$YAML_FILE" ]]; then
    echo "Error: sport spec not found at $YAML_FILE"
    exit 1
fi

# Resolve app directory the same way scaffold.sh does
if [[ $# -ge 2 ]]; then
    APP_DIR="$(cd "$2" && pwd)"
else
    SPORT_NAME_CAP="$(python3 -c "import yaml; s=yaml.safe_load(open('$YAML_FILE')); print(s['sport']['name'].replace(' ',''))")"
    PREFIX="$(python3 -c "import yaml; s=yaml.safe_load(open('$YAML_FILE')); print(s['sport']['prefix'])")"
    APP_DIR="$(dirname "$SCRIPT_DIR")/${PREFIX}-${SPORT_NAME_CAP}-Client-iOS"
fi

if [[ ! -d "$APP_DIR" ]]; then
    echo "Error: app directory not found at $APP_DIR"
    echo "Pass it explicitly as the second argument."
    exit 1
fi

echo "Checking drift: $SPORT_SLUG → $APP_DIR"
echo ""

# ── generate into a temp directory ───────────────────────────────────────────

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Run scaffold into tmp dir (suppressing its printed output)
"$SCRIPT_DIR/scaffold.sh" "$SPORT_SLUG" "$TMP_DIR" > /dev/null 2>&1 || {
    echo "Error: scaffold.sh failed — fix scaffold errors before running drift-check."
    exit 1
}

# ── compare generated files against app ──────────────────────────────────────

DRIFT_COUNT=0
MISSING_COUNT=0
MATCH_COUNT=0

# Files that use write_if_absent — scaffold intentionally never overwrites these.
# Drift in these files is expected and should not be flagged.
SKIP_PATTERNS=(
    "BoardEntryBuilder.swift"
    "BoardView.swift"
    "BoardNavBar.swift"
    "BoardViewModePicker.swift"
    "BoardScrollContent.swift"
    "PropPlayerRow.swift"
    "TierDividerRow.swift"
    "EdgePropCard.swift"
    "AllPropRow.swift"
    "PropsFeedView.swift"
    "ProfileContainerView.swift"
    "NotificationsDetailView.swift"
)

while IFS= read -r -d '' generated_file; do
    rel="${generated_file#$TMP_DIR/}"
    app_file="$APP_DIR/$rel"

    # Check if this file is a write_if_absent stub
    basename_file="$(basename "$generated_file")"
    is_skip=0
    for pattern in "${SKIP_PATTERNS[@]}"; do
        if [[ "$basename_file" == "$pattern" ]]; then
            is_skip=1
            break
        fi
    done

    if [[ $is_skip -eq 1 ]]; then
        printf "  %-8s %s\n" "SKIP" "$rel"
        continue
    fi

    if [[ ! -f "$app_file" ]]; then
        printf "  %-8s %s\n" "MISSING" "$rel"
        (( MISSING_COUNT++ )) || true
        continue
    fi

    if diff -q "$generated_file" "$app_file" > /dev/null 2>&1; then
        printf "  %-8s %s\n" "MATCH" "$rel"
        (( MATCH_COUNT++ )) || true
    else
        printf "  %-8s %s\n" "DRIFT" "$rel"
        diff -u "$generated_file" "$app_file" \
            --label "scaffold/$rel" \
            --label "app/$rel" \
            | head -40 || true
        echo ""
        (( DRIFT_COUNT++ )) || true
    fi
done < <(find "$TMP_DIR" -type f -name "*.swift" -print0 | sort -z)

# ── bootstrap anti-pattern checks ────────────────────────────────────────────
#
# These checks scan hand-authored files that the scaffold does not generate.
# A non-zero FAIL_COUNT causes a non-zero exit alongside any scaffold drift.

FAIL_COUNT=0

echo ""
echo "Bootstrap checks"
echo ""

# Check: the root .task in *App.swift must not call Self.prefetch().
# BoardState.onAppear already fires disk+network concurrently; a prefetch call
# in the launch task races against it and doubles every network request.
# (Bug first found in BKSBasketballApp.swift and BKSBaseballApp.swift, 2026-05-19.)
APP_SWIFT="$(find "$APP_DIR/App/Sources/App/Bootstrap" -name "*App.swift" 2>/dev/null | head -1)"
if [[ -z "$APP_SWIFT" ]]; then
    printf "  %-8s %s\n" "SKIP" "bootstrap prefetch check (no *App.swift found)"
else
    # A prefetch call inside the launch .task looks like:
    #   await Perf.measure("PrefetchAll") { ... }   OR
    #   await Self.prefetch(                         (direct call)
    # Both share "PrefetchAll" or a Self.prefetch call in the launch task context.
    # We detect either form by grepping for Self.prefetch — the sign-in and consent
    # call sites are fine (they fire before the board is visible); only the one
    # inside the WindowGroup .task block is the anti-pattern. We distinguish it by
    # requiring "PrefetchAll" on a nearby line, which is the Perf.measure label used
    # exclusively in the launch task.
    if grep -q 'PrefetchAll' "$APP_SWIFT"; then
        printf "  %-8s %s\n" "FAIL" "$(basename "$APP_SWIFT"): launch .task calls Self.prefetch() — races with BoardState.fetchAll and doubles every network request. Remove the PrefetchAll block; BoardState.onAppear handles warm-up."
        (( FAIL_COUNT++ )) || true
    else
        printf "  %-8s %s\n" "PASS" "$(basename "$APP_SWIFT"): no launch-task prefetch"
    fi
fi

# Check: the disk-hit branch of BoardState.onAppear must apply dailyAnalysis from diskResult.
# loadFromDisk returns a cached DailyAnalysis, but the inline disk branch only copies
# specific fields — if dailyAnalysis is not explicitly assigned, the card flashes
# "not yet available" between the disk render and the network analysisLoaded dispatch.
# (Bug first found in BKSBasketballApp.swift and BKSBaseballApp.swift, 2026-05-19.)
BOARD_STATE_SWIFT="$(find "$APP_DIR/App/Sources/Features/Board/Store" -name "BoardState.swift" 2>/dev/null | head -1)"
if [[ -z "$BOARD_STATE_SWIFT" ]]; then
    printf "  %-8s %s\n" "SKIP" "disk-hit analysis check (no BoardState.swift found)"
else
    if grep -q 'diskResult.dailyAnalysis' "$BOARD_STATE_SWIFT"; then
        printf "  %-8s %s\n" "PASS" "BoardState.swift: disk-hit branch applies dailyAnalysis"
    else
        printf "  %-8s %s\n" "FAIL" "BoardState.swift: disk-hit branch does not apply diskResult.dailyAnalysis — slate analysis card will flash 'not yet available' on every load. Add: if let analysis = diskResult.dailyAnalysis { state.dailyAnalysis = analysis }"
        (( FAIL_COUNT++ )) || true
    fi
fi

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────"
echo "  Match:   $MATCH_COUNT"
echo "  Drift:   $DRIFT_COUNT"
echo "  Missing: $MISSING_COUNT"
echo "  Fails:   $FAIL_COUNT"
echo "────────────────────────────────────────"

if [[ $DRIFT_COUNT -gt 0 ]] || [[ $MISSING_COUNT -gt 0 ]] || [[ $FAIL_COUNT -gt 0 ]]; then
    echo "  ⚠️  Issues detected."
    exit 1
else
    echo "  ✅ No drift — scaffold and app are in sync."
    exit 0
fi
