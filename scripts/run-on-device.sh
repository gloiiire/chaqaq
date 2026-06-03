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

# ── Device discovery ──────────────────────────────────────────────────────────
# devicectl uses CoreDevice UUIDs; xcodebuild needs the Apple Mobile Device ID
# (hardware-serial-derived). They look identical at a glance but aren't
# interchangeable.

DEVICE_ID="${DEVICE_ID:-$(xcrun devicectl list devices 2>/dev/null \
    | awk '/iPhone.*connected /{print $(NF-3); exit}')}"
if [[ -z "$DEVICE_ID" ]]; then
    echo "✗ No connected iPhone found (xcrun devicectl)." >&2
    exit 1
fi

XCODE_DEVICE_ID="${XCODE_DEVICE_ID:-$(xcodebuild -project app/Pinkha.xcodeproj \
    -scheme Pinkha -showdestinations 2>/dev/null \
    | awk -F'id:' '/platform:iOS,.*name:iPhone/ && !/Simulator|Placeholder/ {split($2,a,","); gsub(/[ ]/,"",a[1]); print a[1]; exit}')}"
if [[ -z "$XCODE_DEVICE_ID" ]]; then
    echo "✗ No xcodebuild-side iPhone destination found." >&2
    exit 1
fi

echo "→ Regenerating Pinkha.xcodeproj (xcodegen)…"
(cd app && xcodegen generate >/dev/null)

echo "→ Building for device $XCODE_DEVICE_ID…"
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

echo "→ Installing on device $DEVICE_ID…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" >/dev/null

echo "→ Launching com.gloiiire.pinkha…"
xcrun devicectl device process launch --device "$DEVICE_ID" com.gloiiire.pinkha >/dev/null

echo "✓ Pinkha lancée sur l'iPhone."
