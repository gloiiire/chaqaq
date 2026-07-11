#!/bin/bash
# Build + install + launch Pinkha on a booted iOS Simulator.
#
# Companion to run-on-device.sh — same flow but targets the Simulator instead
# of a physical iPhone. Useful when iterating on UI changes without unplugging
# the dev iPhone, or when you want to test a locale (env-set LANG) or a
# specific simulator (env-set SIM_NAME).
#
# Behaviour:
#   - Picks the first booted iOS simulator. Boot one ahead of time with:
#         xcrun simctl boot "iPhone 17 Pro"
#     or override with SIM_NAME / SIM_UDID env var.
#   - Falls back to "iPhone 17 Pro" (boots it) if no simulator is booted.
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
DEFAULT_SIM="iPhone 17 Pro"

# ── DEVELOPER_DIR sanity (same hardening as run-on-device.sh) ─────────────
if [[ -n "${DEVELOPER_DIR:-}" && ! -d "$DEVELOPER_DIR" ]]; then
    echo "⚠ DEVELOPER_DIR=$DEVELOPER_DIR does not exist — falling back to /Applications/Xcode.app." >&2
    unset DEVELOPER_DIR
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

# ── Simulator discovery ──────────────────────────────────────────────────
# Priority: explicit SIM_UDID > explicit SIM_NAME > first Booted > default.
if [[ -n "${SIM_UDID:-}" ]]; then
    SIM_TARGET="$SIM_UDID"
elif [[ -n "${SIM_NAME:-}" ]]; then
    SIM_TARGET=$(xcrun simctl list devices --json \
        | jq -r --arg name "$SIM_NAME" \
            '.devices | to_entries[] | .value[] | select(.name == $name) | .udid' \
        | head -1)
    if [[ -z "$SIM_TARGET" ]]; then
        echo "✗ Simulator named '$SIM_NAME' not found." >&2
        exit 1
    fi
else
    SIM_TARGET=$(xcrun simctl list devices --json \
        | jq -r '.devices | to_entries[] | .value[] | select(.state == "Booted") | .udid' \
        | head -1)
fi

if [[ -z "${SIM_TARGET:-}" ]]; then
    echo "→ No booted simulator — booting '${DEFAULT_SIM}'…"
    SIM_TARGET=$(xcrun simctl list devices --json \
        | jq -r --arg name "$DEFAULT_SIM" \
            '.devices | to_entries[] | .value[] | select(.name == $name) | .udid' \
        | head -1)
    if [[ -z "$SIM_TARGET" ]]; then
        echo "✗ Default simulator '$DEFAULT_SIM' not found in your Xcode runtimes." >&2
        echo "  Try: SIM_NAME='iPhone 16 Pro' $0" >&2
        exit 1
    fi
    xcrun simctl boot "$SIM_TARGET" 2>/dev/null || true
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
