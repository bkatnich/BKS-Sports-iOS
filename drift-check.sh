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
    "BoardState.swift"
    "BoardIntent.swift"
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
            | head -40
        echo ""
        (( DRIFT_COUNT++ )) || true
    fi
done < <(find "$TMP_DIR" -type f -name "*.swift" -print0 | sort -z)

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────"
echo "  Match:   $MATCH_COUNT"
echo "  Drift:   $DRIFT_COUNT"
echo "  Missing: $MISSING_COUNT"
echo "────────────────────────────────────────"

if [[ $DRIFT_COUNT -gt 0 ]] || [[ $MISSING_COUNT -gt 0 ]]; then
    echo "  ⚠️  Drift detected."
    exit 1
else
    echo "  ✅ No drift — scaffold and app are in sync."
    exit 0
fi
