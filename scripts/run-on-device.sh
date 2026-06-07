#!/bin/bash
# Build + install + launch Pinkha on the connected iPhone.
# Equivalent of pressing Cmd+R in Xcode but driven from the CLI so an agent
# can run it without IDE focus. Use after any change that touches Swift or
# the XCFramework — the Rust-only `cargo test` doesn't tell you whether the
# app actually launches.
#
# Two device IDs in play (one for Xcode, one for devicectl) — both extracted
# automatically. Override with $DEVICE_ID / $XCODE_DEVICE_ID env vars when
# more than one iPhone is connected.
set -euo pipefail

cd "$(dirname "$0")/.."

# ── DEVELOPER_DIR sanity ──────────────────────────────────────────────────
# If the caller's shell has DEVELOPER_DIR pointing somewhere that doesn't
# exist (Xcode-beta uninstalled, agents inheriting a stale value from a
# parent process), every `xcrun` call crashes with `missing DEVELOPER_DIR
# path` and the script silently falls back to "no device found". Detect
# + recover so the script works regardless of the calling env.
if [[ -n "${DEVELOPER_DIR:-}" && ! -d "$DEVELOPER_DIR" ]]; then
    echo "⚠ DEVELOPER_DIR=$DEVELOPER_DIR does not exist — falling back to /Applications/Xcode.app." >&2
    unset DEVELOPER_DIR
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# ── Device discovery ──────────────────────────────────────────────────────────
# devicectl uses CoreDevice UUIDs; xcodebuild needs the Apple Mobile Device ID
# (hardware-serial-derived). They look identical at a glance but aren't
# interchangeable.

DEVICE_ID="${DEVICE_ID:-$(xcrun devicectl list devices --json-output - 2>/dev/null \
    | jq -r '.result.devices[]
        | select((.connectionProperties.tunnelState == "connected"
                  or .connectionProperties.tunnelState == "disconnected")
                 and (.hardwareProperties.productType // "" | startswith("iPhone")))
        | .identifier' \
    | head -1)}"
if [[ -z "$DEVICE_ID" ]]; then
    echo "✗ No connected iPhone found (xcrun devicectl)." >&2
    exit 1
fi

# xcodebuild -showdestinations prints `id:UUID` somewhere in each line. We
# match the iOS-platform line that does NOT mention Simulator/Placeholder/
# Designed for (the latter is the "Mac Designed for iPad" variant) and pull
# the UUID with a strict regex — pure regex avoids field-count issues caused
# by emojis in device names.
XCODE_DEVICE_ID="${XCODE_DEVICE_ID:-$(xcodebuild -project app/Pinkha.xcodeproj \
    -scheme Pinkha -showdestinations 2>/dev/null \
    | grep 'platform:iOS,' \
    | grep -v -E 'Simulator|Placeholder|Designed for' \
    | head -1 \
    | sed -nE 's/.*id:([0-9A-Fa-f-]+).*/\1/p')}"
if [[ -z "$XCODE_DEVICE_ID" ]]; then
    echo "✗ No xcodebuild-side iPhone destination found." >&2
    exit 1
fi

echo "→ Regenerating Pinkha.xcodeproj (xcodegen)…"
(cd app && xcodegen generate >/dev/null)

# xcodegen doesn't register the .icon bundle with the wrapper.icon file
# type that actool expects. The Ruby patch redoes that step idempotently.
if [ -f "scripts/patch-app-icon.rb" ]; then
    ./scripts/patch-app-icon.rb >/dev/null
fi

echo "→ Building for device ${XCODE_DEVICE_ID}…"
xcodebuild build -quiet \
    -project app/Pinkha.xcodeproj \
    -scheme Pinkha \
    -destination "id=$XCODE_DEVICE_ID" \
    -allowProvisioningUpdates

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Pinkha-*/Build/Products/Debug-iphoneos -name "Pinkha.app" -type d 2>/dev/null | head -1)
if [[ -z "$APP_PATH" ]]; then
    echo "✗ Build succeeded but Pinkha.app not found in DerivedData." >&2
    exit 1
fi

echo "→ Installing on device ${DEVICE_ID}…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" >/dev/null

echo "→ Launching com.gloiiire.pinkha…"
xcrun devicectl device process launch --device "$DEVICE_ID" com.gloiiire.pinkha >/dev/null

echo "✓ Pinkha lancée sur l'iPhone."
