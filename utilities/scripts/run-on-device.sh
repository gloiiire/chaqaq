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

# Prune iCloud Drive conflict copies before regenerating — repo lives
# in iCloud which auto-creates "Foo 2.swift", "Pinkha 3.xcodeproj" etc.
# on sync conflicts. They confuse Xcode and bloat the tree.
find app -name "* [2-9].swift" -delete 2>/dev/null
find app -name "* [2-9].xcodeproj" -type d -exec rm -rf {} + 2>/dev/null
find scripts -name "* [2-9].sh" -delete 2>/dev/null

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

# ── Résolution du .app ────────────────────────────────────────────────────
# Demander le chemin à xcodebuild plutôt que de fouiller DerivedData.
#
# `find DerivedData/Pinkha-*/... | head -1` paraît inoffensif tant qu'il n'y a
# qu'un dossier. Dès qu'il y en a deux — ce qui arrive dès qu'un chemin de
# projet change, y compris via une resync iCloud — `find` rend l'ordre du
# système de fichiers, pas le plus récent. On installe alors silencieusement
# un binaire périmé : le build réussit, l'app se lance, et le code qu'on vient
# d'écrire n'est pas dedans. Le symptôme est indiscernable d'un changement qui
# ne fonctionne pas, et fait conclure faux.
resolve_app_path() {
    local destination="$1" products_dir
    products_dir=$(xcodebuild -project app/Pinkha.xcodeproj -scheme Pinkha \
        -destination "$destination" -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
    [ -n "$products_dir" ] && [ -d "$products_dir/Pinkha.app" ] || return 1
    printf '%s\n' "$products_dir/Pinkha.app"
}

APP_PATH=$(resolve_app_path "id=$DEVICE_ID" || true)
if [[ -z "$APP_PATH" ]]; then
    echo "✗ Build succeeded but Pinkha.app not found in DerivedData." >&2
    exit 1
fi

echo "→ Installing on device ${DEVICE_ID}…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" >/dev/null

echo "→ Launching com.gloiiire.pinkha…"
xcrun devicectl device process launch --device "$DEVICE_ID" com.gloiiire.pinkha >/dev/null

echo "✓ Pinkha lancée sur l'iPhone."
