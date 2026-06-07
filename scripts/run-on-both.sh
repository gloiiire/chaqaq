#!/bin/bash
# Build + install + launch Pinkha on BOTH the booted iPhone simulator
# and the connected physical iPhone in one go. Used by the agent so each
# code change lands on both surfaces at once for parallel manual QA.
#
# Falls back gracefully — if either target is missing, the other still
# runs. Set DEVICE_ID / XCODE_DEVICE_ID / SIM_UDID env vars to override
# auto-detection.
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

# ── xcodegen + icon patch (idempotent, cheap) ─────────────────────────────
(cd app && xcodegen generate >/dev/null)
if [ -f "scripts/patch-app-icon.rb" ]; then
    ./scripts/patch-app-icon.rb >/dev/null
fi

# ── Simulator target ──────────────────────────────────────────────────────
SIM_UDID="${SIM_UDID:-3B5F9D7C-EAB0-4BCF-A60C-C44380EF8DF1}"
HAVE_SIM=0
if xcrun simctl list devices booted 2>/dev/null | grep -q "$SIM_UDID"; then
    HAVE_SIM=1
elif xcrun simctl list devices 2>/dev/null | grep -q "$SIM_UDID"; then
    xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
    open -a Simulator
    HAVE_SIM=1
fi

# ── Device target ─────────────────────────────────────────────────────────
DEVICE_ID="${DEVICE_ID:-$(xcrun devicectl list devices --json-output - 2>/dev/null \
    | jq -r '.result.devices[]
        | select((.connectionProperties.tunnelState == "connected"
                  or .connectionProperties.tunnelState == "disconnected")
                 and (.hardwareProperties.productType // "" | startswith("iPhone")))
        | .identifier' \
    | head -1)}"
XCODE_DEVICE_ID="${XCODE_DEVICE_ID:-$(xcodebuild -project app/Pinkha.xcodeproj \
    -scheme Pinkha -showdestinations 2>/dev/null \
    | grep 'platform:iOS,' \
    | grep -v -E 'Simulator|Placeholder|Designed for' \
    | head -1 \
    | sed -nE 's/.*id:([0-9A-Fa-f-]+).*/\1/p')}"
HAVE_DEVICE=0
[[ -n "$DEVICE_ID" && -n "$XCODE_DEVICE_ID" ]] && HAVE_DEVICE=1

if [[ $HAVE_SIM -eq 0 && $HAVE_DEVICE -eq 0 ]]; then
    echo "x No iPhone simulator booted and no iPhone device connected." >&2
    exit 1
fi

# ── Build for whichever targets are available ─────────────────────────────
if [[ $HAVE_SIM -eq 1 ]]; then
    echo "-> Building for simulator $SIM_UDID..."
    xcodebuild build -quiet \
        -project app/Pinkha.xcodeproj \
        -scheme Pinkha \
        -destination "id=$SIM_UDID"
    SIM_APP=$(find ~/Library/Developer/Xcode/DerivedData/Pinkha-*/Build/Products/Debug-iphonesimulator -name "Pinkha.app" -type d 2>/dev/null | head -1)
    if [[ -n "$SIM_APP" ]]; then
        xcrun simctl terminate "$SIM_UDID" com.gloiiire.pinkha 2>/dev/null || true
        xcrun simctl install "$SIM_UDID" "$SIM_APP"
        xcrun simctl launch "$SIM_UDID" com.gloiiire.pinkha >/dev/null
        echo "OK Launched on simulator."
    fi
fi

if [[ $HAVE_DEVICE -eq 1 ]]; then
    echo "-> Building for device $XCODE_DEVICE_ID..."
    xcodebuild build -quiet \
        -project app/Pinkha.xcodeproj \
        -scheme Pinkha \
        -destination "id=$XCODE_DEVICE_ID" \
        -allowProvisioningUpdates
    DEV_APP=$(find ~/Library/Developer/Xcode/DerivedData/Pinkha-*/Build/Products/Debug-iphoneos -name "Pinkha.app" -type d 2>/dev/null | head -1)
    if [[ -n "$DEV_APP" ]]; then
        xcrun devicectl device install app --device "$DEVICE_ID" "$DEV_APP" >/dev/null
        xcrun devicectl device process launch --device "$DEVICE_ID" com.gloiiire.pinkha >/dev/null
        echo "OK Launched on iPhone."
    fi
fi
