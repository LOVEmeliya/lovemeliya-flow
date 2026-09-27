#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
# Keep the builder's personal filesystem paths out of distributed binaries.
BUILD_FLAGS=(-Xswiftc -file-prefix-map -Xswiftc "$PROJECT_ROOT=."
             -Xswiftc -debug-prefix-map -Xswiftc "$PROJECT_ROOT=."
             -Xcc "-ffile-prefix-map=$PROJECT_ROOT=."
             -Xcc "-fdebug-prefix-map=$PROJECT_ROOT=.")
swift build -c release "${BUILD_FLAGS[@]}" --product MediaFlow
swift build -c release "${BUILD_FLAGS[@]}" --product lovemeliya-flow-mcp
BINARY_DIR="$(swift build -c release --show-bin-path)"
APP="$PROJECT_ROOT/dist/LOVEmeliya Flow.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY_DIR/MediaFlow" "$APP/Contents/MacOS/MediaFlow"
cp "$BINARY_DIR/lovemeliya-flow-mcp" "$APP/Contents/MacOS/lovemeliya-flow-mcp"
cp App/Info.plist "$APP/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/LICENSES"
cp -R LICENSES/. "$APP/Contents/Resources/LICENSES/"
swift scripts/generate-icon.swift "$PROJECT_ROOT/dist/AppIcon.iconset"
iconutil -c icns "$PROJECT_ROOT/dist/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
strip -S "$APP/Contents/MacOS/MediaFlow" "$APP/Contents/MacOS/lovemeliya-flow-mcp"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built: %s\n' "$APP"
