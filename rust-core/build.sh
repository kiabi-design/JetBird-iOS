#!/bin/bash
# Build script for jetbird-spake2 Rust core
# Produces .xcframework for iOS integration

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${PROJECT_DIR}/../Frameworks"
CARGO_TARGET_DIR="${PROJECT_DIR}/target"

# Targets - only one simulator target (Apple Silicon macOS runners use arm64 sim)
IOS_TARGETS=(
    "aarch64-apple-ios"           # iOS devices
    "aarch64-apple-ios-sim"       # iOS Simulator (Apple Silicon)
    # "x86_64-apple-ios"          # iOS Simulator (Intel) - skipped: equivalent to arm64 sim on Apple Silicon runners
)

echo "🔨 Building jetbird-spake2 for iOS targets..."

# Install targets if needed
for target in "${IOS_TARGETS[@]}"; do
    rustup target add "$target" 2>/dev/null || true
done

# Build for each target
for target in "${IOS_TARGETS[@]}"; do
    echo "  → Building for $target..."
    cargo build --release --target "$target" --manifest-path "${PROJECT_DIR}/Cargo.toml"
done

# Create XCFramework
echo "📦 Creating XCFramework..."
mkdir -p "$OUTPUT_DIR"

# Find the built static libraries
LIBS=()
for target in "${IOS_TARGETS[@]}"; do
    LIB_PATH="${CARGO_TARGET_DIR}/${target}/release/libjetbird_spake2.a"
    if [[ -f "$LIB_PATH" ]]; then
        LIBS+=("-library" "$LIB_PATH" "-headers" "${PROJECT_DIR}/include")
    else
        echo "⚠️  Warning: $LIB_PATH not found"
    fi
done

if [[ ${#LIBS[@]} -eq 0 ]]; then
    echo "❌ No libraries found!"
    exit 1
fi

# Create the XCFramework
xcodebuild -create-xcframework \
    "${LIBS[@]}" \
    -output "$OUTPUT_DIR/JetBirdSpake2.xcframework"

echo "✅ XCFramework created at: $OUTPUT_DIR/JetBirdSpake2.xcframework"

# Generate modulemap
cat > "$OUTPUT_DIR/JetBirdSpake2.xcframework/ios-arm64/Headers/module.modulemap" << 'EOF'
framework module JetBirdSpake2 {
    umbrella header "jetbird_spake2.h"
    export *
    module * { export * }
}
EOF

# Copy modulemap to all architectures (only arm64 + arm64-simulator now)
for arch in ios-arm64 ios-arm64-simulator; do
    if [[ -d "$OUTPUT_DIR/JetBirdSpake2.xcframework/$arch/Headers" ]]; then
        cp "$OUTPUT_DIR/JetBirdSpake2.xcframework/ios-arm64/Headers/module.modulemap" \
           "$OUTPUT_DIR/JetBirdSpake2.xcframework/$arch/Headers/"
    fi
done

echo "🎉 Done! Add $OUTPUT_DIR/JetBirdSpake2.xcframework to your Xcode project"