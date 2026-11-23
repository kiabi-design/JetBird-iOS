#!/usr/bin/env bash
# Builds the Rust SPAKE2 core and packages it as Frameworks/JetBirdSpake2.xcframework
# (static libraries for iOS device + iOS simulator, with a Clang module "CJetBirdSpake2").
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd .. && pwd)"
OUT_DIR="$ROOT_DIR/Frameworks"
XCFRAMEWORK="$OUT_DIR/JetBirdSpake2.xcframework"
LIB_NAME="libjetbird_spake2.a"

DEVICE_TARGET="aarch64-apple-ios"
SIM_TARGET="aarch64-apple-ios-sim"   # Apple Silicon simulator (the CI runner is arm64)

echo "🔨 Building jetbird-spake2 for iOS targets..."
for target in "$DEVICE_TARGET" "$SIM_TARGET"; do
    echo "  → $target"
    rustup target add "$target" >/dev/null 2>&1 || true
    cargo build --release --target "$target"
done

echo "📦 Creating XCFramework..."
rm -rf "$XCFRAMEWORK"
mkdir -p "$OUT_DIR"

# include/ holds jetbird_spake2.h and module.modulemap; xcodebuild copies both
# into every slice, so no manual post-processing is needed.
xcodebuild -create-xcframework \
    -library "target/$DEVICE_TARGET/release/$LIB_NAME" -headers include \
    -library "target/$SIM_TARGET/release/$LIB_NAME" -headers include \
    -output "$XCFRAMEWORK"

echo "✅ XCFramework created at: $XCFRAMEWORK"
find "$XCFRAMEWORK" -maxdepth 2 | sort
