#!/bin/bash
# Build + install + launch Pinkha on BOTH the booted iPhone simulator
# and the connected physical iPhone in one go. Used by the agent so each
# code change lands on both surfaces at once for parallel manual QA.
#
# Falls back gracefully — if either target is missing, the other still
# runs. Set DEVICE_ID / XCODE_DEVICE_ID / SIM_UDID env vars to override
# auto-detection.
set -euo pipefail

# Anchor at the repo root regardless of where this script lives.
# Was scripts/run-on-both.sh, moved to utilities/scripts/run-on-both.sh ;
# the previous `dirname/..` shortcut landed in utilities/ instead of root.
cd "$(git rev-parse --show-toplevel)"
SCRIPTS_DIR="utilities/scripts"

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

# ── Prune iCloud Drive conflict copies ───────────────────────────────────
# Repo lives in iCloud Drive, which auto-creates "Foo 2.swift",
# "Pinkha 3.xcodeproj" etc. when sync conflicts. They confuse Xcode
# (extra projects), bloat the tree, and are explicitly excluded by
# xcodegen — but only at compile time. Sweep them every build so
# they never accumulate.
find app -name "* [2-9].swift" -delete 2>/dev/null
find app -name "* [2-9].xcodeproj" -type d -exec rm -rf {} + 2>/dev/null
find "$SCRIPTS_DIR" -name "* [2-9].sh" -delete 2>/dev/null

# ── xcodegen + icon patch (idempotent, cheap) ─────────────────────────────
(cd app && xcodegen generate >/dev/null)
if [ -f "$SCRIPTS_DIR/patch-app-icon.rb" ]; then
    "./$SCRIPTS_DIR/patch-app-icon.rb" >/dev/null
fi

# ── Simulator target ──────────────────────────────────────────────────────
# Resolved by name, not by a hardcoded UDID: UDIDs are per-machine and change
# whenever the simulator is recreated, so the literal that used to live here
# had already stopped matching any device — the sim leg silently never ran.
SIM_NAME="${SIM_NAME:-Pinkha SIM}"
SIM_UDID="${SIM_UDID:-$(xcrun simctl list devices --json \
    | jq -r --arg name "$SIM_NAME" \
        '.devices | to_entries[] | .value[] | select(.name == $name) | .udid' \
    | head -1)}"
HAVE_SIM=0
if [[ -z "$SIM_UDID" ]]; then
    echo "⚠ No simulator named '$SIM_NAME' — skipping the simulator leg." >&2
elif xcrun simctl list devices booted 2>/dev/null | grep -q "$SIM_UDID"; then
    HAVE_SIM=1
elif xcrun simctl list devices 2>/dev/null | grep -q "$SIM_UDID"; then
    xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
    # iOS 27 / macOS 27 renamed Simulator.app → DeviceHub.app. Try the new
    # name first, fall back to Simulator for older Xcode installs.
    if ! open -a "DeviceHub" 2>/dev/null; then
        open -a Simulator 2>/dev/null || true
    fi
    # Block until the sim is fully booted — otherwise the install/launch
    # calls below race the boot and fail with "Unable to lookup in current
    # state: Shutdown" (code 405) on cold start.
    xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1 || true
    HAVE_SIM=1
fi

# ── Device target ─────────────────────────────────────────────────────────
# `reality == "physical"` : devicectl liste aussi les SIMULATEURS, et un
# simulateur d'iPhone a un `productType` commençant par "iPhone". Sans ce
# filtre, `head -1` peut rendre un simulateur et l'install échoue sur
# « Install Application is not supported by this device » — un message qui
# fait chercher du côté de l'appairage alors que la cible n'est pas un
# appareil. Ce script duplique la résolution de run-on-device.sh : toute
# correction ici doit être reportée là-bas, et inversement.
DEVICE_ID="${DEVICE_ID:-$(xcrun devicectl list devices --json-output - 2>/dev/null \
    | jq -r '.result.devices[]
        | select((.connectionProperties.tunnelState == "connected"
                  or .connectionProperties.tunnelState == "disconnected")
                 and (.hardwareProperties.reality == "physical")
                 and (.hardwareProperties.productType // "" | startswith("iPhone")))
        | .identifier' \
    | head -1)}"
XCODE_DEVICE_ID="${XCODE_DEVICE_ID:-$(xcodebuild -project app/Pinkha.xcodeproj \
    -scheme Pinkha -showdestinations 2>/dev/null \
    | grep 'platform:iOS,' \
    | grep -v -E 'Simulator|Placeholder|Designed for' \
    | head -1 \
    | sed -nE 's/.*id:([0-9A-Fa-f-]+).*/\1/p' \
    || true)}"
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

    SIM_APP=$(resolve_app_path "id=$SIM_UDID" || true)
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
    DEV_APP=$(resolve_app_path "id=$DEVICE_ID" || true)
    if [[ -n "$DEV_APP" ]]; then
        xcrun devicectl device install app --device "$DEVICE_ID" "$DEV_APP" >/dev/null
        xcrun devicectl device process launch --device "$DEVICE_ID" com.gloiiire.pinkha >/dev/null
        echo "OK Launched on iPhone."
    fi
fi
