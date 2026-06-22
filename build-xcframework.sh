#!/bin/bash
set -e

# Always operate from the repo root regardless of cwd. fastlane's
# `sh` action runs commands from `fastlane/`, so relative paths like
# `swift-bindings/...` would otherwise miss the actual files at
# `<repo>/swift-bindings/...`.
cd "$(dirname "$0")"

PROFILE="${1:-release}"
CARGO_FLAG="--release"
[ "$PROFILE" = "debug" ] && CARGO_FLAG=""

TARGETS=(
    "aarch64-apple-ios"
    "aarch64-apple-ios-sim"
    "aarch64-apple-darwin"
)

echo "=== pinkha XCFramework ($PROFILE) ==="

# 1. Installer les targets Rust manquantes
echo ""
echo "→ Vérification des targets Rust..."
for T in "${TARGETS[@]}"; do
    rustup target add "$T"
done

# 2. Compiler pour chaque cible
echo ""
for T in "${TARGETS[@]}"; do
    echo "→ Compilation : $T"
    cargo build $CARGO_FLAG --target "$T"
done

# 3. Préparer le dossier headers
HDR="target/xcframework-headers"
rm -rf "$HDR"
mkdir -p "$HDR"
cp swift-bindings/pinkhaFFI.h "$HDR/"
cp swift-bindings/pinkhaFFI.modulemap "$HDR/module.modulemap"

# 4. Assembler le XCFramework
OUTPUT="pinkha.xcframework"
rm -rf "$OUTPUT"

echo ""
echo "→ Assemblage du XCFramework..."
xcodebuild -create-xcframework \
    -library "target/aarch64-apple-ios/$PROFILE/libpinkha.a" \
    -headers "$HDR" \
    -library "target/aarch64-apple-ios-sim/$PROFILE/libpinkha.a" \
    -headers "$HDR" \
    -library "target/aarch64-apple-darwin/$PROFILE/libpinkha.a" \
    -headers "$HDR" \
    -output "$OUTPUT"

echo ""
echo "✓ $OUTPUT prêt — glisse-le dans ton projet Xcode."
