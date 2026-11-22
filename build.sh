#!/bin/bash
# Build script for JetBird iOS
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_CORE_DIR="${PROJECT_DIR}/rust-core"
FRAMEWORKS_DIR="${PROJECT_DIR}/Frameworks"
echo "Building JetBird iOS..."
cd "$RUST_CORE_DIR"
./build.sh
echo "Copying XCFramework..."
mkdir -p "$FRAMEWORKS_DIR"
cp -R "$RUST_CORE_DIR/../Frameworks/JetBirdSpake2.xcframework" "$FRAMEWORKS_DIR/"
echo "Building Swift package..."
cd "$PROJECT_DIR"
swift build -c release --arch arm64
if [[ ! -d "JetBird.xcodeproj" ]]; then
    echo "Generating Xcode project..."
    swift package generate-xcodeproj
fi
echo "Build complete!"