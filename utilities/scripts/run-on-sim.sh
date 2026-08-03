#!/bin/bash
# Build + install + launch Pinkha on a booted iOS Simulator.
#
# Companion to run-on-device.sh — same flow but targets the Simulator instead
# of a physical iPhone. Useful when iterating on UI changes without unplugging
# the dev iPhone, or when you want to test a locale (env-set LANG) or a
# specific simulator (env-set SIM_NAME).
#
# Behaviour:
#   - Targets the project's dedicated simulator, "Pinkha SIM", booting it if
#     needed. Deliberately NOT "whichever simulator happens to be booted" —
#     that made the target depend on unrelated work and scattered the app's
#     data across containers. Override with SIM_NAME / SIM_UDID env var.
#   - Falls back to any booted simulator if "Pinkha SIM" doesn't exist.
#   - Prunes iCloud Drive conflict copies before regenerating (same logic as
#     run-on-device.sh — repo lives in iCloud which auto-creates `* 2.swift`).
#   - Regenerates the xcodeproj via xcodegen + patches the app icon (the two
#     idempotent setup steps that are easy to forget manually).
#   - Builds for the simulator destination and installs into it via simctl.
#   - Launches the app and opens Simulator.app so the simulator window
#     comes to focus.
set -euo pipefail

cd "$(dirname "$0")/../.."   # → repo root (utilities/scripts/.. = utilities, ../.. = repo)

BUNDLE_ID="com.gloiiire.pinkha"
DEFAULT_SIM="Pinkha SIM"

# ── DEVELOPER_DIR sanity (same hardening as run-on-device.sh) ─────────────
if [[ -n "${DEVELOPER_DIR:-}" && ! -d "$DEVELOPER_DIR" ]]; then
    echo "⚠ DEVELOPER_DIR=$DEVELOPER_DIR does not exist — falling back to /Applications/Xcode.app." >&2
    unset DEVELOPER_DIR
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

# ── Simulator discovery ──────────────────────────────────────────────────
# Priority: explicit SIM_UDID > explicit SIM_NAME > "Pinkha SIM" > any booted.
#
# The project sim wins over "whatever is booted" on purpose: the app's data
# (SQLite database, covers) lives per-simulator, so drifting between devices
# silently starts you on an empty library and makes "my notes disappeared"
# look like a bug in the app.
udid_for_name() {
    xcrun simctl list devices --json \
        | jq -r --arg name "$1" \
            '.devices | to_entries[] | .value[] | select(.name == $name) | .udid' \
        | head -1
}

if [[ -n "${SIM_UDID:-}" ]]; then
    SIM_TARGET="$SIM_UDID"
elif [[ -n "${SIM_NAME:-}" ]]; then
    SIM_TARGET=$(udid_for_name "$SIM_NAME")
    if [[ -z "$SIM_TARGET" ]]; then
        echo "✗ Simulator named '$SIM_NAME' not found." >&2
        exit 1
    fi
else
    SIM_TARGET=$(udid_for_name "$DEFAULT_SIM")
    if [[ -z "$SIM_TARGET" ]]; then
        echo "⚠ '${DEFAULT_SIM}' not found — falling back to any booted simulator." >&2
        SIM_TARGET=$(xcrun simctl list devices --json \
            | jq -r '.devices | to_entries[] | .value[] | select(.state == "Booted") | .udid' \
            | head -1)
    fi
fi

if [[ -z "${SIM_TARGET:-}" ]]; then
    echo "✗ No simulator to target. Create one named '${DEFAULT_SIM}', or pass" >&2
    echo "  SIM_NAME='iPhone 17 Pro' $0" >&2
    exit 1
fi

# Boot on demand — `bootstatus -b` blocks until it is actually usable, which
# avoids the `Unable to lookup in current state: Shutdown` (code 405) race
# that install/launch hit on a cold start.
SIM_STATE=$(xcrun simctl list devices --json \
    | jq -r --arg udid "$SIM_TARGET" \
        '.devices | to_entries[] | .value[] | select(.udid == $udid) | .state' \
    | head -1)
if [[ "$SIM_STATE" != "Booted" ]]; then
    echo "→ Booting simulator…"
    xcrun simctl boot "$SIM_TARGET" 2>/dev/null || true
    xcrun simctl bootstatus "$SIM_TARGET" -b >/dev/null 2>&1 || true
fi

# Resolve human-readable name for logs.
SIM_NAME_RESOLVED=$(xcrun simctl list devices --json \
    | jq -r --arg udid "$SIM_TARGET" \
        '.devices | to_entries[] | .value[] | select(.udid == $udid) | .name' \
    | head -1)
echo "→ Target simulator: ${SIM_NAME_RESOLVED} (${SIM_TARGET})"

# ── iCloud Drive conflict prune (same logic as run-on-device.sh) ─────────
find app -name "* [2-9].swift" -delete 2>/dev/null
find app -name "* [2-9].xcodeproj" -type d -exec rm -rf {} + 2>/dev/null
find utilities/scripts -name "* [2-9].sh" -delete 2>/dev/null

# ── Project regeneration ─────────────────────────────────────────────────
echo "→ Regenerating Pinkha.xcodeproj (xcodegen)…"
(cd app && xcodegen generate >/dev/null)
if [ -f "utilities/scripts/patch-app-icon.rb" ]; then
    ./utilities/scripts/patch-app-icon.rb >/dev/null
fi

# ── Build ─────────────────────────────────────────────────────────────────
echo "→ Building for simulator ${SIM_TARGET}…"
xcodebuild build -quiet \
    -project app/Pinkha.xcodeproj \
    -scheme Pinkha \
    -destination "id=$SIM_TARGET"

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Pinkha-*/Build/Products/Debug-iphonesimulator \
    -name "Pinkha.app" -type d 2>/dev/null | head -1)
if [[ -z "$APP_PATH" ]]; then
    echo "✗ Build succeeded but Pinkha.app not found in DerivedData." >&2
    exit 1
fi

# ── Install + launch ─────────────────────────────────────────────────────
echo "→ Installing on simulator…"
xcrun simctl install "$SIM_TARGET" "$APP_PATH"

echo "→ Launching ${BUNDLE_ID}…"
# Foreground the simulator window so the user sees the launch. On iOS 27 /
# macOS 27 the host app was renamed Simulator.app → DeviceHub.app and lives
# under Xcode.app/Contents/Applications — try DeviceHub first, fall back to
# Simulator for older Xcode installs.
if ! open -a "DeviceHub" 2>/dev/null; then
    open -a Simulator 2>/dev/null || true
fi
xcrun simctl launch "$SIM_TARGET" "$BUNDLE_ID" >/dev/null

echo "✓ Pinkha lancée sur le simulateur ${SIM_NAME_RESOLVED}."
